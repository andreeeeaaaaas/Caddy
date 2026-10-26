import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One script, beside the library sidebar: the player with the section under
/// the playhead, or the whole script as a table.
struct DocumentView: View {
    enum ViewMode: String {
        case playback, grid
    }

    @Binding var script: Script
    /// The script's name and project, shown at the start of the toolbar.
    var title = ""
    var subtitle = ""

    @AppStorage("viewMode") private var viewMode = ViewMode.playback
    @State private var playback = Playback()
    @State private var thumbnails = Thumbnails()
    @State private var analyzer = Analyzer()
    @State private var selection: ScriptRow.ID?
    @State private var showExport = false
    @State private var showSensitivity = false
    /// The time under the pointer while it skims a frame in the grid.
    @State private var skimTime: Double?
    @State private var videoMissing = false
    /// The library window, so Space only acts there.
    @State private var window: NSWindow?
    @State private var spaceMonitor: Any?
    @Environment(\.undoManager) private var undoManager

    private var rows: [ScriptRow] { script.rows }

    var body: some View {
        Group {
            if script.videoPath == nil && rows.isEmpty {
                EmptyDocumentView { url in script.videoPath = url.path }
            } else {
                workspace
            }
        }
        .background(WindowReader { window = $0 })
        .onAppear(perform: watchSpace)
        .onDisappear {
            if let spaceMonitor { NSEvent.removeMonitor(spaceMonitor) }
            spaceMonitor = nil
        }
        .overlay { toolbarBackground }
        .background {
            // ⌘F has no toolbar button now; the player bar has Add Section.
            Button("Add Section", action: addSection)
                .keyboardShortcut("f", modifiers: .command)
                .disabled(script.videoPath == nil || rows.hasFrame(at: newSectionTime))
                .opacity(0)
                .accessibilityHidden(true)
        }
        .toolbar { toolbar }
        // Drawn by the toolbar itself, so the view toggle can follow it.
        .toolbar(removing: .title)
        // macOS draws a toolbar backing only over scroll views, which left a
        // band over just the panel, so draw one across the window instead.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .sheet(isPresented: $showExport) {
            ExportSheet(script: script, title: title, project: subtitle, fps: playback.frameRate)
        }
        .task(id: script.videoPath) { await start() }
        .onChange(of: script.sensitivity) {
            analyzer.applySensitivity(script: $script)
        }
        .onChange(of: rows.first?.id, initial: true) {
            if selection == nil { selection = rows.first?.id }
        }
        .onChange(of: selection) {
            // The playhead may already be in this frame, e.g. when the carousel follows playback.
            guard let index = rows.firstIndex(where: { $0.id == selection }),
                  rows.index(at: playback.currentTime) != index else { return }
            playback.seek(to: rows[index].time)
        }
    }

    /// A translucent bar behind the toolbar that cards scroll under.
    private var toolbarBackground: some View {
        GeometryReader { proxy in
            VStack(spacing: 0) {
                Rectangle()
                    .fill(.bar)
                    .frame(height: proxy.safeAreaInsets.top)
                    .overlay(alignment: .bottom) { Divider() }
                Spacer(minLength: 0)
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var workspace: some View {
        switch viewMode {
        case .playback:
            PlaybackView(rows: $script.rows, selection: $selection, playback: playback)
        case .grid:
            ScriptTable(
                rows: $script.rows,
                selection: $selection,
                playback: playback,
                thumbnails: thumbnails,
                skimTime: $skimTime,
                onOpen: open
            )
            .onDisappear { skimTime = nil }
        }
    }

    /// From the Figma header: the title on the left with the view toggle after
    /// it, status centred, and Sensitivity and Export on the right as separate
    /// glass groups.
    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            VStack(alignment: .leading, spacing: 0) {
                Text(title.displayName)
                    .font(.headline)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle.displayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: 320, alignment: .leading)
        }
        .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .navigation) {
            Picker("View", selection: $viewMode) {
                Label("Playback", systemImage: "play.rectangle").tag(ViewMode.playback)
                Label("Grid", systemImage: "tablecells").tag(ViewMode.grid)
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Show the player with one section at a time, or the whole script as a table")
        }
        ToolbarItem(placement: .principal) {
            StatusView(
                phase: analyzer.phase,
                notice: analyzer.notice,
                rows: rows,
                videoMissing: videoMissing,
                onNext: nextSuggestion,
                onAcceptAll: acceptAllSuggestions
            )
        }
        ToolbarItem(placement: .primaryAction) {
            Button("Detection Sensitivity", systemImage: "sparkles") { showSensitivity.toggle() }
                .help("Sensitivity")
                .disabled(script.videoPath == nil)
                .popover(isPresented: $showSensitivity, arrowEdge: .bottom) {
                    SensitivityView(
                        sensitivity: $script.sensitivity,
                        sectionCount: rows.count,
                        hasScores: script.sceneScores != nil,
                        isBusy: analyzer.isBusy,
                        detect: detectScenes
                    )
                }
        }
        // Splits Sensitivity and Export into their own glass groups.
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItem(placement: .primaryAction) {
            Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                .help("Export")
                .disabled(rows.isEmpty)
        }
    }

    private func start() async {
        guard let url = script.videoURL else { return }
        videoMissing = !FileManager.default.fileExists(atPath: url.path)
        guard !videoMissing else { return }
        await playback.load(url)
        if let asset = playback.asset { thumbnails.load(asset) }
        if !script.analysed {
            await analyzer.run(videoURL: url, script: $script)
        }
    }

    /// For scripts analysed before scene scores were saved.
    private func detectScenes() {
        guard let url = script.videoURL else { return }
        Task { await analyzer.detectScenes(videoURL: url, script: $script) }
    }

    /// Selects the next section with suggestions, wrapping round to the first.
    private func nextSuggestion() {
        let start = (rows.firstIndex { $0.id == selection } ?? -1) + 1
        let order = rows[start...] + rows[..<start]
        if let row = order.first(where: { $0.suggestionCount > 0 }) { selection = row.id }
    }

    private func acceptAllSuggestions() {
        $script.rows.change("Confirm All Suggestions", undoManager: undoManager) { rows in
            for r in rows.indices {
                for e in rows[r].elements.indices { rows[r].elements[e].source = nil }
            }
        }
    }

    /// Where ⌘F adds a section: the skimmed point in the grid, otherwise the playhead.
    private var newSectionTime: Double {
        skimTime ?? playback.currentTime
    }

    private func addSection() {
        if let id = $script.rows.add(at: newSectionTime, undoManager: undoManager) {
            selection = id
        }
    }

    /// Space plays or pauses from anywhere in the window, whatever was clicked
    /// last, unless a text field is being typed in. Watched at the window rather
    /// than with `onKeyPress`, which needs a focused view, and clicking a button
    /// such as Loop leaves none.
    private func watchSpace() {
        guard spaceMonitor == nil else { return }
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.charactersIgnoringModifiers == " ",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty else { return event }
            let eventWindow = event.window
            let isRepeat = event.isARepeat
            let handled = MainActor.assumeIsolated {
                guard let window, eventWindow === window, window.attachedSheet == nil,
                      !(window.firstResponder is NSText),
                      script.videoPath != nil else { return false }
                if !isRepeat { playback.togglePlay() }
                return true
            }
            return handled ? nil : event
        }
    }

    /// Shows a section from the grid in the playback view.
    private func open(_ id: ScriptRow.ID) {
        guard let row = rows.first(where: { $0.id == id }) else { return }
        selection = id
        playback.seek(to: row.time)
        viewMode = .playback
    }

}

/// Reports the window a view is in.
private struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowView(onWindow: onWindow) }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WindowView: NSView {
        let onWindow: (NSWindow?) -> Void

        init(onWindow: @escaping (NSWindow?) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError() }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Not during SwiftUI's own update.
            DispatchQueue.main.async { [weak self] in self?.onWindow(self?.window) }
        }
    }
}

/// Toolbar status: analysis progress, then a summary of the rows.
private struct StatusView: View {
    let phase: Analyzer.Phase
    let notice: String?
    let rows: [ScriptRow]
    let videoMissing: Bool
    let onNext: () -> Void
    let onAcceptAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var suggestions: Int { rows.map(\.suggestionCount).reduce(0, +) }

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case _ where videoMissing:
                Label("Video not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .findingScenes(let progress):
                Text("Finding scenes · \(sections)")
                    .contentTransition(.numericText(value: Double(rows.count)))
                ProgressView(value: progress).frame(width: 120)
            case .readingText(let progress):
                Text("Reading on-screen text")
                ProgressView(value: progress).frame(width: 120)
            case .downloadingSpeechModel:
                Text("Downloading speech model")
                ProgressView().controlSize(.small)
            case .transcribing(let progress):
                Text("Transcribing")
                ProgressView(value: progress).frame(width: 120)
            case .idle, .finished:
                if suggestions > 0 {
                    Menu {
                        Button("Next Suggestion", systemImage: "arrow.down", action: onNext)
                        Button("Confirm All Suggestions", systemImage: "checkmark.circle", action: onAcceptAll)
                    } label: {
                        Text(summary)
                            .contentTransition(.numericText())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Go to the next suggestion, or confirm them all")
                    if suggestions > 1 {
                        ConfirmButton(title: "Confirm All", help: "Confirm every suggestion", action: onAcceptAll)
                    }
                } else {
                    Text(summary)
                        .contentTransition(.numericText())
                }
                if let notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .monospacedDigit()
        // Counts roll as sections and suggestions come in.
        .animation(reduceMotion ? nil : .snappy, value: rows.count)
        .animation(reduceMotion ? nil : .snappy, value: suggestions)
    }

    private var sections: String {
        "\(rows.count) \(rows.count == 1 ? "section" : "sections")"
    }

    private var summary: String {
        var parts = [sections]
        if suggestions > 0 { parts.append("\(suggestions) \(suggestions == 1 ? "suggestion" : "suggestions")") }
        return parts.joined(separator: " · ")
    }
}

/// Popover for how many sections scene detection finds.
private struct SensitivityView: View {
    @Binding var sensitivity: Double
    let sectionCount: Int
    let hasScores: Bool
    let isBusy: Bool
    let detect: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scene Sensitivity")
                .font(.headline)
            if hasScores {
                Slider(value: $sensitivity, in: 0...1) {
                    Text("Sensitivity")
                } minimumValueLabel: {
                    Text("Cuts only")
                } maximumValueLabel: {
                    Text("Every change")
                }
                .labelsHidden()
                HStack {
                    Text("\(sectionCount) \(sectionCount == 1 ? "section" : "sections")")
                        .monospacedDigit()
                    Spacer()
                    Button("Default") { sensitivity = SceneDetector.defaultSensitivity }
                        .disabled(abs(sensitivity - SceneDetector.defaultSensitivity) < 0.001)
                }
                Text("Sections you've added or written in stay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This script was analysed before scene scores were saved.")
                    .foregroundStyle(.secondary)
                Button("Detect Scenes", action: detect)
                    .disabled(isBusy)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// A script with no video yet.
private struct EmptyDocumentView: View {
    let onChoose: (URL) -> Void
    @State private var showImporter = false

    var body: some View {
        ContentUnavailableView {
            Label("No Video", systemImage: "film")
        } description: {
            Text("Drop a finished ad here, or choose one.")
        } actions: {
            Button("Choose Video…") { showImporter = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: VideoFile.isSupported) else { return false }
            onChoose(url)
            return true
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { onChoose(url) }
        }
    }
}

#Preview {
    DocumentView(script: .constant(.sample))
        .frame(width: 1280, height: 800)
}
