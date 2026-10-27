import AppKit

/// Writes an export as a PDF laid out like the Word template (see
/// `DocxWriter`), measured from the template as Pages sets it: US Letter, the
/// black CAD Script bar across the top of the first page, the client as the
/// title with the asset name and export date under it, then the #, Frame
/// and Script table from margin to margin, its header repeated on each page and
/// no section split across pages. The footer has the client, the script's name
/// and the page; the template's logo sits on the bottom margin of the last page.
/// BentonSansF throughout, or Helvetica Neue without it. Changes to the Word
/// template need making here too, except the logo, which is read from it.
enum PDFWriter {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    /// The template's margins.
    private static let top = 61.2, side = 54.0, bottom = 792 - 68.4
    private static var contentWidth: Double { page.width - side * 2 }

    /// The bar across the top of the first page.
    private static let barHeight = 30.8
    /// Columns, as the template has them; Script takes the rest.
    private static let numberColumn = 30.4, frameColumn = 172.45
    private static let padding = 4.5
    private static let frameWidth = 155.43, cornerRadius = 4.85
    private static let headerHeight = 27.0
    /// A row with a frame is at least this tall.
    private static let rowMinimum = 90.0
    /// Below a frame, to the row's bottom.
    private static let belowFrame = 14.5
    private static let scriptLineHeight = 16.0, paragraphGap = 4.0

    private static let ink = color(0x1D1D1F)
    private static let secondary = color(0x6E6E73)
    private static let tertiary = color(0x86868B)
    private static let hairline = color(0xD2D2D7)

    private struct Row {
        var number: String
        var frame: ExportImage?
        var paragraphs: [NSAttributedString]
        var height: Double
    }

    static func data(for document: ExportDocument) -> Data {
        let data = NSMutableData()
        var box = page
        let info = [kCGPDFContextTitle: document.title, kCGPDFContextCreator: "Caddy"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }

        let hasFrames = document.options.includeThumbnails
        let scriptX = side + numberColumn + (hasFrames ? frameColumn : 0)
        let scriptWidth = side + contentWidth - scriptX - padding * 2

        // The heading: the client, or the asset name without one.
        let heading = text(document.client.isEmpty ? document.title : document.client, size: 26, lineHeight: 34.1, kern: -0.3)
        let headingHeight = height(of: heading, width: contentWidth)
        let assetTop = top + headingHeight + 6
        let tableTop = assetTop + 15.7 * 2 + 14.9

        // Every row measured, then split into pages.
        let rows = document.sections.enumerated().map { index, section in
            let paragraphs = section.script.map(paragraph)
            let textHeight = paragraphs.map { height(of: $0, width: scriptWidth) }.reduce(0, +)
                + paragraphGap * Double(max(paragraphs.count - 1, 0))
            // At least a line, for the number. The last line's spacing below
            // runs 2 pt into the row under it.
            var rowHeight = padding + max(textHeight, scriptLineHeight) - 2
            if hasFrames {
                let frameHeight = section.frame?.height(forWidth: frameWidth) ?? 0
                rowHeight = max(rowHeight, padding + frameHeight + belowFrame, rowMinimum)
            }
            return Row(number: "\(index + 1)", frame: hasFrames ? section.frame : nil, paragraphs: paragraphs, height: rowHeight)
        }
        var pages: [[Row]] = [[]]
        var y = tableTop + headerHeight
        for row in rows {
            // A section too tall for any page is set anyway, cut off at the bottom.
            if y + row.height > bottom, !pages[pages.count - 1].isEmpty {
                pages.append([])
                y = top + headerHeight
            }
            pages[pages.count - 1].append(row)
            y += row.height
        }

        let logo = DocxWriter.templateLogo()
        for (index, rows) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.saveGState()
            // Pages are drawn top down, as AppKit's flipped views are.
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)

            var y = top
            if index == 0 {
                NSColor.black.setFill()
                CGRect(x: 0, y: 0, width: page.width, height: barHeight).fill()
                // The template lowers it 2 pt from the middle.
                draw(text("CAD Script", size: 16, lineHeight: barHeight, color: .white, center: true), x: 0, y: 1.9, width: page.width)
                draw(heading, x: side, y: top, width: contentWidth)
                draw(text(document.title, size: 12, lineHeight: 15.7, color: secondary), x: side, y: assetTop, width: contentWidth)
                draw(text(document.dateText, size: 12, lineHeight: 15.7, color: secondary), x: side, y: assetTop + 15.7, width: contentWidth)
                y = tableTop
            }

            // The header row, repeated on each page.
            let header = [("#", side), ("Frame", side + numberColumn), ("Script", scriptX)].filter { hasFrames || $0.0 != "Frame" }
            for (title, x) in header {
                draw(text(title, size: 10, lineHeight: 13.1, color: tertiary, kern: -0.05), x: x + padding, y: y + 5, width: 200)
            }
            y += headerHeight
            rule(at: y)

            for row in rows {
                let contentTop = y + padding
                draw(text(row.number, size: 10, lineHeight: scriptLineHeight), x: side + padding, y: contentTop, width: numberColumn)
                if let frame = row.frame, let image = NSImage(data: frame.data) {
                    let rect = CGRect(x: side + numberColumn + padding, y: contentTop,
                                      width: frameWidth, height: frame.height(forWidth: frameWidth))
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
                    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                    NSGraphicsContext.restoreGraphicsState()
                }
                var lineTop = contentTop
                for paragraph in row.paragraphs {
                    draw(paragraph, x: scriptX + padding, y: lineTop, width: scriptWidth)
                    lineTop += height(of: paragraph, width: scriptWidth) + paragraphGap
                }
                y += row.height
                rule(at: y)
            }

            // The footer, and the logo on the last page.
            let client = document.client.isEmpty ? "" : document.client + " - "
            let footer = "\(client)\(document.title)   ·   Page \(index + 1) of \(pages.count)"
            draw(text(footer, size: 8, lineHeight: 10.5), x: side, y: 751.6, width: contentWidth)
            if index == pages.count - 1, let logo, let image = NSImage(data: logo.data) {
                let rect = CGRect(x: side + contentWidth - logo.width, y: bottom, width: logo.width, height: logo.height)
                image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    /// A hairline across the table.
    private static func rule(at y: Double) {
        hairline.setFill()
        CGRect(x: side, y: y - 0.25, width: contentWidth, height: 0.5).fill()
    }

    /// A scene description in italics, or the label in Medium and the text after it.
    private static func paragraph(_ line: ExportLine) -> NSAttributedString {
        let string = NSMutableAttributedString()
        let isScene = line.label == ScriptElement.Kind.scene.exportLabel
        if !isScene {
            string.append(text("\(line.label):", size: 10, lineHeight: scriptLineHeight, medium: true))
            string.append(text(" ", size: 10, lineHeight: scriptLineHeight))
        }
        for run in line.text.runs {
            // Line breaks inside an element don't take paragraph spacing.
            string.append(text(run.text.replacingOccurrences(of: "\n", with: "\u{2028}"), size: 10, lineHeight: scriptLineHeight,
                               bold: run.bold, italic: isScene || run.italic, underline: run.underline))
        }
        return string
    }

    private static func draw(_ string: NSAttributedString, x: Double, y: Double, width: Double) {
        string.draw(with: CGRect(x: x, y: y, width: width, height: 10_000), options: [.usesLineFragmentOrigin])
    }

    private static func height(of string: NSAttributedString, width: Double) -> Double {
        guard string.length > 0 else { return 0 }
        return string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
    }

    /// Text on a fixed line height, as the template's paragraphs have. `center`
    /// centres it across and down.
    private static func text(_ string: String, size: Double, lineHeight: Double, color: NSColor = ink, medium: Bool = false,
                             bold: Bool = false, italic: Bool = false, underline: Bool = false, kern: Double = 0,
                             center: Bool = false) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
        if center { paragraph.alignment = .center }
        let font = font(size: size, medium: medium, bold: bold, italic: italic)
        // Text sits at the top of its line, as Pages sets the template, or in
        // the middle for the bar. A fixed line height otherwise leaves the
        // extra space above it.
        let extra = lineHeight - (font.ascender - font.descender)
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
            .baselineOffset: center ? extra / 2 : extra,
        ]
        if kern != 0 { attributes[.kern] = kern }
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// BentonSansF has Book, Book Italic, Medium, Bold and Bold Italic.
    private static func font(size: Double, medium: Bool, bold: Bool, italic: Bool) -> NSFont {
        let name = switch (medium, bold, italic) {
        case (true, _, _): "BentonSansF-Medium"
        case (_, true, true): "BentonSansF-BoldItalic"
        case (_, true, false): "BentonSansF-Bold"
        case (_, false, true): "BentonSansF-BookItalic"
        default: "BentonSansF-Book"
        }
        if let font = NSFont(name: name, size: size) { return font }
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold || medium { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        return NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(srgbRed: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, alpha: 1)
    }
}
