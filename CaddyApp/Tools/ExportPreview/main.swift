import AppKit
import AVFoundation
import PDFKit

// Writes a library script's Word export the way the export sheet does, so the
// writer can be tried without relaunching the app. Built and run by
// `CaddyApp/Tools/export-preview.sh`, which also renders the result.
//
//   ExportPreview docx <name> <out.docx>   a library script, matched by name
//   ExportPreview png <in.pdf> <out.png>   every page side by side

let arguments = CommandLine.arguments.dropFirst()

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    exit(1)
}

struct LibraryIndex: Decodable {
    struct Project: Decodable { var id: UUID; var name: String }
    struct Entry: Decodable { var id: UUID; var name: String; var projectID: UUID?; var modified: Date }
    var projects: [Project]
    var scripts: [Entry]
}

func writeDocx(matching query: String, to output: URL) async {
    let folder = URL.applicationSupportDirectory.appending(path: "Caddy")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let data = try? Data(contentsOf: folder.appending(path: "library.json")),
          let library = try? decoder.decode(LibraryIndex.self, from: data) else { fail("Couldn't read the library.") }
    let matches = library.scripts
        .filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }
        .sorted { $0.modified > $1.modified }
    guard let entry = matches.first else { fail("No script matches \"\(query)\".") }
    let script: Script
    do {
        script = try Script.read(from: folder.appending(path: "Scripts/\(entry.id).caddy"))
    } catch {
        fail("Couldn't open \(entry.name): \(error)")
    }

    var fps = 25.0
    if let videoURL = script.videoURL,
       let track = try? await AVURLAsset(url: videoURL).loadTracks(withMediaType: .video).first,
       let rate = try? await track.load(.nominalFrameRate), rate > 0 {
        fps = Double(rate)
    }
    let project = library.projects.first { $0.id == entry.projectID }?.name ?? ""
    let details = script.videoURL?.deletingPathExtension().lastPathComponent ?? ""
    var document = Exporter.document(title: entry.name, folder: project, details: details,
                                     rows: script.rows, fps: fps, options: ExportOptions())
    // The asset catalog isn't built into this tool, so the logo comes from its SVG.
    let svg = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../Caddy/Assets.xcassets/FrogLogo.imageset/frog-logo.svg")
    document.logo = Exporter.logo(NSImage(contentsOf: svg))
    if let videoURL = script.videoURL {
        let frames = await Exporter.frames(from: videoURL, at: document.sections.map(\.time))
        for index in document.sections.indices {
            document.sections[index].frame = frames[document.sections[index].time]
        }
    }
    do {
        try DocxWriter.data(for: document).write(to: output, options: .atomic)
    } catch {
        fail("Couldn't write \(output.path): \(error)")
    }
    print("\(entry.name): \(document.sections.count) sections")
}

/// Renders every page at 1.5×, side by side with a grey gap, onto one PNG.
func writeContactSheet(from pdf: URL, to output: URL) {
    guard let document = PDFDocument(url: pdf), document.pageCount > 0 else { fail("Couldn't read \(pdf.path).") }
    let scale = 1.5, gap = 24.0
    let pages = (0..<document.pageCount).compactMap { document.page(at: $0) }
    let sizes = pages.map { $0.bounds(for: .mediaBox).size }
    let width = sizes.reduce(gap) { $0 + $1.width * scale + gap }
    let height = (sizes.map(\.height).max() ?? 0) * scale + gap * 2
    guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fail("Couldn't draw.") }
    context.setFillColor(gray: 0.85, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    var x = gap
    for (page, size) in zip(pages, sizes) {
        let rect = CGRect(x: x, y: height - gap - size.height * scale, width: size.width * scale, height: size.height * scale)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(rect)
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.minY)
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        x += rect.width + gap
    }
    guard let image = context.makeImage(),
          let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { fail("Couldn't draw.") }
    do {
        try png.write(to: output, options: .atomic)
    } catch {
        fail("Couldn't write \(output.path): \(error)")
    }
}

switch (arguments.first, arguments.count) {
case ("docx", 3):
    await writeDocx(matching: arguments[arguments.startIndex + 1], to: URL(filePath: arguments[arguments.startIndex + 2]))
case ("png", 3):
    writeContactSheet(from: URL(filePath: arguments[arguments.startIndex + 1]), to: URL(filePath: arguments[arguments.startIndex + 2]))
default:
    fail("Usage: ExportPreview docx <name> <out.docx> | png <in.pdf> <out.png>")
}
