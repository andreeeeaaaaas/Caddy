import AVFoundation
import SwiftUI

/// One fixed player with the section under the playhead beside it, over the
/// player bar. The panel follows playback; typing in it pauses.
struct PlaybackView: View {
    @Binding var rows: [ScriptRow]
    @Binding var selection: ScriptRow.ID?
    let playback: Playback
    /// Set while the video can't be found: the player offers Locate Video….
    var onLocate: (() -> Void)?

    enum Focus: Hashable {
        case player
        case element(ScriptElement.ID)
    }

    /// The coordinate space a dragged card moves in, above the panel and bar.
    static let space = "playback"

    @State private var isLooping = false
    @State private var drag: CardDrag?
    /// The bar's track, for finding the block under a dragged card.
    @State private var trackFrame = CGRect.zero
    /// The panel's scroll view, scrolled while a dragged card is near its top or bottom.
    @State private var scroll = ScrollPosition()
    @State private var scrollMetrics = ScrollMetrics()
    @State private var panelFrame = CGRect.zero
    /// The video's frame, which the panel lines up with.
    @State private var videoFrame = CGRect.zero
    @FocusState private var focus: Focus?
    @Environment(\.undoManager) private var undoManager

    private var selectedIndex: Int? {
        rows.firstIndex { $0.id == selection }
    }

    /// The selected section while looping.
    private var loopRange: Range<Double>? {
        guard isLooping, let index = selectedIndex else { return nil }
        return rows.segment(index, duration: playback.duration)
    }

    private var isEditingText: Bool {
        if case .element = focus { true } else { false }
    }

    var body: some View {
        VStack(spacing: 0) {
            // The video sits centred above the bar. The panel beside it runs
            // from under the toolbar down to just above the bar, and its cards
            // start level with the video's top, so they can scroll up.
            HStack(alignment: .top, spacing: 32) {
                player
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { videoFrame = $0 }
                    .padding(.vertical, 32)
                    .frame(maxHeight: .infinity)
                panel
                    .frame(width: 363)
                    .frame(maxHeight: .infinity)
                    .padding(.bottom, 16)
                    .ignoresSafeArea(.container, edges: .top)
            }
            .frame(maxHeight: .infinity)

            PlayerBar(
                rows: rows,
                playback: playback,
                isLooping: $isLooping,
                onAdd: addSection,
                onPlay: playSection,
                onLoop: loopSection,
                onDelete: deleteSection,
                dropTarget: drag?.section,
                onTrackFrame: { trackFrame = $0 }
            )
            .simultaneousGesture(DragGesture(minimumDistance: 0).onEnded { _ in stopEditing() })
        }
        .padding(EdgeInsets(top: 0, leading: 40, bottom: 24, trailing: 40))
        .overlay(alignment: .topLeading) { liftedCard }
        .coordinateSpace(.named(Self.space))
        .background {
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: stopEditing)
        }
        .onChange(of: playback.currentTime) { followPlayhead() }
        .onChange(of: loopRange, initial: true) { playback.setLoop(loopRange) }
        .onChange(of: focus) {
            if isEditingText { playback.pause() }
            // Keep keys like Space and ↑/↓ working once a card stops editing.
            if focus == nil { focus = .player }
        }
        .onDisappear { playback.setLoop(nil) }
        .task(id: autoScrollSpeed) { await autoScroll() }
    }

    // MARK: Dragging

    /// The dragged card, above everything so it can travel to the bar.
    @ViewBuilder
    private var liftedCard: some View {
        if let drag {
            CardFace(element: drag.element)
                .frame(width: drag.size.width, height: drag.size.height, alignment: .top)
                .scaleEffect(drag.isDropping ? 0.3 : drag.isLifted ? 1.03 : 1)
                .opacity(drag.isDropping ? 0 : 1)
                .shadow(color: .black.opacity(drag.isLifted ? 0.18 : 0), radius: 14, y: 8)
                .offset(x: drag.origin.x, y: drag.origin.y)
                .allowsHitTesting(false)
        }
    }

    /// Points a frame to scroll the panel by: faster the further a dragged card's
    /// pointer is into the panel's top or bottom 48 points, and 0 once it can't go further.
    private var autoScrollSpeed: Int {
        guard let drag, drag.section == nil, panelFrame.height > 0 else { return 0 }
        let zone: CGFloat = 48
        let top = panelFrame.minY + scrollMetrics.insetTop
        let y = drag.pointer.y
        let isUp = y < (top + panelFrame.maxY) / 2
        let depth = isUp ? top + zone - y : y - (panelFrame.maxY - zone)
        guard depth > 0 else { return 0 }
        let speed = min(10, max(1, Int((depth / zone * 10).rounded(.up))))
        if isUp {
            return scrollMetrics.offset > scrollMetrics.minOffset ? -speed : 0
        }
        return scrollMetrics.offset < scrollMetrics.maxOffset ? speed : 0
    }

    private func autoScroll() async {
        let speed = CGFloat(autoScrollSpeed)
        guard speed != 0 else { return }
        while !Task.isCancelled {
            scroll.scrollTo(y: min(max(scrollMetrics.offset + speed, scrollMetrics.minOffset), scrollMetrics.maxOffset))
            try? await Task.sleep(for: .milliseconds(16))
        }
    }

    /// The section whose block in the bar is under a point.
    private func section(at point: CGPoint) -> ScriptRow.ID? {
        guard trackFrame.width > 0, playback.duration > 0,
              trackFrame.insetBy(dx: -8, dy: -20).contains(point) else { return nil }
        let fraction = min(max((point.x - trackFrame.minX) / trackFrame.width, 0), 1)
        return rows.index(at: fraction * playback.duration).map { rows[$0].id }
    }

    // MARK: Player

    private var player: some View {
        PlayerView(player: playback.player, showsControls: false, gravity: .resizeAspect)
            .background(.black)
            .overlay {
                if let onLocate {
                    VStack(spacing: 6) {
                        Text("Video not found")
                            .font(.headline)
                        Text("It may have been moved, renamed or deleted.\nYour script is safe.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.white.opacity(0.6))
                        Button("Locate Video…", action: onLocate)
                            .buttonStyle(CapsuleButtonStyle())
                            .padding(.top, 10)
                    }
                    .foregroundStyle(.white)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .top)
            .contentShape(.rect)
            .onTapGesture {
                focus = .player
                playback.togglePlay()
            }
            .focusable()
            .focused($focus, equals: .player)
            .focusEffectDisabled()
            .defaultFocus($focus, .player)
            .onKeyPress("l") {
                isLooping.toggle()
                return .handled
            }
            .onKeyPress(.upArrow) { step(-1) }
            .onKeyPress(.downArrow) { step(1) }
            .onKeyPress(.return) {
                guard let id = selection else { return .ignored }
                acceptAll(id)
                return .handled
            }
            .onDeleteCommand {
                if let selection { deleteSection(selection) }
            }
            .accessibilityLabel("Video")
            .accessibilityHint("Space plays or pauses")
    }

    /// Clicking outside a card ends editing, so Space plays again.
    private func stopEditing() {
        if isEditingText { focus = .player }
    }

    // MARK: Panel

    /// Where the cards start in the panel's content, level with the video's top.
    private var cardsTop: CGFloat {
        max(0, videoFrame.minY - panelFrame.minY - scrollMetrics.insetTop)
    }

    @ViewBuilder
    private var panel: some View {
        if let index = selectedIndex {
            let row = rows[index]
            GeometryReader { proxy in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        // Level with the top of the video.
                        Color.clear.frame(height: cardsTop)
                        SectionPanel(
                            row: binding(for: row.id),
                            number: index + 1,
                            range: rows.segment(index, duration: playback.duration),
                            sections: rows.enumerated().map { SectionRef(id: $1.id, number: $0 + 1, time: $1.time) },
                            focus: $focus,
                            move: { moveElement($0, to: $1, at: $2) },
                            edit: { name, body in edit(row.id, name, body) },
                            onAcceptAll: { acceptAll(row.id) },
                            drag: $drag,
                            sectionAt: section(at:),
                            scrollOffset: scrollMetrics.offset,
                            onDragStart: {
                                playback.pause()
                                focus = .player
                            }
                        )
                        .id(row.id)
                    }
                    // Clicks below the cards end editing too.
                    .frame(minHeight: max(0, proxy.size.height - scrollMetrics.insetTop), alignment: .top)
                    .background {
                        Color.clear
                            .contentShape(.rect)
                            .onTapGesture(perform: stopEditing)
                    }
                }
                .scrollIndicators(.automatic)
                // Only the cards run up under the toolbar, not the scroll bar.
                .contentMargins(.top, cardsTop, for: .scrollIndicators)
                .scrollBounceBehavior(.basedOnSize)
                .scrollPosition($scroll)
                // The toolbar's own background blurs cards scrolled under it.
                // The edge effect would add a second band over just the panel.
                .scrollEdgeEffectHidden(true, for: .top)
                .onScrollGeometryChange(for: ScrollMetrics.self) { geometry in
                    ScrollMetrics(
                        offset: geometry.contentOffset.y,
                        minOffset: -geometry.contentInsets.top,
                        maxOffset: max(-geometry.contentInsets.top, geometry.contentSize.height + geometry.contentInsets.bottom - geometry.containerSize.height),
                        insetTop: geometry.contentInsets.top
                    )
                } action: { _, metrics in
                    scrollMetrics = metrics
                }
                // Cards that run on below the video fade out.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: scrollMetrics.offset < scrollMetrics.maxOffset - 1 ? 48 : 0)
                    }
                    .animation(.easeOut(duration: 0.2), value: scrollMetrics.offset < scrollMetrics.maxOffset - 1)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { panelFrame = $0 }
            }
        } else {
            ContentUnavailableView("No Section", systemImage: "rectangle.split.3x1", description: Text("Play the ad or add a section with ⌘F."))
        }
    }

    // MARK: Actions

    /// Selects the section under the playhead as it plays or is scrubbed.
    private func followPlayhead() {
        guard let index = rows.index(at: playback.currentTime), rows[index].id != selection else { return }
        selection = rows[index].id
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        guard let index = selectedIndex else { return .ignored }
        let next = min(max(index + delta, 0), rows.count - 1)
        selection = rows[next].id
        return .handled
    }

    private func playSection(_ id: ScriptRow.ID) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let range = rows.segment(index, duration: playback.duration)
        focus = .player
        playback.playSegment(from: range.lowerBound, to: range.upperBound)
    }

    private func loopSection(_ id: ScriptRow.ID) {
        focus = .player
        selection = id
        isLooping = true
        if !playback.isPlaying { playback.togglePlay() }
    }

    private func addSection() {
        if let id = $rows.add(at: playback.currentTime, undoManager: undoManager) { selection = id }
    }

    /// Merges the section into the one before it.
    private func deleteSection(_ id: ScriptRow.ID) {
        if let kept = $rows.merge(id, undoManager: undoManager) { selection = kept }
    }

    /// Moves a dragged element, given by its ID's string, within or between sections.
    private func moveElement(_ id: String, to rowID: ScriptRow.ID, at index: Int? = nil) -> Bool {
        guard let id = UUID(uuidString: id) else { return false }
        var moved = false
        $rows.change("Move Element", undoManager: undoManager) { rows in
            moved = rows.move(element: id, to: rowID, at: index)
        }
        return moved
    }

    private func acceptAll(_ id: ScriptRow.ID) {
        edit(id, "Confirm Suggestions") { $0.acceptAll() }
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

/// A card being dragged: lifted above everything and following the pointer,
/// while the other cards in its section move to leave a slot where it lands.
struct CardDrag {
    var element: ScriptElement
    var from: Int
    /// Where the pointer took hold, from the card's top-left corner.
    var grab: CGSize
    var size: CGSize
    /// The card's top-left corner in `PlaybackView.space`.
    var origin: CGPoint
    var pointer: CGPoint
    /// Where it would land among the section's other elements.
    var target: Int
    /// Another section whose block in the bar is under the pointer.
    var section: ScriptRow.ID?
    var isLifted = false
    /// Shrinking into a block in the bar.
    var isDropping = false
}

/// How far the panel is scrolled, and how far it can go, in content offsets
/// (which start at minus the top inset when the panel runs under the toolbar).
private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var minOffset: CGFloat = 0
    var maxOffset: CGFloat = 0
    var insetTop: CGFloat = 0
}

/// A section to move an element to.
private struct SectionRef: Identifiable {
    let id: ScriptRow.ID
    let number: Int
    let time: Double
}

/// The selected section: its header, its elements and the element picker. Elements read top to bottom in the order they
/// happen; drag one by its top edge to reorder it, or onto a block in the bar
/// to move it to that section.
private struct SectionPanel: View {
    @Binding var row: ScriptRow
    let number: Int
    let range: Range<Double>
    let sections: [SectionRef]
    var focus: FocusState<PlaybackView.Focus?>.Binding
    /// Moves an element, by its ID's string, to a section at an index, or to the end.
    let move: (String, ScriptRow.ID, Int?) -> Bool
    let edit: (String, (inout ScriptRow) -> Void) -> Void
    let onAcceptAll: () -> Void
    @Binding var drag: CardDrag?
    let sectionAt: (CGPoint) -> ScriptRow.ID?
    /// How far the panel is scrolled, so a drag keeps its place while it auto-scrolls.
    let scrollOffset: CGFloat
    let onDragStart: () -> Void

    @State private var isPicking = false
    /// Each card's frame in `PlaybackView.space`. The dragged card's is its slot.
    @State private var frames: [ScriptElement.ID: CGRect] = [:]
    /// The other cards' frames when the drag began, which decide where it lands.
    @State private var startFrames: [CGRect] = []
    @State private var startScrollOffset: CGFloat = 0

    /// Where the dragged card's slot is: where it would land, or where it came
    /// from while it's over the bar.
    private var slot: Int? {
        drag.map { $0.section == nil ? $0.target : $0.from }
    }

    /// The elements in the order shown, with the dragged one moved to its slot.
    private var shown: [ScriptElement] {
        guard let drag, let slot, let from = row.elements.firstIndex(where: { $0.id == drag.element.id }) else { return row.elements }
        var elements = row.elements
        let element = elements.remove(at: from)
        elements.insert(element, at: min(slot, elements.count))
        return elements
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            ForEach(Array(shown.enumerated()), id: \.element.id) { index, element in
                let isDragged = element.id == drag?.element.id
                ElementView(
                    element: element,
                    text: text(for: element.id),
                    focus: focus,
                    onAccept: { accept(element.id) },
                    onChangeKind: { changeKind(element, to: $0) },
                    onDuplicate: { duplicate(element) },
                    onDelete: { delete(element) },
                    onDragChanged: { dragChanged(element, $0) },
                    onDragEnded: dragEnded
                )
                // The dragged card stays (its gesture would end if it went) but
                // is hidden, leaving its slot.
                .opacity(isDragged ? 0 : 1)
                .background {
                    if isDragged {
                        RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.02))
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(PlaybackView.space)) } action: { frames[element.id] = $0 }
                .contextMenu { moveMenu(element, index: index) }
            }
            if row.elements.isEmpty || isPicking {
                ElementPicker(onPick: add)
            } else {
                Button {
                    isPicking = true
                } label: {
                    Label("Add Element", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(CaddyStyle.field, in: .rect(cornerRadius: 6))
                        .contentShape(.rect)
                }
                .buttonStyle(IconButtonStyle())
            }
        }
        .font(.system(size: 13))
        .animation(.spring(duration: 0.3, bounce: 0.15), value: slot)
        .onChange(of: scrollOffset) { updateTarget() }
    }

    // MARK: Dragging

    private func dragChanged(_ element: ScriptElement, _ value: DragGesture.Value) {
        if drag == nil {
            guard let frame = frames[element.id], let from = row.elements.firstIndex(where: { $0.id == element.id }) else { return }
            onDragStart()
            startFrames = row.elements.filter { $0.id != element.id }.compactMap { frames[$0.id] }
            startScrollOffset = scrollOffset
            drag = CardDrag(
                element: element,
                from: from,
                grab: CGSize(width: value.startLocation.x - frame.minX, height: value.startLocation.y - frame.minY),
                size: frame.size,
                origin: frame.origin,
                pointer: value.location,
                target: from
            )
            withAnimation(.snappy(duration: 0.2)) { drag?.isLifted = true }
        }
        guard var current = drag else { return }
        current.origin = CGPoint(x: value.location.x - current.grab.width, y: value.location.y - current.grab.height)
        current.pointer = value.location
        current.section = sectionAt(value.location).flatMap { $0 == row.id ? nil : $0 }
        drag = current
        updateTarget()
    }

    /// It lands after every other card whose middle it has passed, measured
    /// where the cards were when the drag began, plus any scrolling since.
    private func updateTarget() {
        guard let current = drag else { return }
        let centre = current.origin.y + current.size.height / 2 + scrollOffset - startScrollOffset
        let target = startFrames.filter { $0.midY < centre }.count
        if target != current.target { drag?.target = target }
    }

    /// Settles the card into its slot, or shrinks it into a block in the bar, then moves it.
    private func dragEnded(_ value: DragGesture.Value) {
        guard let current = drag else { return }
        let id = current.element.id.uuidString
        if let section = current.section {
            withAnimation(.easeIn(duration: 0.18)) {
                drag?.isDropping = true
            } completion: {
                finishDrag { _ = move(id, section, nil) }
            }
            return
        }
        let slotFrame = frames[current.element.id] ?? CGRect(origin: current.origin, size: current.size)
        withAnimation(.spring(duration: 0.25, bounce: 0.1)) {
            drag?.origin = slotFrame.origin
            drag?.isLifted = false
        } completion: {
            finishDrag {
                guard current.target != current.from else { return }
                // `move` counts positions with the card still in place.
                _ = move(id, row.id, current.target < current.from ? current.target : current.target + 1)
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

    @ViewBuilder
    private func moveMenu(_ element: ScriptElement, index: Int) -> some View {
        let id = element.id.uuidString
        Button("Move Up", systemImage: "arrow.up") { _ = move(id, row.id, index - 1) }
            .disabled(index == 0)
        Button("Move Down", systemImage: "arrow.down") { _ = move(id, row.id, index + 2) }
            .disabled(index == row.elements.count - 1)
        Menu("Move to Section") {
            ForEach(sections.filter { $0.id != row.id }) { section in
                Button("Section \(section.number)  \(Timecode.compact(section.time))") { _ = move(id, section.id, nil) }
            }
        }
        Menu("Change To") {
            KindPicker(kind: element.kind) { changeKind(element, to: $0) }
        }
        Divider()
        Button("Duplicate", systemImage: "plus.square.on.square") { duplicate(element) }
        Button(element.isSuggested ? "Dismiss" : "Delete", systemImage: "trash", role: .destructive) { delete(element) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Section \(number)")
                .fontWeight(.semibold)
            Text("\(Timecode.compact(range.lowerBound)) – \(Timecode.compact(range.upperBound))")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Spacer()
            if row.suggestionCount > 1 {
                Button("Confirm All", action: onAcceptAll)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .help("Confirm every suggestion in this section (⏎)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 4)
    }

    // MARK: Elements

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

    private func accept(_ id: ScriptElement.ID) {
        edit("Confirm Suggestion") { $0.accept(id) }
    }

    private func changeKind(_ element: ScriptElement, to kind: ScriptElement.Kind) {
        guard kind != element.kind else { return }
        edit("Change to \(kind.title)") { $0.change(element.id, to: kind) }
    }

    private func duplicate(_ element: ScriptElement) {
        edit("Duplicate \(element.kind.title)") { $0.duplicate(element.id) }
    }

    private func delete(_ element: ScriptElement) {
        edit(element.isSuggested ? "Dismiss Suggestion" : "Delete Element") { $0.remove(element.id) }
    }

    private func add(_ kind: ScriptElement.Kind) {
        let element = ScriptElement(kind: kind, text: "")
        edit("Add \(kind.title)") { $0.elements.append(element) }
        isPicking = false
        Task { focus.wrappedValue = .element(element.id) }
    }
}

#Preview {
    PlaybackView(rows: .constant(Script.sample.rows), selection: .constant(Script.sample.rows[2].id), playback: Playback())
        .frame(width: 1280, height: 720)
}
