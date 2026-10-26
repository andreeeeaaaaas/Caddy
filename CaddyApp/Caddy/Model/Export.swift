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
    /// The project, the video's file name and the date.
    var subtitle: String
    var options: ExportOptions
    var sections: [ExportSection]

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
    var frame: ExportFrame?
    /// Every element, scene descriptions included, in the order it happens.
    var script: [ExportLine]
}

nonisolated struct ExportLine: Sendable {
    var label: String
    var text: RichText
}

/// A section's frame as JPEG data.
nonisolated struct ExportFrame: Sendable {
    var jpeg: Data
    var width: Int
    var height: Int

    /// Height for a given width, keeping the frame's shape.
    func height(forWidth width: Double) -> Double {
        self.width > 0 ? width * Double(height) / Double(self.width) : width * 9 / 16
    }
}

nonisolated enum Exporter {
    /// Lays out the rows, without frames. Empty elements are left out, and
    /// scene descriptions and suggestions unless the options include them.
    static func document(title: String, subtitle: String, rows: [ScriptRow], fps: Double, options: ExportOptions) -> ExportDocument {
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
        return ExportDocument(title: title, subtitle: subtitle, options: options, sections: sections)
    }

    /// Grabs each section's frame from the video. Frames it can't grab are left out.
    @concurrent
    static func frames(from videoURL: URL, at times: [Double]) async -> [Double: ExportFrame] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: videoURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 720)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var frames: [Double: ExportFrame] = [:]
        for time in times {
            guard !Task.isCancelled else { break }
            let cmTime = CMTime(seconds: time + Playback.frameNudge, preferredTimescale: 600_000)
            guard let (image, _) = try? await generator.image(at: cmTime), let jpeg = jpeg(image) else { continue }
            frames[time] = ExportFrame(jpeg: jpeg, width: image.width, height: image.height)
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
