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
            CommandGroup(replacing: .appInfo) { AboutButton() }
            CommandGroup(replacing: .newItem) {
                Button("New Script from Video…") { ui.chooseVideo(in: ui.targetProject(in: library)) }
                    .keyboardShortcut("n")
                Button("New Folder") { ui.newProject(in: library) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                Button("Import .caddy File…") { ui.isImporting = true }
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
            // In place of Caddy Help, which has no help book to open.
            CommandGroup(replacing: .help) {
                Button("Show onboarding") { ui.isShowingWelcome = true }
                Button("Report an issue…") { ui.isReportingIssue = true }
            }
        }

        Window("About Caddy", id: "about") {
            AboutView()
                .windowMinimizeBehavior(.disabled)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .defaultPosition(.center)
        // Opened from the Caddy menu, not listed in the Window menu.
        .commandsRemoved()
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
