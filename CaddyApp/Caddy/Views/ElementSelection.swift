import AppKit
import SwiftUI

/// Cards picked to delete together: a click outside a card's text and type
/// picks just that card, ⇧-click picks a run from the last card picked and
/// ⌘-click picks or drops one. ⌫ deletes them and Esc lets them go.
/// The playback panel and the grid each have their own.
@Observable
final class ElementSelection {
    private(set) var ids: Set<ScriptElement.ID> = []
    /// Bumped to have the view delete the selection, from a key or button.
    fileprivate(set) var deleteRequests = 0
    /// Where a ⇧-click run starts.
    @ObservationIgnored private var anchor: ScriptElement.ID?
    /// Every element shown, in order, for ⇧-click runs.
    @ObservationIgnored fileprivate var order: [ScriptElement.ID] = []
    /// The card under the pointer, set by the cards' hover, for the click monitor.
    @ObservationIgnored fileprivate var hovered: ScriptElement.ID?
    @ObservationIgnored fileprivate var isOverBar = false

    var count: Int { ids.count }

    func contains(_ id: ScriptElement.ID) -> Bool { ids.contains(id) }

    func hover(_ id: ScriptElement.ID, _ isHovering: Bool) {
        if isHovering { hovered = id } else if hovered == id { hovered = nil }
    }

    /// Picks just this element, as a click on its card does.
    func select(_ id: ScriptElement.ID) {
        ids = [id]
        anchor = id
    }

    func clear() {
        if !ids.isEmpty { ids = [] }
        anchor = nil
        isOverBar = false
    }

    func requestDelete() {
        if !ids.isEmpty { deleteRequests += 1 }
    }

    fileprivate func click(_ id: ScriptElement.ID, extending: Bool) {
        if extending, let anchor, let start = order.firstIndex(of: anchor), let end = order.firstIndex(of: id) {
            ids.formUnion(order[min(start, end)...max(start, end)])
        } else if ids.contains(id) {
            ids.remove(id)
            anchor = id
        } else {
            ids.insert(id)
            anchor = id
        }
    }

    /// Lets go of elements no longer shown: deleted, undone, or in another section.
    fileprivate func keep(only shown: [ScriptElement.ID]) {
        let shown = Set(shown)
        if !ids.isSubset(of: shown) { ids.formIntersection(shown) }
        if let anchor, !shown.contains(anchor) { self.anchor = nil }
        if let hovered, !shown.contains(hovered) { self.hovered = nil }
    }
}

extension View {
    /// Lets the cards inside be picked with ⇧- and ⌘-click and deleted together.
    /// `order` is every element shown, in order.
    func elementSelection(_ selection: ElementSelection, rows: Binding<[ScriptRow]>, order: [ScriptElement.ID]) -> some View {
        modifier(ElementSelectionModifier(selection: selection, rows: rows, order: order))
    }
}

/// Watches clicks and keys at the window rather than on the cards, whose text
/// views would otherwise take ⇧-click as extending a text selection.
private struct ElementSelectionModifier: ViewModifier {
    let selection: ElementSelection
    @Binding var rows: [ScriptRow]
    let order: [ScriptElement.ID]

    @State private var window: NSWindow?
    @State private var monitor: Any?
    @Environment(\.undoManager) private var undoManager

    func body(content: Content) -> some View {
        content
            .environment(selection)
            .background(WindowReader { window = $0 })
            .onChange(of: order, initial: true) {
                selection.order = order
                selection.keep(only: order)
            }
            .onChange(of: selection.deleteRequests) { delete() }
            .onAppear(perform: watch)
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
                selection.clear()
            }
    }

    private func delete() {
        let ids = selection.ids
        guard !ids.isEmpty else { return }
        $rows.change(ids.count == 1 ? "Delete Element" : "Delete \(ids.count) Elements", undoManager: undoManager) { rows in
            for index in rows.indices {
                for id in ids { rows[index].remove(id) }
            }
        }
        selection.clear()
    }

    private func watch() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            let eventWindow = event.window
            let isClick = event.type == .leftMouseDown
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Only key events have a key code: reading it from a click throws, and the click is lost.
            let keyCode = isClick ? 0 : event.keyCode
            let handled = MainActor.assumeIsolated {
                guard let window, eventWindow === window, window.attachedSheet == nil else { return false }
                return isClick ? click(flags, in: window) : key(keyCode, in: window)
            }
            return handled ? nil : event
        }
    }

    /// ⇧- or ⌘-click on a card picks it, ending any editing. A plain click
    /// anywhere but the selection bar lets the selection go.
    private func click(_ flags: NSEvent.ModifierFlags, in window: NSWindow) -> Bool {
        // Control-click opens a context menu, which may act on the selection.
        guard !flags.contains(.control) else { return false }
        let extending = flags.contains(.shift)
        guard extending || flags.contains(.command) else {
            if !selection.isOverBar { selection.clear() }
            return false
        }
        guard let id = selection.hovered else { return false }
        window.makeFirstResponder(nil)
        selection.click(id, extending: extending)
        return true
    }

    /// ⌫ or ⌦ deletes the selection and Esc lets it go, unless text is being typed.
    private func key(_ keyCode: UInt16, in window: NSWindow) -> Bool {
        guard selection.count > 0, !(window.firstResponder is NSText) else { return false }
        switch keyCode {
        case 51, 117:
            selection.requestDelete()
            return true
        case 53:
            selection.clear()
            return true
        default:
            return false
        }
    }
}

/// How many cards are picked, with Delete, floating over the cards.
struct SelectionBar: View {
    @Environment(ElementSelection.self) private var selection: ElementSelection?

    var body: some View {
        ZStack {
            if let selection, selection.count > 0 {
                HStack(spacing: 12) {
                    Text(selection.count == 1 ? "1 element selected" : "\(selection.count) elements selected")
                        .monospacedDigit()
                    Button("Delete", systemImage: "trash", role: .destructive) { selection.requestDelete() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle())
                        .help("Delete the selected elements (⌫)")
                    Button("Deselect", systemImage: "xmark") { selection.clear() }
                        .labelStyle(.iconOnly)
                        .buttonStyle(IconButtonStyle())
                        .help("Deselect (Esc)")
                }
                .font(.system(size: 13))
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
                .onHover { selection.isOverBar = $0 }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.2), value: selection?.count ?? 0 > 0)
    }
}
