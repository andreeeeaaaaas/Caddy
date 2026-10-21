import SwiftUI

/// The script as a list of rows. Fields are edited in the inspector.
struct ScriptSheet: View {
    @Binding var rows: [ScriptRow]
    @Binding var selection: ScriptRow.ID?
    let thumbnails: Thumbnails
    let isTranscribing: Bool

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    SheetRow(row: row, number: index + 1, thumbnails: thumbnails, isTranscribing: isTranscribing)
                        .tag(row.id)
                }
            } header: {
                SheetHeader()
            }
        }
        .listStyle(.plain)
        .onDeleteCommand(perform: removeSelected)
        .onKeyPress(.return) {
            guard let index = selectedIndex, rows[index].status == .suggested else { return .ignored }
            rows[index].status = .pending
            return .handled
        }
    }

    private var selectedIndex: Int? {
        rows.firstIndex { $0.id == selection }
    }

    private func removeSelected() {
        guard let index = selectedIndex else { return }
        rows.remove(at: index)
        selection = rows.indices.contains(index) ? rows[index].id : rows.last?.id
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

    private var isSuggested: Bool { row.status == .suggested }

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
            Text(row.supers)
                .frame(width: Column.supers, alignment: .leading)
            Text(row.notes)
                .foregroundStyle(.secondary)
                .frame(width: Column.notes, alignment: .leading)
            statusIcon
                .frame(width: Column.status)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, isSuggested ? 6 : 0)
        .overlay {
            if isSuggested {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.secondary.opacity(0.6), style: CaddyStyle.suggestionDash)
            }
        }
    }

    @ViewBuilder
    private var vo: some View {
        VStack(alignment: .leading, spacing: 6) {
            if row.vo.isEmpty && isTranscribing && isSuggested {
                Text("Transcribing…")
                    .foregroundStyle(.tertiary)
                    .redacted(reason: .placeholder)
            } else if row.vo.isEmpty {
                Text("No VO")
                    .italic()
                    .foregroundStyle(.tertiary)
            } else {
                Text(row.vo)
                    .foregroundStyle(isSuggested ? .secondary : .primary)
            }
            if isSuggested {
                HStack(spacing: 8) {
                    Text("Suggested")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(CaddyStyle.placeholder, in: .rect(cornerRadius: 4))
                    Text("⏎ Accept   ⌫ Remove")
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
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.tertiary)
        case .suggested:
            EmptyView()
        }
    }
}
