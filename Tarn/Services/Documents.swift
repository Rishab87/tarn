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
        guard let type = types[url.pathExtension.lowercased()] else {
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
        func font(_ size: CGFloat, bold: Bool) -> NSFont {
            let f = NSFont(name: "Helvetica", size: size) ?? .systemFont(ofSize: size)
            return bold ? NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) : f
        }
        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = 6
            var size = base, bold = false, prefix = ""
            if let m = line.firstMatch(of: /^(#{1,3})\s+(.*)$/) {
                let level = m.1.count
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
            // **bold** runs inside the line
            for (i, part) in line.components(separatedBy: "**").enumerated() where !part.isEmpty {
                out.append(NSAttributedString(string: part, attributes: [.font: font(size, bold: bold || i % 2 == 1), .paragraphStyle: style]))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font(size, bold: false), .paragraphStyle: style]))
        }
        return out
    }
}
