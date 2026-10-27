import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What the library window is showing and asking for, shared with the menu
/// commands so New Script and New Project work from the menu bar.
@Observable
final class LibraryUI {
    enum Renaming: Equatable {
        case script(Library.Entry.ID)
        case project(Library.Project.ID)
    }

    enum Deletion: Identifiable {
        case script(Library.Entry)
        case project(Library.Project)

        var id: UUID {
            switch self {
            case .script(let entry): entry.id
            case .project(let project): project.id
            }
        }
    }

    /// A script or a project; their IDs never clash.
    var selection: UUID? {
        didSet { UserDefaults.standard.set(selection?.uuidString, forKey: "selectedScript") }
    }
    var expanded: Set<Library.Project.ID> = []
    var renaming: Renaming?
    var deleting: Deletion?
    var isChoosingVideo = false
    /// The project a chosen video's script goes into.
    var videoProject: Library.Project.ID?
    var isImporting = false
    var isShowingWelcome = false
    var isReportingIssue = false
    /// Whether the sidebar shows, so New Folder can open it to name the folder.
    var columns = NavigationSplitViewVisibility.automatic

    init() {
        selection = UserDefaults.standard.string(forKey: "selectedScript").flatMap(UUID.init(uuidString:))
    }

    /// Where new scripts go: the selected project, the selected script's
    /// project, or none.
    func targetProject(in library: Library) -> Library.Project.ID? {
        guard let selection else { return nil }
        if library.project(selection) != nil { return selection }
        return library.entry(selection)?.projectID
    }

    func chooseVideo(in projectID: Library.Project.ID?) {
        videoProject = projectID
        isChoosingVideo = true
    }

    func newProject(in library: Library) {
        let id = library.addProject()
        if columns == .detailOnly { columns = .all }
        expanded.insert(id)
        selection = id
        renaming = .project(id)
    }

    /// Adds dropped or chosen files: videos become new scripts, `.caddy` files are imported.
    @discardableResult
    func add(_ urls: [URL], to projectID: Library.Project.ID?, in library: Library) -> Bool {
        var added: Library.Entry.ID?
        for url in urls {
            if url.pathExtension.lowercased() == "caddy" {
                added = library.importScript(at: url, in: projectID) ?? added
            } else if VideoFile.isSupported(url) {
                added = library.createScript(videoURL: url, in: projectID) ?? added
            }
        }
        guard let added else { return false }
        if let projectID { expanded.insert(projectID) }
        selection = added
        return true
    }
}

/// The app's one window: the library's projects and scripts in a sidebar, and
/// the selected script beside it.
struct LibraryView: View {
    let library: Library
    @Bindable var ui: LibraryUI
    /// The tour ended on Choose a Video, so the file picker opens once it's gone.
    @State private var choosesVideoAfterWelcome = false

    var body: some View {
        NavigationSplitView(columnVisibility: $ui.columns) {
            LibrarySidebar(library: library, ui: ui)
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 380)
        } detail: {
            detail
                // The same smallest size whether a script is open or not.
                .frame(minWidth: 900, minHeight: 640)
        }
        .fileImporter(isPresented: $ui.isChoosingVideo, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { ui.add([url], to: ui.videoProject, in: library) }
        }
        // A `.caddy` file opened from Finder joins the library.
        .onOpenURL { ui.add([$0], to: nil, in: library) }
        .sheet(isPresented: $ui.isShowingWelcome, onDismiss: {
            if choosesVideoAfterWelcome {
                choosesVideoAfterWelcome = false
                ui.chooseVideo(in: ui.targetProject(in: library))
            }
        }) {
            WelcomeSheet { choosesVideoAfterWelcome = true }
        }
        .sheet(isPresented: $ui.isReportingIssue) { ReportIssueSheet() }
        .alert("Something Went Wrong", isPresented: Binding { library.error != nil } set: { if !$0 { library.error = nil } }) {
            Button("OK") { library.error = nil }
        } message: {
            Text(library.error ?? "")
        }
        .onAppear {
            // Open on the projects, with the selected script's project showing.
            if ui.expanded.isEmpty { ui.expanded = Set(library.projects.map(\.id)) }
            if let selection = ui.selection, library.entry(selection) == nil, library.project(selection) == nil { ui.selection = nil }
            // The tour opens once, on the first launch on this Mac.
            if !UserDefaults.standard.bool(forKey: "hasSeenWelcome") {
                UserDefaults.standard.set(true, forKey: "hasSeenWelcome")
                ui.isShowingWelcome = true
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let selection = ui.selection, let entry = library.entry(selection) {
            ScriptHost(library: library, id: selection, title: entry.name, subtitle: library.project(entry.projectID)?.name ?? "")
                .id(selection)
                .navigationTitle(entry.name)
                .navigationSubtitle(library.project(entry.projectID)?.name ?? "")
        } else {
            NoScriptView { ui.add($0, to: ui.targetProject(in: library), in: library) } onChoose: {
                ui.chooseVideo(in: ui.targetProject(in: library))
            }
            .navigationTitle(library.project(ui.selection)?.name ?? "Caddy")
        }
    }
}

/// Projects, each expandable with its scripts and a count, then the scripts in
/// no project. Drag a script onto a project or another script to move it;
/// drop videos or `.caddy` files to add them.
private struct LibrarySidebar: View {
    let library: Library
    @Bindable var ui: LibraryUI

    var body: some View {
        List(selection: $ui.selection) {
            Section("Folders") {
                ForEach(library.sortedProjects) { project in
                    DisclosureGroup(isExpanded: expansion(project.id)) {
                        ForEach(library.scripts(in: project.id)) { scriptRow($0) }
                    } label: {
                        projectRow(project)
                    }
                }
                if library.projects.isEmpty {
                    Button("New Folder", systemImage: "plus") { ui.newProject(in: library) }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Scripts") {
                ForEach(library.scripts(in: nil)) { scriptRow($0) }
                if library.scripts(in: nil).isEmpty {
                    Text(library.entries.isEmpty ? "Drop a finished ad here" : "No scripts outside a folder")
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .listStyle(.sidebar)
        // Return renames the selected row, as in Finder.
        .onKeyPress(.return) {
            guard ui.renaming == nil, let selection = ui.selection else { return .ignored }
            if library.entry(selection) != nil {
                ui.renaming = .script(selection)
            } else if library.project(selection) != nil {
                ui.renaming = .project(selection)
            } else {
                return .ignored
            }
            return .handled
        }
        .onDeleteCommand {
            guard let selection = ui.selection else { return }
            if let entry = library.entry(selection) {
                ui.deleting = .script(entry)
            } else if let project = library.project(selection) {
                ui.deleting = .project(project)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            ui.add(urls, to: ui.targetProject(in: library), in: library)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("New Folder", systemImage: "folder.badge.plus") { ui.newProject(in: library) }
                    .help("New Folder (⇧⌘N)")
                Spacer()
                Button("New Script", systemImage: "plus") { ui.chooseVideo(in: ui.targetProject(in: library)) }
                    .help("New Script from a video (⌘N)")
            }
            .buttonStyle(IconButtonStyle())
            .labelStyle(.iconOnly)
            .font(.system(size: 15))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
        .fileImporter(isPresented: $ui.isImporting, allowedContentTypes: [.caddyDocument], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { ui.add(urls, to: ui.targetProject(in: library), in: library) }
        }
        .confirmationDialog(deletionTitle, isPresented: Binding { ui.deleting != nil } set: { if !$0 { ui.deleting = nil } }, presenting: ui.deleting) { deletion in
            Button(deletion.isProject ? "Delete Folder" : "Delete Script", role: .destructive) { delete(deletion) }
        } message: { deletion in
            Text(deletion.isProject ? "Its scripts move to Scripts." : "The script is removed from the library. The video isn't touched.")
        }
    }

    private var deletionTitle: String {
        switch ui.deleting {
        case .script(let entry): "Delete “\(entry.name)”?"
        case .project(let project): "Delete “\(project.name)”?"
        case nil: ""
        }
    }

    // MARK: Rows

    private func projectRow(_ project: Library.Project) -> some View {
        HStack {
            if ui.renaming == .project(project.id) {
                RenameField(name: project.name, systemImage: "folder") { name in
                    if let name { library.renameProject(project.id, to: name) }
                    ui.renaming = nil
                }
            } else {
                Label(project.name.displayName, systemImage: "folder")
                    .lineLimit(1)
            }
            Spacer()
            Text("\(library.scripts(in: project.id).count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        .tag(project.id)
        // Simultaneous, so the list still selects the row on the first click.
        .simultaneousGesture(TapGesture(count: 2).onEnded { ui.renaming = .project(project.id) })
        .dropDestination(for: ScriptDrag.self) { items, _ in
            move(items, to: project.id)
        }
        .contextMenu {
            Button("New Script from Video…", systemImage: "plus") { ui.chooseVideo(in: project.id) }
            Button("Rename", systemImage: "pencil") { ui.renaming = .project(project.id) }
            Divider()
            Button("Delete Folder…", systemImage: "trash", role: .destructive) { ui.deleting = .project(project) }
        }
    }

    private func scriptRow(_ entry: Library.Entry) -> some View {
        Group {
            if ui.renaming == .script(entry.id) {
                RenameField(name: entry.name, systemImage: "doc.text.image") { name in
                    if let name { library.rename(entry.id, to: name) }
                    ui.renaming = nil
                }
            } else {
                Label(entry.name.displayName, systemImage: "doc.text.image")
                    .lineLimit(1)
            }
        }
        .tag(entry.id)
        .contentShape(.rect)
        .simultaneousGesture(TapGesture(count: 2).onEnded { ui.renaming = .script(entry.id) })
        .draggable(ScriptDrag(id: entry.id)) {
            Label(entry.name.displayName, systemImage: "doc.text.image")
        }
        // Dropped on a script, a script joins that script's project.
        .dropDestination(for: ScriptDrag.self) { items, _ in
            move(items, to: entry.projectID)
        }
        .contextMenu {
            Button("Rename", systemImage: "pencil") { ui.renaming = .script(entry.id) }
            Menu("Move to Folder") {
                ForEach(library.sortedProjects) { project in
                    Button(project.name) { library.move(entry.id, to: project.id) }
                        .disabled(project.id == entry.projectID)
                }
                Divider()
                Button("No Folder") { library.move(entry.id, to: nil) }
                    .disabled(entry.projectID == nil)
            }
            if let path = entry.videoPath {
                Button("Show Video in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            }
            Divider()
            Button("Delete Script…", systemImage: "trash", role: .destructive) { ui.deleting = .script(entry) }
        }
    }

    // MARK: Actions

    private func expansion(_ id: Library.Project.ID) -> Binding<Bool> {
        Binding {
            ui.expanded.contains(id)
        } set: { isExpanded in
            if isExpanded { ui.expanded.insert(id) } else { ui.expanded.remove(id) }
        }
    }

    private func move(_ items: [ScriptDrag], to projectID: Library.Project.ID?) -> Bool {
        guard !items.isEmpty else { return false }
        for item in items { library.move(item.id, to: projectID) }
        if let projectID { ui.expanded.insert(projectID) }
        return true
    }

    private func delete(_ deletion: LibraryUI.Deletion) {
        switch deletion {
        case .script(let entry):
            if ui.selection == entry.id { ui.selection = nil }
            library.delete(entry.id)
        case .project(let project):
            library.deleteProject(project.id)
            ui.expanded.remove(project.id)
        }
        ui.deleting = nil
    }
}

private extension LibraryUI.Deletion {
    var isProject: Bool {
        if case .project = self { true } else { false }
    }
}

/// A name being edited in the sidebar. Return or clicking away keeps it, Esc
/// cancels.
private struct RenameField: View {
    let name: String
    let systemImage: String
    /// The new name, or nil if cancelled.
    let onDone: (String?) -> Void

    @State private var text = ""
    /// The whole name, so typing replaces it, as in Finder.
    @State private var textSelection: TextSelection?
    @FocusState private var isFocused: Bool

    var body: some View {
        Label {
            TextField("Name", text: $text, selection: $textSelection)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onSubmit { onDone(text) }
                .onExitCommand { onDone(nil) }
        } icon: {
            Image(systemName: systemImage)
        }
        .onAppear {
            text = name
            textSelection = TextSelection(range: text.startIndex..<text.endIndex)
            isFocused = true
        }
        .onChange(of: isFocused) {
            if !isFocused { onDone(text) }
        }
    }
}

/// The selected script, loaded from the library and saved back a moment after
/// each change, and again as it closes or the app quits.
private struct ScriptHost: View {
    let library: Library
    let id: Library.Entry.ID
    let title: String
    let subtitle: String

    @State private var script: Script?
    @State private var failed = false
    @State private var pendingSave: Task<Void, Never>?
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        Group {
            if let script {
                DocumentView(script: Binding { self.script ?? script } set: { self.script = $0 }, title: title, subtitle: subtitle)
            } else if failed {
                ContentUnavailableView("Couldn't Open Script", systemImage: "exclamationmark.triangle", description: Text("Its file in the library is missing or damaged."))
            } else {
                Color.clear
            }
        }
        .onAppear {
            // Undo steps belong to the script they were made in.
            undoManager?.removeAllActions()
            do { script = try library.loadScript(id) } catch { failed = true }
        }
        .onChange(of: script) { old, _ in
            if old != nil { scheduleSave() }
        }
        .onDisappear(perform: saveNow)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in saveNow() }
    }

    /// Analysis writes many times a second, so saves wait for a pause.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        if let script { library.save(script, for: id) }
    }
}

/// The detail with no script selected: drop a video or choose one.
private struct NoScriptView: View {
    let onDrop: ([URL]) -> Bool
    let onChoose: () -> Void

    @State private var isTargeted = false

    var body: some View {
        ContentUnavailableView {
            Label("Start a new script", systemImage: "doc.text.image")
        } description: {
            Text("Drop a finished ad here, or choose one")
                .lineLimit(1)
                .fixedSize()
        } actions: {
            Button("Choose a Video", action: onChoose)
                .buttonStyle(CapsuleButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A faint frog wordmark under the empty state.
        .overlay(alignment: .bottom) {
            FrogWordmark(width: 110)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 32)
        }
        .background(isTargeted ? Color.accentColor.opacity(0.06) : .clear)
        .dropDestination(for: URL.self) { urls, _ in onDrop(urls) } isTargeted: { isTargeted = $0 }
    }
}

/// A script dragged in the sidebar to another project.
nonisolated struct ScriptDrag: Codable, Transferable {
    let id: Library.Entry.ID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .caddyScriptReference)
    }
}

extension UTType {
    /// Declared in Info.plist. Only Caddy reads it.
    nonisolated static let caddyScriptReference = UTType(exportedAs: "andreasthoma.caddy.script-reference")
}
