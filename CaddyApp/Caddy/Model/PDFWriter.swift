import AppKit

/// Writes an export as a PDF: US Letter, 0.5" margins, the table's header row
/// repeated on each page and no section split across pages.
enum PDFWriter {
    private static let page = CGRect(x: 0, y: 0, width: 612, height: 792)
    private static let margin = 36.0
    private static let padding = 6.0
    private static let grid = NSColor(white: 0.6, alpha: 1)

    static func data(for document: ExportDocument) -> Data {
        let data = NSMutableData()
        var box = page
        let info = [kCGPDFContextTitle: document.title, kCGPDFContextCreator: "Caddy"] as CFDictionary
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, info) else { return Data() }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }

        let columns = document.columns
        let bottom = page.height - margin
        var y = margin

        // Pages are drawn top down, as AppKit's flipped views are.
        func beginPage() {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(x: 0, y: page.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            y = margin
        }

        func endPage() {
            context.restoreGState()
            context.endPDFPage()
        }

        func drawHeader() {
            let height = 20.0
            var x = margin
            for column in columns {
                let width = document.width(of: column)
                let rect = CGRect(x: x, y: y, width: width, height: height)
                NSColor.black.setFill()
                rect.fill()
                let label = text(column.title, size: 9, bold: true, color: .white, center: true)
                label.draw(with: rect.insetBy(dx: padding, dy: 5), options: [.usesLineFragmentOrigin, .usesFontLeading])
                x += width
            }
            y += height
        }

        beginPage()
        let title = text(document.title, size: 14, bold: true)
        title.draw(with: CGRect(x: margin, y: y, width: page.width - margin * 2, height: 40), options: [.usesLineFragmentOrigin, .usesFontLeading])
        y += height(of: title, width: page.width - margin * 2) + 2
        if !document.subtitle.isEmpty {
            let subtitle = text(document.subtitle, size: 8.5, color: NSColor(white: 0.4, alpha: 1))
            subtitle.draw(with: CGRect(x: margin, y: y, width: page.width - margin * 2, height: 40), options: [.usesLineFragmentOrigin, .usesFontLeading])
            y += height(of: subtitle, width: page.width - margin * 2)
        }
        y += 10
        drawHeader()

        for (index, section) in document.sections.enumerated() {
            let cells = columns.map { column in (column, document.width(of: column), content(of: column, in: section)) }
            let rowHeight = cells.map { _, width, content in
                switch content {
                case .frame(let frame): (frame?.height(forWidth: width - padding * 2) ?? 12) + padding * 2
                case .text(let string): height(of: string, width: width - padding * 2) + padding * 2
                }
            }.max() ?? 0

            // A section too tall for any page is drawn anyway, cut off at the bottom.
            if y + rowHeight > bottom && y > margin + 20 {
                endPage()
                beginPage()
                drawHeader()
            }

            var x = margin
            for (_, width, content) in cells {
                let rect = CGRect(x: x, y: y, width: width, height: rowHeight)
                if !index.isMultiple(of: 2) {
                    NSColor(white: 0.97, alpha: 1).setFill()
                    rect.fill()
                }
                let inner = rect.insetBy(dx: padding, dy: padding)
                switch content {
                case .frame(let frame?):
                    let image = NSImage(data: frame.jpeg)
                    let frameRect = CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: frame.height(forWidth: inner.width))
                    image?.draw(in: frameRect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                case .frame(nil):
                    text("No frame", size: 9, italic: true, color: NSColor(white: 0.53, alpha: 1), center: true)
                        .draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
                case .text(let string):
                    string.draw(with: inner, options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
                grid.setStroke()
                let border = NSBezierPath(rect: rect)
                border.lineWidth = 0.5
                border.stroke()
                x += width
            }
            y += rowHeight
        }
        endPage()
        context.closePDF()
        return data as Data
    }

    private enum Content {
        case frame(ExportFrame?)
        case text(NSAttributedString)
    }

    private static func content(of column: ExportColumn, in section: ExportSection) -> Content {
        switch column {
        case .frame:
            return .frame(section.frame)
        case .script:
            let string = NSMutableAttributedString(attributedString: text(section.timecode, size: 7, color: NSColor(white: 0.53, alpha: 1), spacing: 4))
            for line in section.script {
                string.append(text("\n"))
                string.append(text("\(line.label): ", bold: true))
                string.append(rich(line.text))
            }
            return .text(string)
        }
    }

    private static func height(of string: NSAttributedString, width: Double) -> Double {
        guard string.length > 0 else { return 0 }
        return string.boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                                   options: [.usesLineFragmentOrigin, .usesFontLeading]).height.rounded(.up)
    }

    /// An element's text with its styles. Line breaks inside it don't take paragraph spacing.
    private static func rich(_ value: RichText) -> NSAttributedString {
        let string = NSMutableAttributedString()
        for run in value.runs {
            string.append(text(run.text.replacingOccurrences(of: "\n", with: "\u{2028}"),
                               bold: run.bold, italic: run.italic, underline: run.underline))
        }
        return string
    }

    private static func text(_ string: String, size: Double = 9, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                             color: NSColor = .black, center: Bool = false, spacing: Double = 6) -> NSAttributedString {
        var traits: NSFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let base = NSFont(name: "Helvetica Neue", size: size) ?? .systemFont(ofSize: size)
        let font = NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 1.5
        paragraph.paragraphSpacing = spacing
        if center { paragraph.alignment = .center }
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return NSAttributedString(string: string, attributes: attributes)
    }
}
