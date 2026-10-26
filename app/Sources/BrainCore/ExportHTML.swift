import Foundation
import Markdown

/// Markdown (already preprocessed) → HTML body fragment. Unlike swift-markdown's HTMLFormatter it
/// escapes text, keeps inline formatting inside headings, renders task items as ☐/☑ and marks
/// callout blockquotes so they can be styled.
struct ExportHTMLRenderer: MarkupWalker {
    private(set) var result = ""
    private var inTableHead = false
    private var alignments: [Table.ColumnAlignment?] = []
    private var column = 0

    static func render(_ markdown: String) -> String {
        let doc = Document(parsing: markdown, options: [.disableSmartOpts])
        var r = ExportHTMLRenderer()
        r.visit(doc)
        return r.result
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for c in s {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(c)
            }
        }
        return out
    }

    // MARK: Blocks

    mutating func visitBlockQuote(_ q: BlockQuote) {
        result += calloutClass(q).map { "<blockquote class=\"\($0)\">\n" } ?? "<blockquote>\n"
        descendInto(q)
        result += "</blockquote>\n"
    }

    /// Callouts were turned into `> **⚠️ Label**` by the preprocessor.
    private func calloutClass(_ q: BlockQuote) -> String? {
        guard let p = q.child(at: 0) as? Paragraph, let strong = p.child(at: 0) as? Strong else { return nil }
        let label = strong.plainText
        if label.hasPrefix("⚠️") { return "callout warn" }
        if label.hasPrefix("ℹ️") || label.hasPrefix("💡") || label.hasPrefix("❓") || label.hasPrefix("📌")
            || label.hasPrefix("📄") || label.hasPrefix("❝") || label.hasPrefix("☐") { return "callout" }
        return nil
    }

    mutating func visitCodeBlock(_ c: CodeBlock) {
        var code = c.code
        if code.hasSuffix("\n") { code.removeLast() }
        result += "<pre><code>\(Self.escape(code))</code></pre>\n"
    }

    mutating func visitHeading(_ h: Heading) {
        let level = min(max(h.level, 1), 6)
        result += "<h\(level)>"
        descendInto(h)
        result += "</h\(level)>\n"
    }

    mutating func visitThematicBreak(_ t: ThematicBreak) { result += "<hr>\n" }

    mutating func visitHTMLBlock(_ html: HTMLBlock) {
        // Raw HTML is not trusted in an exported document: keep its text only.
        let text = Self.stripTags(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { result += "<p>\(Self.escape(text))</p>\n" }
    }

    mutating func visitUnorderedList(_ l: UnorderedList) {
        let isTasks = l.listItems.contains { $0.checkbox != nil }
        result += isTasks ? "<ul class=\"tasks\">\n" : "<ul>\n"
        descendInto(l)
        result += "</ul>\n"
    }

    mutating func visitOrderedList(_ l: OrderedList) {
        result += l.startIndex != 1 ? "<ol start=\"\(l.startIndex)\">\n" : "<ol>\n"
        descendInto(l)
        result += "</ol>\n"
    }

    mutating func visitListItem(_ item: ListItem) {
        switch item.checkbox {
        case .checked?: result += "<li class=\"task done\"><span class=\"box\">☑</span> "
        case .unchecked?: result += "<li class=\"task\"><span class=\"box\">☐</span> "
        case nil: result += "<li>"
        }
        descendInto(item)
        if result.hasSuffix("\n") { result.removeLast() }
        result += "</li>\n"
    }

    mutating func visitParagraph(_ p: Paragraph) {
        // The first paragraph of a list item is rendered inline (tight lists, no extra spacing).
        if p.parent is ListItem, p.indexInParent == 0 {
            descendInto(p)
            result += "\n"
            return
        }
        result += "<p>"
        descendInto(p)
        result += "</p>\n"
    }

    mutating func visitTable(_ t: Table) {
        alignments = t.columnAlignments
        result += "<table>\n"
        descendInto(t)
        result += "</table>\n"
        alignments = []
    }

    mutating func visitTableHead(_ head: Table.Head) {
        result += "<thead>\n<tr>\n"
        inTableHead = true
        column = 0
        descendInto(head)
        inTableHead = false
        result += "</tr>\n</thead>\n"
    }

    mutating func visitTableBody(_ body: Table.Body) {
        guard !body.isEmpty else { return }
        result += "<tbody>\n"
        descendInto(body)
        result += "</tbody>\n"
    }

    mutating func visitTableRow(_ row: Table.Row) {
        result += "<tr>\n"
        column = 0
        descendInto(row)
        result += "</tr>\n"
    }

    mutating func visitTableCell(_ cell: Table.Cell) {
        guard cell.colspan > 0, cell.rowspan > 0 else { return }
        let tag = inTableHead ? "th" : "td"
        result += "<\(tag)"
        if column < alignments.count, let a = alignments[column] {
            switch a {
            case .left: result += " align=\"left\""
            case .center: result += " align=\"center\""
            case .right: result += " align=\"right\""
            }
        }
        if cell.colspan > 1 { result += " colspan=\"\(cell.colspan)\"" }
        if cell.rowspan > 1 { result += " rowspan=\"\(cell.rowspan)\"" }
        result += ">"
        column += Int(cell.colspan)
        descendInto(cell)
        result += "</\(tag)>\n"
    }

    // MARK: Inline

    mutating func visitText(_ t: Text) { result += Self.escape(t.string) }
    mutating func visitInlineCode(_ c: InlineCode) { result += "<code>\(Self.escape(c.code))</code>" }
    mutating func visitEmphasis(_ e: Emphasis) { result += "<em>"; descendInto(e); result += "</em>" }
    mutating func visitStrong(_ s: Strong) { result += "<strong>"; descendInto(s); result += "</strong>" }
    mutating func visitStrikethrough(_ s: Strikethrough) { result += "<del>"; descendInto(s); result += "</del>" }
    mutating func visitSoftBreak(_ b: SoftBreak) { result += "\n" }
    mutating func visitLineBreak(_ b: LineBreak) { result += "<br>\n" }
    mutating func visitSymbolLink(_ s: SymbolLink) { result += "<code>\(Self.escape(s.destination ?? ""))</code>" }

    mutating func visitLink(_ link: Link) {
        if let dest = link.destination, Self.isExternal(dest) {
            result += "<a href=\"\(Self.escape(dest))\">"
            descendInto(link)
            result += "</a>"
        } else {
            // Vault-relative links have nowhere to go outside the app: keep the label.
            descendInto(link)
        }
    }

    mutating func visitImage(_ image: Image) {
        // No remote fetches while exporting; show the alt text (and the address when external).
        let alt = image.plainText
        if let src = image.source, Self.isExternal(src) {
            result += "<a href=\"\(Self.escape(src))\">\(Self.escape(alt.isEmpty ? src : alt))</a>"
        } else if !alt.isEmpty {
            result += "<em>\(Self.escape(alt))</em>"
        }
    }

    private static let allowedInline: Set<String> = ["br", "b", "strong", "i", "em", "u", "s", "del", "sub", "sup", "mark", "kbd", "small"]

    mutating func visitInlineHTML(_ html: InlineHTML) {
        let raw = html.rawHTML
        let name = raw.drop(while: { $0 == "<" || $0 == "/" }).prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
        if Self.allowedInline.contains(name), !raw.contains("=") {
            result += name == "br" ? "<br>\n" : raw
        }
    }

    static func isExternal(_ dest: String) -> Bool {
        let d = dest.lowercased()
        return d.hasPrefix("http://") || d.hasPrefix("https://") || d.hasPrefix("mailto:")
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
    }
}

// MARK: - Full documents

enum ExportHTMLDocument {

    /// Standalone .html file: readable on screen, prints well, light/dark aware.
    static func page(title: String, body: String, lang: Lang) -> String {
        """
        <!DOCTYPE html>
        <html lang="\(lang.en ? "en" : "es")">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="generator" content="SecondBrain">
        <title>\(ExportHTMLRenderer.escape(title))</title>
        <style>
        \(screenCSS)
        </style>
        </head>
        <body>
        <article>
        \(body)</article>
        </body>
        </html>

        """
    }

    static let screenCSS = """
    :root { color-scheme: light dark; --fg: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --soft: #f5f5f7;
            --accent: #0a66c2; --info-bg: #eef5ff; --warn-bg: #fff6e5; --warn-line: #f0a020; }
    @media (prefers-color-scheme: dark) {
      :root { --fg: #f2f2f7; --muted: #a1a1a6; --line: #3a3a3c; --soft: #1c1c1e; --accent: #4da3ff;
              --info-bg: #16222f; --warn-bg: #2d2412; --warn-line: #c98a1a; }
      body { background: #111113; }
    }
    html { -webkit-text-size-adjust: 100%; }
    body { margin: 0; color: var(--fg); background: #fff;
           font: 11pt/1.55 -apple-system, BlinkMacSystemFont, "Segoe UI", "Helvetica Neue", Arial, sans-serif; }
    article { max-width: 46em; margin: 0 auto; padding: 2.5em 1.25em 4em; overflow-wrap: break-word; }
    h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 .5em; font-weight: 650; }
    h1 { font-size: 1.9em; margin-top: 0; letter-spacing: -.01em; }
    h2 { font-size: 1.4em; padding-bottom: .25em; border-bottom: 1px solid var(--line); }
    h3 { font-size: 1.15em; }
    h4, h5, h6 { font-size: 1em; }
    p, ul, ol, blockquote, table, pre { margin: 0 0 .9em; }
    ul, ol { padding-left: 1.5em; }
    li { margin: .2em 0; }
    li > ul, li > ol { margin: .2em 0 0; }
    ul.tasks { list-style: none; padding-left: .3em; }
    li.task .box { display: inline-block; width: 1.2em; }
    li.task.done { color: var(--muted); }
    a { color: var(--accent); text-decoration: none; }
    a:hover { text-decoration: underline; }
    blockquote { margin-left: 0; padding: .5em 1em; border-left: 3px solid var(--line); color: var(--muted); }
    blockquote.callout { color: var(--fg); background: var(--info-bg); border-left-color: var(--accent); border-radius: 0 6px 6px 0; }
    blockquote.callout.warn { background: var(--warn-bg); border-left-color: var(--warn-line); }
    blockquote > :last-child { margin-bottom: 0; }
    code { font: .92em ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; background: var(--soft);
           padding: .1em .3em; border-radius: 4px; }
    pre { background: var(--soft); padding: .8em 1em; border-radius: 6px; overflow-x: auto; }
    pre code { background: none; padding: 0; }
    table { border-collapse: collapse; width: 100%; display: block; overflow-x: auto; }
    @media (min-width: 40em) { table { display: table; } }
    th, td { border: 1px solid var(--line); padding: .4em .65em; text-align: left; vertical-align: top; }
    th { background: var(--soft); font-weight: 600; }
    hr { border: 0; border-top: 1px solid var(--line); margin: 1.6em 0; }
    del { color: var(--muted); }
    @media print { body { background: #fff; color: #000; } article { max-width: none; padding: 0; }
                   a { color: inherit; } h2, h3 { break-after: avoid; } tr, li { break-inside: avoid; } }
    """

    /// HTML flavour for the clipboard (Mail, Gmail, Docs, Word): inline styles only, since pasted
    /// HTML usually loses its <style> sheet.
    static func forClipboard(body: String) -> String {
        var b = body
        let styles: [(String, String)] = [
            ("<h1>", "<h1 style=\"font-size:20px;margin:0 0 10px\">"),
            ("<h2>", "<h2 style=\"font-size:16px;margin:16px 0 6px\">"),
            ("<h3>", "<h3 style=\"font-size:13px;margin:12px 0 4px\">"),
            ("<blockquote class=\"callout warn\">", "<blockquote style=\"margin:6px 0;padding:6px 10px;border-left:3px solid #f0a020;background:#fff6e5\">"),
            ("<blockquote class=\"callout\">", "<blockquote style=\"margin:6px 0;padding:6px 10px;border-left:3px solid #0a66c2;background:#eef5ff\">"),
            ("<blockquote>", "<blockquote style=\"margin:6px 0;padding:2px 10px;border-left:3px solid #c7c7cc;color:#555\">"),
            ("<ul class=\"tasks\">", "<ul style=\"list-style:none;padding-left:4px\">"),
            ("<table>", "<table style=\"border-collapse:collapse;margin:4px 0 10px\">"),
            ("<th>", "<th style=\"border:1px solid #c7c7cc;padding:4px 8px;background:#f0f0f2;text-align:left\">"),
            ("<th ", "<th style=\"border:1px solid #c7c7cc;padding:4px 8px;background:#f0f0f2;text-align:left\" "),
            ("<td>", "<td style=\"border:1px solid #c7c7cc;padding:4px 8px;vertical-align:top\">"),
            ("<td ", "<td style=\"border:1px solid #c7c7cc;padding:4px 8px;vertical-align:top\" "),
            ("<pre>", "<pre style=\"background:#f5f5f7;padding:8px 10px;font-family:Menlo,Consolas,monospace;font-size:12px\">"),
        ]
        for (from, to) in styles { b = b.replacingOccurrences(of: from, with: to) }
        return "<meta charset=\"utf-8\"><div style=\"font-family:-apple-system,'Helvetica Neue',Arial,sans-serif;font-size:14px;line-height:1.45;color:#1d1d1f\">\n\(b)</div>"
    }
}
