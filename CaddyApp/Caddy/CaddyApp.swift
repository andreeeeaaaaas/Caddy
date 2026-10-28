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
        // Icons only, without the toolbar menu's Icon and Text option.
        .windowToolbarLabelStyle(fixed: .iconOnly)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutButton() }
            CommandGroup(replacing: .newItem) {
                LibraryCommand("New Script from Video…") { ui.chooseVideo(in: ui.targetProject(in: library)) }
                    .keyboardShortcut("n")
                LibraryCommand("New Folder") { ui.newProject(in: library) }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Divider()
                LibraryCommand("Import .caddy File…") { ui.isImporting = true }
            }
            CommandGroup(replacing: .importExport) { ExportButton() }
            CommandGroup(after: .pasteboard) {
                Divider()
                SplitButton()
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
                LibraryCommand("Show onboarding") { ui.isShowingWelcome = true }
                LibraryCommand("Report an issue…") { ui.isReportingIssue = true }
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

/// A menu command that acts in the library window. Closing the window leaves
/// Caddy running, so the command opens it (or brings it forward) first.
struct LibraryCommand: View {
    let title: String
    let action: () -> Void
    @Environment(\.openWindow) private var openWindow

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(title) {
            openWindow(id: "library")
            action()
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
