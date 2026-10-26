import Foundation

/// Writes an export as a Word document: OOXML parts zipped into a `.docx`.
/// Laid out like an Apple document: BentonSansF, Apple's greys, hairlines
/// instead of a grid, and the frog logo bottom right of every page.
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
        zip.add("word/footer1.xml", footer(for: document))
        zip.add("word/_rels/footer1.xml.rels", footerRelationships(hasLogo: document.logo != nil))
        for (index, frame) in frames {
            zip.add("word/media/frame\(index + 1).\(frame.format.rawValue)", frame.data)
        }
        if let logo = document.logo {
            zip.add("word/media/logo.\(logo.format.rawValue)", logo.data)
        }
        return zip.finish()
    }

    // MARK: Layout

    /// Twips per point.
    private static let twips = 20.0
    /// EMUs per point, for drawings.
    private static let emus = 12_700.0

    /// US Letter less 0.75" each side.
    private static let contentWidth = 7.0 * 72
    private static let frameColumn = 2.45 * 72
    /// Between the frame and the script.
    private static let gutter = 16.0
    private static let rowPadding = 12.0
    private static let cornerRadius = 5.0

    // Apple's text, secondary, tertiary and separator greys.
    private static let ink = "1D1D1F"
    private static let secondary = "6E6E73"
    private static let tertiary = "86868B"
    private static let hairline = "D2D2D7"

    /// Word names BentonSansF by its legacy families: Book holds regular,
    /// italic, bold and bold italic; Medium is a family of its own.
    private static let book = "BentonSansF Book"
    private static let medium = "BentonSansF Medium"

    // MARK: Document

    private static func body(for document: ExportDocument) -> String {
        let hasFrames = document.options.includeThumbnails
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document \(namespaces)><w:body>
        """

        // Title block: the folder small above, the video and date below.
        if !document.folder.isEmpty {
            xml += paragraph(runs: [run(document.folder.uppercased(), font: medium, size: 8, color: tertiary, tracking: 1.2)], after: 6)
        }
        xml += paragraph(runs: [run(document.title, bold: true, size: 26, color: ink, tracking: -0.3)], after: 6)
        if !document.details.isEmpty {
            xml += paragraph(runs: [run(document.details, size: 10, color: secondary)], after: 30)
        }

        let columns: [(title: String, width: Double)] = hasFrames
            ? [("Frame", frameColumn), ("Script", contentWidth - frameColumn)]
            : [("Script", contentWidth)]
        xml += "<w:tbl><w:tblPr><w:tblW w:w=\"\(Int(contentWidth * twips))\" w:type=\"dxa\"/><w:tblBorders>"
        for edge in ["top", "left", "right", "insideV"] { xml += "<w:\(edge) w:val=\"none\" w:sz=\"0\" w:space=\"0\" w:color=\"auto\"/>" }
        xml += "<w:bottom \(border(hairline, 0.5))/><w:insideH \(border(hairline, 0.5))/>"
        xml += "</w:tblBorders><w:tblLayout w:type=\"fixed\"/><w:tblCellMar>"
        for edge in ["top", "left", "bottom", "right"] { xml += "<w:\(edge) w:w=\"0\" w:type=\"dxa\"/>" }
        xml += "</w:tblCellMar></w:tblPr><w:tblGrid>"
        for column in columns { xml += "<w:gridCol w:w=\"\(Int(column.width * twips))\"/>" }
        xml += "</w:tblGrid>"

        // Small tracked labels over a dark rule, repeated at the top of every page.
        xml += "<w:tr><w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>"
        for (index, column) in columns.enumerated() {
            let label = paragraph(runs: [run(column.title.uppercased(), font: medium, size: 7.5, color: tertiary, tracking: 1.2)])
            xml += cell(width: column.width, bottom: 7, right: hasFrames && index == 0 ? gutter : 0, rule: (ink, 0.75), label)
        }
        xml += "</w:tr>"

        for (index, section) in document.sections.enumerated() {
            xml += "<w:tr><w:trPr><w:cantSplit/></w:trPr>"
            let caption = paragraph(runs: [
                run(String(format: "%02d", index + 1), font: medium, size: 8, color: ink),
                run("   " + section.timecode, size: 8, color: tertiary),
            ], after: hasFrames ? 0 : 8)
            if hasFrames {
                let imageWidth = frameColumn - gutter
                xml += cell(width: frameColumn, top: rowPadding, bottom: rowPadding, right: gutter,
                            frame(section.frame, index: index, width: imageWidth) + caption)
            }
            var script = hasFrames ? "" : caption
            for line in section.script {
                script += scriptLine(line)
            }
            xml += cell(width: contentWidth - (hasFrames ? frameColumn : 0), top: rowPadding, bottom: rowPadding, script)
            xml += "</w:tr>"
        }
        xml += "</w:tbl>"

        // A table can't end the body. The section is US Letter, 0.75" each side,
        // with the footer 0.45" from the bottom.
        xml += """
        <w:p/><w:sectPr><w:footerReference w:type="default" r:id="rIdFooter"/>\
        <w:pgSz w:w="12240" w:h="15840"/>\
        <w:pgMar w:top="1224" w:right="1080" w:bottom="1368" w:left="1080" w:header="648" w:footer="648" w:gutter="0"/>\
        </w:sectPr></w:body></w:document>
        """
        return xml
    }

    /// A small tracked label above the text, kept on the same page as it. Stacked
    /// rather than tabbed, so it lays out the same in Word, Pages and Quick Look.
    private static func scriptLine(_ line: ExportLine) -> String {
        let label = run(line.label, font: medium, size: 7, color: tertiary, tracking: 1)
        let text = line.text.runs.map { run($0.text, bold: $0.bold, italic: $0.italic, underline: $0.underline, size: 10, color: ink) }
        return "<w:p><w:pPr><w:keepNext/><w:spacing w:after=\"\(Int(3 * twips))\"/></w:pPr>\(label)</w:p>"
            + "<w:p><w:pPr><w:spacing w:after=\"\(Int(11 * twips))\" w:line=\"288\" w:lineRule=\"auto\"/></w:pPr>\(text.joined())</w:p>"
    }

    private static func frame(_ frame: ExportImage?, index: Int, width: Double) -> String {
        guard let frame else {
            return paragraph(runs: [run("No frame", italic: true, size: 9, color: tertiary)], after: 8)
        }
        let height = frame.height(forWidth: width)
        let corner = Int(cornerRadius / min(width, height) * 100_000)
        return paragraph(runs: [drawing(id: index + 1, name: "Frame \(index + 1)", relationship: "rIdFrame\(index + 1)",
                                        width: width, height: height, corner: corner)], after: 7)
    }

    /// An inline picture. `corner` rounds it, in thousandths of a percent of its shorter side.
    private static func drawing(id: Int, name: String, relationship: String, width: Double, height: Double, corner: Int = 0) -> String {
        let cx = Int(width * emus), cy = Int(height * emus)
        let geometry = corner > 0
            ? "<a:prstGeom prst=\"roundRect\"><a:avLst><a:gd name=\"adj\" fmla=\"val \(corner)\"/></a:avLst></a:prstGeom>"
            : "<a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
        return """
        <w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0">\
        <wp:extent cx="\(cx)" cy="\(cy)"/><wp:docPr id="\(id)" name="\(escape(name))"/>\
        <wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>\
        <a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>\
        <pic:nvPicPr><pic:cNvPr id="\(id)" name="\(escape(name))"/><pic:cNvPicPr/></pic:nvPicPr>\
        <pic:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>\
        <pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\(cx)" cy="\(cy)"/></a:xfrm>\(geometry)</pic:spPr>\
        </pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>
        """
    }

    // MARK: Footer

    /// The script's name and page number on the left, the frog logo on the right.
    private static func footer(for document: ExportDocument) -> String {
        let style = { (text: String) in run(text, size: 7.5, color: tertiary) }
        var runs = [style(document.title + "   ·   Page "), field("PAGE", style("1")), style(" of "), field("NUMPAGES", style("1"))]
        if let logo = document.logo {
            let width = 30.0
            runs += ["<w:r><w:tab/></w:r>", drawing(id: 1000, name: "frog", relationship: "rIdLogo",
                                                     width: width, height: logo.height(forWidth: width))]
        }
        return """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:ftr \(namespaces)><w:p><w:pPr><w:tabs><w:tab w:val="right" w:pos="\(Int(contentWidth * twips))"/></w:tabs></w:pPr>\
        \(runs.joined())</w:p></w:ftr>
        """
    }

    private static func field(_ instruction: String, _ placeholder: String) -> String {
        "<w:fldSimple w:instr=\" \(instruction) \">\(placeholder)</w:fldSimple>"
    }

    // MARK: Parts

    private static let namespaces = """
    xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" \
    xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" \
    xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" \
    xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" \
    xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
    """

    /// `width` is in points.
    private static func border(_ color: String, _ width: Double) -> String {
        "w:val=\"single\" w:sz=\"\(Int(width * 8))\" w:space=\"0\" w:color=\"\(color)\""
    }

    /// Padding in points. `rule` draws a line under the cell, as the header row has.
    private static func cell(width: Double, top: Double = 0, bottom: Double = 0, right: Double = 0,
                             rule: (color: String, width: Double)? = nil, _ content: String) -> String {
        var xml = "<w:tc><w:tcPr><w:tcW w:w=\"\(Int(width * twips))\" w:type=\"dxa\"/>"
        if let rule { xml += "<w:tcBorders><w:bottom \(border(rule.color, rule.width))/></w:tcBorders>" }
        xml += "<w:tcMar><w:top w:w=\"\(Int(top * twips))\" w:type=\"dxa\"/><w:left w:w=\"0\" w:type=\"dxa\"/>"
        xml += "<w:bottom w:w=\"\(Int(bottom * twips))\" w:type=\"dxa\"/><w:right w:w=\"\(Int(right * twips))\" w:type=\"dxa\"/></w:tcMar>"
        // A cell holds at least one paragraph, or Word won't open the file.
        xml += "</w:tcPr>" + (content.isEmpty ? "<w:p/>" : content) + "</w:tc>"
        return xml
    }

    /// `after` is the space below in points.
    private static func paragraph(runs: [String], after: Double = 0) -> String {
        let properties = after > 0 ? "<w:pPr><w:spacing w:after=\"\(Int(after * twips))\"/></w:pPr>" : ""
        return "<w:p>" + properties + runs.joined() + "</w:p>"
    }

    /// `size` and `tracking` are in points. Every run names its font, since
    /// Pages and Quick Look ignore the document's default.
    /// Line breaks and tabs become Word's own.
    private static func run(_ text: String, font: String = book, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                            size: Double? = nil, color: String? = nil, tracking: Double? = nil) -> String {
        // In the schema's order, which Word holds to.
        var properties = "<w:rFonts w:ascii=\"\(font)\" w:hAnsi=\"\(font)\" w:cs=\"\(font)\" w:eastAsia=\"\(font)\"/>"
        if bold { properties += "<w:b/><w:bCs/>" }
        if italic { properties += "<w:i/><w:iCs/>" }
        if let color { properties += "<w:color w:val=\"\(color)\"/>" }
        if let tracking { properties += "<w:spacing w:val=\"\(Int(tracking * twips))\"/>" }
        if let size { properties += "<w:sz w:val=\"\(Int(size * 2))\"/><w:szCs w:val=\"\(Int(size * 2))\"/>" }
        if underline { properties += "<w:u w:val=\"single\"/>" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.split(separator: "\t", omittingEmptySubsequences: false)
                .map { "<w:t xml:space=\"preserve\">\(escape(String($0)))</w:t>" }
                .joined(separator: "<w:tab/>")
        }
        return "<w:r><w:rPr>\(properties)</w:rPr>" + lines.joined(separator: "<w:br/>") + "</w:r>"
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

    private static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
    <Default Extension="xml" ContentType="application/xml"/>\
    <Default Extension="jpeg" ContentType="image/jpeg"/>\
    <Default Extension="png" ContentType="image/png"/>\
    <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>\
    <Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>\
    <Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>\
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

    /// BentonSansF Book 10 pt in Apple's near-black.
    private static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">\
    <w:docDefaults><w:rPrDefault><w:rPr>\
    <w:rFonts w:ascii="\(book)" w:hAnsi="\(book)" w:eastAsia="\(book)" w:cs="\(book)"/>\
    <w:color w:val="\(ink)"/><w:sz w:val="20"/><w:szCs w:val="20"/><w:lang w:val="en-US"/>\
    </w:rPr></w:rPrDefault>\
    <w:pPrDefault><w:pPr><w:spacing w:after="0" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault>\
    </w:docDefaults>\
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\
    </w:styles>
    """

    private static func documentRelationships(frames: [Int]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>\
        <Relationship Id="rIdFooter" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer" Target="footer1.xml"/>
        """
        for index in frames {
            xml += "<Relationship Id=\"rIdFrame\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/frame\(index + 1).jpeg\"/>"
        }
        return xml + "</Relationships>"
    }

    private static func footerRelationships(hasLogo: Bool) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        """
        if hasLogo {
            xml += "<Relationship Id=\"rIdLogo\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" Target=\"media/logo.png\"/>"
        }
        return xml + "</Relationships>"
    }
}
