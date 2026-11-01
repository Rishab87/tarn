import AppKit
import PDFKit

/// Text out of the documents people actually have (Word, RTF, OpenDocument, PDF), and Word
/// documents written from the simple Markdown the model produces.
enum Documents {
    static let types: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument,
    ]

    static func isRich(_ url: URL) -> Bool { types[url.pathExtension.lowercased()] != nil }

    static func isPDF(_ url: URL, _ data: Data) -> Bool {
        url.pathExtension.lowercased() == "pdf" || data.starts(with: Data("%PDF-".utf8))
    }

    /// The text of a Word, RTF, OpenDocument or PDF file; nil when the file is none of those.
    static func text(_ url: URL, _ data: Data) throws -> String? {
        let name = url.lastPathComponent
        if let type = types[url.pathExtension.lowercased()] {
            guard let doc = try? NSAttributedString(data: data, options: [.documentType: type], documentAttributes: nil) else {
                throw ToolFailure("Tarn couldn’t open \(name). It may be damaged or in an unusual format.")
            }
            return doc.string
        }
        guard isPDF(url, data) else { return nil }
        guard let pdf = PDFDocument(data: data) else { throw ToolFailure("Tarn couldn’t read \(name). It may be damaged.") }
        if pdf.isLocked { throw ToolFailure("\(name) is password-protected.") }
        let text = (0..<pdf.pageCount).compactMap { i in pdf.page(at: i)?.string.map { "[Page \(i + 1)]\n\($0)" } }.joined(separator: "\n\n")
        if text.replacing(/\[Page \d+\]/, with: "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ToolFailure("\(name) has no selectable text (it may be a scan), so Tarn can’t read it yet.")
        }
        return text
    }

    /// Saves `content` to `url`. Word, RTF and OpenDocument paths get a formatted document built
    /// from simple Markdown (# headings, - bullets, 1. lists, **bold**); anything else is plain text.
    static func write(_ content: String, to url: URL) throws {
        let ext = url.pathExtension.lowercased()
        if ext == "docx" { return try WordDocument.write(content, to: url) }
        guard let type = types[ext] else {
            try Data(content.utf8).write(to: url, options: .atomic)
            return
        }
        let doc = formatted(content)
        let data = try doc.data(from: NSRange(location: 0, length: doc.length), documentAttributes: [.documentType: type])
        try data.write(to: url, options: .atomic)
    }

    static func formatted(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let base: CGFloat = 12
        func font(_ size: CGFloat, bold: Bool = false, italic: Bool = false) -> NSFont {
            var f = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
            if bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
            if italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
            return f
        }
        /// Inline **bold** and *italic* runs.
        func inline(_ text: String, size: CGFloat, bold: Bool, style: NSParagraphStyle) -> NSAttributedString {
            let run = NSMutableAttributedString()
            for (i, part) in text.components(separatedBy: "**").enumerated() where !part.isEmpty {
                let isBold = bold || i % 2 == 1
                for (j, piece) in part.components(separatedBy: "*").enumerated() where !piece.isEmpty {
                    run.append(NSAttributedString(string: piece, attributes: [.font: font(size, bold: isBold, italic: j % 2 == 1), .paragraphStyle: style]))
                }
            }
            return run
        }
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            var line = lines[i].trimmingCharacters(in: .whitespaces)
            // A Markdown table: consecutive lines starting with "|" become a real table.
            if line.hasPrefix("|") {
                var rows: [[String]] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = lines[i].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "|"))
                        .components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                    if !cells.allSatisfy({ $0.isEmpty || $0.allSatisfy { "-:".contains($0) } }) { rows.append(cells) }
                    i += 1
                }
                let columns = rows.map(\.count).max() ?? 0
                guard columns > 0 else { continue }
                let table = NSTextTable()
                table.numberOfColumns = columns
                table.collapsesBorders = true
                table.setContentWidth(100, type: .percentageValueType)
                for (r, row) in rows.enumerated() {
                    for c in 0..<columns {
                        let block = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                        block.setWidth(0.5, type: .absoluteValueType, for: .border)
                        block.setBorderColor(NSColor(calibratedWhite: 0.6, alpha: 1))
                        block.setWidth(4, type: .absoluteValueType, for: .padding)
                        if r == 0 { block.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1) }
                        let style = NSMutableParagraphStyle()
                        style.textBlocks = [block]
                        let cell = c < row.count ? row[c] : ""
                        out.append(inline(cell.isEmpty ? " " : cell, size: base - 1, bold: r == 0, style: style))
                        out.append(NSAttributedString(string: "\n", attributes: [.font: font(base - 1), .paragraphStyle: style]))
                    }
                }
                continue
            }
            i += 1
            // Horizontal rules (---, ***) only separate sections in Markdown; Word doesn't need them.
            if line.firstMatch(of: /^(-{3,}|\*{3,}|_{3,})$/) != nil { continue }
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            var size = base, bold = false, prefix = ""
            if let m = line.firstMatch(of: /^(#{1,4})\s+(.*)$/) {
                let level = min(3, m.1.count)
                size = [20, 16, 13.5][level - 1]
                bold = true
                style.paragraphSpacingBefore = level == 1 ? 6 : 10
                line = String(m.2)
            } else if let m = line.firstMatch(of: /^[-*•]\s+(?:\[( |x|X)\]\s+)?(.*)$/) {
                prefix = m.1.map { $0 == " " ? "☐\t" : "☑\t" } ?? "•\t"
                line = String(m.2)
            } else if let m = line.firstMatch(of: /^(\d+)[.)]\s+(.*)$/) {
                prefix = "\(m.1).\t"
                line = String(m.2)
            }
            if !prefix.isEmpty {
                style.headIndent = 18
                style.firstLineHeadIndent = 0
                style.tabStops = [NSTextTab(textAlignment: .left, location: 18)]
                style.paragraphSpacing = 3
            }
            out.append(NSAttributedString(string: prefix, attributes: [.font: font(size, bold: bold), .paragraphStyle: style]))
            out.append(inline(line, size: size, bold: bold, style: style))
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(size), .paragraphStyle: style]))
        }
        return out
    }
}
