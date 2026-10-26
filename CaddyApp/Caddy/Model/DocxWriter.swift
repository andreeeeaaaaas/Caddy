import Foundation

/// Writes an export as a Word document: OOXML parts zipped into a `.docx`.
nonisolated enum DocxWriter {
    static func data(for document: ExportDocument) -> Data {
        var zip = ZipWriter()
        let frames = document.sections.enumerated().compactMap { index, section in
            section.frame.map { (index: index, frame: $0) }
        }
        zip.add("[Content_Types].xml", contentTypes)
        zip.add("_rels/.rels", packageRelationships)
        zip.add("docProps/core.xml", coreProperties(title: document.title))
        zip.add("word/styles.xml", styles)
        zip.add("word/_rels/document.xml.rels", documentRelationships(frames: frames.map(\.index)))
        zip.add("word/document.xml", body(for: document))
        for (index, frame) in frames {
            zip.add("word/media/frame\(index + 1).jpeg", frame.jpeg)
        }
        return zip.finish()
    }

    // MARK: Document

    /// Twips per point.
    private static let twips = 20.0
    /// EMUs per point, for drawings.
    private static let emus = 12_700.0
    private static let cellPadding = 5.0

    private static func body(for document: ExportDocument) -> String {
        let columns = document.columns
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
        xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
        xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
        xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>
        """
        xml += paragraph(runs: [run(document.title, bold: true, size: 14)], after: 2)
        if !document.subtitle.isEmpty {
            xml += paragraph(runs: [run(document.subtitle, size: 8.5, color: "666666")], after: 10)
        }

        let border = #"w:val="single" w:sz="4" w:space="0" w:color="999999""#
        let padding = Int(cellPadding * twips)
        xml += "<w:tbl><w:tblPr><w:tblW w:w=\"\(Int(7.5 * 72 * twips))\" w:type=\"dxa\"/><w:tblBorders>"
        for edge in ["top", "left", "bottom", "right", "insideH", "insideV"] { xml += "<w:\(edge) \(border)/>" }
        xml += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar>"
        for edge in ["top", "left", "bottom", "right"] { xml += "<w:\(edge) w:w=\"\(padding)\" w:type=\"dxa\"/>" }
        xml += "</w:tblCellMar></w:tblPr><w:tblGrid>"
        for column in columns { xml += "<w:gridCol w:w=\"\(Int(document.width(of: column) * twips))\"/>" }
        xml += "</w:tblGrid>"

        // The header row repeats at the top of every page.
        xml += "<w:tr><w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>"
        for column in columns {
            xml += cell(width: document.width(of: column), fill: "000000",
                        paragraph(runs: [run(column.title, bold: true, size: 10, color: "FFFFFF")], center: true))
        }
        xml += "</w:tr>"

        for (index, section) in document.sections.enumerated() {
            xml += "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
            let fill = index.isMultiple(of: 2) ? nil : "F7F7F7"
            for column in columns {
                let width = document.width(of: column)
                switch column {
                case .frame:
                    xml += cell(width: width, fill: fill, frame(section.frame, index: index, width: width - cellPadding * 2))
                case .script:
                    var content = paragraph(runs: [run(section.timecode, size: 7.5, color: "888888")], after: 4)
                    for line in section.script {
                        content += paragraph(runs: [run("\(line.label): ", bold: true)] + runs(line.text), after: 6)
                    }
                    xml += cell(width: width, fill: fill, content)
                case .notes:
                    xml += cell(width: width, fill: fill, section.notes.map { paragraph(runs: runs($0), after: 6) }.joined())
                }
            }
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"

        // A table can't end the body, and the section properties set US Letter with 0.5" margins.
        xml += """
        <w:p/><w:sectPr><w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" w:header="360" w:footer="360" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """
        return xml
    }

    private static func frame(_ frame: ExportFrame?, index: Int, width: Double) -> String {
        guard let frame else {
            return paragraph(runs: [run("No frame", italic: true, color: "888888")], center: true)
        }
        let cx = Int(width * emus)
        let cy = Int(frame.height(forWidth: width) * emus)
        let id = index + 1
        let drawing = """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="Frame \(id)"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(id)" name="frame\(id).jpeg"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="rIdFrame\(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\
        <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
        return paragraph(runs: [drawing], center: true)
    }

    /// A cell holds at least one paragraph, or Word won't open the file.
    private static func cell(width: Double, fill: String?, _ content: String) -> String {
        var xml = "<w:tc><w:tcPr><w:tcW w:w=\"\(Int(width * twips))\" w:type=\"dxa\"/>"
        if let fill { xml += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\(fill)\"/>" }
        xml += "</w:tcPr>" + (content.isEmpty ? "<w:p/>" : content) + "</w:tc>"
        return xml
    }

    /// `after` is the space below in points.
    private static func paragraph(runs: [String], center: Bool = false, after: Double = 0) -> String {
        var properties = ""
        if after > 0 { properties += "<w:spacing w:after=\"\(Int(after * twips))\"/>" }
        if center { properties += "<w:jc w:val=\"center\"/>" }
        return "<w:p>" + (properties.isEmpty ? "" : "<w:pPr>\(properties)</w:pPr>") + runs.joined() + "</w:p>"
    }

    private static func runs(_ text: RichText) -> [String] {
        text.runs.map { run($0.text, bold: $0.bold, italic: $0.italic, underline: $0.underline) }
    }

    /// `size` is in points. Line breaks and tabs become Word's own.
    private static func run(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                            size: Double? = nil, color: String? = nil) -> String {
        var properties = ""
        if bold { properties += "<w:b/>" }
        if italic { properties += "<w:i/>" }
        // In the schema's order, which Word holds to.
        if let color { properties += "<w:color w:val=\"\(color)\"/>" }
        if let size { properties += "<w:sz w:val=\"\(Int(size * 2))\"/><w:szCs w:val=\"\(Int(size * 2))\"/>" }
        if underline { properties += "<w:u w:val=\"single\"/>" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { "<w:t xml:space=\"preserve\">\(escape(String($0)))</w:t>" }
                .joined(separator: "<w:tab/>")
        }
        return "<w:r>" + (properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>") + lines.joined(separator: "<w:br/>") + "</w:r>"
    }

    /// Escapes markup and drops control characters, which XML can't hold.
    private static func escape(_ text: String) -> String {
        var escaped = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case _ where scalar.value < 0x20: continue
            case "\u{FFFE}", "\u{FFFF}": continue
            default: escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    // MARK: Package parts

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
    </Types>
    """

    private static let packageRelationships = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
    <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>\
    <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
    </Relationships>
    """

    private static func coreProperties(title: String) -> String {
        let now = ISO8601DateFormatter().string(from: .now)
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
        xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" \
        xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">\
        <dc:title>\(escape(title))</dc:title><dc:creator>Caddy</dc:creator>\
        <dcterms:created xsi:type="dcterms:W3CDTF">\(now)</dcterms:created>\
        </cp:coreProperties>
        """
    }

    /// Calibri 10 pt, as the reference build's template used.
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr>\
    <w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/>\
    <w:sz w:val="20"/><w:szCs w:val="20"/><w:lang w:val="en-US"/>\
    </w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
    </w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    </w:styles>
    """

    private static func documentRelationships(frames: [Int]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
        """
        for index in frames {
            xml += "<Relationship Id=\"rIdFrame\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/frame\(index + 1).jpeg\"/>"
        }
        return xml + "</Relationships>"
    }
}

/// A ZIP archive with every entry stored, not compressed: enough for a `.docx`,
/// whose frames are JPEGs already.
nonisolated struct ZipWriter {
    private var data = Data()
    private var directory = Data()
    private var count = 0

    mutating func add(_ path: String, _ text: String) {
        add(path, Data(text.utf8))
    }

    mutating func add(_ path: String, _ content: Data) {
        let name = Data(path.utf8)
        let crc = CRC32.checksum(content)
        let offset = UInt32(data.count)
        // DOS time and date: midnight, 1 January 1980.
        let time: UInt16 = 0, date: UInt16 = 0x21

        data.append(le32: 0x0403_4b50)
        data.append(le16: 20)
        data.append(le16: 0x0800) // Names are UTF-8.
        data.append(le16: 0)      // Stored.
        data.append(le16: time)
        data.append(le16: date)
        data.append(le32: crc)
        data.append(le32: UInt32(content.count))
        data.append(le32: UInt32(content.count))
        data.append(le16: UInt16(name.count))
        data.append(le16: 0)
        data.append(name)
        data.append(content)

        directory.append(le32: 0x0201_4b50)
        directory.append(le16: 20)
        directory.append(le16: 20)
        directory.append(le16: 0x0800)
        directory.append(le16: 0)
        directory.append(le16: time)
        directory.append(le16: date)
        directory.append(le32: crc)
        directory.append(le32: UInt32(content.count))
        directory.append(le32: UInt32(content.count))
        directory.append(le16: UInt16(name.count))
        directory.append(le16: 0) // Extra field.
        directory.append(le16: 0) // Comment.
        directory.append(le16: 0) // Disk.
        directory.append(le16: 0) // Internal attributes.
        directory.append(le32: 0) // External attributes.
        directory.append(le32: offset)
        directory.append(name)
        count += 1
    }

    func finish() -> Data {
        var archive = data
        archive.append(directory)
        archive.append(le32: 0x0605_4b50)
        archive.append(le16: 0)
        archive.append(le16: 0)
        archive.append(le16: UInt16(count))
        archive.append(le16: UInt16(count))
        archive.append(le32: UInt32(directory.count))
        archive.append(le32: UInt32(data.count))
        archive.append(le16: 0)
        return archive
    }
}

private nonisolated enum CRC32 {
    static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    nonisolated mutating func append(le16 value: UInt16) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    nonisolated mutating func append(le32 value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
