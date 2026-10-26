import AppKit
import SwiftUI

/// Export options, then a save panel. Frames are grabbed from the video, then
/// the DOCX or PDF is written.
struct ExportSheet: View {
    let script: Script
    var title = ""
    /// The script's project.
    var project = ""
    var created = Date()
    var fps: Double = 25

    @Environment(\.dismiss) private var dismiss
    @State private var options = ExportOptions()
    @State private var template = "frog CAD script"
    @State private var export: Task<Void, Never>?
    @State private var failure: String?

    private var rows: [ScriptRow] { script.rows }
    private var suggestionCount: Int { rows.map(\.suggestionCount).reduce(0, +) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Script")
                .font(.headline)

            HStack(alignment: .top, spacing: 22) {
                PagePreview(showThumbnails: options.includeThumbnails)
                    .frame(width: 150, height: 212)
                VStack(alignment: .leading, spacing: 14) {
                    group("Format") {
                        Picker("Format", selection: $options.format) {
                            ForEach(ExportOptions.Format.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    group("Template") {
                        Picker("Template", selection: $template) {
                            Text("frog CAD script").tag("frog CAD script")
                        }
                        .labelsHidden()
                    }
                    group("Include") {
                        Toggle("Frame thumbnails", isOn: $options.includeThumbnails)
                        Toggle("Scene descriptions", isOn: $options.includeSceneDescriptions)
                        Toggle("Suggestions not yet confirmed", isOn: $options.includeSuggestions)
                    }
                }
            }

            if let warning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 6))
            }

            if let failure {
                Label(failure, systemImage: "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
            }

            HStack {
                if export != nil {
                    ProgressView()
                        .controlSize(.small)
                    Text("Exporting…")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…", action: chooseFile)
                    .keyboardShortcut(.defaultAction)
                    .disabled(export != nil)
            }
        }
        .padding(22)
        .frame(width: 580)
        .onDisappear { export?.cancel() }
    }

    private var warning: String? {
        guard suggestionCount > 0 else { return nil }
        let count = suggestionCount == 1 ? "1 suggestion isn't" : "\(suggestionCount) suggestions aren't"
        return "\(count) confirmed yet. " + (options.includeSuggestions ? "They'll be exported as they are." : "They'll be left out.")
    }

    /// The script's name, without characters a file name can't hold.
    private var fileName: String {
        let name = title.components(separatedBy: CharacterSet(charactersIn: "/:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? "Script" : name
    }

    /// The video's name, without its extension, under the title.
    private var details: String {
        script.videoURL?.deletingPathExtension().lastPathComponent ?? ""
    }

    private func chooseFile() {
        failure = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [options.format.contentType]
        panel.nameFieldStringValue = "\(fileName).\(options.format.fileExtension)"
        panel.canCreateDirectories = true
        let options = options
        export = Task {
            let response = if let window = NSApp.keyWindow {
                await panel.beginSheetModal(for: window)
            } else {
                await panel.begin()
            }
            if response == .OK, let url = panel.url {
                await write(to: url, options: options)
            }
            export = nil
        }
    }

    private func write(to url: URL, options: ExportOptions) async {
        var document = Exporter.document(title: title.isEmpty ? "Script" : title, folder: project, details: details,
                                         created: created, rows: rows, fps: fps, options: options)
        if options.includeThumbnails, let videoURL = script.videoURL {
            let frames = await Exporter.frames(from: videoURL, at: document.sections.map(\.time))
            for index in document.sections.indices {
                document.sections[index].frame = frames[document.sections[index].time]
            }
        }
        guard !Task.isCancelled else { return }
        let data: Data
        do {
            data = switch options.format {
            case .docx: try DocxWriter.data(for: document)
            case .pdf: PDFWriter.data(for: document)
            }
        } catch {
            failure = "Couldn't export the script. \(error.localizedDescription)"
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            dismiss()
        } catch {
            failure = "Couldn't save the file. \(error.localizedDescription)"
        }
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }
}

/// A sketch of the exported page.
private struct PagePreview: View {
    let showThumbnails: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bar(70, 6, .secondary.opacity(0.5))
            bar(50, 4, CaddyStyle.placeholder)
            ForEach(0..<5, id: \.self) { _ in
                HStack(alignment: .top, spacing: 6) {
                    if showThumbnails {
                        Rectangle().fill(CaddyStyle.placeholder).frame(width: 40, height: 24)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        bar(76, 4, CaddyStyle.placeholder)
                        bar(60, 4, CaddyStyle.placeholder)
                        bar(44, 4, CaddyStyle.placeholder.opacity(0.6))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.white, in: .rect(cornerRadius: 3))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
    }

    private func bar(_ width: CGFloat, _ height: CGFloat, _ color: Color) -> some View {
        Rectangle().fill(color).frame(width: width, height: height)
    }
}

#Preview {
    ExportSheet(script: .sample, title: "Summer Sale", project: "Retail")
}
