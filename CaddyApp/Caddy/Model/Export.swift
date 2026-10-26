import AppKit
import AVFoundation
import ImageIO
import UniformTypeIdentifiers

/// What goes into an exported script, chosen in the export sheet.
nonisolated struct ExportOptions: Sendable {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case docx = "Word (.docx)"
        case pdf = "PDF"
        var id: Self { self }

        var fileExtension: String {
            switch self {
            case .docx: "docx"
            case .pdf: "pdf"
            }
        }

        var contentType: UTType {
            switch self {
            case .docx: UTType(filenameExtension: "docx") ?? .data
            case .pdf: .pdf
            }
        }
    }

    var format = Format.docx
    var includeThumbnails = true
    var includeSceneDescriptions = true
    var includeSuggestions = true
}

/// A script laid out for export: the frog CAD script template, a table with
/// Frame and Script columns and one row per section.
nonisolated struct ExportDocument: Sendable {
    var title: String
    /// The script's folder, if it's in one.
    var folder: String
    /// The video's file name and the date.
    var details: String
    var options: ExportOptions
    var sections: [ExportSection]
    /// The frog logo, set in the bottom right of every page.
    var logo: ExportImage?

    /// The folder and details on one line.
    var subtitle: String {
        [folder, details].filter { !$0.isEmpty }.joined(separator: "  ·  ")
    }

    var columns: [ExportColumn] {
        options.includeThumbnails ? [.frame, .script] : [.script]
    }

    /// Column widths in points, across the 7.5" between US Letter's 0.5" margins.
    func width(of column: ExportColumn) -> Double {
        switch column {
        case .frame: 2.8 * 72
        case .script: options.includeThumbnails ? 4.7 * 72 : 7.5 * 72
        }
    }
}

nonisolated enum ExportColumn: CaseIterable, Sendable {
    case frame, script

    var title: String {
        switch self {
        case .frame: "FRAME"
        case .script: "SCRIPT"
        }
    }
}

nonisolated struct ExportSection: Sendable {
    var time: Double
    var timecode: String
    var frame: ExportImage?
    /// Every element, scene descriptions included, in the order it happens.
    var script: [ExportLine]
}

nonisolated struct ExportLine: Sendable {
    var label: String
    var text: RichText
}

/// A section's frame as a JPEG, or the logo as a PNG.
nonisolated struct ExportImage: Sendable {
    enum Format: String, Sendable {
        case jpeg, png
    }

    var data: Data
    var format = Format.jpeg
    var width: Int
    var height: Int

    /// Height for a given width, keeping the image's shape.
    func height(forWidth width: Double) -> Double {
        self.width > 0 ? width * Double(height) / Double(self.width) : width * 9 / 16
    }
}

nonisolated enum Exporter {
    /// Lays out the rows, without frames. Empty elements are left out, and
    /// scene descriptions and suggestions unless the options include them.
    static func document(title: String, folder: String, details: String, rows: [ScriptRow], fps: Double, options: ExportOptions) -> ExportDocument {
        let sections = rows.map { row in
            let elements = row.elements.filter { element in
                !element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (options.includeSuggestions || !element.isSuggested)
                    && (options.includeSceneDescriptions || element.kind != .scene)
            }
            return ExportSection(
                time: row.time,
                timecode: Timecode.full(row.time, fps: fps),
                script: elements.map { ExportLine(label: $0.kind.exportLabel, text: $0.richText) }
            )
        }
        return ExportDocument(title: title, folder: folder, details: details, options: options, sections: sections)
    }

    /// The frog logo as a PNG in Apple's secondary grey, `points` wide at 4×.
    @MainActor
    static func logo(_ image: NSImage? = NSImage(named: "FrogLogo"), points: Double = 30) -> ExportImage? {
        guard let image, image.size.width > 0 else { return nil }
        let width = Int(points * 4)
        let height = Int((points * image.size.height / image.size.width * 4).rounded())
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = context
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        image.draw(in: rect)
        // Tints the logo's shape, keeping its holes clear.
        NSColor(srgbRed: 0x86 / 255, green: 0x86 / 255, blue: 0x8B / 255, alpha: 1).set()
        rect.fill(using: .sourceAtop)
        context.flushGraphics()
        NSGraphicsContext.current = previous
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return ExportImage(data: png, format: .png, width: width, height: height)
    }

    /// Grabs each section's frame from the video. Frames it can't grab are left out.
    @concurrent
    static func frames(from videoURL: URL, at times: [Double]) async -> [Double: ExportImage] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [Double: ExportImage] = [:]
        for time in times {
            guard !Task.isCancelled else { break }
            let cmTime = CMTime(seconds: time + Playback.frameNudge, preferredTimescale: 600_000)
            guard let (image, _) = try? await generator.image(at: cmTime), let jpeg = jpeg(image) else { continue }
            frames[time] = ExportImage(data: jpeg, width: image.width, height: image.height)
        }
        return frames
    }

    private static func jpeg(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}

extension ScriptElement.Kind {
    /// The label an exported line starts with.
    nonisolated var exportLabel: String {
        switch self {
        case .scene: "SCENE"
        case .voiceover: "VO"
        case .superText: "SUPER"
        case .sfx: "SFX"
        case .music: "MUSIC"
        case .disclaimer: "DISCLAIMER"
        }
    }
}

extension RichText {
    /// The text cut into runs that share a style, for writers that need them.
    nonisolated var runs: [(text: String, bold: Bool, italic: Bool, underline: Bool)] {
        let characters = Array(text)
        var flags = Array(repeating: (bold: false, italic: false, underline: false), count: characters.count)
        for style in styles where style.start >= 0 && style.length > 0 {
            for index in style.start..<min(style.start + style.length, characters.count) {
                if style.bold { flags[index].bold = true }
                if style.italic { flags[index].italic = true }
                if style.underline { flags[index].underline = true }
            }
        }
        var runs: [(text: String, bold: Bool, italic: Bool, underline: Bool)] = []
        for (character, flag) in zip(characters, flags) {
            if let last = runs.last, last.bold == flag.bold, last.italic == flag.italic, last.underline == flag.underline {
                runs[runs.count - 1].text.append(character)
            } else {
                runs.append((String(character), flag.bold, flag.italic, flag.underline))
            }
        }
        return runs
    }
}
