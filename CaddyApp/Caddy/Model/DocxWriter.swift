import Foundation

/// Writes an export as a Word document by filling in the CAD script template,
/// `Templates/CADScript.docx`, which is made in Word, so the layout is changed
/// there rather than here.
///
/// - `{Client}`, `{Asset name}` and `{Date created …}` anywhere in the body,
///   header or footer become the client and asset name typed in the export
///   sheet and the day of the export. Without a client, `{Client}` is the
///   asset name, or left out (with what separates it) where the asset name
///   follows it.
/// - The table's first row that isn't a repeated header is copied once per
///   section: the cell holding a number gets the section's, the one holding a
///   picture its frame (same width, the frame's shape), and the one holding
///   the script gets its elements. A paragraph with a `{…}` placeholder is the
///   pattern for scene descriptions, one starting `LABEL:` for that label
///   (VO, SUPER…), and the first `LABEL:` one for labels it doesn't have.
/// - Without thumbnails the frame column is taken out, the script column
///   widened to fill it, and rows no longer kept as tall as a frame.
/// - The table runs from margin to margin, the script column taking up the
///   difference, whatever widths the template has.
/// - A picture anchored after the table (the logo) is pinned to the top of
///   the bottom margin, so it stays where the template has it however long
///   the table runs.
nonisolated enum DocxWriter {
    enum Failure: LocalizedError {
        case noTemplate
        case damagedTemplate

        var errorDescription: String? {
            switch self {
            case .noTemplate: "The Word template is missing from the app."
            case .damagedTemplate: "The Word template couldn't be read."
            }
        }
    }

    static func data(for document: ExportDocument) throws -> Data {
        guard let template = bundledTemplate else { throw Failure.noTemplate }
        return try data(for: document, template: template)
    }

    private static var bundledTemplate: Data? {
        Bundle.main.url(forResource: "CADScript", withExtension: "docx").flatMap { try? Data(contentsOf: $0) }
    }

    /// The picture anchored after the template's table (the logo) and its size
    /// in points, so the PDF can set the same one in the same place.
    static func templateLogo(from template: Data? = bundledTemplate) -> (data: Data, width: Double, height: Double)? {
        guard let template, let entries = try? ZipReader.entries(of: template) else { return nil }
        let files = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
        guard let main = files["word/document.xml"].flatMap({ try? XMLDocument(data: $0) }),
              let links = files["word/_rels/document.xml.rels"].flatMap({ try? XMLDocument(data: $0) })?.rootElement(),
              let body = main.rootElement()?.children("w:body").first,
              let table = scriptTable(in: body),
              let siblings = body.children,
              let start = siblings.firstIndex(where: { $0 === table }) else { return nil }
        for case let sibling as XMLElement in siblings[(start + 1)...] {
            for anchor in sibling.descendants("wp:anchor") {
                guard let id = anchor.descendants("a:blip").first?.value(of: "r:embed"),
                      let extent = anchor.children("wp:extent").first,
                      let width = extent.value(of: "cx").flatMap(Double.init),
                      let height = extent.value(of: "cy").flatMap(Double.init),
                      let target = links.children("Relationship").first(where: { $0.value(of: "Id") == id })?.value(of: "Target"),
                      let data = files["word/" + target] else { continue }
                return (data, width / 12_700, height / 12_700) // EMUs per point
            }
        }
        return nil
    }

    /// The table with a repeated header row, or the first.
    private static func scriptTable(in body: XMLElement) -> XMLElement? {
        let tables = body.descendants("w:tbl")
        return tables.first { !$0.descendants("w:tblHeader").isEmpty } ?? tables.first
    }

    static func data(for document: ExportDocument, template: Data) throws -> Data {
        guard let entries = try? ZipReader.entries(of: template) else { throw Failure.damagedTemplate }
        var files = Dictionary(entries.map { ($0.path, $0.data) }, uniquingKeysWith: { first, _ in first })
        var order = entries.map(\.path)

        func xml(_ path: String) throws -> XMLDocument {
            guard let data = files[path], let xml = try? XMLDocument(data: data, options: [.nodePreserveWhitespace])
            else { throw Failure.damagedTemplate }
            return xml
        }
        let main = try xml("word/document.xml")
        let relationships = try xml("word/_rels/document.xml.rels")
        let contentTypes = try xml("[Content_Types].xml")
        guard let body = main.rootElement()?.children("w:body").first,
              let types = contentTypes.rootElement(),
              let links = relationships.rootElement() else { throw Failure.damagedTemplate }

        // Placeholders, in the body and every header and footer.
        let headersAndFooters = try order
            .filter { $0.hasPrefix("word/header") || $0.hasPrefix("word/footer") }
            .filter { $0.hasSuffix(".xml") }
            .map { ($0, try xml($0)) }
        for root in [main] + headersAndFooters.map(\.1) {
            guard let root = root.rootElement() else { continue }
            for paragraph in root.descendants("w:p") {
                fillPlaceholders(in: paragraph, document: document)
            }
        }

        // The table's rows, one per section.
        var frames: [(path: String, id: String, data: Data)] = []
        guard let table = scriptTable(in: body),
              let prototype = table.children("w:tr").first(where: { !isHeader($0) }) else { throw Failure.damagedTemplate }
        var roles = prototype.children("w:tc").map(role)
        if !document.options.includeThumbnails, let frame = roles.firstIndex(of: .frame),
           let script = roles.firstIndex(of: .script) {
            removeColumn(frame, wideningColumn: script, of: table, rows: table.children("w:tr"))
            roles.remove(at: frame)
        }
        if let script = roles.firstIndex(of: .script), let width = textWidth(of: body) {
            stretch(table, column: script, toWidth: width)
        }
        for row in table.children("w:tr") where !isHeader(row) {
            row.detach()
        }
        for (index, section) in document.sections.enumerated() {
            guard let row = prototype.copy() as? XMLElement else { continue }
            for (cell, role) in zip(row.children("w:tc"), roles) {
                switch role {
                case .number:
                    setText(of: cell, to: "\(index + 1)")
                case .frame:
                    guard let frame = section.frame else {
                        for run in cell.descendants("w:r") where !run.descendants("w:drawing").isEmpty {
                            run.detach()
                        }
                        continue
                    }
                    let id = "rIdCaddyFrame\(index + 1)"
                    frames.append(("word/media/caddy-frame\(index + 1).jpeg", id, frame.data))
                    fillFrame(in: cell, relationship: id, image: frame, number: index + 1)
                case .script:
                    fillScript(in: cell, lines: section.script)
                case .other:
                    break
                }
            }
            table.addChild(row)
        }

        pinTrailingAnchors(in: body, after: table)

        // Frames in, and the template's sample pictures out once nothing shows them.
        for frame in frames {
            files[frame.path] = frame.data
            order.append(frame.path)
            links.addChild(element("Relationship", [
                "Id": frame.id,
                "Type": "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image",
                "Target": String(frame.path.dropFirst("word/".count)),
            ]))
        }
        setDefault(in: types, extension: "jpeg", type: "image/jpeg")
        let mainText = main.xmlString
        for link in links.children("Relationship") where link.value(of: "Type")?.hasSuffix("/image") == true {
            guard let id = link.value(of: "Id"), let target = link.value(of: "Target"),
                  !mainText.contains("\"\(id)\"") else { continue }
            link.detach()
            let path = "word/" + target
            let elsewhere = order.contains { other in
                other.hasSuffix(".rels") && other != "word/_rels/document.xml.rels"
                    && files[other].map { String(decoding: $0, as: UTF8.self).contains(target) } == true
            }
            guard !elsewhere else { continue }
            files[path] = nil
            order.removeAll { $0 == path }
            types.children("Override").filter { $0.value(of: "PartName") == "/" + path }.forEach { $0.detach() }
        }

        // The title in the file's properties.
        if let core = try? xml("docProps/core.xml"), let properties = core.rootElement() {
            properties.children("dc:title").forEach { $0.detach() }
            let title = XMLElement(name: "dc:title", stringValue: clean(document.title))
            properties.insertChild(title, at: 0)
            files["docProps/core.xml"] = core.xmlData(options: [.nodeCompactEmptyElement])
        }

        files["word/document.xml"] = main.xmlData(options: [.nodeCompactEmptyElement])
        files["word/_rels/document.xml.rels"] = relationships.xmlData(options: [.nodeCompactEmptyElement])
        files["[Content_Types].xml"] = contentTypes.xmlData(options: [.nodeCompactEmptyElement])
        for (path, xml) in headersAndFooters {
            files[path] = xml.xmlData(options: [.nodeCompactEmptyElement])
        }

        // Content types first, as Word writes them.
        var zip = ZipWriter()
        let contentTypesPath = "[Content_Types].xml"
        for path in [contentTypesPath] + order.filter({ $0 != contentTypesPath }) {
            if let data = files[path] { zip.add(path, data) }
        }
        return zip.finish()
    }

    // MARK: Placeholders

    private static func fillPlaceholders(in paragraph: XMLElement, document: ExportDocument) {
        let texts = ownTexts(of: paragraph)
        joinSplitPlaceholders(texts)
        let joined = texts.map { $0.stringValue ?? "" }.joined().lowercased()
        guard joined.contains("{") else { return }
        let hasAsset = joined.contains("{asset")
        // Without a client, it's left out beside the asset name, or replaced
        // by the asset name where it stands alone.
        let dropClient = document.client.isEmpty && hasAsset
        let client = document.client.isEmpty ? document.title : document.client
        var droppingSeparator = false
        for text in texts {
            var value = text.stringValue ?? ""
            if droppingSeparator {
                if value.trimmingCharacters(in: separators).isEmpty, !value.isEmpty {
                    text.setText("")
                    continue
                }
                droppingSeparator = false
            }
            guard value.contains("{") else { continue }
            if dropClient {
                value = value.replacing(/\{\s*[Cc]lient[^{}]*\}[\s\-–—·|:]*/, with: "")
                droppingSeparator = value.isEmpty
            }
            value = value.replacing(/\{([^{}]*)\}/) { match in
                let key = match.output.1.lowercased().trimmingCharacters(in: .whitespaces)
                if key.hasPrefix("client") { return client }
                if key.hasPrefix("asset") { return document.title }
                if key.hasPrefix("date") { return document.dateText }
                return String(match.output.0)
            }
            text.setText(clean(value))
        }
    }

    private static let separators = CharacterSet(charactersIn: " -–—·|:")

    /// Word splits text into runs as it's edited, so `{Client}` can end up as
    /// `{`, `Client`, `}`. Each placeholder is gathered into the run it starts in.
    private static func joinSplitPlaceholders(_ texts: [XMLElement]) {
        for (index, text) in texts.enumerated() {
            var value = text.stringValue ?? ""
            guard let open = value.lastIndex(of: "{"), !value[open...].contains("}"),
                  texts[(index + 1)...].contains(where: { $0.stringValue?.contains("}") == true }) else { continue }
            for next in texts[(index + 1)...] {
                let rest = next.stringValue ?? ""
                if let close = rest.firstIndex(of: "}") {
                    value += rest[...close]
                    next.setText(String(rest[rest.index(after: close)...]))
                    break
                }
                value += rest
                next.setText("")
            }
            text.setText(value)
        }
    }

    /// The paragraph's own text, not that of text boxes inside it.
    private static func ownTexts(of paragraph: XMLElement) -> [XMLElement] {
        paragraph.descendants("w:t").filter { text in
            var node = text.parent
            while let current = node as? XMLElement, current.name != "w:p" { node = current.parent }
            return node === paragraph
        }
    }

    // MARK: Table

    private enum Role { case number, frame, script, other }

    private static func isHeader(_ row: XMLElement) -> Bool {
        !row.children("w:trPr").flatMap { $0.children("w:tblHeader") }.isEmpty
    }

    /// What a cell of the pattern row holds.
    private static func role(of cell: XMLElement) -> Role {
        if !cell.descendants("w:drawing").isEmpty { return .frame }
        let text = cell.descendants("w:t").compactMap(\.stringValue).joined().trimmingCharacters(in: .whitespaces)
        if text.contains("{") || text.contains(":") { return .script }
        if !text.isEmpty, text.allSatisfy(\.isNumber) { return .number }
        return .other
    }

    private static func removeColumn(_ column: Int, wideningColumn target: Int, of table: XMLElement, rows: [XMLElement]) {
        if let grid = table.children("w:tblGrid").first {
            let columns = grid.children("w:gridCol")
            if columns.indices.contains(column), columns.indices.contains(target) {
                let width = Int(columns[column].value(of: "w:w") ?? "") ?? 0
                columns[target].setValue(String((Int(columns[target].value(of: "w:w") ?? "") ?? 0) + width), of: "w:w")
                columns[column].detach()
            }
        }
        for row in rows {
            let cells = row.children("w:tc")
            guard cells.indices.contains(column), cells.indices.contains(target) else { continue }
            let width = { (cell: XMLElement) in cell.children("w:tcPr").first?.children("w:tcW").first }
            if let removed = width(cells[column]), let widened = width(cells[target]) {
                let sum = (Int(removed.value(of: "w:w") ?? "") ?? 0) + (Int(widened.value(of: "w:w") ?? "") ?? 0)
                widened.setValue(String(sum), of: "w:w")
            }
            cells[column].detach()
            // The row's least height was the frame's.
            row.children("w:trPr").first?.children("w:trHeight").forEach { $0.detach() }
        }
    }

    /// Twips between the page's left and right margins.
    private static func textWidth(of body: XMLElement) -> Int? {
        guard let section = body.descendants("w:sectPr").last,
              let page = section.children("w:pgSz").first?.value(of: "w:w").flatMap(Int.init),
              let margins = section.children("w:pgMar").first else { return nil }
        let left = margins.value(of: "w:left").flatMap(Int.init) ?? 0
        let right = margins.value(of: "w:right").flatMap(Int.init) ?? 0
        return page - left - right
    }

    /// Makes the table run from margin to margin, `column` taking up the difference.
    private static func stretch(_ table: XMLElement, column: Int, toWidth width: Int) {
        guard let grid = table.children("w:tblGrid").first else { return }
        let columns = grid.children("w:gridCol")
        guard columns.indices.contains(column) else { return }
        let others = columns.indices.filter { $0 != column }
            .reduce(0) { $0 + (Int(columns[$1].value(of: "w:w") ?? "") ?? 0) }
        let stretched = String(max(width - others, 0))
        columns[column].setValue(stretched, of: "w:w")
        if let properties = table.children("w:tblPr").first {
            properties.children("w:tblW").first?.setValue(String(width), of: "w:w")
            properties.children("w:tblW").first?.setValue("dxa", of: "w:type")
            properties.children("w:tblInd").first?.setValue("0", of: "w:w")
        }
        for row in table.children("w:tr") {
            let cells = row.children("w:tc")
            guard cells.count == columns.count else { continue }
            cells[column].children("w:tcPr").first?.children("w:tcW").first?.setValue(stretched, of: "w:w")
        }
    }

    private static func setText(of cell: XMLElement, to value: String) {
        let texts = cell.descendants("w:t")
        for (index, text) in texts.enumerated() {
            text.setText(index == 0 ? value : "")
        }
    }

    /// Points the cell's picture at the frame, as wide as the template's and as tall as the frame's shape needs.
    private static func fillFrame(in cell: XMLElement, relationship: String, image: ExportImage, number: Int) {
        guard let drawing = cell.descendants("w:drawing").first else { return }
        drawing.descendants("a:blip").first?.setValue(relationship, of: "r:embed")
        drawing.descendants("a:srcRect").forEach { $0.detach() }
        let extents = drawing.descendants("wp:extent") + drawing.descendants("a:ext")
        for extent in extents {
            guard let width = Double(extent.value(of: "cx") ?? "") else { continue }
            extent.setValue(String(Int(image.height(forWidth: width))), of: "cy")
        }
        // Drawing IDs must be unique in the document.
        let id = String(1_073_742_000 + number)
        for properties in drawing.descendants("wp:docPr") + drawing.descendants("pic:cNvPr") {
            properties.setValue(id, of: "id")
            properties.setValue("Frame \(number)", of: "name")
            properties.setValue("Frame \(number)", of: "descr")
        }
    }

    private static func fillScript(in cell: XMLElement, lines: [ExportLine]) {
        let paragraphs = cell.children("w:p")
        guard let first = paragraphs.first else { return }
        var description: XMLElement?
        var labelled: [String: XMLElement] = [:]
        var firstLabelled: XMLElement?
        for paragraph in paragraphs {
            let text = ownTexts(of: paragraph).compactMap(\.stringValue).joined()
            if text.contains("{") {
                description = description ?? paragraph
            } else if let match = text.firstMatch(of: /^\s*([^:{}]+):/) {
                let label = match.output.1.trimmingCharacters(in: .whitespaces).uppercased()
                labelled[label] = labelled[label] ?? paragraph
                firstLabelled = firstLabelled ?? paragraph
            }
        }
        paragraphs.forEach { $0.detach() }

        for line in lines {
            if line.label == ScriptElement.Kind.scene.exportLabel {
                let pattern = description ?? firstLabelled ?? first
                let paragraph = emptied(pattern)
                let base = runProperties(of: pattern, where: { $0.contains("{") })
                appendRuns(of: line.text, to: paragraph, properties: base)
                cell.addChild(paragraph)
            } else {
                let pattern = labelled[line.label] ?? firstLabelled ?? description ?? first
                let paragraph = emptied(pattern)
                let label = runProperties(of: pattern, where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
                let text = runProperties(of: pattern, last: true, where: { !$0.trimmingCharacters(in: separators).isEmpty })
                paragraph.addChild(run(properties: label, text: "\(line.label):"))
                paragraph.addChild(run(properties: text, text: " "))
                appendRuns(of: line.text, to: paragraph, properties: text)
                cell.addChild(paragraph)
            }
        }
        // A cell holds at least one paragraph, or Word won't open the file.
        if lines.isEmpty {
            cell.addChild(emptied(description ?? first))
        }
    }

    /// The paragraph with its properties and nothing else.
    private static func emptied(_ paragraph: XMLElement) -> XMLElement {
        let copy = paragraph.copy() as! XMLElement
        for child in copy.children ?? [] where child.name != "w:pPr" {
            child.detach()
        }
        return copy
    }

    /// The properties of the first (or last) run whose text passes `test`.
    private static func runProperties(of paragraph: XMLElement, last: Bool = false, where test: (String) -> Bool) -> XMLElement? {
        let runs = paragraph.children("w:r").filter { run in
            test(run.children("w:t").compactMap(\.stringValue).joined())
        }
        return (last ? runs.last : runs.first)?.children("w:rPr").first
    }

    /// The text's own bold, italic and underline go on top of the pattern's.
    private static func appendRuns(of text: RichText, to paragraph: XMLElement, properties: XMLElement?) {
        for part in text.runs {
            let styled = (properties?.copy() as? XMLElement) ?? XMLElement(name: "w:rPr")
            if part.bold { setProperty("w:b", in: styled); setProperty("w:bCs", in: styled) }
            if part.italic { setProperty("w:i", in: styled); setProperty("w:iCs", in: styled) }
            if part.underline { setProperty("w:u", value: "single", in: styled) }
            paragraph.addChild(run(properties: styled, text: part.text))
        }
    }

    /// A run with line breaks and tabs as Word's own.
    private static func run(properties: XMLElement?, text: String) -> XMLElement {
        let run = XMLElement(name: "w:r")
        if let properties { run.addChild(properties.copy() as! XMLElement) }
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            if index > 0 { run.addChild(XMLElement(name: "w:br")) }
            for (index, piece) in line.split(separator: "\t", omittingEmptySubsequences: false).enumerated() {
                if index > 0 { run.addChild(XMLElement(name: "w:tab")) }
                guard !piece.isEmpty else { continue }
                let text = XMLElement(name: "w:t")
                text.setText(clean(String(piece)))
                run.addChild(text)
            }
        }
        return run
    }

    /// Run properties in the schema's order, which Word holds to.
    private static let propertyOrder = [
        "w:rStyle", "w:rFonts", "w:b", "w:bCs", "w:i", "w:iCs", "w:caps", "w:smallCaps", "w:strike", "w:dstrike",
        "w:outline", "w:shadow", "w:emboss", "w:imprint", "w:noProof", "w:snapToGrid", "w:vanish", "w:webHidden",
        "w:color", "w:spacing", "w:w", "w:kern", "w:position", "w:sz", "w:szCs", "w:highlight", "w:u", "w:effect",
        "w:bdr", "w:shd", "w:fitText", "w:vertAlign", "w:rtl", "w:cs", "w:em", "w:lang", "w:eastAsianLayout",
        "w:specVanish", "w:oMath",
    ]

    /// Sets a run property's value, adding it in its place if it isn't there.
    private static func setProperty(_ name: String, value: String = "1", in properties: XMLElement) {
        if let existing = properties.children(name).first {
            existing.setValue(value, of: "w:val")
            return
        }
        let property = element(name, ["w:val": value])
        let rank = propertyOrder.firstIndex(of: name) ?? propertyOrder.count
        let children = properties.children ?? []
        let position = children.firstIndex { child in
            (propertyOrder.firstIndex(of: child.name ?? "") ?? propertyOrder.count) > rank
        } ?? children.count
        properties.insertChild(property, at: position)
    }

    // MARK: Logo

    /// Pictures anchored to a line after the table are moved to the top of the
    /// bottom margin, where the template's sample table leaves them.
    private static func pinTrailingAnchors(in body: XMLElement, after table: XMLElement) {
        let section = body.descendants("w:sectPr").last
        let pageHeight = section?.children("w:pgSz").first?.value(of: "w:h").flatMap(Int.init) ?? 15_840
        let bottomMargin = section?.children("w:pgMar").first?.value(of: "w:bottom").flatMap(Int.init) ?? 1_440
        let top = (pageHeight - bottomMargin) * 635 // EMUs per twip
        let siblings = body.children ?? []
        guard let start = siblings.firstIndex(where: { $0 === table }) else { return }
        for case let sibling as XMLElement in siblings[(start + 1)...] {
            for position in sibling.descendants("wp:positionV")
            where ["line", "paragraph"].contains(position.value(of: "relativeFrom") ?? "") {
                position.setValue("page", of: "relativeFrom")
                position.children?.forEach { $0.detach() }
                position.addChild(XMLElement(name: "wp:posOffset", stringValue: String(top)))
            }
        }
    }

    // MARK: Parts

    private static func setDefault(in types: XMLElement, extension name: String, type: String) {
        if let existing = types.children("Default").first(where: { $0.value(of: "Extension")?.lowercased() == name }) {
            existing.setValue(type, of: "ContentType")
        } else {
            types.insertChild(element("Default", ["Extension": name, "ContentType": type]), at: 0)
        }
    }

    private static func element(_ name: String, _ attributes: KeyValuePairs<String, String>) -> XMLElement {
        let element = XMLElement(name: name)
        for (key, value) in attributes {
            element.addAttribute(XMLNode.attribute(withName: key, stringValue: value) as! XMLNode)
        }
        return element
    }

    /// Drops control characters, which XML can't hold.
    private static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.value >= 0x20 && $0 != "\u{FFFE}" && $0 != "\u{FFFF}" }))
    }
}

nonisolated private extension XMLElement {
    func children(_ name: String) -> [XMLElement] {
        (children ?? []).compactMap { $0 as? XMLElement }.filter { $0.name == name }
    }

    func descendants(_ name: String) -> [XMLElement] {
        var found: [XMLElement] = []
        for case let child as XMLElement in children ?? [] {
            if child.name == name { found.append(child) }
            found += child.descendants(name)
        }
        return found
    }

    func value(of attribute: String) -> String? {
        self.attribute(forName: attribute)?.stringValue
    }

    func setValue(_ value: String, of attribute: String) {
        if let existing = self.attribute(forName: attribute) {
            existing.stringValue = value
        } else {
            addAttribute(XMLNode.attribute(withName: attribute, stringValue: value) as! XMLNode)
        }
    }

    /// A `w:t`'s text, kept with its spaces.
    func setText(_ text: String) {
        stringValue = text
        setValue("preserve", of: "xml:space")
    }
}
