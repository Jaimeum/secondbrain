import Compression
import Foundation
import Markdown

/// Markdown (already preprocessed) → .docx written as real WordprocessingML: Word heading styles
/// (navigation pane works), real bullet/number lists, bordered tables with a repeated header row,
/// shaded callouts, page numbers. AppKit's own docx writer drops tables and lists, hence this.
enum ExportDocx {

    static func data(markdown: String, title: String, lang: Lang) throws -> Data {
        var b = Builder(lang: lang)
        b.textWidth = Int(((ExportRich.paperSize.width - 2 * ExportRich.marginPoints) * 20).rounded())
        let doc = Document(parsing: markdown, options: [.disableSmartOpts])
        for child in doc.children { b.block(child, Builder.Context()) }
        return try b.package(title: title)
    }

    // MARK: - XML helpers

    static func esc(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                // XML 1.0 forbids most C0 controls and the U+FFFE/FFFF non-characters.
                if u.value < 0x20 || u.value == 0xFFFE || u.value == 0xFFFF { continue }
                out.unicodeScalars.append(u)
            }
        }
        return out
    }

    /// Percent-encodes non-ASCII characters and spaces (Word wants URIs, not IRIs, in relationships).
    static func asciiURL(_ s: String) -> String {
        var out = ""
        for u in s.unicodeScalars {
            if u.isASCII && u != " " && u.value >= 0x21 { out.unicodeScalars.append(u); continue }
            for b in String(u).utf8 { out += String(format: "%%%02X", b) }
        }
        return out
    }

    // MARK: - Builder

    struct Builder {
        let lang: Lang
        var textWidth = 9638       // twips
        var body = ""
        var links: [String] = []   // external URLs, rId = "rIdL\(index)"
        var orderedNums: [(id: Int, level: Int, start: Int)] = []
        private var nextNumId = 4  // 1 = bullets, 2 = ☐, 3 = ☑

        init(lang: Lang) { self.lang = lang }

        struct Context {
            var level = 0               // list nesting
            var quoteStyle: String? = nil
            var color: String? = nil
        }

        struct RunStyle {
            var bold = false, italic = false, strike = false, mono = false
            var color: String? = nil
            var size: Int? = nil        // half-points
        }

        // MARK: Inline

        mutating func runs(_ m: Markup, _ s: RunStyle) -> String {
            var x = ""
            for child in m.children { x += run(child, s) }
            return x
        }

        mutating func run(_ m: Markup, _ s: RunStyle) -> String {
            var s = s
            switch m {
            case let t as Text: return textRun(t.string, s)
            case let c as InlineCode: s.mono = true; return textRun(c.code, s)
            case is SoftBreak: return textRun(" ", s)
            case is LineBreak: return "<w:r><w:br/></w:r>"
            case let e as Emphasis: s.italic = true; return runs(e, s)
            case let b as Strong: s.bold = true; return runs(b, s)
            case let x as Strikethrough: s.strike = true; s.color = "6E6E73"; return runs(x, s)
            case let l as Link:
                guard let d = l.destination, ExportHTMLRenderer.isExternal(d) else { return runs(l, s) }
                links.append(d)
                return "<w:hyperlink r:id=\"rIdL\(links.count)\" w:history=\"1\">" + runs(l, s, hyperlink: true) + "</w:hyperlink>"
            case let img as Image:
                s.italic = true
                let alt = img.plainText
                return textRun(alt.isEmpty ? (img.source ?? "") : alt, s)
            case let h as InlineHTML:
                return h.rawHTML.lowercased().hasPrefix("<br") ? "<w:r><w:br/></w:r>" : ""
            case let sym as SymbolLink: s.mono = true; return textRun(sym.destination ?? "", s)
            default: return runs(m, s)
            }
        }

        private mutating func runs(_ m: Markup, _ s: RunStyle, hyperlink: Bool) -> String {
            var x = ""
            for child in m.children {
                if let t = child as? Text { x += textRun(t.string, s, hyperlink: true) } else { x += run(child, s) }
            }
            return x
        }

        func textRun(_ text: String, _ s: RunStyle, hyperlink: Bool = false) -> String {
            guard !text.isEmpty else { return "" }
            var p = ""
            if hyperlink { p += "<w:rStyle w:val=\"Hyperlink\"/>" }
            // Fonts on every run too: some readers (Apple's, TextEdit, Quick Look) ignore style fonts.
            p += s.mono ? "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Consolas\"/>"
                        : "<w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:cs=\"Arial\"/>"
            if s.bold { p += "<w:b/><w:bCs/>" }
            if s.italic { p += "<w:i/><w:iCs/>" }
            if s.strike { p += "<w:strike/>" }
            if let c = s.color, !hyperlink { p += "<w:color w:val=\"\(c)\"/>" }
            if let sz = s.size ?? (s.mono ? 19 : nil) { p += "<w:sz w:val=\"\(sz)\"/><w:szCs w:val=\"\(sz)\"/>" }
            if s.mono { p += "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F2F2F4\"/>" }
            let rPr = p.isEmpty ? "" : "<w:rPr>\(p)</w:rPr>"
            // Tabs and line breaks inside text become Word elements.
            var x = ""
            let pieces = text.components(separatedBy: "\t")
            for (i, piece) in pieces.enumerated() {
                if i > 0 { x += "<w:r>\(rPr)<w:tab/></w:r>" }
                let lines = piece.components(separatedBy: CharacterSet(charactersIn: "\n\u{2028}"))
                for (j, line) in lines.enumerated() {
                    if j > 0 { x += "<w:r>\(rPr)<w:br/></w:r>" }
                    if !line.isEmpty { x += "<w:r>\(rPr)<w:t xml:space=\"preserve\">\(ExportDocx.esc(line))</w:t></w:r>" }
                }
            }
            return x
        }

        // MARK: Paragraphs

        mutating func para(style: String?, extra: String = "", _ runs: String) {
            var pPr = ""
            if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
            pPr += extra
            body += "<w:p>" + (pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>") + runs + "</w:p>\n"
        }

        private func base(_ ctx: Context) -> RunStyle {
            var s = RunStyle()
            s.color = ctx.color
            return s
        }

        mutating func block(_ m: Markup, _ ctx: Context) {
            switch m {
            case let h as Heading:
                let level = min(max(h.level, 1), 4)
                para(style: "Heading\(level)", runs(h, RunStyle()))

            case let p as Paragraph:
                let indent = ctx.level > 0 && ctx.quoteStyle == nil ? "<w:ind w:left=\"\(360 * ctx.level)\"/>" : ""
                para(style: ctx.quoteStyle ?? (ctx.level > 0 ? "ListParagraph" : nil), extra: indent, runs(p, base(ctx)))

            case let l as UnorderedList:
                list(Array(l.listItems), ordered: false, start: 1, ctx)
            case let l as OrderedList:
                list(Array(l.listItems), ordered: true, start: Int(l.startIndex), ctx)

            case let q as BlockQuote:
                var inner = ctx
                let label = (q.child(at: 0) as? Paragraph)?.child(at: 0).flatMap { ($0 as? Strong)?.plainText } ?? ""
                if label.hasPrefix("⚠️") {
                    inner.quoteStyle = "CalloutWarn"
                } else if ["ℹ️", "💡", "❓", "📌", "📄", "❝", "☐"].contains(where: { label.hasPrefix($0) }) {
                    inner.quoteStyle = "Callout"
                } else {
                    inner.quoteStyle = "Quote"
                }
                for child in q.children { block(child, inner) }

            case let c as CodeBlock:
                var code = c.code
                if code.hasSuffix("\n") { code.removeLast() }
                for line in code.components(separatedBy: "\n") {
                    para(style: "Code", textRun(line.isEmpty ? " " : line, RunStyle(mono: true, size: 19)))
                }

            case is ThematicBreak:
                para(style: nil, extra: "<w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"C7C7CC\"/></w:pBdr>", "")

            case let html as HTMLBlock:
                let t = ExportHTMLRenderer.stripTags(html.rawHTML).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { para(style: ctx.quoteStyle, textRun(t, base(ctx))) }

            case let t as Table:
                table(t)

            default:
                for child in m.children { block(child, ctx) }
            }
        }

        mutating func list(_ items: [ListItem], ordered: Bool, start: Int, _ ctx: Context) {
            var numId = 1
            if ordered && ctx.quoteStyle == nil {
                numId = nextNumId
                nextNumId += 1
                orderedNums.append((numId, min(ctx.level, 8), start))
            }
            for (i, item) in items.enumerated() {
                var inner = ctx
                inner.level = ctx.level + 1
                if item.checkbox == .checked { inner.color = "6E6E73" }
                let box: String? = item.checkbox.map { $0 == .checked ? "☑" : "☐" }

                for (j, child) in item.children.enumerated() {
                    guard j == 0, let p = child as? Paragraph else { block(child, inner); continue }
                    let content = runs(p, base(inner))
                    if let quote = ctx.quoteStyle {
                        // Inside a callout: keep the box, write the marker as text.
                        // (Word draws the box border at the paragraph indent, so no list indent here.)
                        let marker = box ?? (ordered ? "\(start + i)." : "•")
                        let nested = String(repeating: "\u{00A0}\u{00A0}\u{00A0}", count: inner.level - 1)
                        para(style: quote, textRun(nested + marker + "\u{00A0} ", RunStyle()) + content)
                    } else if let box {
                        // Checkboxes are list bullets ("☐"/"☑" numbering), so every reader aligns them.
                        para(style: "ListParagraph",
                             extra: "<w:numPr><w:ilvl w:val=\"\(min(ctx.level, 8))\"/><w:numId w:val=\"\(box == "☑" ? 3 : 2)\"/></w:numPr>",
                             content)
                    } else {
                        para(style: "ListParagraph",
                             extra: "<w:numPr><w:ilvl w:val=\"\(min(ctx.level, 8))\"/><w:numId w:val=\"\(numId)\"/></w:numPr>",
                             content)
                    }
                }
                if item.childCount == 0 { para(style: "ListParagraph", textRun(box ?? "", RunStyle())) }
            }
        }

        mutating func table(_ t: Table) {
            var rows: [(cells: [Table.Cell], header: Bool)] = [(Array(t.head.cells), true)]
            rows += t.body.rows.map { (Array($0.cells), false) }
            let cols = max(rows.map(\.cells.count).max() ?? 0, 1)
            let colWidth = textWidth / cols
            let alignments = t.columnAlignments
            var x = "<w:tbl><w:tblPr><w:tblStyle w:val=\"SBTable\"/><w:tblW w:w=\"5000\" w:type=\"pct\"/><w:tblLook w:val=\"0420\" w:firstRow=\"1\" w:lastRow=\"0\" w:firstColumn=\"0\" w:lastColumn=\"0\" w:noHBand=\"1\" w:noVBand=\"1\"/></w:tblPr>"
            x += "<w:tblGrid>" + String(repeating: "<w:gridCol w:w=\"\(colWidth)\"/>", count: cols) + "</w:tblGrid>"
            for row in rows {
                x += "<w:tr>" + (row.header ? "<w:trPr><w:tblHeader/><w:cantSplit/></w:trPr>" : "<w:trPr><w:cantSplit/></w:trPr>")
                for c in 0..<cols {
                    var s = RunStyle()
                    s.bold = row.header
                    let content = c < row.cells.count ? runs(row.cells[c], s) : ""
                    var pPr = "<w:pStyle w:val=\"TableText\"/>"
                    if c < alignments.count, let a = alignments[c], a != .left {
                        pPr += "<w:jc w:val=\"\(a == .center ? "center" : "right")\"/>"
                    }
                    let shd = row.header ? "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F0F0F2\"/>" : ""
                    x += "<w:tc><w:tcPr><w:tcW w:w=\"\(colWidth)\" w:type=\"dxa\"/>\(shd)</w:tcPr><w:p><w:pPr>\(pPr)</w:pPr>\(content)</w:p></w:tc>"
                }
                x += "</w:tr>\n"
            }
            x += "</w:tbl>\n"
            body += x
            // Word glues a following table to this one; a small spacer paragraph keeps them apart.
            para(style: "TableSpacer", "")
        }

        // MARK: Package

        func package(title: String) throws -> Data {
            let paper = ExportRich.paperSize
            let pgW = Int((paper.width * 20).rounded()), pgH = Int((paper.height * 20).rounded())
            let margin = Int((ExportRich.marginPoints * 20).rounded())
            let W = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\""
            let R = "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
            let head = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"

            let document = head + "<w:document \(W) \(R)><w:body>\n" + body
                + "<w:sectPr><w:footerReference w:type=\"default\" r:id=\"rIdFooter\"/>"
                + "<w:pgSz w:w=\"\(pgW)\" w:h=\"\(pgH)\"/>"
                + "<w:pgMar w:top=\"\(margin)\" w:right=\"\(margin)\" w:bottom=\"\(margin)\" w:left=\"\(margin)\" w:header=\"567\" w:footer=\"567\" w:gutter=\"0\"/>"
                + "</w:sectPr></w:body></w:document>"

            let small = "<w:rPr><w:color w:val=\"808080\"/><w:sz w:val=\"17\"/></w:rPr>"
            func txt(_ s: String) -> String { "<w:r>\(small)<w:t xml:space=\"preserve\">\(ExportDocx.esc(s))</w:t></w:r>" }
            func field(_ f: String) -> String { "<w:fldSimple w:instr=\" \(f) \"><w:r>\(small)<w:t>1</w:t></w:r></w:fldSimple>" }
            let footer = head + "<w:ftr \(W) \(R)><w:p><w:pPr><w:jc w:val=\"center\"/></w:pPr>"
                + txt(lang.t("Página ", "Page ")) + field("PAGE") + txt(lang.t(" de ", " of ")) + field("NUMPAGES")
                + "</w:p></w:ftr>"

            var rels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>"
                + "<Relationship Id=\"rIdNumbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
                + "<Relationship Id=\"rIdSettings\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/settings\" Target=\"settings.xml\"/>"
                + "<Relationship Id=\"rIdFooter\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/footer\" Target=\"footer1.xml\"/>"
            for (i, url) in links.enumerated() {
                rels += "<Relationship Id=\"rIdL\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(ExportDocx.esc(ExportDocx.asciiURL(url)))\" TargetMode=\"External\"/>"
            }
            rels += "</Relationships>"

            let iso = ISO8601DateFormatter().string(from: Date())
            let core = head + "<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:dcterms=\"http://purl.org/dc/terms/\" xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">"
                + "<dc:title>\(ExportDocx.esc(title))</dc:title><dc:language>\(lang.en ? "en-US" : "es-MX")</dc:language>"
                + "<dcterms:created xsi:type=\"dcterms:W3CDTF\">\(iso)</dcterms:created><dcterms:modified xsi:type=\"dcterms:W3CDTF\">\(iso)</dcterms:modified>"
                + "</cp:coreProperties>"
            let app = head + "<Properties xmlns=\"http://schemas.openxmlformats.org/officeDocument/2006/extended-properties\"><Application>SecondBrain</Application></Properties>"
            let settings = head + "<w:settings \(W)><w:defaultTabStop w:val=\"720\"/><w:characterSpacingControl w:val=\"doNotCompress\"/><w:compat><w:compatSetting w:name=\"compatibilityMode\" w:uri=\"http://schemas.microsoft.com/office/word\" w:val=\"15\"/></w:compat></w:settings>"

            let contentTypes = head + "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
                + "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
                + "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
                + "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
                + "<Override PartName=\"/word/styles.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml\"/>"
                + "<Override PartName=\"/word/numbering.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml\"/>"
                + "<Override PartName=\"/word/settings.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml\"/>"
                + "<Override PartName=\"/word/footer1.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml\"/>"
                + "<Override PartName=\"/docProps/core.xml\" ContentType=\"application/vnd.openxmlformats-package.core-properties+xml\"/>"
                + "<Override PartName=\"/docProps/app.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.extended-properties+xml\"/>"
                + "</Types>"
            let rootRels = head + "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
                + "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
                + "<Relationship Id=\"rId2\" Type=\"http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties\" Target=\"docProps/core.xml\"/>"
                + "<Relationship Id=\"rId3\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties\" Target=\"docProps/app.xml\"/>"
                + "</Relationships>"

            var zip = ExportZip()
            zip.add("[Content_Types].xml", contentTypes)
            zip.add("_rels/.rels", rootRels)
            zip.add("word/document.xml", document)
            zip.add("word/_rels/document.xml.rels", rels)
            zip.add("word/styles.xml", head + styles(W))
            zip.add("word/numbering.xml", head + numbering(W))
            zip.add("word/settings.xml", settings)
            zip.add("word/footer1.xml", footer)
            zip.add("docProps/core.xml", core)
            zip.add("docProps/app.xml", app)
            return zip.finish()
        }

        private func styles(_ W: String) -> String {
            let langTag = lang.en ? "en-US" : "es-MX"
            func heading(_ n: Int, size: Int, before: Int, after: Int, color: String = "1D1D1F") -> String {
                "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(n)\"><w:name w:val=\"heading \(n)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:uiPriority w:val=\"9\"/><w:qFormat/>"
                + "<w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before=\"\(before)\" w:after=\"\(after)\" w:line=\"240\" w:lineRule=\"auto\"/><w:outlineLvl w:val=\"\(n - 1)\"/></w:pPr>"
                + "<w:rPr><w:b/><w:bCs/><w:color w:val=\"\(color)\"/><w:sz w:val=\"\(size)\"/><w:szCs w:val=\"\(size)\"/></w:rPr></w:style>"
            }
            func box(_ id: String, name: String, line: String, fill: String?, color: String) -> String {
                "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"\(id)\"><w:name w:val=\"\(name)\"/><w:basedOn w:val=\"Normal\"/><w:qFormat/>"
                + "<w:pPr><w:pBdr><w:left w:val=\"single\" w:sz=\"18\" w:space=\"8\" w:color=\"\(line)\"/></w:pBdr>"
                + (fill.map { "<w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"\($0)\"/>" } ?? "")
                + "<w:spacing w:before=\"0\" w:after=\"60\"/><w:ind w:left=\"284\" w:right=\"113\"/></w:pPr>"
                + "<w:rPr><w:color w:val=\"\(color)\"/></w:rPr></w:style>"
            }
            return "<w:styles \(W)>"
                + "<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"Arial\" w:cs=\"Arial\"/>"
                + "<w:color w:val=\"1D1D1F\"/><w:sz w:val=\"22\"/><w:szCs w:val=\"22\"/><w:lang w:val=\"\(langTag)\" w:eastAsia=\"\(langTag)\" w:bidi=\"ar-SA\"/></w:rPr></w:rPrDefault>"
                + "<w:pPrDefault><w:pPr><w:spacing w:after=\"120\" w:line=\"276\" w:lineRule=\"auto\"/></w:pPr></w:pPrDefault></w:docDefaults>"
                + "<w:style w:type=\"paragraph\" w:default=\"1\" w:styleId=\"Normal\"><w:name w:val=\"Normal\"/><w:qFormat/><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:eastAsia=\"Arial\" w:cs=\"Arial\"/></w:rPr></w:style>"
                + "<w:style w:type=\"character\" w:default=\"1\" w:styleId=\"DefaultParagraphFont\"><w:name w:val=\"Default Paragraph Font\"/><w:uiPriority w:val=\"1\"/><w:semiHidden/></w:style>"
                + "<w:style w:type=\"table\" w:default=\"1\" w:styleId=\"TableNormal\"><w:name w:val=\"Normal Table\"/><w:semiHidden/><w:tblPr><w:tblInd w:w=\"0\" w:type=\"dxa\"/><w:tblCellMar><w:top w:w=\"0\" w:type=\"dxa\"/><w:left w:w=\"108\" w:type=\"dxa\"/><w:bottom w:w=\"0\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
                + heading(1, size: 40, before: 0, after: 200)
                + heading(2, size: 30, before: 320, after: 100)
                + heading(3, size: 25, before: 240, after: 80)
                + heading(4, size: 22, before: 200, after: 60, color: "48484A")
                + "<w:style w:type=\"paragraph\" w:styleId=\"ListParagraph\"><w:name w:val=\"List Paragraph\"/><w:basedOn w:val=\"Normal\"/><w:uiPriority w:val=\"34\"/><w:qFormat/><w:pPr><w:spacing w:after=\"50\"/><w:ind w:left=\"720\"/><w:contextualSpacing/></w:pPr></w:style>"
                + box("Quote", name: "Quote", line: "C7C7CC", fill: nil, color: "55555A")
                + box("Callout", name: lang.t("Nota destacada", "Callout"), line: "0A66C2", fill: "EEF5FF", color: "1D1D1F")
                + box("CalloutWarn", name: lang.t("Contradicción", "Contradiction"), line: "F0A020", fill: "FFF6E5", color: "1D1D1F")
                + "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"Code\"><w:name w:val=\"Code\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F5F5F7\"/><w:spacing w:after=\"0\" w:line=\"240\" w:lineRule=\"auto\"/><w:ind w:left=\"113\" w:right=\"113\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Consolas\"/><w:sz w:val=\"19\"/></w:rPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"TableText\"><w:name w:val=\"Table Text\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:before=\"40\" w:after=\"40\" w:line=\"240\" w:lineRule=\"auto\"/></w:pPr><w:rPr><w:sz w:val=\"20\"/><w:szCs w:val=\"20\"/></w:rPr></w:style>"
                + "<w:style w:type=\"paragraph\" w:customStyle=\"1\" w:styleId=\"TableSpacer\"><w:name w:val=\"Table Spacer\"/><w:basedOn w:val=\"Normal\"/><w:pPr><w:spacing w:after=\"0\" w:line=\"200\" w:lineRule=\"exact\"/></w:pPr><w:rPr><w:sz w:val=\"12\"/></w:rPr></w:style>"
                + "<w:style w:type=\"character\" w:styleId=\"Hyperlink\"><w:name w:val=\"Hyperlink\"/><w:basedOn w:val=\"DefaultParagraphFont\"/><w:uiPriority w:val=\"99\"/><w:rPr><w:color w:val=\"0A66C2\"/><w:u w:val=\"single\"/></w:rPr></w:style>"
                + "<w:style w:type=\"table\" w:customStyle=\"1\" w:styleId=\"SBTable\"><w:name w:val=\"SecondBrain Table\"/><w:basedOn w:val=\"TableNormal\"/><w:tblPr><w:tblBorders>"
                + ["top", "left", "bottom", "right", "insideH", "insideV"].map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"B8B8BD\"/>" }.joined()
                + "</w:tblBorders><w:tblCellMar><w:top w:w=\"40\" w:type=\"dxa\"/><w:left w:w=\"113\" w:type=\"dxa\"/><w:bottom w:w=\"40\" w:type=\"dxa\"/><w:right w:w=\"113\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr></w:style>"
                + "</w:styles>"
        }

        private func numbering(_ W: String) -> String {
            let bullets = ["•", "◦", "▪"]
            var x = "<w:numbering \(W)>"
            x += "<w:abstractNum w:abstractNumId=\"0\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            for l in 0..<9 {
                x += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(bullets[l % 3])\"/><w:lvlJc w:val=\"left\"/>"
                    + "<w:pPr><w:ind w:left=\"\(360 * (l + 1))\" w:hanging=\"360\"/></w:pPr><w:rPr><w:rFonts w:ascii=\"Arial\" w:hAnsi=\"Arial\" w:hint=\"default\"/></w:rPr></w:lvl>"
            }
            x += "</w:abstractNum>"
            for (id, glyph) in [(2, "☐"), (3, "☑")] {
                x += "<w:abstractNum w:abstractNumId=\"\(id)\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
                for l in 0..<9 {
                    x += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"bullet\"/><w:lvlText w:val=\"\(glyph)\"/><w:lvlJc w:val=\"left\"/>"
                        + "<w:pPr><w:ind w:left=\"\(360 * (l + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
                }
                x += "</w:abstractNum>"
            }
            x += "<w:abstractNum w:abstractNumId=\"1\"><w:multiLevelType w:val=\"hybridMultilevel\"/>"
            let fmts = ["decimal", "lowerLetter", "lowerRoman"]
            for l in 0..<9 {
                x += "<w:lvl w:ilvl=\"\(l)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmts[l % 3])\"/><w:lvlText w:val=\"%\(l + 1).\"/><w:lvlJc w:val=\"left\"/>"
                    + "<w:pPr><w:ind w:left=\"\(360 * (l + 1) + 40)\" w:hanging=\"400\"/></w:pPr></w:lvl>"
            }
            x += "</w:abstractNum>"
            x += "<w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>"
            x += "<w:num w:numId=\"2\"><w:abstractNumId w:val=\"2\"/></w:num><w:num w:numId=\"3\"><w:abstractNumId w:val=\"3\"/></w:num>"
            for n in orderedNums {
                x += "<w:num w:numId=\"\(n.id)\"><w:abstractNumId w:val=\"1\"/>"
                    + "<w:lvlOverride w:ilvl=\"\(n.level)\"><w:startOverride w:val=\"\(n.start)\"/></w:lvlOverride></w:num>"
            }
            return x + "</w:numbering>"
        }
    }
}

// MARK: - Minimal ZIP writer (deflate via Compression, CRC-32)

struct ExportZip {
    private var data = Data()
    private var central = Data()
    private var count = 0

    mutating func add(_ name: String, _ text: String) { add(name, Data(text.utf8)) }

    mutating func add(_ name: String, _ content: Data) {
        let crc = Self.crc32(content)
        let deflated = Self.deflate(content)
        let method: UInt16 = deflated == nil ? 0 : 8
        let payload = deflated ?? content
        let nameData = Data(name.utf8)
        let (time, date) = Self.dosDateTime(Date())
        let offset = UInt32(data.count)

        var local = Data()
        local.le32(0x04034b50); local.le16(20); local.le16(0x0800); local.le16(method)
        local.le16(time); local.le16(date); local.le32(crc)
        local.le32(UInt32(payload.count)); local.le32(UInt32(content.count))
        local.le16(UInt16(nameData.count)); local.le16(0)
        data.append(local); data.append(nameData); data.append(payload)

        var c = Data()
        c.le32(0x02014b50); c.le16(20); c.le16(20); c.le16(0x0800); c.le16(method)
        c.le16(time); c.le16(date); c.le32(crc)
        c.le32(UInt32(payload.count)); c.le32(UInt32(content.count))
        c.le16(UInt16(nameData.count)); c.le16(0); c.le16(0); c.le16(0); c.le16(0); c.le32(0); c.le32(offset)
        central.append(c); central.append(nameData)
        count += 1
    }

    mutating func finish() -> Data {
        let cdOffset = UInt32(data.count)
        var out = data
        out.append(central)
        var end = Data()
        end.le32(0x06054b50); end.le16(0); end.le16(0)
        end.le16(UInt16(count)); end.le16(UInt16(count))
        end.le32(UInt32(central.count)); end.le32(cdOffset); end.le16(0)
        out.append(end)
        return out
    }

    /// Raw DEFLATE (RFC 1951), which is what COMPRESSION_ZLIB produces. nil when not worth it.
    private static func deflate(_ input: Data) -> Data? {
        guard input.count > 64 else { return nil }
        let capacity = input.count + 1024
        var out = Data(count: capacity)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            input.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                                          src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0, written < input.count else { return nil }
        out.count = written
        return out
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        d.withUnsafeBytes { buf in
            for b in buf.bindMemory(to: UInt8.self) { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }

    private static func dosDateTime(_ date: Date) -> (UInt16, UInt16) {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let time = UInt16((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | ((c.second ?? 0) / 2))
        let day = UInt16(max((c.year ?? 1980) - 1980, 0) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
    mutating func le32(_ v: UInt32) { var x = v.littleEndian; Swift.withUnsafeBytes(of: &x) { append(contentsOf: $0) } }
}
