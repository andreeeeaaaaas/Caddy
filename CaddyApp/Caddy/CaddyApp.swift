import SwiftUI

@main
struct CaddyApp: App {
    @State private var library = Library()
    @State private var ui = LibraryUI()

    init() {
        TextMenuCleaner.install()
    }

    var body: some Scene {
        Window("Caddy", id: "library") {
            LibraryView(library: library, ui: ui)
                // No Writing Tools button by the cursor or in text menus, in any field.
                .writingToolsBehavior(.disabled)
        }
        .defaultSize(width: 1440, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Script…") { ui.chooseVideo(in: ui.targetProject(in: library)) }
                    .keyboardShortcut("n")
                Button("New Folder") { ui.newProject(in: library) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Import Script…") { ui.isImporting = true }
            }
            // Just what the cards' text keeps.
            CommandMenu("Format") {
                Button("Bold") { CardTextFormat.toggle(.bold) }
                    .keyboardShortcut("b")
                Button("Italic") { CardTextFormat.toggle(.italic) }
                    .keyboardShortcut("i")
                Button("Underline") { CardTextFormat.toggle(.underline) }
                    .keyboardShortcut("u")
            }
            CommandGroup(after: .help) {
                Button("Welcome to Caddy") { ui.isShowingWelcome = true }
            }
        }
    }
}

/// Video formats AVFoundation can read. The Python app also took MKV and AVI,
/// which AVFoundation can't decode.
enum VideoFile {
    static let extensions: Set<String> = ["mp4", "mov", "m4v"]

    static func isSupported(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
