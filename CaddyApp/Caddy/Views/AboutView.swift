import AppKit
import SwiftUI

/// Caddy › About Caddy: the icon, name and version, and who made it.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? ""
        let build = info?["CFBundleVersion"] as? String ?? ""
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Caddy")
                .font(.title.bold())
                .padding(.top, 8)
            Text(version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.top, 2)
            MadeAtFrog(markWidth: 32)
                .font(.headline)
                .padding(.top, 22)
            Text("For the brand and creative team")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
        .padding(.horizontal, 40)
        .padding(.top, 28)
        .padding(.bottom, 32)
        .frame(width: 300)
    }
}

/// Replaces the standard About item, which can't show the frog.
struct AboutButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Caddy") { openWindow(id: "about") }
    }
}

#Preview {
    AboutView()
}
