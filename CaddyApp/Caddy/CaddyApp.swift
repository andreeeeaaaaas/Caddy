import SwiftUI

@main
struct CaddyApp: App {
    var body: some Scene {
        Window("Welcome to Caddy", id: WelcomeView.windowID) {
            WelcomeView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.presented)

        DocumentGroup(newDocument: CaddyDocument()) { file in
            DocumentView(document: file.$document)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            // Just what the cards' text keeps.
            CommandMenu("Format") {
                Button("Bold") { CardTextFormat.toggle(.bold) }
                    .keyboardShortcut("b")
                Button("Italic") { CardTextFormat.toggle(.italic) }
                    .keyboardShortcut("i")
                Button("Underline") { CardTextFormat.toggle(.underline) }
                    .keyboardShortcut("u")
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
