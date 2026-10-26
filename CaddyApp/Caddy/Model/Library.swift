import AppKit
import Foundation
import Observation

/// The local library of scripts, grouped into projects. Kept in Application
/// Support rather than Documents, which iCloud may sync: the library is local
/// to each Mac (BRD section 3).
///
/// `library.json` holds the projects and each script's name and project; each
/// script is a `.caddy` package in `Scripts`, named by its ID.
@Observable
final class Library {
    struct Project: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
    }

    /// A script as the sidebar lists it.
    struct Entry: Identifiable, Codable, Equatable {
        var id = UUID()
        var name: String
        /// Nil for a script that isn't in a project.
        var projectID: Project.ID?
        /// Kept here too, so the sidebar can show the video without reading the script.
        var videoPath: String?
        var created = Date()
        var modified = Date()
    }

    private struct Index: Codable {
        var projects: [Project] = []
        var scripts: [Entry] = []
    }

    private(set) var projects: [Project] = []
    private(set) var entries: [Entry] = []
    /// The last thing that went wrong, for an alert.
    var error: String?

    let folder: URL
    private var indexURL: URL { folder.appending(path: "library.json") }
    private var scriptsFolder: URL { folder.appending(path: "Scripts") }

    static var defaultFolder: URL {
        URL.applicationSupportDirectory.appending(path: "Caddy", directoryHint: .isDirectory)
    }

    init(folder: URL = Library.defaultFolder) {
        self.folder = folder
        load()
    }

    // MARK: Reading

    var sortedProjects: [Project] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// A project's scripts, or those in no project, by name.
    func scripts(in projectID: Project.ID?) -> [Entry] {
        entries
            .filter { $0.projectID == projectID }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func entry(_ id: Entry.ID) -> Entry? {
        entries.first { $0.id == id }
    }

    func project(_ id: Project.ID?) -> Project? {
        projects.first { $0.id == id }
    }

    func package(for id: Entry.ID) -> URL {
        scriptsFolder.appending(path: "\(id.uuidString).caddy", directoryHint: .isDirectory)
    }

    func loadScript(_ id: Entry.ID) throws -> Script {
        try Script.read(from: package(for: id))
    }

    // MARK: Scripts

    /// A new script for a video, named after it.
    @discardableResult
    func createScript(videoURL: URL, in projectID: Project.ID?) -> Entry.ID? {
        add(Script(videoPath: videoURL.path), name: videoURL.deletingPathExtension().lastPathComponent, in: projectID)
    }

    /// Copies a `.caddy` file into the library. The original is left alone.
    @discardableResult
    func importScript(at url: URL, in projectID: Project.ID?) -> Entry.ID? {
        do {
            return add(try Script.read(from: url), name: url.deletingPathExtension().lastPathComponent, in: projectID)
        } catch {
            self.error = "Couldn't import \(url.lastPathComponent): \(error.localizedDescription)"
            return nil
        }
    }

    /// Saves an open script. Ignored once the script has been deleted, so a
    /// last save as it closes can't bring it back.
    func save(_ script: Script, for id: Entry.ID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        do {
            try script.write(to: package(for: id))
            entries[index].modified = Date()
            entries[index].videoPath = script.videoPath
            saveIndex()
        } catch {
            self.error = "Couldn't save \(entries[index].name): \(error.localizedDescription)"
        }
    }

    func rename(_ id: Entry.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].name = name
        saveIndex()
    }

    func move(_ id: Entry.ID, to projectID: Project.ID?) {
        guard let index = entries.firstIndex(where: { $0.id == id }), entries[index].projectID != projectID else { return }
        entries[index].projectID = projectID
        saveIndex()
    }

    /// Removes a script and its package. The video isn't touched.
    func delete(_ id: Entry.ID) {
        entries.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: package(for: id))
        saveIndex()
    }

    private func add(_ script: Script, name: String, in projectID: Project.ID?) -> Entry.ID? {
        let entry = Entry(name: name, projectID: projectID, videoPath: script.videoPath)
        do {
            try script.write(to: package(for: entry.id))
        } catch {
            self.error = "Couldn't create \(name): \(error.localizedDescription)"
            return nil
        }
        entries.append(entry)
        saveIndex()
        return entry.id
    }

    // MARK: Projects

    @discardableResult
    func addProject(named name: String = "New Project") -> Project.ID {
        let project = Project(name: name)
        projects.append(project)
        saveIndex()
        return project.id
    }

    func renameProject(_ id: Project.ID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let index = projects.firstIndex(where: { $0.id == id }) else { return }
        projects[index].name = name
        saveIndex()
    }

    /// Removes a project. Its scripts stay in the library, outside any project.
    func deleteProject(_ id: Project.ID) {
        projects.removeAll { $0.id == id }
        for index in entries.indices where entries[index].projectID == id {
            entries[index].projectID = nil
        }
        saveIndex()
    }

    // MARK: Storage

    private func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            importRecentDocuments()
            return
        }
        do {
            let index = try JSONDecoder.library.decode(Index.self, from: Data(contentsOf: indexURL))
            projects = index.projects
            // A package removed outside Caddy drops out of the sidebar.
            entries = index.scripts.filter { FileManager.default.fileExists(atPath: package(for: $0.id).path) }
        } catch {
            self.error = "Couldn't read the library: \(error.localizedDescription)"
        }
    }

    private func saveIndex() {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try JSONEncoder.library.encode(Index(projects: projects, scripts: entries))
            try data.write(to: indexURL, options: .atomic)
        } catch {
            self.error = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    /// On first launch, brings in the documents opened before the library existed.
    private func importRecentDocuments() {
        for url in NSDocumentController.shared.recentDocumentURLs where url.pathExtension == "caddy" {
            if FileManager.default.fileExists(atPath: url.path) { importScript(at: url, in: nil) }
        }
        saveIndex()
    }
}

extension String {
    /// A script or project name as shown: cut to 30 characters with an
    /// ellipsis. The full name is kept, and shown when renaming.
    var displayName: String {
        count > 30 ? prefix(29).trimmingCharacters(in: .whitespaces) + "…" : self
    }
}

private extension JSONEncoder {
    static var library: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var library: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
