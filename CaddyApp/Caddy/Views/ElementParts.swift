import SwiftUI

// Pieces shared by the playback panel's cards and the grid's.

/// An element's type, as a button on hover that opens a menu of every type.
/// Only hovering the type itself shows it as a button, not the rest of the card.
struct KindMenu: View {
    let kind: ScriptElement.Kind
    let onChange: (ScriptElement.Kind) -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            KindPicker(kind: kind, onChange: onChange)
        } label: {
            HStack(spacing: 5) {
                Label(kind.title, systemImage: kind.symbol)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .opacity(isHovering ? 1 : 0)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(isHovering ? 0.06 : 0), in: .rect(cornerRadius: 6))
            .padding(.horizontal, -6)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help("Change the type")
    }
}

/// ✦ Confirm for a suggestion, in its purple. A soft tint on hover shows it's a button.
struct ConfirmButton: View {
    let title: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                Text(title)
            }
        }
        .buttonStyle(ConfirmButtonStyle())
        .help(help)
    }
}

private struct ConfirmButtonStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(CaddyStyle.suggested)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(CaddyStyle.suggested.opacity(configuration.isPressed ? 0.2 : isHovering ? 0.12 : 0), in: .rect(cornerRadius: 6))
            // The tint reaches past the label without moving it.
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .animation(CaddyStyle.hover, value: isHovering)
    }
}

/// A plain icon (or icon and label) button that strengthens a little on hover,
/// darker in light mode and lighter in dark, to show it's clickable.
struct IconButtonStyle: ButtonStyle {
    /// How strong it is at rest: 0.5 for secondary, 0.25 for faint.
    var rest = 0.5
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary.opacity(rest + (configuration.isPressed ? 0.35 : isHovering ? 0.2 : 0)))
            .contentShape(.rect)
            .onHover { isHovering = $0 }
            .animation(CaddyStyle.hover, value: isHovering)
    }
}

/// Every element type, the current one ticked.
struct KindPicker: View {
    let kind: ScriptElement.Kind
    let onChange: (ScriptElement.Kind) -> Void

    var body: some View {
        Picker("Type", selection: Binding(get: { kind }, set: { onChange($0) })) {
            ForEach(ScriptElement.Kind.allCases, id: \.self) { kind in
                Label(kind.title, systemImage: kind.symbol).tag(kind)
            }
        }
        .pickerStyle(.inline)
        .labelsHidden()
    }
}

/// Eight dots, four by two.
struct GripDots: View {
    var body: some View {
        Grid(horizontalSpacing: 2.5, verticalSpacing: 2.5) {
            ForEach(0..<2, id: \.self) { _ in
                GridRow {
                    ForEach(0..<4, id: \.self) { _ in
                        Circle().frame(width: 3, height: 3)
                    }
                }
            }
        }
        .foregroundStyle(Color.primary.opacity(0.3))
    }
}

/// A chip per element kind. Picking one adds that element.
struct ElementPicker: View {
    let onPick: (ScriptElement.Kind) -> Void

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(ScriptElement.Kind.allCases, id: \.self) { kind in
                Button {
                    onPick(kind)
                } label: {
                    Label(kind.title, systemImage: kind.symbol)
                }
                .buttonStyle(ChipStyle())
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CaddyStyle.field, in: .rect(cornerRadius: 12))
    }
}

private struct ChipStyle: ButtonStyle {
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Color.primary.opacity(configuration.isPressed ? 0.2 : isHovering ? 0.14 : 0.07), in: .capsule)
            .animation(CaddyStyle.hover, value: isHovering)
            .contentShape(.capsule)
            .onHover { isHovering = $0 }
    }
}

/// Lays children out in rows, wrapping when the next one doesn't fit.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty && rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            let gap = rows[rows.count - 1].indices.isEmpty ? 0 : spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += gap + size.width
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows
    }
}

/// One element: its kind, where a suggestion came from, and its text.
/// Suggestions are tinted purple with ✦ Confirm and a faint Dismiss, and can't be dragged until confirmed.
/// Used by the playback panel and the grid.
struct ElementView: View {
    let element: ScriptElement
    @Binding var text: String
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let onAccept: () -> Void
    let onChangeKind: (ScriptElement.Kind) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void
    /// The playback panel's drag, in `PlaybackView.space`.
    let onDragChanged: (DragGesture.Value) -> Void
    let onDragEnded: (DragGesture.Value) -> Void

    @State private var isHovering = false

    private var isFocused: Bool { focus.wrappedValue == .element(element.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                KindMenu(kind: element.kind, onChange: onChangeKind)
                Spacer()
                if let source = element.source {
                    HStack(spacing: 10) {
                        ConfirmButton(title: "Confirm", help: "Confirm this suggestion, \(source.title)", action: onAccept)
                        iconButton("Dismiss", systemImage: "trash", help: "Dismiss this suggestion", rest: 0.25, action: onDelete)
                    }
                } else if isHovering {
                    iconButton("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                    iconButton("Delete", systemImage: "trash", action: onDelete)
                }
            }
            .frame(height: 16)

            TextField(element.kind.title, text: $text, prompt: Text(element.kind.prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .lineSpacing(3)
                .focused(focus, equals: .element(element.id))
                .onExitCommand { focus.wrappedValue = .player }
                .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
        // A suggestion is tinted purple until it's confirmed; then it's a plain card that can be dragged.
        .background(element.isSuggested ? CaddyStyle.suggested.opacity(0.06) : CaddyStyle.field, in: .rect(cornerRadius: 12))
        // The tints are translucent; a solid backing keeps a selected grid row's blue out of them.
        .background(.background, in: .rect(cornerRadius: 12))
        .overlay(alignment: .top) {
            if !element.isSuggested { handle }
        }
        .overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onHover { isHovering = $0 }
    }

    /// The strip along a confirmed card's top: drag it to reorder the card, or
    /// to another section. Shows a grip on hover.
    private var handle: some View {
        GripDots()
            .opacity(isHovering ? 1 : 0)
            .padding(.top, 3.5)
            .frame(maxWidth: .infinity, minHeight: 14, alignment: .top)
            .contentShape(.rect)
            .pointerStyle(.grabIdle)
            .accessibilityHidden(true)
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .named(PlaybackView.space))
                    .onChanged(onDragChanged)
                    .onEnded(onDragEnded)
            )
            .help("Drag to reorder, or onto a section in the bar to move it there")
    }

    private func iconButton(_ title: String, systemImage: String, help: String? = nil, rest: Double = 0.5, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle(rest: rest))
            .help(help ?? title)
    }
}

/// A still copy of a confirmed card, lifted while it's dragged.
struct CardFace: View {
    let element: ScriptElement

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Label(element.kind.title, systemImage: element.kind.symbol)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(height: 16)
            Text(element.text.isEmpty ? element.kind.prompt : element.text)
                .foregroundStyle(element.text.isEmpty ? .tertiary : .primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 12)
        .background(CaddyStyle.field, in: .rect(cornerRadius: 12))
        // The field colour is translucent; nothing should show through a lifted card.
        .background(.background, in: .rect(cornerRadius: 12))
    }
}
