import Foundation
import Markdown

/// Markdown (already preprocessed) → clean plain text: underlined headings, "• " bullets, ☐/☑
/// tasks, links as "label (url)" for web links only, tables as aligned columns.
enum ExportTextRenderer {

    static func render(_ markdown: String) -> String {
        let doc = Document(parsing: markdown, options: [.disableSmartOpts])
        let blocks = doc.children.map { block($0) }.filter { !$0.isEmpty }
        var lines: [String] = []
        for (i, b) in blocks.enumerated() {
            if i > 0 { lines.append("") }
            lines += b
        }
        return lines.map { trimTrailing($0) }.joined(separator: "\n") + "\n"
    }

    // MARK: Blocks

    private static func block(_ m: Markup) -> [String] {
        switch m {
        case let h as Heading:
            let text = inline(h).replacingOccurrences(of: "\n", with: " ")
            switch h.level {
            case 1: return [text.uppercased(), String(repeating: "=", count: max(displayWidth(text), 3))]
            case 2: return [text, String(repeating: "-", count: max(displayWidth(text), 3))]
            default: return [text]
            }
        case let p as Paragraph:
            return inline(p).components(separatedBy: "\n")
        case let l as UnorderedList:
            return list(Array(l.listItems), ordered: false, start: 1)
        case let l as OrderedList:
            return list(Array(l.listItems), ordered: true, start: Int(l.startIndex))
        case let q as BlockQuote:
            return children(q, tight: false).map { $0.isEmpty ? "│" : "│ " + $0 }
        case let c as CodeBlock:
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            return code.components(separatedBy: "\n").map { "    " + $0 }
        case is ThematicBreak:
            return [String(repeating: "─", count: 40)]
        case let html as HTMLBlock:
            let t = ExportHTMLRenderer.stripTags(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? [] : t.components(separatedBy: "\n")
        case let t as Table:
            return table(t)
        default:
            return children(m, tight: false)
        }
    }

    private static func children(_ m: Markup, tight: Bool) -> [String] {
        var lines: [String] = []
        var first = true
        for child in m.children {
            let b = block(child)
            if b.isEmpty { continue }
            // Nested lists hug their parent item; other blocks get a blank line in loose content.
            if !first && !(tight || child is UnorderedList || child is OrderedList) { lines.append("") }
            lines += b
            first = false
        }
        return lines
    }

    private static func list(_ items: [ListItem], ordered: Bool, start: Int) -> [String] {
        var lines: [String] = []
        let lastNumber = start + items.count - 1
        let numberWidth = String(lastNumber).count
        for (i, item) in items.enumerated() {
            let marker: String
            switch item.checkbox {
            case .checked?: marker = "☑ "
            case .unchecked?: marker = "☐ "
            case nil:
                if ordered {
                    let n = String(start + i)
                    marker = String(repeating: " ", count: numberWidth - n.count) + n + ". "
                } else {
                    marker = "• "
                }
            }
            let pad = String(repeating: " ", count: marker.count)
            let content = children(item, tight: true)
            if content.isEmpty { lines.append(marker); continue }
            for (j, l) in content.enumerated() {
                lines.append(j == 0 ? marker + l : (l.isEmpty ? "" : pad + l))
            }
        }
        return lines
    }

    private static func table(_ t: Table) -> [String] {
        var rows: [[String]] = []
        rows.append(t.head.cells.map { inline($0).replacingOccurrences(of: "\n", with: " ") })
        for row in t.body.rows {
            rows.append(row.cells.map { inline($0).replacingOccurrences(of: "\n", with: " ") })
        }
        let cols = rows.map(\.count).max() ?? 0
        guard cols > 0 else { return [] }
        rows = rows.map { $0 + Array(repeating: "", count: cols - $0.count) }
        var widths = (0..<cols).map { c in rows.map { displayWidth($0[c]) }.max() ?? 0 }
        // Very wide tables would wrap into a mess: fall back to "a | b" rows.
        if widths.reduce(0, +) + 3 * (cols - 1) > 100 {
            widths = Array(repeating: 0, count: cols)
        }
        func fmt(_ r: [String]) -> String {
            r.enumerated().map { c, cell in
                cell + String(repeating: " ", count: max(0, widths[c] - displayWidth(cell)))
            }.joined(separator: " | ")
        }
        var lines = [fmt(rows[0])]
        let ruleWidths = widths.enumerated().map { c, w in w > 0 ? w : displayWidth(rows[0][c]) }
        lines.append(ruleWidths.map { String(repeating: "-", count: max($0, 3)) }.joined(separator: "-+-"))
        lines += rows.dropFirst().map(fmt)
        return lines
    }

    // MARK: Inline

    static func inline(_ m: Markup) -> String {
        var s = ""
        for child in m.children { s += inlineNode(child) }
        return s
    }

    private static func inlineNode(_ m: Markup) -> String {
        switch m {
        case let t as Text: return t.string
        case let c as InlineCode: return c.code
        case is SoftBreak: return " "
        case is LineBreak: return "\n"
        case let html as InlineHTML:
            return html.rawHTML.lowercased().hasPrefix("<br") ? "\n" : ""
        case let link as Link:
            let label = inline(link)
            if let d = link.destination, d.lowercased().hasPrefix("http") {
                return label.isEmpty || label == d ? d : "\(label) (\(d))"
            }
            if let d = link.destination, d.lowercased().hasPrefix("mailto:"), label.isEmpty {
                return String(d.dropFirst(7))
            }
            return label
        case let img as Image:
            let alt = img.plainText
            if let src = img.source, src.lowercased().hasPrefix("http") { return alt.isEmpty ? src : "\(alt) (\(src))" }
            return alt
        case let s as SymbolLink: return s.destination ?? ""
        default: return inline(m)
        }
    }

    // MARK: Helpers

    /// Column width as seen in a monospaced viewer (combining marks don't take a column; emoji take two).
    static func displayWidth(_ s: String) -> Int {
        var w = 0
        for ch in s {
            if let first = ch.unicodeScalars.first, first.properties.isEmojiPresentation || ch.unicodeScalars.contains(where: { $0.value == 0xFE0F }) {
                w += 2
            } else {
                w += 1
            }
        }
        return w
    }

    private static func trimTrailing(_ s: String) -> String {
        var t = Substring(s)
        while t.last == " " { t.removeLast() }
        return String(t)
    }
}
