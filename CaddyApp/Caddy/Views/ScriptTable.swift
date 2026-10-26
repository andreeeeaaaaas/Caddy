import AppKit
import AVFoundation
import Combine
import SwiftUI

/// The grid view: the whole script as a table with one row per section. Its
/// Script cell holds the section's elements as cards, in the order they happen,
/// as the playback panel and the export have them. Hover a frame to skim the
/// section, with Play and Loop on it. Cards drag as in the playback panel:
/// the card lifts and follows the pointer while the others make room for it.
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
    /// The section under the playhead while it plays. Watched by `PlayheadWatcher`,
    /// so the table redraws when the playing section changes, not every frame.
    @State private var playingRow: ScriptRow.ID?
    /// The row whose context menu is open: the only time a row is highlighted.
    /// Rows aren't otherwise shown as selected, since editing doesn't need it.
    @State private var menuRow: ScriptRow.ID?
    @State private var rightClickMonitor: Any?
    @State private var drag: GridDrag?
    @State private var layout = GridLayout()
    @Environment(\.undoManager) private var undoManager

    /// The coordinate space a dragged card moves in, above the scroll view.
    nonisolated static let space = "grid"
    /// The scrolled content's own space, where cards and rows are measured, so
    /// their frames don't change as it scrolls.
    nonisolated fileprivate static let contentSpace = "gridContent"

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
            // The card stays under the pointer while the rows scroll past it.
            GridScroller(selection: selection, autoScrollSpeed: autoScrollSpeed, layout: layout, onScroll: updateTarget) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        HoverRow(id: row.id, layout: layout) { isHovered in
                            rowView(index, row, isHovered: isHovered)
                        }
                        .id(row.id)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.contentSpace)) } action: { layout.rows[row.id] = $0 }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, Self.inset)
                .padding(.vertical, 6)
                .coordinateSpace(.named(Self.contentSpace))
                .animation(.spring(duration: 0.3, bounce: 0.15), value: drag?.slot)
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { layout.scrollFrame = $0 }
        }
        .overlay(alignment: .topLeading) { liftedCard }
        // Cards drag from here rather than from their own handles: a lazy row
        // scrolled off screen would end its gesture mid-drag.
        .simultaneousGesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged(dragChanged)
                .onEnded(dragEnded)
        )
        .coordinateSpace(.named(Self.space))
        .background { PlayheadWatcher(playback: playback, rows: rows) { playingRow = $0 } }
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

    private func rowView(_ index: Int, _ row: ScriptRow, isHovered: Bool) -> some View {
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
                isPlaying: playingRow == row.id,
                isLooping: loopingRow == row.id,
                onPlay: { togglePlay(row.id) },
                onLoop: { toggleLoop(row.id) }
            )
            .padding(.horizontal, Self.cellPadding)
            .frame(width: frameWidth, alignment: .leading)
            Text("\(Timecode.compact(range.lowerBound)) – \(Timecode.compact(range.upperBound))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, Self.cellPadding)
            .frame(width: timeWidth, alignment: .leading)
            ScriptCell(
                row: binding(for: row.id),
                isHovered: isHovered,
                focus: $focus,
                edit: { name, body in edit(row.id, name, body) },
                onAcceptAll: { acceptAll(row.id) },
                drag: drag,
                layout: layout
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
        .contextMenu {
            Button(playingRow == row.id ? "Pause" : "Play Section \(index + 1)", systemImage: "play.fill") { togglePlay(row.id) }
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

    // MARK: Dragging

    /// The dragged card, above the rows so it can travel between them.
    @ViewBuilder
    private var liftedCard: some View {
        if let drag {
            TableCardFace(element: drag.element)
                .frame(width: drag.size.width, height: drag.size.height, alignment: .top)
                .scaleEffect(drag.isLifted ? 1.03 : 1)
                .shadow(color: .black.opacity(drag.isLifted ? 0.18 : 0), radius: 14, y: 8)
                .offset(x: drag.origin.x, y: drag.origin.y)
                .allowsHitTesting(false)
        }
    }

    /// A confirmed card whose handle, the strip along its top, is under a point in `ScriptTable.space`.
    private func handle(at point: CGPoint) -> (element: ScriptElement, row: ScriptRow.ID, from: Int, frame: CGRect)? {
        guard layout.scrollFrame.contains(point) else { return nil }
        let point = CGPoint(x: point.x - layout.scrollFrame.minX, y: layout.contentY(point.y))
        for row in rows where layout.rows[row.id]?.contains(point) == true {
            for (index, element) in row.elements.enumerated() where !element.isSuggested {
                guard let frame = layout.cards[element.id], frame.contains(point), point.y < frame.minY + TableCard.handleHeight else { continue }
                return (element, row.id, index, layout.grid(frame))
            }
        }
        return nil
    }

    private func dragChanged(_ value: DragGesture.Value) {
        if drag == nil {
            // Decided once per gesture, so a drag elsewhere can't become a card drag as the rows scroll.
            guard !layout.ignoresGesture else { return }
            guard let (element, rowID, from, frame) = handle(at: value.startLocation) else {
                layout.ignoresGesture = true
                return
            }
            playback.pause()
            focus = nil
            drag = GridDrag(
                element: element,
                fromRow: rowID,
                from: from,
                grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                size: frame.size,
                origin: frame.origin,
                pointer: value.location,
                slot: GridDrag.Slot(row: rowID, index: from)
            )
            withAnimation(.snappy(duration: 0.2)) { drag?.isLifted = true }
        }
        guard var current = drag else { return }
        current.origin = CGPoint(x: value.location.x - current.grab.width, y: value.location.y - current.grab.height)
        current.pointer = value.location
        drag = current
        updateTarget()
    }

    /// It lands in the row its middle is over, after every other card there
    /// whose middle it has passed.
    private func updateTarget() {
        guard let current = drag else { return }
        let centre = layout.contentY(current.origin.y + current.size.height / 2)
        // Rows off screen may not be laid out, so only a row the middle is
        // actually over counts; past either end the slot stays where it was.
        guard let row = rows.first(where: { layout.rows[$0.id].map { $0.minY <= centre && centre < $0.maxY } ?? false }) else { return }
        let index = row.elements
            .filter { $0.id != current.element.id && (layout.cards[$0.id]?.midY ?? .infinity) < centre }
            .count
        let slot = GridDrag.Slot(row: row.id, index: index)
        if slot != current.slot { drag?.slot = slot }
    }

    /// Settles the card into its slot, then moves it.
    private func dragEnded(_ value: DragGesture.Value) {
        layout.ignoresGesture = false
        guard let current = drag else { return }
        let isHome = current.slot.row == current.fromRow
        let slotFrame = (isHome ? layout.cards[current.element.id] : layout.gap).map(layout.grid)
            ?? CGRect(origin: current.origin, size: current.size)
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            drag?.origin = slotFrame.origin
            drag?.isLifted = false
        } completion: {
            finishDrag {
                let index = current.slot.index
                if !isHome {
                    move(current.element.id, to: current.slot.row, at: index)
                } else if index != current.from {
                    // `move` counts positions with the card still in place.
                    move(current.element.id, to: current.fromRow, at: index < current.from ? index : index + 1)
                }
            }
        }
    }

    /// Makes the move and drops the lifted card in one step, so nothing jumps.
    private func finishDrag(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            body()
            drag = nil
        }
    }

    /// Points a frame to scroll by: faster the further the pointer is into the
    /// table's top or bottom 48 points.
    private var autoScrollSpeed: Int {
        guard let drag, layout.scrollFrame.height > 0 else { return 0 }
        let zone: CGFloat = 48
        let frame = layout.scrollFrame
        let y = drag.pointer.y
        let isUp = y < frame.midY
        let depth = isUp ? frame.minY + zone - y : y - (frame.maxY - zone)
        guard depth > 0 else { return 0 }
        let speed = min(10, max(1, Int((depth / zone * 10).rounded(.up))))
        return isUp ? -speed : speed
    }

    // MARK: Actions

    /// Notes the row under the pointer when a context menu opens (right-click or
    /// Control-click), to highlight it until the menu closes.
    private func watchRightClicks() {
        guard rightClickMonitor == nil else { return }
        rightClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .leftMouseDown]) { event in
            if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
                MainActor.assumeIsolated { menuRow = layout.hoveredRow }
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
    /// Whether the playhead is in this section while it plays.
    let isPlaying: Bool
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
                if isPlaying {
                    PlayerView(player: playback.player, showsControls: false, gravity: .resizeAspectFill)
                } else if let image = thumbnails.images[time] ?? lastShown.flatMap({ thumbnails.images[$0] }) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .overlay(alignment: .topLeading) {
                if let skim, !isPlaying {
                    Rectangle()
                        .fill(.red)
                        .frame(width: 2)
                        .offset(x: skim * width - 1)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if let exactSkim, !isPlaying {
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
            .overlay(alignment: .bottomLeading) {
                if skim != nil || isLooping {
                    HStack(spacing: 6) {
                        Button(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill", action: onPlay)
                            .help(isPlaying ? "Pause" : "Play")
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

/// The dark buttons on a frame, like the player bar's. `isOn` tints a toggle.
private struct FrameButtonStyle: ButtonStyle {
    var isOn = false
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(isOn ? .mint : .white)
            .frame(width: 36, height: 28)
            .background(.black.opacity(configuration.isPressed ? 0.8 : isHovering ? 0.7 : 0.55), in: .rect(cornerRadius: 8))
            .animation(CaddyStyle.hover, value: isHovering)
            .contentShape(.rect(cornerRadius: 8))
            .onHover { isHovering = $0 }
    }
}

/// A section's elements as cards, top to bottom in the order they happen. The
/// selected row can add elements. While a card is dragged over this row, the
/// others make room where it would land.
private struct ScriptCell: View {
    @Binding var row: ScriptRow
    let isHovered: Bool
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let edit: (String, (inout ScriptRow) -> Void) -> Void
    let onAcceptAll: () -> Void
    let drag: GridDrag?
    let layout: GridLayout

    @State private var isPicking = false

    private static let spacing: CGFloat = 4
    /// Cards stop here, however wide the column, so Confirm stays near the text.
    static let cardWidth: CGFloat = 600

    /// The cards in the order shown: the dragged one moved to its slot, or a gap
    /// where it would land when it came from another row.
    private var items: [CellItem] {
        var items = row.elements.map { CellItem(element: $0) }
        guard let drag, drag.slot.row == row.id else { return items }
        if let from = row.elements.firstIndex(where: { $0.id == drag.element.id }) {
            let card = items.remove(at: from)
            items.insert(card, at: min(drag.slot.index, items.count))
        } else {
            items.insert(CellItem(element: nil), at: min(drag.slot.index, items.count))
        }
        return items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(items) { item in
                if let element = item.element {
                    card(element)
                } else {
                    slot
                        .frame(height: drag?.size.height ?? 0)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ScriptTable.contentSpace)) } action: { layout.gap = $0 }
                }
            }
            if isPicking {
                ElementPicker(onPick: add)
                    .frame(maxWidth: Self.cardWidth)
            }
            HStack {
                if !isPicking {
                    // Always laid out, so rows don't change height as the pointer passes.
                    Button {
                        isPicking = true
                    } label: {
                        Label("Add Element", systemImage: "plus")
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .contentShape(.rect)
                    }
                    .buttonStyle(IconButtonStyle())
                    .opacity(isHovered ? 1 : 0)
                    .allowsHitTesting(isHovered)
                }
                Spacer(minLength: 0)
                if row.suggestionCount > 1 {
                    Button("Confirm All", action: onAcceptAll)
                        .buttonBorderShape(.capsule)
                        .controlSize(.small)
                        .help("Confirm every suggestion in this section")
                }
            }
            .frame(maxWidth: Self.cardWidth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: isHovered) {
            if !isHovered { isPicking = false }
        }
    }

    @ViewBuilder
    private func card(_ element: ScriptElement) -> some View {
        let isDragged = element.id == drag?.element.id
        // Over another row, the dragged card's own slot closes.
        let isAway = isDragged && drag?.slot.row != row.id
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
        // The dragged card is hidden, leaving its slot.
        .opacity(isDragged ? 0 : 1)
        .background {
            if isDragged && !isAway { slot }
        }
        .frame(height: isAway ? 0 : nil, alignment: .top)
        .padding(.bottom, isAway ? -Self.spacing : 0)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ScriptTable.contentSpace)) } action: { layout.cards[element.id] = $0 }
    }

    /// Where a dragged card would land.
    private var slot: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(Color.primary.opacity(0.02))
            .frame(maxWidth: Self.cardWidth)
    }

    /// Typing in a suggestion, or styling it, accepts it.
    private func text(for id: ScriptElement.ID) -> Binding<RichText> {
        Binding {
            row.elements.first { $0.id == id }?.richText ?? RichText(text: "", styles: [])
        } set: { newValue in
            // Focusing a field can write its text back unchanged, which mustn't accept it.
            guard let index = row.elements.firstIndex(where: { $0.id == id }), row.elements[index].richText != newValue else { return }
            row.elements[index].richText = newValue
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
    @Binding var text: RichText
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let onAccept: () -> Void
    let onChangeKind: (ScriptElement.Kind) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    /// The strip along the top that drags the card. The table's own gesture
    /// does the dragging, finding the card by this strip.
    static let handleHeight: CGFloat = 12

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            KindMenu(kind: element.kind, onChange: onChangeKind)
                .frame(width: 108, alignment: .leading)
            RichTextField(prompt: element.kind.prompt, value: $text, focus: focus, id: element.id)
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
                ConfirmButton(title: "Confirm", help: "Confirm this suggestion, \(source.title)", action: onAccept)
                iconButton("Dismiss", systemImage: "trash", rest: 0.25, action: onDelete)
            }
        } else {
            // Always laid out, so the text doesn't reflow when they appear.
            HStack(spacing: 8) {
                iconButton("Duplicate", systemImage: "plus.square.on.square", action: onDuplicate)
                iconButton("Delete", systemImage: "trash", action: onDelete)
            }
            .opacity(isHovering ? 1 : 0)
        }
    }

    /// The strip along the card's top, with a grip on hover.
    private var handle: some View {
        GripDots()
            .opacity(isHovering ? 1 : 0)
            .padding(.top, 3)
            .frame(maxWidth: .infinity, minHeight: Self.handleHeight, maxHeight: Self.handleHeight, alignment: .top)
            .contentShape(.rect)
            .pointerStyle(.grabIdle)
            .help("Drag to reorder, or onto another section")
            .accessibilityHidden(true)
    }

    private func iconButton(_ title: String, systemImage: String, rest: Double = 0.5, action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .buttonStyle(IconButtonStyle(rest: rest))
            .help(title)
    }
}

/// A still copy of a confirmed grid card, lifted while it's dragged.
private struct TableCardFace: View {
    let element: ScriptElement

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(element.kind.title, systemImage: element.kind.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 108, alignment: .leading)
            Text(element.text.isEmpty ? AttributedString(element.kind.prompt) : RichTextField.attributed(element.richText, base: .system(size: 13)))
                .foregroundStyle(element.text.isEmpty ? .tertiary : .primary)
                .lineSpacing(3)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(CaddyStyle.field, in: .rect(cornerRadius: 8))
        // The field colour is translucent; nothing should show through a lifted card.
        .background(.background, in: .rect(cornerRadius: 8))
    }
}

/// The table's scroll view. It owns the scroll position, which changes as it
/// scrolls, so scrolling redraws this view rather than every row.
private struct GridScroller<Content: View>: View {
    let selection: ScriptRow.ID?
    let autoScrollSpeed: Int
    let layout: GridLayout
    let onScroll: () -> Void
    @ViewBuilder let content: Content

    @State private var scroll: ScrollPosition

    init(selection: ScriptRow.ID?, autoScrollSpeed: Int, layout: GridLayout, onScroll: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.selection = selection
        self.autoScrollSpeed = autoScrollSpeed
        self.layout = layout
        self.onScroll = onScroll
        self.content = content()
        // Opens on the selected section, coming from playback, without
        // drawing the top first and jumping.
        _scroll = State(initialValue: selection.map { ScrollPosition(id: $0, anchor: .top) } ?? ScrollPosition())
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView { content }
                .scrollPosition($scroll)
                .onScrollGeometryChange(for: GridScroll.self) { geometry in
                    GridScroll(
                        offset: geometry.contentOffset.y,
                        minOffset: -geometry.contentInsets.top,
                        maxOffset: max(-geometry.contentInsets.top, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height)
                    )
                } action: { _, metrics in
                    layout.scroll = metrics
                    onScroll()
                }
                .onChange(of: selection) {
                    if let selection { proxy.scrollTo(selection) }
                }
        }
        .task(id: autoScrollSpeed) { await autoScroll() }
    }

    private func autoScroll() async {
        let speed = CGFloat(autoScrollSpeed)
        guard speed != 0 else { return }
        while !Task.isCancelled {
            let metrics = layout.scroll
            let next = min(max(metrics.offset + speed, metrics.minOffset), metrics.maxOffset)
            if next != metrics.offset { scroll.scrollTo(y: next) }
            try? await Task.sleep(for: .milliseconds(16))
        }
    }
}

/// A row that tracks its own hover, so the pointer crossing rows redraws
/// those two rows rather than the whole table.
private struct HoverRow<Content: View>: View {
    let id: ScriptRow.ID
    let layout: GridLayout
    @ViewBuilder let content: (Bool) -> Content

    @State private var isHovered = false

    var body: some View {
        content(isHovered)
            .onHover { isHovering in
                isHovered = isHovering
                // For the right-click monitor, which highlights the row whose menu is open.
                if isHovering { layout.hoveredRow = id } else if layout.hoveredRow == id { layout.hoveredRow = nil }
            }
    }
}

/// Reports the section under the playhead while it plays. Reading the time
/// here, not in the table, keeps the table from redrawing every frame.
private struct PlayheadWatcher: View {
    let playback: Playback
    let rows: [ScriptRow]
    let onChange: (ScriptRow.ID?) -> Void

    var body: some View {
        let id = playback.isPlaying ? rows.index(at: playback.currentTime).map { rows[$0].id } : nil
        Color.clear.onChange(of: id, initial: true) { onChange(id) }
    }
}

/// A card being dragged in the grid: lifted above the rows and following the
/// pointer, while the cards in the row under it make room where it would land.
private struct GridDrag {
    struct Slot: Equatable {
        var row: ScriptRow.ID
        /// Among the row's other elements.
        var index: Int
    }

    var element: ScriptElement
    var fromRow: ScriptRow.ID
    var from: Int
    /// Where the pointer took hold, from the card's top-left corner.
    var grab: CGSize
    var size: CGSize
    /// The card's top-left corner in `ScriptTable.space`.
    var origin: CGPoint
    var pointer: CGPoint
    var slot: Slot
    var isLifted = false
}

/// A card in a row, or the gap where a card from another row would land.
private struct CellItem: Identifiable {
    let element: ScriptElement?
    var id: String { element?.id.uuidString ?? "gap" }
}

private struct GridScroll: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
}

/// Where cards and rows sit, for placing a dragged card. Not observed: frames
/// change as rows lay out, and only a drag reads them.
private final class GridLayout {
    /// In `ScriptTable.contentSpace`.
    var cards: [ScriptElement.ID: CGRect] = [:]
    var rows: [ScriptRow.ID: CGRect] = [:]
    var gap: CGRect?
    /// The scroll view's frame in `ScriptTable.space`.
    var scrollFrame = CGRect.zero
    var scroll = GridScroll()
    var hoveredRow: ScriptRow.ID?
    /// The current drag didn't start on a card's handle.
    var ignoresGesture = false

    func contentY(_ y: CGFloat) -> CGFloat {
        y - scrollFrame.minY + scroll.offset
    }

    /// A content frame in `ScriptTable.space`.
    func grid(_ frame: CGRect) -> CGRect {
        frame.offsetBy(dx: scrollFrame.minX, dy: scrollFrame.minY - scroll.offset)
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
