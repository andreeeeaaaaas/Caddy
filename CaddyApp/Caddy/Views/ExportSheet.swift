import SwiftUI

/// Export options. The DOCX and PDF writers aren't built yet; Export only closes the sheet.
struct ExportSheet: View {
    enum Format: String, CaseIterable, Identifiable {
        case docx = "Word (.docx)"
        case pdf = "PDF"
        var id: Self { self }
    }

    let rows: [ScriptRow]

    @Environment(\.dismiss) private var dismiss
    @State private var format = Format.docx
    @State private var template = "frog CAD script"
    @State private var includeThumbnails = true
    @State private var includeNotes = true
    @State private var includeUnchecked = false

    private var suggestedCount: Int { rows.filter { $0.status == .suggested }.count }
    private var uncheckedCount: Int { rows.filter { $0.status == .pending }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Script")
                .font(.headline)

            HStack(alignment: .top, spacing: 22) {
                PagePreview(showThumbnails: includeThumbnails)
                    .frame(width: 150, height: 212)
                VStack(alignment: .leading, spacing: 14) {
                    group("Format") {
                        Picker("Format", selection: $format) {
                            ForEach(Format.allCases) { Text($0.rawValue).tag($0) }
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
                        Toggle("Frame thumbnails", isOn: $includeThumbnails)
                        Toggle("Notes column", isOn: $includeNotes)
                        Toggle("Rows not yet checked", isOn: $includeUnchecked)
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

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 580)
    }

    private var warning: String? {
        guard !includeUnchecked, suggestedCount + uncheckedCount > 0 else { return nil }
        var parts: [String] = []
        if suggestedCount > 0 { parts.append("\(suggestedCount) still suggested") }
        if uncheckedCount > 0 { parts.append("\(uncheckedCount) unchecked") }
        return "Rows left out of this export: " + parts.joined(separator: ", ") + "."
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
    ExportSheet(rows: Script.sample.rows)
}
