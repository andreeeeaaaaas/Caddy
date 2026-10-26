import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    nonisolated static let caddyDocument = UTType(exportedAs: "andreasthoma.caddy.document")
}

/// One ad's script. Saved as a `.caddy` package holding `script.json`, one per
/// script in the library. The video is referenced by path, not copied in.
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
    /// Set once every section has its scene description, so one the user deletes
    /// doesn't come back. Nil in documents from before sections had one. Keeps
    /// its name from when scene descriptions were notes, since it's saved.
    var hasFrameNotes: Bool? = true

    var sensitivity: Double {
        get { sceneSensitivity ?? SceneDetector.defaultSensitivity }
        set { sceneSensitivity = newValue }
    }

    var videoURL: URL? { videoPath.map { URL(filePath: $0) } }

    static let fileName = "script.json"

    /// Reads a `.caddy` package.
    static func read(from package: URL) throws -> Script {
        let data = try Data(contentsOf: package.appending(path: fileName))
        var script = try JSONDecoder().decode(Script.self, from: data)
        script.addSceneDescriptions()
        return script
    }

    /// Writes a `.caddy` package, creating it if needed.
    func write(to package: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try data.write(to: package.appending(path: Self.fileName), options: .atomic)
    }

    /// Gives each section without a scene description an empty one at the top,
    /// once, for documents from before every section started with one.
    mutating func addSceneDescriptions() {
        guard hasFrameNotes != true else { return }
        for index in rows.indices where !rows[index].elements.contains(where: { $0.kind == .scene }) {
            rows[index].elements.insert(.emptyScene(), at: 0)
        }
        hasFrameNotes = true
    }
}

/// One section of the ad: from its time to the next section's. Holds the
/// script elements written or suggested for it.
nonisolated struct ScriptRow: Identifiable, Codable, Equatable {
    enum Status: String, Codable {
        /// From scene detection and untouched, so a sensitivity change can
        /// replace it. Shown like any other section.
        case detected = "suggested"
        case pending
        /// From documents saved while sections could be marked as checked.
        case checked
    }

    var id = UUID()
    var time: Double
    var status: Status = .pending
    var elements: [ScriptElement] = []
    /// Suggestions the user dismissed, so analysis doesn't offer them again.
    var dismissed: [String] = []

    /// A new section starts with an empty scene description.
    init(id: UUID = UUID(), time: Double, status: Status = .pending, elements: [ScriptElement] = [.emptyScene()]) {
        self.id = id
        self.time = time
        self.status = status
        self.elements = elements
    }

    var suggestionCount: Int {
        elements.filter(\.isSuggested).count
    }

    /// Whether the user has accepted or written anything: more than suggestions
    /// and the empty scene description every section starts with.
    var hasUserContent: Bool {
        elements.contains { !$0.isSuggested && !$0.isEmptyScene }
    }

    /// Confirms a suggestion.
    mutating func accept(_ id: ScriptElement.ID) {
        if let index = elements.firstIndex(where: { $0.id == id }) { elements[index].source = nil }
    }

    mutating func acceptAll() {
        for index in elements.indices { elements[index].source = nil }
    }

    /// Changes an element's type, keeping its text and place. Accepts a suggestion.
    mutating func change(_ id: ScriptElement.ID, to kind: ScriptElement.Kind) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].kind = kind
        elements[index].source = nil
    }

    /// Puts a copy under the element. Duplicating a suggestion accepts it, or
    /// the accepted copy would stop analysis offering the original.
    mutating func duplicate(_ id: ScriptElement.ID) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        elements[index].source = nil
        var copy = ScriptElement(kind: elements[index].kind, text: elements[index].text)
        copy.styles = elements[index].styles
        elements.insert(copy, at: index + 1)
    }

    /// Deletes an element. A dismissed suggestion isn't offered again.
    mutating func remove(_ id: ScriptElement.ID) {
        guard let index = elements.firstIndex(where: { $0.id == id }) else { return }
        let element = elements.remove(at: index)
        if element.isSuggested { dismissed.append(element.text) }
    }

    /// Adds an element after the others of its kind, keeping kinds in their usual order.
    mutating func insert(_ element: ScriptElement) {
        let order = ScriptElement.Kind.allCases
        let rank = order.firstIndex(of: element.kind) ?? 0
        let index = elements.firstIndex { (order.firstIndex(of: $0.kind) ?? 0) > rank } ?? elements.count
        elements.insert(element, at: index)
    }

    /// Replaces this section's suggestions of one kind from analysis. Texts the
    /// user has dismissed, or accepted as any kind (so a super changed to a
    /// disclaimer stays put), aren't offered again. With `exclusive` none are
    /// offered once the user has any element of that kind.
    mutating func suggest(_ texts: [String], kind: ScriptElement.Kind, source: ScriptElement.Source, exclusive: Bool = false) {
        let accepted = elements.filter { $0.kind == kind && !$0.isSuggested }
        let fresh = exclusive && !accepted.isEmpty ? [] : texts.filter { text in
            !text.isEmpty && !dismissed.contains(text) && !elements.contains { !$0.isSuggested && $0.text == text }
        }
        let current = elements.filter { $0.kind == kind && $0.source == source }
        guard current.map(\.text) != fresh else { return }
        // Keep the IDs of suggestions that didn't change, so focus and hover survive.
        let new = fresh.map { text in current.first { $0.text == text } ?? ScriptElement(kind: kind, text: text, source: source) }
        // Updated suggestions stay where the old ones were, in case the user reordered them.
        let anchor = elements.firstIndex { $0.kind == kind && $0.source == source }
        elements.removeAll { $0.kind == kind && $0.source == source }
        if let anchor {
            elements.insert(contentsOf: new, at: min(anchor, elements.count))
        } else {
            new.forEach { insert($0) }
        }
    }

    // MARK: Coding

    private enum CodingKeys: String, CodingKey {
        case id, time, status, elements, dismissed
        // Fields from before elements.
        case vo, supers, jingle, graphics, notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        time = try c.decode(Double.self, forKey: .time)
        status = try c.decodeIfPresent(Status.self, forKey: .status) ?? .pending
        dismissed = try c.decodeIfPresent([String].self, forKey: .dismissed) ?? []
        if let elements = try c.decodeIfPresent([ScriptElement].self, forKey: .elements) {
            self.elements = elements
            return
        }
        // A document from before elements: each field becomes elements. A detected
        // row's VO and supers came from analysis, so they stay suggestions.
        func field(_ key: CodingKeys) throws -> String {
            try c.decodeIfPresent(String.self, forKey: key) ?? ""
        }
        let fromAnalysis = status == .detected
        var elements: [ScriptElement] = []
        if case let notes = try field(.notes), !notes.isEmpty { elements.append(ScriptElement(kind: .scene, text: notes)) }
        if case let graphics = try field(.graphics), !graphics.isEmpty { elements.append(ScriptElement(kind: .scene, text: "Graphics: \(graphics)")) }
        if case let vo = try field(.vo), !vo.isEmpty {
            elements.append(ScriptElement(kind: .voiceover, text: vo, source: fromAnalysis ? .audio : nil))
        }
        for line in try field(.supers).split(separator: "\n") {
            elements.append(ScriptElement(kind: .superText, text: String(line), source: fromAnalysis ? .screen : nil))
        }
        if case let jingle = try field(.jingle), !jingle.isEmpty { elements.append(ScriptElement(kind: .music, text: jingle)) }
        self.elements = elements
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        try c.encode(status, forKey: .status)
        try c.encode(elements, forKey: .elements)
        if !dismissed.isEmpty { try c.encode(dismissed, forKey: .dismissed) }
    }
}

/// One line of the script for a section: a scene description, a voiceover, a super and so on.
nonisolated struct ScriptElement: Identifiable, Codable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        /// Describes what's on screen. Saved as "note", its name before.
        case scene = "note"
        case voiceover
        case superText = "super"
        case sfx
        case music
        case disclaimer

        var title: String {
            switch self {
            case .scene: "Scene Description"
            case .voiceover: "Voiceover"
            case .superText: "Super"
            case .sfx: "SFX"
            case .music: "Music"
            case .disclaimer: "Disclaimer"
            }
        }

        var symbol: String {
            switch self {
            case .scene: "square.and.pencil"
            case .voiceover: "waveform"
            case .superText: "character.textbox"
            case .sfx: "party.popper"
            case .music: "music.note"
            case .disclaimer: "exclamationmark.bubble"
            }
        }

        var prompt: String {
            switch self {
            case .scene: "Describe the scene, e.g. Open on a medium shot of…"
            case .voiceover: "Write the voiceover…"
            case .superText: "Type the super as it appears…"
            case .sfx: "Describe the sound effect…"
            case .music: "Name or describe the music…"
            case .disclaimer: "Type the disclaimer…"
            }
        }
    }

    /// Where a suggestion came from.
    enum Source: String, Codable {
        case audio
        case screen

        var title: String {
            switch self {
            case .audio: "from audio"
            case .screen: "read on screen"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var text: String
    /// Set while the element is a suggestion from analysis; cleared once accepted or edited.
    var source: Source?
    /// Bold, italic and underlined runs in `text`, which stays plain for matching suggestions.
    var styles: [TextStyle]?

    var isSuggested: Bool { source != nil }

    var richText: RichText {
        get { RichText(text: text, styles: styles ?? []) }
        set {
            text = newValue.text
            styles = newValue.styles.isEmpty ? nil : newValue.styles
        }
    }

    var isEmptyScene: Bool { kind == .scene && text.isEmpty }

    /// The empty scene description a section starts with.
    static func emptyScene() -> ScriptElement {
        ScriptElement(kind: .scene, text: "")
    }
}

/// A run of bold, italic or underlined text, in characters from the start.
nonisolated struct TextStyle: Codable, Equatable, Sendable {
    var start: Int
    var length: Int
    var bold = false
    var italic = false
    var underline = false

    init(start: Int, length: Int, bold: Bool = false, italic: Bool = false, underline: Bool = false) {
        self.start = start
        self.length = length
        self.bold = bold
        self.italic = italic
        self.underline = underline
    }

    private enum CodingKeys: String, CodingKey {
        case start, length, bold, italic, underline
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(Int.self, forKey: .start)
        length = try c.decode(Int.self, forKey: .length)
        bold = try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        italic = try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false
    }

    /// Writes only the styles a run has.
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(start, forKey: .start)
        try c.encode(length, forKey: .length)
        if bold { try c.encode(true, forKey: .bold) }
        if italic { try c.encode(true, forKey: .italic) }
        if underline { try c.encode(true, forKey: .underline) }
    }
}

/// An element's text with its styled runs, as a card edits it.
nonisolated struct RichText: Equatable, Sendable {
    var text: String
    var styles: [TextStyle]
}

extension [ScriptRow] {
    /// The row whose segment holds `time`: the last one starting at or before it.
    func index(at time: Double) -> Int? {
        lastIndex { $0.time <= time + Playback.frameNudge }
    }

    /// From a row's time to the next row's, or to `duration` for the last row.
    func segment(_ index: Int, duration: Double) -> Range<Double> {
        let start = self[index].time
        let end = index + 1 < count ? self[index + 1].time : duration
        return start..<Swift.max(start, end)
    }

    /// Whether a frame already starts within half a frame (at 25 fps) of `time`.
    func hasFrame(at time: Double) -> Bool {
        contains { abs($0.time - time) < 0.02 }
    }

    /// Moves an element to `index` in a section's elements, or to the end. Elements
    /// read top to bottom in the order they happen. A suggestion moved to another
    /// section is accepted, and isn't offered in its old section again.
    @discardableResult
    mutating func move(element id: ScriptElement.ID, to rowID: ScriptRow.ID, at index: Int? = nil) -> Bool {
        guard let from = firstIndex(where: { $0.elements.contains { $0.id == id } }),
              let to = firstIndex(where: { $0.id == rowID }),
              let position = self[from].elements.firstIndex(where: { $0.id == id }) else { return false }
        var element = self[from].elements.remove(at: position)
        if from != to && element.isSuggested {
            self[from].dismissed.append(element.text)
            element.source = nil
        }
        var target = index ?? self[to].elements.count
        if from == to && position < target { target -= 1 }
        self[to].elements.insert(element, at: Swift.min(Swift.max(target, 0), self[to].elements.count))
        return true
    }

    /// Deletes a section by removing the cut at its start, so its time joins the
    /// section before. Its elements move there, so nothing typed is lost.
    /// Returns the row it merged into.
    @discardableResult
    mutating func merge(_ id: ScriptRow.ID) -> ScriptRow.ID? {
        guard let index = firstIndex(where: { $0.id == id }), index > 0 else { return nil }
        let row = remove(at: index)
        var target = self[index - 1]
        // Its empty scene description would leave the kept section with two.
        target.elements += row.elements.filter { !$0.isEmptyScene }
        target.dismissed += row.dismissed
        // Analysis replaces detected sections, which would drop a kept one's elements.
        if target.status == .detected && row.status != .detected {
            target.status = .pending
        }
        self[index - 1] = target
        return target.id
    }

}

extension Binding<[ScriptRow]> {
    /// `merge(_:)` as one undoable step. Returns the row it merged into.
    @discardableResult
    func merge(_ id: ScriptRow.ID, undoManager: UndoManager?) -> ScriptRow.ID? {
        var rows = wrappedValue
        guard let kept = rows.merge(id) else { return nil }
        replace(with: rows, undoManager: undoManager, actionName: "Delete Section")
        return kept
    }

    /// Adds an empty section at `time` as one undoable step, unless one already starts there.
    @discardableResult
    func add(at time: Double, undoManager: UndoManager?) -> ScriptRow.ID? {
        guard !wrappedValue.hasFrame(at: time) else { return nil }
        let row = ScriptRow(time: time)
        var rows = wrappedValue
        rows.append(row)
        rows.sort { $0.time < $1.time }
        replace(with: rows, undoManager: undoManager, actionName: "Add Section")
        return row.id
    }

    /// Any change to the rows as one undoable step.
    func change(_ actionName: String, undoManager: UndoManager?, _ body: (inout [ScriptRow]) -> Void) {
        var rows = wrappedValue
        body(&rows)
        guard rows != wrappedValue else { return }
        replace(with: rows, undoManager: undoManager, actionName: actionName)
    }

    /// Swaps in new rows and registers the swap back, so undo and redo alternate.
    private func replace(with rows: [ScriptRow], undoManager: UndoManager?, actionName: String) {
        let old = wrappedValue
        wrappedValue = rows
        guard let undoManager else { return }
        undoManager.registerUndo(withTarget: undoManager) { manager in
            replace(with: old, undoManager: manager, actionName: actionName)
        }
        undoManager.setActionName(actionName)
    }
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

    /// `MM:SS`
    static func minutes(_ seconds: Double) -> String {
        let t = max(0, Int(seconds.isFinite ? seconds : 0))
        return String(format: "%02d:%02d", t / 60, t % 60)
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
        ScriptRow(time: 0, elements: [
            ScriptElement(kind: .scene, text: "Open on beach, WS"),
            ScriptElement(kind: .voiceover, text: "Summer's here, and so are the savings."),
            ScriptElement(kind: .superText, text: "SUMMER SALE"),
        ]),
        ScriptRow(time: 3, elements: [
            .emptyScene(),
            ScriptElement(kind: .voiceover, text: "Up to 40% off everything in store."),
            ScriptElement(kind: .superText, text: "UP TO 40% OFF*", source: .screen),
        ]),
        ScriptRow(time: 7, status: .detected, elements: [
            .emptyScene(),
            ScriptElement(kind: .voiceover, text: "Including the brands you love.", source: .audio),
        ]),
        ScriptRow(time: 11, elements: [
            ScriptElement(kind: .scene, text: "Product hero. Pack shot, logo lock-up"),
            ScriptElement(kind: .voiceover, text: "But be quick."),
            ScriptElement(kind: .superText, text: "ENDS SUNDAY"),
        ]),
        ScriptRow(time: 15, elements: [
            ScriptElement(kind: .scene, text: "Hold disclaimer 3s"),
            ScriptElement(kind: .disclaimer, text: "*Conditions apply. See website for details."),
        ]),
        ScriptRow(time: 24, elements: [
            ScriptElement(kind: .scene, text: "End frame"),
            ScriptElement(kind: .voiceover, text: "Shop now, online and in store."),
            ScriptElement(kind: .superText, text: "LOGO + URL"),
        ]),
    ], analysed: true)
}
