import AppKit
import Foundation
import Markdown

/// Markdown (already preprocessed) → NSAttributedString for PDF, RTF and the clipboard, built
/// straight from the swift-markdown AST: consistent fonts, real lists (NSTextList), bordered
/// tables (NSTextTable), boxed callouts/quotes and code (NSTextBlock, PDF only).
struct ExportAttributedRenderer {

    enum Target {
        case screen     // PDF / clipboard preview: system font, boxed quotes
        case portable   // RTF / clipboard: Arial (every Word/Pages/Google Docs has it), indented quotes
    }

    // MARK: Theme

    static let bodySize: CGFloat = 11
    static let text = NSColor(srgbRed: 0.114, green: 0.114, blue: 0.122, alpha: 1)
    static let muted = NSColor(srgbRed: 0.40, green: 0.40, blue: 0.43, alpha: 1)
    static let accent = NSColor(srgbRed: 0.04, green: 0.40, blue: 0.76, alpha: 1)
    static let rule = NSColor(srgbRed: 0.78, green: 0.78, blue: 0.80, alpha: 1)
    static let soft = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1)
    static let headerFill = NSColor(srgbRed: 0.94, green: 0.94, blue: 0.95, alpha: 1)
    static let warnFill = NSColor(srgbRed: 1.0, green: 0.965, blue: 0.898, alpha: 1)
    static let warnLine = NSColor(srgbRed: 0.94, green: 0.63, blue: 0.13, alpha: 1)
    static let infoFill = NSColor(srgbRed: 0.93, green: 0.96, blue: 1.0, alpha: 1)

    let target: Target
    private let out = NSMutableAttributedString()

    // Block context while descending.
    private struct Context {
        var indent: CGFloat = 0
        var lists: [NSTextList] = []
        var blocks: [NSTextBlock] = []
        var color: NSColor = ExportAttributedRenderer.text
        var listLevel = 0
    }

    static func render(_ markdown: String, target: Target) -> NSAttributedString {
        let doc = Document(parsing: markdown, options: [.disableSmartOpts])
        var r = ExportAttributedRenderer(target: target)
        for child in doc.children { r.block(child, Context()) }
        r.trimTrailingNewline()
        return r.out
    }

    // MARK: Fonts

    static func font(size: CGFloat, bold: Bool = false, italic: Bool = false, mono: Bool = false, target: Target) -> NSFont {
        var f: NSFont
        if mono {
            f = target == .screen
                ? NSFont.monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
                : (NSFont(name: bold ? "Menlo-Bold" : "Menlo-Regular", size: size) ?? NSFont.userFixedPitchFont(ofSize: size)
                   ?? NSFont.systemFont(ofSize: size))
        } else if target == .screen {
            f = NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        } else {
            f = NSFont(name: bold ? "Arial-BoldMT" : "ArialMT", size: size)
                ?? NSFont(name: bold ? "Helvetica-Bold" : "Helvetica", size: size)
                ?? NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        }
        if italic {
            let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
            f = NSFont(descriptor: d, size: size) ?? NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask)
        }
        return f
    }

    // MARK: Inline

    private struct InlineStyle {
        var size: CGFloat = ExportAttributedRenderer.bodySize
        var bold = false, italic = false, mono = false, strike = false
        var color: NSColor = ExportAttributedRenderer.text
        var link: URL? = nil
    }

    private func attrs(_ s: InlineStyle) -> [NSAttributedString.Key: Any] {
        var a: [NSAttributedString.Key: Any] = [
            .font: Self.font(size: s.mono ? s.size * 0.9 : s.size, bold: s.bold, italic: s.italic, mono: s.mono, target: target),
            .foregroundColor: s.link != nil ? Self.accent : s.color,
        ]
        if s.strike { a[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; a[.foregroundColor] = Self.muted }
        if let l = s.link { a[.link] = l }
        return a
    }

    private func inlines(_ m: Markup, _ s: InlineStyle) -> NSMutableAttributedString {
        let r = NSMutableAttributedString()
        for child in m.children { r.append(inline(child, s)) }
        return r
    }

    private func inline(_ m: Markup, _ s: InlineStyle) -> NSAttributedString {
        var s = s
        switch m {
        case let t as Text: return NSAttributedString(string: t.string, attributes: attrs(s))
        case let c as InlineCode: s.mono = true; return NSAttributedString(string: c.code, attributes: attrs(s))
        case is SoftBreak: return NSAttributedString(string: " ", attributes: attrs(s))
        case is LineBreak: return NSAttributedString(string: "\u{2028}", attributes: attrs(s))
        case let e as Emphasis: s.italic = true; return inlines(e, s)
        case let b as Strong: s.bold = true; return inlines(b, s)
        case let x as Strikethrough: s.strike = true; return inlines(x, s)
        case let l as Link:
            if let d = l.destination, ExportHTMLRenderer.isExternal(d), let url = URL(string: d) { s.link = url }
            return inlines(l, s)
        case let img as Image:
            s.italic = true
            if let src = img.source, ExportHTMLRenderer.isExternal(src), let url = URL(string: src) { s.link = url }
            let alt = img.plainText
            return NSAttributedString(string: alt.isEmpty ? (img.source ?? "") : alt, attributes: attrs(s))
        case let h as InlineHTML:
            return h.rawHTML.lowercased().hasPrefix("<br") ? NSAttributedString(string: "\u{2028}", attributes: attrs(s)) : NSAttributedString()
        case let sym as SymbolLink: s.mono = true; return NSAttributedString(string: sym.destination ?? "", attributes: attrs(s))
        default: return inlines(m, s)
        }
    }

    // MARK: Paragraphs

    private func style(_ ctx: Context, before: CGFloat = 0, after: CGFloat = 6, first: CGFloat? = nil,
                       head: CGFloat? = nil, tabs: [CGFloat] = [], lineMultiple: CGFloat = 1.18) -> NSMutableParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineHeightMultiple = lineMultiple
        p.paragraphSpacingBefore = before
        p.paragraphSpacing = after
        p.firstLineHeadIndent = first ?? ctx.indent
        p.headIndent = head ?? ctx.indent
        p.tabStops = tabs.map { NSTextTab(textAlignment: .left, location: $0) }
        p.defaultTabInterval = 36
        p.textLists = ctx.lists
        p.textBlocks = ctx.blocks
        return p
    }

    private mutating func paragraph(_ content: NSAttributedString, _ ps: NSParagraphStyle) {
        let start = out.length
        out.append(content)
        out.append(NSAttributedString(string: "\n", attributes: content.length > 0
            ? content.attributes(at: content.length - 1, effectiveRange: nil) : attrs(InlineStyle())))
        out.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: start, length: out.length - start))
    }

    /// Changes the spacing after the last paragraph written (end of a list / quote).
    private func setLastSpacing(_ after: CGFloat) {
        guard out.length > 0, let ps = out.attribute(.paragraphStyle, at: out.length - 1, effectiveRange: nil) as? NSParagraphStyle else { return }
        let m = ps.mutableCopy() as! NSMutableParagraphStyle
        m.paragraphSpacing = after
        let range = (out.string as NSString).paragraphRange(for: NSRange(location: out.length - 1, length: 0))
        out.addAttribute(.paragraphStyle, value: m, range: range)
    }

    /// Thin empty paragraph: NSTextBlock margins aren't honoured between consecutive blocks.
    private mutating func spacer(_ ctx: Context, height: CGFloat = 7) {
        let p = NSMutableParagraphStyle()
        p.minimumLineHeight = 1
        p.maximumLineHeight = 1
        p.paragraphSpacing = height
        p.textBlocks = ctx.blocks
        p.textLists = ctx.lists
        out.append(NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: 1), .paragraphStyle: p]))
    }

    private mutating func trimTrailingNewline() {
        while out.length > 0, (out.string as NSString).character(at: out.length - 1) == 10 {
            out.deleteCharacters(in: NSRange(location: out.length - 1, length: 1))
        }
    }

    // MARK: Blocks

    private mutating func block(_ m: Markup, _ ctx: Context) {
        var base = InlineStyle()
        base.color = ctx.color
        switch m {
        case let h as Heading:
            let sizes: [CGFloat] = [22, 15.5, 12.5, 11, 11, 11]
            let before: [CGFloat] = [0, 16, 12, 10, 8, 8]
            let after: [CGFloat] = [10, 5, 4, 3, 2, 2]
            let i = min(max(h.level, 1), 6) - 1
            base.size = sizes[i]
            base.bold = true
            if i >= 4 { base.color = Self.muted }
            let isFirst = out.length == 0
            let content = inlines(h, base)
            content.addAttribute(.exportKeepWithNext, value: true, range: NSRange(location: 0, length: content.length))
            paragraph(content, style(ctx, before: isFirst ? 0 : before[i], after: after[i], lineMultiple: 1.05))

        case let p as Paragraph:
            paragraph(inlines(p, base), style(ctx))

        case let l as UnorderedList:
            list(Array(l.listItems), ordered: false, start: 1, ctx)
        case let l as OrderedList:
            list(Array(l.listItems), ordered: true, start: Int(l.startIndex), ctx)

        case let q as BlockQuote:
            quote(q, ctx)

        case let c as CodeBlock:
            var code = c.code
            if code.hasSuffix("\n") { code.removeLast() }
            var inner = ctx
            if target == .screen {
                let b = NSTextBlock()
                b.setContentWidth(100, type: .percentageValueType)
                b.backgroundColor = Self.soft
                b.setWidth(8, type: .absoluteValueType, for: .padding)
                b.setWidth(6, type: .absoluteValueType, for: .margin, edge: .maxY)
                inner.blocks.append(b)
            } else {
                inner.indent += 14
            }
            var s = base
            s.mono = true
            let lines = code.components(separatedBy: "\n")
            for (i, line) in lines.enumerated() {
                paragraph(NSAttributedString(string: line.isEmpty ? " " : line, attributes: attrs(s)),
                          style(inner, after: i == lines.count - 1 && target != .screen ? 6 : 0, lineMultiple: 1.1))
            }
            if target == .screen { spacer(ctx) }

        case is ThematicBreak:
            if target == .screen {
                var inner = ctx
                let b = NSTextBlock()
                b.setContentWidth(100, type: .percentageValueType)
                b.setWidth(0.75, type: .absoluteValueType, for: .border, edge: .maxY)
                b.setBorderColor(Self.rule, for: .maxY)
                b.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
                inner.blocks.append(b)
                var s = base; s.size = 4
                paragraph(NSAttributedString(string: " ", attributes: attrs(s)), style(inner, after: 0, lineMultiple: 1))
            } else {
                let ps = style(ctx, before: 4, after: 10)
                ps.alignment = .center
                var s = base; s.color = Self.muted
                paragraph(NSAttributedString(string: "• • •", attributes: attrs(s)), ps)
            }

        case let html as HTMLBlock:
            let t = ExportHTMLRenderer.stripTags(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { paragraph(NSAttributedString(string: t, attributes: attrs(base)), style(ctx)) }

        case let t as Table:
            table(t, ctx)

        default:
            for child in m.children { block(child, ctx) }
        }
    }

    private mutating func list(_ items: [ListItem], ordered: Bool, start: Int, _ ctx: Context) {
        let level = ctx.listLevel + 1
        let markerColumn = ctx.indent + 6
        let textColumn = ctx.indent + (ordered ? 24 : 20)
        let format: NSTextList.MarkerFormat = ordered ? .decimal : (level == 1 ? .disc : (level == 2 ? .circle : .square))
        let textList = NSTextList(markerFormat: format, options: 0)
        textList.startingItemNumber = start
        let isTaskList = items.contains { $0.checkbox != nil }

        for (i, item) in items.enumerated() {
            var inner = ctx
            inner.indent = textColumn
            inner.listLevel = level
            if !isTaskList { inner.lists.append(textList) }
            if item.checkbox == .checked { inner.color = Self.muted }

            let marker: String
            switch item.checkbox {
            case .checked?: marker = "☑"
            case .unchecked?: marker = "☐"
            case nil: marker = ordered ? "\(start + i)." : textList.marker(forItemNumber: start + i)
            }
            var markerStyle = InlineStyle()
            markerStyle.color = item.checkbox == nil ? Self.text : (item.checkbox == .checked ? Self.muted : Self.text)

            for (j, child) in item.children.enumerated() {
                if j == 0, let p = child as? Paragraph {
                    var s = InlineStyle(); s.color = inner.color
                    let line = NSMutableAttributedString(string: "\t\(marker)\t", attributes: attrs(markerStyle))
                    // Zero-width space in plain style first: RTF readers style the list marker
                    // like the item's first character (a struck-through item → struck marker).
                    line.append(NSAttributedString(string: "\u{200B}", attributes: attrs(s)))
                    line.append(inlines(p, s))
                    paragraph(line, style(inner, after: 2.5, first: ctx.indent, head: textColumn, tabs: [markerColumn, textColumn]))
                } else {
                    block(child, inner)
                }
            }
            if item.childCount == 0 {
                paragraph(NSAttributedString(string: "\t\(marker)\t", attributes: attrs(markerStyle)),
                          style(inner, after: 2.5, first: ctx.indent, head: textColumn, tabs: [markerColumn, textColumn]))
            }
        }
        if ctx.listLevel == 0 { setLastSpacing(7) }
    }

    private mutating func quote(_ q: BlockQuote, _ ctx: Context) {
        var inner = ctx
        let label = (q.child(at: 0) as? Paragraph)?.child(at: 0).flatMap { ($0 as? Strong)?.plainText } ?? ""
        let isWarn = label.hasPrefix("⚠️")
        let isCallout = isWarn || ["ℹ️", "💡", "❓", "📌", "📄", "❝", "☐"].contains { label.hasPrefix($0) }
        if target == .screen {
            let b = NSTextBlock()
            b.setContentWidth(100, type: .percentageValueType)
            b.backgroundColor = isWarn ? Self.warnFill : (isCallout ? Self.infoFill : nil)
            b.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
            b.setBorderColor(isWarn ? Self.warnLine : (isCallout ? Self.accent : Self.rule), for: .minX)
            b.setWidth(isCallout ? 7 : 3, type: .absoluteValueType, for: .padding)
            b.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
            b.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
            b.setWidth(9, type: .absoluteValueType, for: .margin, edge: .maxY)
            inner.blocks.append(b)
            inner.indent = 0
            inner.lists = []
            inner.listLevel = 0
        } else {
            inner.indent += 18
        }
        if !isCallout { inner.color = Self.muted }
        let startLength = out.length
        for child in q.children { block(child, inner) }
        if out.length > startLength { setLastSpacing(target == .screen ? 0 : 8) }
        if target == .screen { spacer(ctx) }
    }

    private mutating func table(_ t: Table, _ ctx: Context) {
        var rows: [(cells: [Table.Cell], header: Bool)] = [(Array(t.head.cells), true)]
        rows += t.body.rows.map { (Array($0.cells), false) }
        let cols = max(rows.map(\.cells.count).max() ?? 0, 1)
        let table = NSTextTable()
        table.numberOfColumns = cols
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        // Absolute widths: Cocoa writes RTF percentages it can't read back (100% → 250%).
        let tableWidth = ExportRich.paperSize.width - 2 * ExportRich.marginPoints - ctx.indent
        table.setContentWidth(tableWidth, type: .absoluteValueType)
        table.setWidth(10, type: .absoluteValueType, for: .margin, edge: .maxY)
        table.setWidth(2, type: .absoluteValueType, for: .margin, edge: .minY)
        let alignments = t.columnAlignments
        // Column widths proportional to content (clamped), so short columns don't waste space.
        var weights = Array(repeating: 4.0, count: cols)
        for row in rows {
            for (c, cell) in row.cells.enumerated() where c < cols {
                weights[c] = max(weights[c], min(Double(cell.plainText.count), 40))
            }
        }
        let total = weights.reduce(0, +)

        for (r, row) in rows.enumerated() {
            for c in 0..<cols {
                let cellBlock = NSTextTableBlock(table: table, startingRow: r, rowSpan: 1, startingColumn: c, columnSpan: 1)
                cellBlock.setValue(CGFloat(weights[c] / total) * tableWidth, type: .absoluteValueType, for: .width)
                cellBlock.setWidth(0.6, type: .absoluteValueType, for: .border)
                cellBlock.setBorderColor(Self.rule)
                cellBlock.setWidth(4, type: .absoluteValueType, for: .padding)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .minX)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding, edge: .maxX)
                cellBlock.verticalAlignment = .topAlignment
                if row.header { cellBlock.backgroundColor = Self.headerFill }
                var inner = ctx
                inner.blocks.append(cellBlock)
                inner.lists = []
                inner.indent = 0
                var s = InlineStyle()
                s.size = Self.bodySize - 1
                s.bold = row.header
                let content = c < row.cells.count ? inlines(row.cells[c], s) : NSMutableAttributedString()
                if content.length == 0 { content.append(NSAttributedString(string: " ", attributes: attrs(s))) }
                let ps = style(inner, after: 0, lineMultiple: 1.1)
                if c < alignments.count, let a = alignments[c] {
                    ps.alignment = a == .center ? .center : (a == .right ? .right : .left)
                }
                paragraph(content, ps)
            }
        }
    }
}
