import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The grid view: the whole script as a table with one row per section. Its
/// Script cell holds the section's elements as cards, in the order they happen,
/// as the playback panel and the export have them. Hover a frame to skim the
/// section, with Play and Loop on it.
///
/// Laid out by hand rather than with `Table`, whose selection is the strong
/// accent and which lays cells out at a column's widest, so a frame couldn't
/// follow its column's width.
struct ScriptTable: View {
    @Binding var rows: [ScriptRow]
    @Binding var selection: ScriptRow.ID?
    let playback: Playback
    let thumbnails: Thumbnails
    /// The time under the pointer while it skims a frame, where ⌘F adds a section.
    @Binding var skimTime: Double?
    /// Opens a section in the playback view.
    let onOpen: (ScriptRow.ID) -> Void

    @AppStorage("gridFrameWidth") private var frameWidth = 288.0
    @AppStorage("gridTimeWidth") private var timeWidth = 96.0
    @State private var loopingRow: ScriptRow.ID?
    @FocusState private var focus: PlaybackView.Focus?
    @State private var hoveredRow: ScriptRow.ID?
    /// The row whose context menu is open: the only time a row is highlighted.
    /// Rows aren't otherwise shown as selected, since editing doesn't need it.
    @State private var menuRow: ScriptRow.ID?
    @State private var rightClickMonitor: Any?
    @Environment(\.undoManager) private var undoManager

    private static let numberWidth: CGFloat = 36
    private static let inset: CGFloat = 10
    /// Each cell's own inset from its column's edges.
    fileprivate static let cellPadding: CGFloat = 8

    private var isEditingText: Bool {
        if case .element = focus { true } else { false }
    }

    private var loopRange: Range<Double>? {
        guard let loopingRow, let index = rows.firstIndex(where: { $0.id == loopingRow }) else { return nil }
        return rows.segment(index, duration: playback.duration)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            rowView(index, row)
                                .id(row.id)
                        }
                    }
                    .padding(.horizontal, Self.inset)
                    .padding(.vertical, 6)
                }
                .onChange(of: selection) {
                    if let selection { proxy.scrollTo(selection) }
                }
            }
        }
        // Takes focus itself, so a card's field doesn't get it when the window opens.
        .focusable()
        .focusEffectDisabled()
        .onAppear(perform: watchRightClicks)
        .onDisappear {
            if let rightClickMonitor { NSEvent.removeMonitor(rightClickMonitor) }
            rightClickMonitor = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { _ in
            menuRow = nil
        }
        .onChange(of: focus) {
            if isEditingText { playback.pause() }
        }
        .onChange(of: loopRange) { playback.setLoop(loopRange) }
        .onDisappear { playback.setLoop(nil) }
    }

    // MARK: Layout

    private var header: some View {
        HStack(spacing: 0) {
            HeaderCell(title: "#")
                .frame(width: Self.numberWidth, alignment: .leading)
            HeaderCell(title: "Frame", width: $frameWidth, range: 160...560)
                .frame(width: frameWidth, alignment: .leading)
            HeaderCell(title: "Time", width: $timeWidth, range: 72...160)
                .frame(width: timeWidth, alignment: .leading)
            HeaderCell(title: "Script")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Self.inset)
        .frame(height: 28)
    }

    private func rowView(_ index: Int, _ row: ScriptRow) -> some View {
        let range = rows.segment(index, duration: playback.duration)
        let isHighlighted = row.id == menuRow
        // No line under or over the highlight.
        let showsSeparator = !isHighlighted && index + 1 < rows.count && rows[index + 1].id != menuRow
        return HStack(alignment: .top, spacing: 0) {
            Text("\(index + 1)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.cellPadding)
                .frame(width: Self.numberWidth, alignment: .leading)
            FrameCell(
                range: range,
                width: frameWidth - Self.cellPadding * 2,
                playback: playback,
                thumbnails: thumbnails,
                skimTime: $skimTime,
                isLooping: loopingRow == row.id,
                onPlay: { togglePlay(row.id) },
                onLoop: { toggleLoop(row.id) }
            )
            .padding(.horizontal, Self.cellPadding)
            .frame(width: frameWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: 8) {
                Text("\(Timecode.compact(range.lowerBound)) – \(Timecode.compact(range.upperBound))")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if row.suggestionCount > 1 {
                    Button("Confirm All") { acceptAll(row.id) }
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .help("Confirm every suggestion in this section")
                }
            }
            .padding(.horizontal, Self.cellPadding)
            .frame(width: timeWidth, alignment: .leading)
            ScriptCell(
                row: binding(for: row.id),
                isHovered: hoveredRow == row.id,
                focus: $focus,
                edit: { name, body in edit(row.id, name, body) },
                move: move
            )
            .padding(.horizontal, Self.cellPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(isHighlighted ? Color.accentColor.opacity(0.12) : .clear)
                .contentShape(.rect)
                .onTapGesture { focus = nil }
                .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen(row.id) })
        }
        .overlay(alignment: .bottom) {
            if showsSeparator {
                Rectangle()
                    .fill(.separator)
                    .frame(height: 1)
                    .padding(.horizontal, Self.cellPadding)
            }
        }
        // Clicking anything in the row, a card included, selects it, so
        // switching to playback stays on this section.
        .simultaneousGesture(TapGesture().onEnded { selection = row.id })
        .onHover { isHovering in
            if isHovering { hoveredRow = row.id } else if hoveredRow == row.id { hoveredRow = nil }
        }
        .contextMenu {
            Button(playback.isPlaying && range.contains(playback.currentTime) ? "Pause" : "Play Section \(index + 1)", systemImage: "play.fill") { togglePlay(row.id) }
            Button(loopingRow == row.id ? "Stop Looping" : "Loop Section \(index + 1)", systemImage: "repeat") { toggleLoop(row.id) }
            Button("Open in Playback", systemImage: "play.rectangle") { onOpen(row.id) }
            if row.suggestionCount > 0 {
                Button("Confirm Suggestions", systemImage: "checkmark.circle") { acceptAll(row.id) }
            }
            Divider()
            Button("Delete Section \(index + 1)", systemImage: "trash", role: .destructive) { delete(row.id) }
                .disabled(index == 0)
        }
    }

    // MARK: Actions

    /// Notes the row under the pointer when a context menu opens (right-click or
    /// Control-click), to highlight it until the menu closes.
    private func watchRightClicks() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                MainActor.assumeIsolated { menuRow = hoveredRow }
            }
            return event
        }
    }

    /// Plays the section, or pauses it if it's playing. A looping section plays on in its loop.
    private func togglePlay(_ id: ScriptRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selection = id
        let range = rows.segment(index, duration: playback.duration)
        if playback.isPlaying && range.contains(playback.currentTime) {
            playback.pause()
        } else if loopingRow == id {
            playback.togglePlay()
        } else {
            stopLooping()
            playback.playSegment(from: range.lowerBound, to: range.upperBound)
        }
    }

    /// Loops the section, playing it, or stops looping and lets it play to its end.
    private func toggleLoop(_ id: ScriptRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        selection = id
        let range = rows.segment(index, duration: playback.duration)
        if loopingRow == id {
            stopLooping()
            if playback.isPlaying { playback.playSegment(from: playback.currentTime, to: range.upperBound) }
        } else {
            loopingRow = id
            playback.setLoop(range)
            if !playback.isPlaying { playback.togglePlay() }
        }
    }

    private func stopLooping() {
        loopingRow = nil
        playback.setLoop(nil)
    }

    /// Merges the section into the one before it.
    private func delete(_ id: ScriptRow.ID) {
        if loopingRow == id { stopLooping() }
        if let kept = $rows.merge(id, undoManager: undoManager) { selection = kept }
    }

    private func acceptAll(_ id: ScriptRow.ID) {
        edit(id, "Confirm Suggestions") { $0.acceptAll() }
    }

    private func move(_ id: ScriptElement.ID, to rowID: ScriptRow.ID, at index: Int?) {
        $rows.change("Move Element", undoManager: undoManager) { rows in
            rows.move(element: id, to: rowID, at: index)
        }
    }

    private func edit(_ id: ScriptRow.ID, _ actionName: String, _ body: (inout ScriptRow) -> Void) {
        $rows.change(actionName, undoManager: undoManager) { rows in
            if let index = rows.firstIndex(where: { $0.id == id }) { body(&rows[index]) }
        }
    }

    /// Looks the row up by ID on every access, so a row removed by analysis can't leave a stale index.
    private func binding(for id: ScriptRow.ID) -> Binding<ScriptRow> {
        let fallback = rows.first { $0.id == id } ?? ScriptRow(time: 0)
        return Binding {
            rows.first { $0.id == id } ?? fallback
        } set: { newValue in
            if let index = rows.firstIndex(where: { $0.id == id }) { rows[index] = newValue }
        }
    }
}

/// A column's title, with a divider on its trailing edge that resizes the column when it has a width to change.
private struct HeaderCell: View {
    let title: String
    var width: Binding<Double>? = nil
    var range: ClosedRange<Double> = 0...0

    @State private var startWidth: Double?

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, ScriptTable.cellPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .trailing) {
                if let width { resizer(width) }
            }
    }

    private func resizer(_ width: Binding<Double>) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1, height: 14)
            .frame(width: 9, height: 28)
            .contentShape(.rect)
            .offset(x: 4)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { value in
                        let start = startWidth ?? width.wrappedValue
                        startWidth = start
                        width.wrappedValue = min(max(start + value.translation.width, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startWidth = nil }
            )
            .help("Drag to resize the column")
    }
}

/// A section's first frame, as wide as its column. Hovering skims through the
/// section and shows Play and Loop; while the section plays, the video shows here.
private struct FrameCell: View {
    let range: Range<Double>
    let width: CGFloat
    let playback: Playback
    let thumbnails: Thumbnails
    @Binding var skimTime: Double?
    let isLooping: Bool
    let onPlay: () -> Void
    let onLoop: () -> Void

    /// How far across the frame the pointer is, from 0 to 1.
    @State private var skim: Double?
    /// The last frame shown, kept while the next one loads so skimming doesn't flicker.
    @State private var lastShown: Double?

    /// Frames skimming can show per section. Each is cached, so a few will do.
    private static let steps = 16

    private var height: CGFloat { (width * 9 / 16).rounded() }

    private var isPlayingHere: Bool {
        playback.isPlaying && range.contains(playback.currentTime)
    }

    /// The time under the pointer.
    private var exactSkim: Double? {
        skim.map { range.lowerBound + $0 * (range.upperBound - range.lowerBound) }
    }

    /// The frame to show: the skim position rounded down to one of `steps`, or the section's start.
    private var frameTime: Double {
        guard let skim, !range.isEmpty else { return range.lowerBound }
        let step = min(Double(Self.steps - 1), (skim * Double(Self.steps)).rounded(.down))
        return range.lowerBound + step * (range.upperBound - range.lowerBound) / Double(Self.steps)
    }

    var body: some View {
        let time = frameTime
        Rectangle()
            .fill(CaddyStyle.placeholder)
            .overlay {
                if isPlayingHere {
                    PlayerView(player: playback.player, showsControls: false, gravity: .resizeAspectFill)
                } else if let image = thumbnails.images[time] ?? lastShown.flatMap({ thumbnails.images[$0] }) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .topLeading) {
                if let skim, !isPlayingHere {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 2)
                        .offset(x: skim * width - 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if let exactSkim, !isPlayingHere {
                    Text(Self.label(exactSkim))
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                        .padding(6)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if skim != nil || isLooping {
                    HStack(spacing: 4) {
                        Button(isPlayingHere ? "Pause" : "Play", systemImage: isPlayingHere ? "pause.fill" : "play.fill", action: onPlay)
                            .help(isPlayingHere ? "Pause" : "Play")
                        Button("Loop", systemImage: "repeat", action: onLoop)
                            .buttonStyle(FrameButtonStyle(isOn: isLooping))
                            .help(isLooping ? "Stop looping" : "Loop")
                    }
                    .buttonStyle(FrameButtonStyle())
                    .labelStyle(.iconOnly)
                    .padding(6)
                }
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 6))
            .contentShape(.rect)
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    skim = min(max(location.x / width, 0), 1)
                    skimTime = exactSkim
                case .ended:
                    skim = nil
                    skimTime = nil
                }
            }
            .onTapGesture(perform: onPlay)
            .task(id: time) { thumbnails.request(time) }
            .onChange(of: thumbnails.images[time] != nil, initial: true) { _, isLoaded in
                if isLoaded { lastShown = time }
            }
    }

    /// `M:SS.s`
    private static func label(_ seconds: Double) -> String {
        let s = max(0, seconds)
        return String(format: "%d:%04.1f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }
}

/// The small dark buttons on a frame, like the player bar's. `isOn` tints a toggle.
private struct FrameButtonStyle: ButtonStyle {
    var isOn = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(isOn ? .mint : .white)
            .frame(width: 28, height: 22)
            .background(.black.opacity(configuration.isPressed ? 0.8 : isHovering ? 0.7 : 0.55), in: .rect(cornerRadius: 6))
            .contentShape(.rect(cornerRadius: 6))
            .onHover { isHovering = $0 }
    }
}

/// A section's elements as cards, top to bottom in the order they happen. The
/// selected row can add elements. Cards dropped here land between the cards
/// nearest the pointer.
private struct ScriptCell: View {
    @Binding var row: ScriptRow
    let isHovered: Bool
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let edit: (String, (inout ScriptRow) -> Void) -> Void
    let move: (ScriptElement.ID, ScriptRow.ID, Int?) -> Void

    @State private var isPicking = false
    @State private var isTargeted = false
    /// Each card's frame in the cell, for placing a drop.
    @State private var frames: [ScriptElement.ID: CGRect] = [:]

    nonisolated private static let space = "scriptCell"
    /// Cards stop here, however wide the column, so Confirm stays near the text.
    static let cardWidth: CGFloat = 600

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(row.elements) { element in
                TableCard(
                    element: element,
                    text: text(for: element.id),
                    focus: focus,
                    onAccept: { edit("Confirm Suggestion") { $0.accept(element.id) } },
                    onChangeKind: { kind in
                        guard kind != element.kind else { return }
                        edit("Change to \(kind.title)") { $0.change(element.id, to: kind) }
                    },
                    onDuplicate: { edit("Duplicate \(element.kind.title)") { $0.duplicate(element.id) } },
                    onDelete: { edit(element.isSuggested ? "Dismiss Suggestion" : "Delete Element") { $0.remove(element.id) } }
                )
                .frame(maxWidth: Self.cardWidth)
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[element.id] = $0 }
            }
            if isPicking {
                ElementPicker(onPick: add)
                    .frame(maxWidth: Self.cardWidth)
            } else {
                // Always laid out, so rows don't change height as the pointer passes.
                Button {
                    isPicking = true
                } label: {
                    Label("Add Element", systemImage: "plus")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(.named(Self.space))
        .dropDestination(for: ElementDrag.self) { items, location in
            guard let id = items.first?.id else { return false }
            // Counted with the dragged card still in place, as `move` expects.
            let index = row.elements.filter { (frames[$0.id]?.midY ?? .infinity) < location.y }.count
            move(id, row.id, index)
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-4)
                    .frame(maxWidth: Self.cardWidth + 8, maxHeight: .infinity, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .allowsHitTesting(false)
            }
        }
        .onChange(of: isHovered) {
            if !isHovered { isPicking = false }
        }
    }

    /// Typing in a suggestion accepts it.
    private func text(for id: ScriptElement.ID) -> Binding<String> {
        Binding {
            row.elements.first { $0.id == id }?.text ?? ""
        } set: { newValue in
            // Focusing a field can write its text back unchanged, which mustn't accept it.
            guard let index = row.elements.firstIndex(where: { $0.id == id }), row.elements[index].text != newValue else { return }
            row.elements[index].text = newValue
            row.elements[index].source = nil
        }
    }

    private func add(_ kind: ScriptElement.Kind) {
        let element = ScriptElement(kind: kind, text: "")
        edit("Add \(kind.title)") { $0.elements.append(element) }
        isPicking = false
        Task { focus.wrappedValue = .element(element.id) }
    }
}

/// One element on a line: its type, its text, then Confirm for a suggestion or
/// Duplicate and Delete on hover. Capped in width so Confirm stays near the text.
/// A confirmed card drags by its top edge to reorder it or move it to another row.
private struct TableCard: View {
    let element: ScriptElement
    @Binding var text: String
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let onAccept: () -> Void
    let onChangeKind: (ScriptElement.Kind) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindMenu(kind: element.kind, onChange: onChangeKind)
                .frame(width: 108, alignment: .leading)
            TextField(element.kind.title, text: $text, prompt: Text(element.kind.prompt), axis: .vertical)
                .textFieldStyle(.plain)
                .lineSpacing(3)
                .focused(focus, equals: .element(element.id))
                .onExitCommand { focus.wrappedValue = .player }
                .labelsHidden()
            actions
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(element.isSuggested ? CaddyStyle.suggested.opacity(0.06) : CaddyStyle.field, in: .rect(cornerRadius: 8))
        // The tints are translucent; a solid backing keeps a highlighted row's blue out of them.
        .background(.background, in: .rect(cornerRadius: 8))
        .overlay(alignment: .top) {
            if !element.isSuggested { handle }
        }
        .overlay {
            if focus.wrappedValue == .element(element.id) {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .onHover { isHovering = $0 }
    }

    @ViewBuilder
    private var actions: some View {
        if let source = element.source {
            HStack(spacing: 10) {
                Button(action: onAccept) {
                    HStack(spacing: 2) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 11))
                        Text("Confirm")
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(CaddyStyle.suggested)
                .help("Confirm this suggestion, \(source.title)")
                iconButton("Dismiss", systemImage: "trash", action: onDelete)
                    .foregroundStyle(.tertiary)
            }
        } else {
            // Always laid out, so the text doesn't reflow when they appear.
            HStack(spacing: 8) {
                iconButton("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                iconButton("Delete", systemImage: "trash", action: onDelete)
            }
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
        }
    }

    /// The strip along the card's top, with a grip on hover.
    private var handle: some View {
        GripDots()
            .opacity(isHovering ? 1 : 0)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, minHeight: 11, alignment: .top)
            .contentShape(.rect)
            .pointerStyle(.grabIdle)
            .draggable(ElementDrag(id: element.id)) {
                CardFace(element: element).frame(width: 360)
            }
            .help("Drag to reorder, or onto another section")
            .accessibilityHidden(true)
    }

    private func iconButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(.plain)
            .help(title)
    }
}

#Preview {
    ScriptTable(
        rows: .constant(Script.sample.rows),
        selection: .constant(Script.sample.rows[1].id),
        playback: Playback(),
        thumbnails: Thumbnails(),
        skimTime: .constant(nil),
        onOpen: { _ in }
    )
    .frame(width: 1280, height: 720)
}
