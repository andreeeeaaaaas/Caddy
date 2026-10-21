import SwiftUI
import UniformTypeIdentifiers

/// One ad: script sheet, inspector and filmstrip in a single window.
struct DocumentView: View {
    @Binding var document: CaddyDocument

    @State private var playback = Playback()
    @State private var thumbnails = Thumbnails()
    @State private var analyzer = Analyzer()
    @State private var selection: ScriptRow.ID?
    @State private var showInspector = true
    @State private var showExport = false
    @State private var showSensitivity = false
    @State private var videoMissing = false

    private var rows: [ScriptRow] { document.script.rows }

    var body: some View {
        Group {
            if document.script.videoPath == nil && rows.isEmpty {
                EmptyDocumentView { url in document.script.videoPath = url.path }
            } else {
                workspace
            }
        }
        .frame(minWidth: 1000, minHeight: 640)
        .toolbar { toolbar }
        .sheet(isPresented: $showExport) {
            ExportSheet(rows: rows)
        }
        .task(id: document.script.videoPath) { await start() }
        .onChange(of: document.script.sensitivity) {
            analyzer.applySensitivity(script: $document.script)
        }
        .onChange(of: rows.first?.id, initial: true) {
            if selection == nil { selection = rows.first?.id }
        }
        .onChange(of: selection) {
            if let row = rows.first(where: { $0.id == selection }) {
                playback.seek(to: row.time)
            }
        }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ScriptSheet(
                    rows: $document.script.rows,
                    selection: $selection,
                    thumbnails: thumbnails,
                    isTranscribing: analyzer.isTranscribing
                )
                if showInspector {
                    Divider()
                    inspector
                        .frame(width: 320)
                }
            }
            Divider()
            FilmstripView(
                rows: rows,
                selection: $selection,
                playback: playback,
                thumbnails: thumbnails,
                sceneProgress: sceneProgress
            )
            .frame(height: 150)
        }
    }

    @ViewBuilder
    private var inspector: some View {
        if let id = selection, let row = binding(for: id), let index = rows.firstIndex(where: { $0.id == id }) {
            InspectorView(
                row: row,
                number: index + 1,
                segmentEnd: index + 1 < rows.count ? rows[index + 1].time : playback.duration,
                playback: playback,
                onRemove: { remove(id) }
            )
        } else {
            ContentUnavailableView("No Frame Selected", systemImage: "rectangle.on.rectangle", description: Text("Select a row to see its frame and fields."))
                .frame(maxHeight: .infinity)
                .background(.background.secondary)
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            StatusView(phase: analyzer.phase, notice: analyzer.notice, rows: rows, videoMissing: videoMissing)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Scene Sensitivity", systemImage: "slider.horizontal.3") { showSensitivity.toggle() }
                .help("How many frames to suggest")
                .disabled(document.script.videoPath == nil)
                .popover(isPresented: $showSensitivity, arrowEdge: .bottom) {
                    SensitivityView(
                        sensitivity: $document.script.sensitivity,
                        suggestedCount: rows.filter { $0.status == .suggested }.count,
                        hasScores: document.script.sceneScores != nil,
                        isBusy: analyzer.isBusy,
                        detect: detectScenes
                    )
                }
            Button("Add Frame", systemImage: "plus.rectangle.on.rectangle", action: addFrame)
                .keyboardShortcut("f", modifiers: .command)
                .help("Add a frame at the playhead (⌘F)")
                .disabled(document.script.videoPath == nil)
            Button("Export…", systemImage: "square.and.arrow.up") { showExport = true }
                .help("Export the script as Word or PDF")
                .disabled(rows.isEmpty)
            Button("Inspector", systemImage: "sidebar.trailing") { showInspector.toggle() }
                .help(showInspector ? "Hide inspector" : "Show inspector")
        }
    }

    private var sceneProgress: Double? {
        if case .findingScenes(let progress) = analyzer.phase { progress } else { nil }
    }

    private func start() async {
        guard let url = document.script.videoURL else { return }
        videoMissing = !FileManager.default.fileExists(atPath: url.path)
        guard !videoMissing else { return }
        await playback.load(url)
        if let asset = playback.asset { thumbnails.load(asset) }
        if !document.script.analysed {
            await analyzer.run(videoURL: url, script: $document.script)
        }
    }

    /// For documents analysed before scene scores were saved.
    private func detectScenes() {
        guard let url = document.script.videoURL else { return }
        Task { await analyzer.detectScenes(videoURL: url, script: $document.script) }
    }

    private func addFrame() {
        let row = ScriptRow(time: playback.currentTime)
        document.script.rows.append(row)
        document.script.rows.sort { $0.time < $1.time }
        selection = row.id
    }

    private func remove(_ id: ScriptRow.ID) {
        document.script.rows.removeAll { $0.id == id }
        selection = nil
    }

    /// Looks the row up by ID on every access, so deleting a row can't leave a stale index.
    private func binding(for id: ScriptRow.ID) -> Binding<ScriptRow>? {
        guard let row = rows.first(where: { $0.id == id }) else { return nil }
        return Binding {
            document.script.rows.first { $0.id == id } ?? row
        } set: { newValue in
            if let index = document.script.rows.firstIndex(where: { $0.id == id }) {
                document.script.rows[index] = newValue
            }
        }
    }
}

/// Toolbar status: analysis progress, then a summary of the rows.
private struct StatusView: View {
    let phase: Analyzer.Phase
    let notice: String?
    let rows: [ScriptRow]
    let videoMissing: Bool

    var body: some View {
        HStack(spacing: 10) {
            switch phase {
            case _ where videoMissing:
                Label("Video not found", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            case .findingScenes(let progress):
                Text("Finding scenes")
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
                Text(summary)
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
    }

    private var summary: String {
        let checked = rows.filter { $0.status == .checked }.count
        let suggested = rows.filter { $0.status == .suggested }.count
        var parts = ["\(rows.count) frames", "\(checked) checked"]
        if suggested > 0 { parts.append("\(suggested) suggested") }
        return parts.joined(separator: " · ")
    }
}

/// Popover for how many frames analysis suggests.
private struct SensitivityView: View {
    @Binding var sensitivity: Double
    let suggestedCount: Int
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
                    Text("\(suggestedCount) suggested \(suggestedCount == 1 ? "frame" : "frames")")
                        .monospacedDigit()
                    Spacer()
                    Button("Default") { sensitivity = SceneDetector.defaultSensitivity }
                        .disabled(abs(sensitivity - SceneDetector.defaultSensitivity) < 0.001)
                }
                Text("Accepted and added frames are kept.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("This document was analysed before scene scores were saved.")
                    .foregroundStyle(.secondary)
                Button("Detect Scenes", action: detect)
                    .disabled(isBusy)
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}

/// A document with no video yet, e.g. from File > New.
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
    DocumentView(document: .constant(CaddyDocument(script: .sample)))
        .frame(width: 1280, height: 800)
}
