import SwiftUI

/// The script as a list of rows. Fields are edited in the inspector.
struct ScriptSheet: View {
    @Binding var rows: [ScriptRow]
    @Binding var selection: ScriptRow.ID?
    let thumbnails: Thumbnails
    let isTranscribing: Bool

    @Environment(\.undoManager) private var undoManager

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SheetRow(row: row, number: index + 1, thumbnails: thumbnails, isTranscribing: isTranscribing)
                        .tag(row.id)
                        .contextMenu {
                            Button("Delete Section \(index + 1)", systemImage: "trash", role: .destructive) { delete(row.id) }
                                .keyboardShortcut(.delete, modifiers: [])
                                .disabled(index == 0)
                        }
                }
            } header: {
                SheetHeader()
            }
        }
        .listStyle(.plain)
        .onDeleteCommand {
            if let selection { delete(selection) }
        }
        .onKeyPress(.return) {
            guard let index = selectedIndex, rows[index].suggestionCount > 0 else { return .ignored }
            $rows.change("Confirm Suggestions", undoManager: undoManager) { rows in
                for i in rows[index].elements.indices { rows[index].elements[i].source = nil }
            }
            return .handled
        }
    }

    private var selectedIndex: Int? {
        rows.firstIndex { $0.id == selection }
    }

    /// Merges the row into the one before it and selects that one.
    private func delete(_ id: ScriptRow.ID) {
        if let kept = $rows.merge(id, undoManager: undoManager) { selection = kept }
    }
}

private enum Column {
    static let number: CGFloat = 24
    static let thumbnail: CGFloat = 112
    static let timecode: CGFloat = 64
    static let supers: CGFloat = 160
    static let notes: CGFloat = 140
    static let status: CGFloat = 20
    static let spacing: CGFloat = 16
}

private struct SheetHeader: View {
    var body: some View {
        HStack(spacing: Column.spacing) {
            Text("#").frame(width: Column.number, alignment: .leading)
            Text("Frame").frame(width: Column.thumbnail, alignment: .leading)
            Text("TC").frame(width: Column.timecode, alignment: .leading)
            Text("VO").frame(maxWidth: .infinity, alignment: .leading)
            Text("Super").frame(width: Column.supers, alignment: .leading)
            Text("Notes").frame(width: Column.notes, alignment: .leading)
            Color.clear.frame(width: Column.status)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .textCase(.uppercase)
        .padding(.vertical, 4)
    }
}

private struct SheetRow: View {
    let row: ScriptRow
    let number: Int
    let thumbnails: Thumbnails
    let isTranscribing: Bool

    private var hasSuggestions: Bool { row.suggestionCount > 0 }

    var body: some View {
        HStack(alignment: .top, spacing: Column.spacing) {
            Text("\(number)")
                .foregroundStyle(.secondary)
                .frame(width: Column.number, alignment: .leading)
            ThumbnailView(time: row.time, thumbnails: thumbnails)
                .frame(width: Column.thumbnail, height: 63)
            Text(Timecode.short(row.time))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: Column.timecode, alignment: .leading)
            vo
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.text(.superText))
                .frame(width: Column.supers, alignment: .leading)
            Text(row.text(.note))
                .foregroundStyle(.secondary)
                .frame(width: Column.notes, alignment: .leading)
            statusIcon
                .frame(width: Column.status)
        }
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var vo: some View {
        VStack(alignment: .leading, spacing: 6) {
            let vo = row.text(.voiceover)
            if vo.isEmpty && isTranscribing {
                Text("Transcribing…")
                    .foregroundStyle(.tertiary)
                    .redacted(reason: .placeholder)
            } else if vo.isEmpty {
                Text("No VO")
                    .foregroundStyle(.tertiary)
            } else {
                Text(vo)
                    .foregroundStyle(row.elements.contains { $0.kind == .voiceover && $0.isSuggested } ? .secondary : .primary)
            }
            if hasSuggestions {
                HStack(spacing: 8) {
                    Text(row.suggestionCount == 1 ? "1 suggestion" : "\(row.suggestionCount) suggestions")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CaddyStyle.placeholder, in: .rect(cornerRadius: 4))
                    Text("⏎ Confirm")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch row.status {
        case .checked:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CaddyStyle.checked)
        case .pending, .detected:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        }
    }
}
