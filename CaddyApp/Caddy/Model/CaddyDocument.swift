import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let caddyDocument = UTType(exportedAs: "andreasthoma.caddy.document")
}

/// One ad's script, saved as a `.caddy` package holding `script.json`.
/// The video is referenced by path, not copied in (BRD section 6).
nonisolated struct CaddyDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.caddyDocument]

    var script: Script

    init(script: Script = Script()) {
        self.script = script
    }

    init(videoURL: URL) {
        script = Script(videoPath: videoURL.path)
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.fileWrappers?["script.json"]?.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        script = try JSONDecoder().decode(Script.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let json = FileWrapper(regularFileWithContents: try encoder.encode(script))
        return FileWrapper(directoryWithFileWrappers: ["script.json": json])
    }
}

nonisolated struct Script: Codable, Equatable {
    var videoPath: String?
    var rows: [ScriptRow] = []
    /// Set once analysis has run, so reopening a document doesn't redo it.
    var analysed = false
    /// Per-frame scores, kept so sensitivity changes don't need another decode.
    var sceneScores: [SceneScore]?
    /// Optional so documents saved before it existed still open.
    var sceneSensitivity: Double?
    var transcript: [TranscriptWord]?
    var screenText: [ScreenText]?

    var sensitivity: Double {
        get { sceneSensitivity ?? SceneDetector.defaultSensitivity }
        set { sceneSensitivity = newValue }
    }

    var videoURL: URL? { videoPath.map { URL(filePath: $0) } }
}

nonisolated struct ScriptRow: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        /// Proposed by analysis; not in the script until accepted.
        case suggested
        case pending
        case checked
    }

    var id = UUID()
    var time: Double
    var vo = ""
    var supers = ""
    var jingle = ""
    var graphics = ""
    var notes = ""
    var status: Status = .pending
}

nonisolated enum Timecode {
    /// `HH:MM:SS`
    static func short(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    }

    /// `HH:MM:SS:FF`
    static func full(_ seconds: Double, fps: Double) -> String {
        let s = seconds.isFinite ? max(0, seconds) : 0
        let frame = Int((s - s.rounded(.down)) * fps)
        return short(s) + String(format: ":%02d", frame)
    }

    /// `M:SS`
    static func compact(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}

extension Script {
    /// Rows from the Figma wireframes, for previews.
    static let sample = Script(rows: [
        ScriptRow(time: 0, vo: "Summer's here, and so are the savings.", supers: "SUMMER SALE", notes: "Open on beach, WS", status: .checked),
        ScriptRow(time: 3, vo: "Up to 40% off everything in store.", supers: "UP TO 40% OFF*", status: .checked),
        ScriptRow(time: 7, vo: "Including the brands you love.", status: .suggested),
        ScriptRow(time: 11, vo: "But be quick.", supers: "ENDS SUNDAY", graphics: "Pack shot, logo lock-up", notes: "Product hero"),
        ScriptRow(time: 15, supers: "*Conditions apply. See website for details.", notes: "Hold disclaimer 3s", status: .checked),
        ScriptRow(time: 24, vo: "Shop now, online and in store.", supers: "LOGO + URL", notes: "End frame", status: .checked),
    ], analysed: true)
}
