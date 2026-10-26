import AppKit
import SwiftUI

/// A card's text: bold, italic and underline from the Format menu (⌘B, ⌘I,
/// ⌘U, see `CardTextFormat`), and Return for a new line. Nothing else is kept.
///
/// It edits a local copy and writes back only real changes, so the model's
/// round trip never moves the cursor. The editor doesn't grow with its text,
/// so a hidden copy of the text sizes it.
struct RichTextField: View {
    let prompt: String
    @Binding var value: RichText
    var focus: FocusState<PlaybackView.Focus?>.Binding
    let id: ScriptElement.ID

    @State private var content = AttributedString()
    @Environment(\.font) private var font
    @Environment(\.fontResolutionContext) private var fontContext

    var body: some View {
        Text(sizing)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .overlay(alignment: .topLeading) {
                if value.text.isEmpty {
                    Text(prompt)
                        .foregroundStyle(.tertiary)
                        .lineSpacing(3)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                TextEditor(text: $content)
                    .textEditorStyle(.plain)
                    .scrollDisabled(true)
                    .scrollIndicators(.never)
                    .lineSpacing(3)
                    // Fonts and underline only, so nothing else pasted in sticks.
                    .attributedTextFormattingDefinition(CardTextScope.self)
                    // The editor insets its text 5 pt each side; this lines it up with the card.
                    .padding(.horizontal, -5)
                    .focused(focus, equals: .element(id))
                    .onExitCommand { focus.wrappedValue = .player }
            }
            .onChange(of: value, initial: true) {
                if richText(from: content) != value { content = Self.attributed(value, base: font ?? .body) }
            }
            .onChange(of: content) {
                let edited = richText(from: content)
                if edited != value { value = edited }
            }
    }

    /// The text to size by. An empty last line needs a character to take up room.
    private var sizing: AttributedString {
        var text = content
        if text.characters.isEmpty || text.characters.last == "\n" { text.append(AttributedString(" ")) }
        return text
    }

    /// The text with its styled runs as fonts and underline, for editing or display.
    static func attributed(_ value: RichText, base: Font) -> AttributedString {
        var text = AttributedString(value.text)
        let characters = text.characters
        for style in value.styles where style.start >= 0 && style.length > 0 && style.start + style.length <= characters.count {
            let lower = characters.index(characters.startIndex, offsetBy: style.start)
            let upper = characters.index(lower, offsetBy: style.length)
            if style.bold || style.italic {
                var font = base
                if style.bold { font = font.bold() }
                if style.italic { font = font.italic() }
                text[lower..<upper].font = font
            }
            if style.underline { text[lower..<upper].underlineStyle = .single }
        }
        return text
    }

    /// Plain text and its styled runs, read from the editor's fonts and underline.
    private func richText(from content: AttributedString) -> RichText {
        var styles: [TextStyle] = []
        var offset = 0
        for run in content.runs {
            let length = content[run.range].characters.count
            let resolved = run.swiftUI.font?.resolve(in: fontContext)
            let bold = resolved?.isBold ?? false
            let italic = resolved?.isItalic ?? false
            let underline = run.swiftUI.underlineStyle != nil
            if bold || italic || underline {
                if let last = styles.last, last.start + last.length == offset, last.bold == bold, last.italic == italic, last.underline == underline {
                    styles[styles.count - 1].length += length
                } else {
                    styles.append(TextStyle(start: offset, length: length, bold: bold, italic: italic, underline: underline))
                }
            }
            offset += length
        }
        return RichText(text: String(content.characters), styles: styles)
    }
}

/// What a card's editor may change: fonts, which carry bold and italic, and underline.
struct CardTextScope: AttributeScope {
    let font: AttributeScopes.SwiftUIAttributes.FontAttribute
    let underlineStyle: AttributeScopes.SwiftUIAttributes.UnderlineStyleAttribute
}

/// The Format menu's Bold, Italic and Underline, applied to the card being
/// typed in. Each turns on unless the whole selection already has it; with
/// nothing selected it applies to what's typed next.
enum CardTextFormat {
    enum Style {
        case bold, italic, underline
    }

    static func toggle(_ style: Style) {
        guard let textView = NSApp.keyWindow?.firstResponder as? NSTextView, textView.isRichText else { return }
        let range = textView.selectedRange()
        if range.length == 0 {
            var attributes = textView.typingAttributes
            apply(style, to: &attributes, on: !isOn(style, in: attributes))
            textView.typingAttributes = attributes
            return
        }
        guard let storage = textView.textStorage else { return }
        var isAllOn = true
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            if !isOn(style, in: attributes) { isAllOn = false }
        }
        guard textView.shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttributes(in: range) { attributes, subrange, _ in
            var attributes = attributes
            apply(style, to: &attributes, on: !isAllOn)
            storage.setAttributes(attributes, range: subrange)
        }
        storage.endEditing()
        textView.didChangeText()
    }

    private static func isOn(_ style: Style, in attributes: [NSAttributedString.Key: Any]) -> Bool {
        switch style {
        case .bold: hasTrait(.boldFontMask, attributes)
        case .italic: hasTrait(.italicFontMask, attributes)
        case .underline: (attributes[.underlineStyle] as? Int ?? 0) != 0
        }
    }

    private static func hasTrait(_ trait: NSFontTraitMask, _ attributes: [NSAttributedString.Key: Any]) -> Bool {
        guard let font = attributes[.font] as? NSFont else { return false }
        return NSFontManager.shared.traits(of: font).contains(trait)
    }

    private static func apply(_ style: Style, to attributes: inout [NSAttributedString.Key: Any], on: Bool) {
        switch style {
        case .bold, .italic:
            guard let font = attributes[.font] as? NSFont else { return }
            let trait: NSFontTraitMask = style == .bold ? .boldFontMask : .italicFontMask
            let manager = NSFontManager.shared
            attributes[.font] = on ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
        case .underline:
            attributes[.underlineStyle] = on ? NSUnderlineStyle.single.rawValue : nil
        }
    }
}
