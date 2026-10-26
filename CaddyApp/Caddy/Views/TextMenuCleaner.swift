import AppKit
import ObjectiveC

/// Takes the Siri items out of every text view's right-click menu: the cards,
/// renaming in the sidebar and any other field.
///
/// macOS adds those items as the menu opens, after any SwiftUI or AppKit hook
/// that builds it, so each text view's menu gets this as its delegate and the
/// items go in `menuWillOpen`. Installed once at launch by swapping in
/// `caddy_menu(for:)` for `NSTextView.menu(for:)`.
final class TextMenuCleaner: NSObject, NSMenuDelegate {
    static let shared = TextMenuCleaner()

    static func install() {
        guard let original = class_getInstanceMethod(NSTextView.self, #selector(NSTextView.menu(for:))),
              let replacement = class_getInstanceMethod(NSTextView.self, #selector(NSTextView.caddy_menu(for:))) else { return }
        method_exchangeImplementations(original, replacement)
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items.reversed() where item.title.localizedCaseInsensitiveContains("Siri") {
            menu.removeItem(item)
        }
        // No separators left doubled up, or at either end.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }
}

extension NSTextView {
    /// Runs as `menu(for:)` once installed; calling itself calls the original.
    @objc func caddy_menu(for event: NSEvent) -> NSMenu? {
        let menu = caddy_menu(for: event)
        if menu?.delegate == nil { menu?.delegate = TextMenuCleaner.shared }
        return menu
    }
}
