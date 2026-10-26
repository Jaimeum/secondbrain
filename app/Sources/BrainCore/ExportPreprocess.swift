import Foundation

/// Turns wiki-flavoured markdown (Obsidian: frontmatter, [[wikilinks]], callouts, HTML comments)
/// into portable CommonMark/GFM before rendering (CONTRACT §11.4). Code blocks and inline code
/// are left untouched.
enum ExportPreprocessor {

    struct Output {
        var markdown: String      // what gets rendered (frontmatter re-attached only when kept)
        var hasH1: Bool
    }

    static func run(_ input: String, format: ExportFormat, options: ExportOptions, lang: Lang) -> Output {
        var text = input.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }

        let keepFM = options.keepFrontmatter && format == .markdown
        let keepLinks = options.keepWikilinks && format == .markdown
        // Obsidian-flavoured markdown export (wikilinks kept) also keeps the native callout syntax.
        let keepCallouts = keepLinks

        let parts = Frontmatter.split(text)
        let body = parts.body

        var out: [String] = []
        var fence: (char: Character, count: Int)? = nil
        var inComment = false
        var hasH1 = false

        for rawLine in body.components(separatedBy: "\n") {
            var line = rawLine

            // Fenced code blocks pass through verbatim.
            if let f = fence {
                out.append(line)
                if let close = fenceMarker(line), close.char == f.char, close.count >= f.count,
                   line.trimmingCharacters(in: .whitespaces).allSatisfy({ $0 == f.char }) {
                    fence = nil
                }
                continue
            }
            if !inComment, let open = fenceMarker(line) {
                fence = open
                out.append(line)
                continue
            }

            // HTML comments (possibly spanning lines).
            let hadContent = !line.trimmingCharacters(in: .whitespaces).isEmpty
            let before = line
            (line, inComment) = removeComments(line, inComment: inComment)
            if line != before { while line.last == " " || line.last == "\t" { line.removeLast() } }
            if hadContent && line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            if inComment && line.trimmingCharacters(in: .whitespaces).isEmpty { continue }

            // Callouts: `> [!conflict] Title` → `> **⚠️ Contradicción: Title**` + blank quote line.
            if !keepCallouts, let callout = parseCallout(line) {
                out.append(callout.prefix + "**" + calloutLabel(kind: callout.kind, title: callout.title, lang: lang, keepLinks: keepLinks) + "**")
                out.append(callout.prefix.trimmingCharacters(in: .whitespaces))
                continue
            }

            if !keepLinks { line = replaceWikilinks(line) }
            if line.hasPrefix("# ") || line == "#" { hasH1 = true }
            out.append(line)
        }

        // Collapse runs of blank lines left behind by removed comments.
        var collapsed: [String] = []
        for l in out {
            if l.trimmingCharacters(in: .whitespaces).isEmpty, let last = collapsed.last,
               last.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            collapsed.append(l)
        }
        while let first = collapsed.first, first.trimmingCharacters(in: .whitespaces).isEmpty { collapsed.removeFirst() }

        var md = collapsed.joined(separator: "\n")
        if keepFM, let yaml = parts.yaml { md = "---\n\(yaml)\n---\n\n" + md }
        return Output(markdown: md, hasH1: hasH1)
    }

    // MARK: - Fences

    private static func fenceMarker(_ line: String) -> (char: Character, count: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let c = trimmed.first, c == "`" || c == "~" else { return nil }
        let n = trimmed.prefix(while: { $0 == c }).count
        return n >= 3 ? (c, n) : nil
    }

    // MARK: - Comments

    private static func removeComments(_ line: String, inComment: Bool) -> (String, Bool) {
        var result = ""
        var rest = Substring(line)
        var inside = inComment
        while true {
            if inside {
                guard let end = rest.range(of: "-->") else { return (result, true) }
                rest = rest[end.upperBound...]
                inside = false
            } else {
                guard let start = rest.range(of: "<!--") else { result += rest; return (result, false) }
                result += rest[..<start.lowerBound]
                rest = rest[start.upperBound...]
                inside = true
            }
        }
    }

    // MARK: - Callouts

    private static let calloutRegex = try! NSRegularExpression(pattern: #"^(\s{0,3}(?:>\s?)+)\[!([A-Za-z-]+)\][+-]?\s*(.*)$"#)

    private static func parseCallout(_ line: String) -> (prefix: String, kind: String, title: String)? {
        let ns = line as NSString
        guard let m = calloutRegex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        var prefix = ns.substring(with: m.range(at: 1))
        if !prefix.hasSuffix(" ") { prefix += " " }
        return (prefix, ns.substring(with: m.range(at: 2)).lowercased(), ns.substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespaces))
    }

    static func calloutLabel(kind: String, title: String, lang: Lang, keepLinks: Bool) -> String {
        let t = keepLinks ? title : replaceWikilinks(title)
        let (icon, name): (String, String)
        switch kind {
        case "conflict", "contradiction":
            (icon, name) = ("⚠️", lang.t("Contradicción", "Contradiction"))
        case "warning", "caution", "attention", "danger", "error", "bug", "failure", "fail":
            (icon, name) = ("⚠️", lang.t("Atención", "Warning"))
        case "tip", "hint", "important", "success", "check", "done":
            (icon, name) = ("💡", lang.t("Importante", "Important"))
        case "question", "help", "faq":
            (icon, name) = ("❓", lang.t("Pregunta", "Question"))
        case "quote", "cite":
            (icon, name) = ("❝", lang.t("Cita", "Quote"))
        case "example":
            (icon, name) = ("📌", lang.t("Ejemplo", "Example"))
        case "abstract", "summary", "tldr":
            (icon, name) = ("📄", lang.t("Resumen", "Summary"))
        case "todo":
            (icon, name) = ("☐", lang.t("Pendiente", "To do"))
        default:   // note, info, …
            (icon, name) = ("ℹ️", lang.t("Nota", "Note"))
        }
        if t.isEmpty { return "\(icon) \(name)" }
        // A contradiction always says so; other callouts use their own title ("Cambio").
        if kind == "conflict" || kind == "contradiction" { return "\(icon) \(name): \(t)" }
        return "\(icon) \(t)"
    }

    // MARK: - Wikilinks

    private static let wikilinkRegex = try! NSRegularExpression(pattern: #"!?\[\[([^\[\]\n]+?)\]\]"#)

    /// `[[target]]`, `[[target|Label]]`, `[[path/x\|Label]]` (inside tables), `![[embed]]` → plain text.
    /// Inline code spans are skipped.
    static func replaceWikilinks(_ line: String) -> String {
        guard line.contains("[[") else { return line }
        // Split on backtick code spans; only even segments are prose.
        var result = ""
        var segments: [(String, Bool)] = []   // (text, isCode)
        var current = ""
        var chars = Array(line)
        var i = 0
        while i < chars.count {
            if chars[i] == "`" {
                var n = 0
                while i + n < chars.count, chars[i + n] == "`" { n += 1 }
                let ticks = String(repeating: "`", count: n)
                // Find a matching closing run.
                let restStart = i + n
                if let close = findRun(of: n, in: chars, from: restStart) {
                    segments.append((current, false)); current = ""
                    segments.append((ticks + String(chars[restStart..<close]) + ticks, true))
                    i = close + n
                    continue
                }
                current += ticks
                i += n
                continue
            }
            current.append(chars[i])
            i += 1
        }
        segments.append((current, false))
        chars.removeAll()
        for (text, isCode) in segments {
            result += isCode ? text : replaceWikilinksInProse(text)
        }
        return result
    }

    private static func findRun(of n: Int, in chars: [Character], from start: Int) -> Int? {
        var j = start
        while j < chars.count {
            if chars[j] == "`" {
                var m = 0
                while j + m < chars.count, chars[j + m] == "`" { m += 1 }
                if m == n { return j }
                j += m
            } else { j += 1 }
        }
        return nil
    }

    private static func replaceWikilinksInProse(_ text: String) -> String {
        let ns = text as NSString
        let matches = wikilinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for m in matches {
            out += ns.substring(with: NSRange(location: cursor, length: m.range.location - cursor))
            out += wikilinkText(ns.substring(with: m.range(at: 1)))
            cursor = m.range.location + m.range.length
        }
        out += ns.substring(from: cursor)
        return out
    }

    static func wikilinkText(_ inner: String) -> String {
        var target = inner
        var label: String? = nil
        if let bar = inner.firstIndex(of: "|") {
            target = String(inner[..<bar])
            label = String(inner[inner.index(after: bar)...])
        }
        if target.hasSuffix("\\") { target.removeLast() }
        if let l = label?.trimmingCharacters(in: .whitespaces), !l.isEmpty { return l }
        return humanize(target)
    }

    private static let datePrefix = try! NSRegularExpression(pattern: #"^(\d{4}-\d{2}-\d{2})(?:-(\d{2})(\d{2}))?(?:-(.+))?$"#)

    /// `projects/x/wiki/plan-de-lanzamiento.md#Fechas` → "Plan de lanzamiento › Fechas";
    /// `2026-10-26-1530-kickoff` → "Kickoff (2026-10-26 15:30)".
    static func humanize(_ target: String) -> String {
        var t = target.trimmingCharacters(in: .whitespaces)
        var anchor: String? = nil
        if let hash = t.firstIndex(of: "#") {
            anchor = String(t[t.index(after: hash)...]).trimmingCharacters(in: .whitespaces)
            if anchor?.hasPrefix("^") == true { anchor = nil }   // block reference
            t = String(t[..<hash])
        }
        if let slash = t.lastIndex(of: "/") { t = String(t[t.index(after: slash)...]) }
        if t.lowercased().hasSuffix(".md") { t = String(t.dropLast(3)) }

        var name = words(t)
        let ns = t as NSString
        if let m = datePrefix.firstMatch(in: t, range: NSRange(location: 0, length: ns.length)) {
            var stamp = ns.substring(with: m.range(at: 1))
            if m.range(at: 2).location != NSNotFound {
                stamp += " " + ns.substring(with: m.range(at: 2)) + ":" + ns.substring(with: m.range(at: 3))
            }
            if m.range(at: 4).location != NSNotFound {
                name = words(ns.substring(with: m.range(at: 4))) + " (\(stamp))"
            } else {
                name = stamp
            }
        }
        if let a = anchor, !a.isEmpty { return name.isEmpty ? a : "\(name) › \(a)" }
        return name
    }

    private static func words(_ s: String) -> String {
        let spaced = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
            .split(separator: " ").joined(separator: " ")
        guard let first = spaced.first else { return "" }
        return first.uppercased() + spaced.dropFirst()
    }
}
