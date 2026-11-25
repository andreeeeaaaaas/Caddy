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
    /// The element types to export, every one to start with.
    var kinds = Set(ScriptElement.Kind.allCases)
    var includeSuggestions = true
}

/// A script laid out for export in the frog CAD script template: a table
/// with #, Frame and Script columns and one row per section.
nonisolated struct ExportDocument: Sendable {
    /// The asset name, as typed in the export sheet.
    var title: String
    /// The client, as typed in the export sheet; empty for none.
    var client: String
    /// The day of the export.
    var date: Date
    var options: ExportOptions
    var sections: [ExportSection]

    /// The day of the export, as the template has it: 26 Oct 2026.
    var dateText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "dd MMM yyyy"
        return formatter.string(from: date)
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

/// A section's frame as a JPEG.
nonisolated struct ExportImage: Sendable {
    var data: Data
    var width: Int
    var height: Int

    /// Height for a given width, keeping the image's shape.
    func height(forWidth width: Double) -> Double {
        self.width > 0 ? width * Double(height) / Double(self.width) : width * 9 / 16
    }
}

nonisolated enum Exporter {
    /// Lays out the rows, without frames. Empty elements are left out, and
    /// types and suggestions unless the options include them.
    static func document(title: String, client: String, date: Date, rows: [ScriptRow], fps: Double,
                         options: ExportOptions) -> ExportDocument {
        let sections = rows.map { row in
            let elements = row.elements.filter { element in
                !element.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && (options.includeSuggestions || !element.isSuggested)
                    && options.kinds.contains(element.kind)
            }
            return ExportSection(
                time: row.time,
                timecode: Timecode.full(row.time, fps: fps),
                script: elements.map { ExportLine(label: $0.kind.exportLabel, text: $0.richText) }
            )
        }
        return ExportDocument(title: title, client: client, date: date, options: options, sections: sections)
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
