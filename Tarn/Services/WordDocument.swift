import Foundation
import ZIPFoundation

/// Writes a real Word document (.docx) from the simple Markdown the model produces: headings,
/// paragraphs, bulleted, numbered and checkbox lists, tables, **bold** and *italic*.
///
/// AppKit can save attributed strings as .docx, but it drops tables, and summaries with
/// "action items" tables are exactly what people ask for, so this writes WordprocessingML
/// directly. Headings use Word's Heading styles, so they show up in Word's navigation pane.
enum WordDocument {
    enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String)
        case numbered(String, list: Int)
        case table([[String]])
    }

    static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        var list = 0, inNumbered = false
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[i].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.isEmpty || $0.allSatisfy { "-:".contains($0) } }) { rows.append(cells) }
                    i += 1
                }
                if !rows.isEmpty { out.append(.table(rows)) }
                inNumbered = false
                continue
            }
            i += 1
            if line.isEmpty || line.firstMatch(of: /^(-{3,}|\*{3,}|_{3,})$/) != nil {
                inNumbered = false
                continue
            }
            if let m = line.firstMatch(of: /^(#{1,6})\s+(.*)$/) {
                out.append(.heading(min(3, m.1.count), String(m.2)))
                inNumbered = false
            } else if let m = line.firstMatch(of: /^[-*•]\s+(?:\[( |x|X)\]\s+)?(.*)$/) {
                let box = m.1.map { $0 == " " ? "☐ " : "☑ " } ?? ""
                out.append(.bullet(box + String(m.2)))
                inNumbered = false
            } else if let m = line.firstMatch(of: /^\d+[.)]\s+(.*)$/) {
                if !inNumbered { list += 1; inNumbered = true }
                out.append(.numbered(String(m.1), list: list))
            } else {
                out.append(.paragraph(line))
                inNumbered = false
            }
        }
        return out
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Runs for one line: **bold**, *italic*, `code` and [links](url) become plain styled text.
    static func runs(_ text: String, bold: Bool = false) -> String {
        let plain = text.replacing(/\[([^\]]+)\]\([^)]*\)/) { String($0.output.1) }.replacingOccurrences(of: "`", with: "")
        var xml = ""
        for (i, part) in plain.components(separatedBy: "**").enumerated() where !part.isEmpty {
            for (j, piece) in part.components(separatedBy: "*").enumerated() where !piece.isEmpty {
                var props = ""
                if bold || i % 2 == 1 { props += "<w:b/>" }
                if j % 2 == 1 { props += "<w:i/>" }
                xml += "<w:r>" + (props.isEmpty ? "" : "<w:rPr>\(props)</w:rPr>") + "<w:t xml:space=\"preserve\">\(escape(piece))</w:t></w:r>"
            }
        }
        return xml
    }

    static func documentXML(_ blocks: [Block]) -> (document: String, numberedLists: Int) {
        var body = ""
        var lists = 0
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                body += "<w:p><w:pPr><w:pStyle w:val=\"Heading\(level)\"/></w:pPr>\(runs(text))</w:p>"
            case .paragraph(let text):
                body += "<w:p>\(runs(text))</w:p>"
            case .bullet(let text):
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"1\"/></w:numPr></w:pPr>\(runs(text))</w:p>"
            case .numbered(let text, let list):
                lists = max(lists, list)
                body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"0\"/><w:numId w:val=\"\(list + 1)\"/></w:numPr></w:pPr>\(runs(text))</w:p>"
            case .table(let rows):
                let columns = rows.map(\.count).max() ?? 1
                let width = 9000 / columns
                body += "<w:tbl><w:tblPr><w:tblStyle w:val=\"TableGrid\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/></w:tblPr><w:tblGrid>"
                body += String(repeating: "<w:gridCol w:w=\"\(width)\"/>", count: columns) + "</w:tblGrid>"
                for (r, row) in rows.enumerated() {
                    body += "<w:tr>" + (r == 0 ? "<w:trPr><w:tblHeader/></w:trPr>" : "")
                    for c in 0..<columns {
                        let shade = r == 0 ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F2\"/>" : ""
                        let cell = c < row.count ? row[c] : ""
                        body += "<w:tc><w:tcPr><w:tcW w:w=\"\(width)\" w:type=\"dxa\"/>\(shade)</w:tcPr><w:p><w:pPr><w:spacing w:after=\"0\"/></w:pPr>\(runs(cell, bold: r == 0))</w:p></w:tc>"
                    }
                    body += "</w:tr>"
                }
                body += "</w:tbl><w:p/>"
            }
        }
        let doc = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>\(body)<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/></w:sectPr></w:body></w:document>
        """
        return (doc, lists)
    }

    static func numberingXML(numberedLists: Int) -> String {
        let bullet = "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"•\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        let decimal = "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/><w:lvl w:ilvl=\"0\"><w:start w:val=\"1\"/><w:numFmt w:val=\"decimal\"/><w:lvlText w:val=\"%1.\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"720\" w:hanging=\"360\"/></w:pPr></w:lvl></w:abstractNum>"
        // numId 1 is bullets; each numbered list gets its own numId so it starts again at 1.
        var nums = "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
        for list in 0..<max(1, numberedLists) {
            nums += "<w:num w:numId=\"\(list + 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?><w:numbering xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">\(bullet)\(decimal)\(nums)</w:numbering>"
    }

    static let styles = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-IN"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="140" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
    <w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
    <w:style w:type="paragraph" w:styleId="Heading1"><w:name w:val="heading 1"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="120"/><w:outlineLvl w:val="0"/></w:pPr><w:rPr><w:b/><w:sz w:val="36"/><w:szCs w:val="36"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading2"><w:name w:val="heading 2"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="100"/><w:outlineLvl w:val="1"/></w:pPr><w:rPr><w:b/><w:sz w:val="28"/><w:szCs w:val="28"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="Heading3"><w:name w:val="heading 3"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="200" w:after="80"/><w:outlineLvl w:val="2"/></w:pPr><w:rPr><w:b/><w:sz w:val="24"/><w:szCs w:val="24"/></w:rPr></w:style>
    <w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="60"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>
    <w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/></w:tblBorders><w:tblCellMar><w:top w:w="60" w:type="dxa"/><w:left w:w="100" w:type="dxa"/><w:bottom w:w="60" w:type="dxa"/><w:right w:w="100" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
    </w:styles>
    """

    static let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>
    """

    static let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/></Relationships>
    """

    static let documentRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering" Target="numbering.xml"/></Relationships>
    """

    /// Writes `markdown` as a .docx file at `url` (replacing it).
    static func write(_ markdown: String, to url: URL) throws {
        let (document, lists) = documentXML(blocks(markdown))
        let parts: [(String, String)] = [
            ("[Content_Types].xml", contentTypes),
            ("_rels/.rels", packageRels),
            ("word/document.xml", document),
            ("word/_rels/document.xml.rels", documentRels),
            ("word/styles.xml", styles),
            ("word/numbering.xml", numberingXML(numberedLists: lists)),
        ]
        // Build next to the destination, then swap in, so a failed write never leaves half a file.
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let archive = try Archive(url: tmp, accessMode: .create)
        for (path, xml) in parts {
            let data = Data(xml.utf8)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { pos, size in
                data.subdata(in: Int(pos)..<Int(pos) + size)
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}
