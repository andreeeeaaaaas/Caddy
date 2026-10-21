import SwiftUI
import UniformTypeIdentifiers

/// Launch window: drop or choose a video, or reopen a recent document.
struct WelcomeView: View {
    static let windowID = "welcome"

    @Environment(\.newDocument) private var newDocument
    @Environment(\.openDocument) private var openDocument
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var isTargeted = false
    @State private var showImporter = false

    var body: some View {
        HStack(spacing: 0) {
            start
                .frame(width: 460)
            Divider()
            recents
                .frame(width: 300)
        }
        .frame(height: 408)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.mpeg4Movie, .quickTimeMovie]) { result in
            if case .success(let url) = result { create(from: url) }
        }
    }

    private var start: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            VStack(spacing: 4) {
                Text("Caddy")
                    .font(.largeTitle.bold())
                Text("Turn a finished ad into a CAD script")
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 8) {
                Text("Drop a video here")
                    .font(.title3.weight(.medium))
                Text("MP4, MOV or M4V")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Choose Video…") { showImporter = true }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, minHeight: 150)
            .background(isTargeted ? Color.accentColor.opacity(0.08) : CaddyStyle.placeholder.opacity(0.3), in: .rect(cornerRadius: 12))
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(isTargeted ? Color.accentColor : .secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
            }
            .dropDestination(for: URL.self) { urls, _ in
                guard let url = urls.first(where: VideoFile.isSupported) else { return false }
                create(from: url)
                return true
            } isTargeted: { isTargeted = $0 }
        }
        .padding(36)
    }

    private var recents: some View {
        let urls = NSDocumentController.shared.recentDocumentURLs
        return VStack(alignment: .leading, spacing: 2) {
            Text("Recent")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            if urls.isEmpty {
                Text("No recent documents")
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }
            ForEach(urls, id: \.self) { url in
                Button {
                    Task {
                        try? await openDocument(at: url)
                        dismissWindow(id: Self.windowID)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(url.deletingPathExtension().lastPathComponent)
                            .fontWeight(.medium)
                        Text(url.deletingLastPathComponent().path(percentEncoded: false))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(12)
        .frame(maxHeight: .infinity)
        .background(.background.secondary)
    }

    private func create(from url: URL) {
        newDocument(CaddyDocument(videoURL: url))
        dismissWindow(id: Self.windowID)
    }
}

#Preview {
    WelcomeView()
}
