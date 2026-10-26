import Foundation

/// Assembles ONE markdown document for a source or page (CONTRACT §11.4). Rendering to md/txt/docx/pdf/html/rtf is
/// `Exporter.export(markdown:title:format:options:to:)`.
public extension BrainEngine {
    /// Title + both dates + the wiki page (summary in the chosen template) + that source's tasks (mine / others') +
    /// optionally the transcript (speaker names resolved, with/without timestamps), the thread's emails, or the
    /// document text. For an email, the whole thread is exported.
    func exportDocument(sourceId: String, options: ExportOptions) async throws -> (title: String, markdown: String) {
        guard let src = source(sourceId) else { throw EngineError.sourceNotFound(sourceId) }
        let language = config.uiLanguage
        let lang = self.lang
        let page = pagePath(for: src)
        let pageText = page.flatMap { try? vault.read($0) }
        let thread = src.kind == .email ? src.threadKey.map { emails(inThread: $0) } ?? [src] : nil
        let threadSubject = src.threadKey.flatMap { key in emailThreads(projectSlug: nil).first { $0.key == key }?.subject }
        let title = pageText.flatMap { Frontmatter.field("title", in: $0) } ?? threadSubject ?? src.title
        let projectName = src.projectSlug.flatMap { projects.get($0)?.name }

        var md = "# \(title)\n\n"
        md += datesLine(src, thread: thread, projectName: projectName) + "\n"

        if options.includeSummary, let pageText {
            md += "\n" + Self.pageBodyForExport(pageText) + "\n"
        }
        if options.includeTasks {
            let tasks = await tasks(forSourceId: src.id)
            if !tasks.isEmpty {
                md += "\n## " + lang.t("Pendientes (estado actual)", "Tasks (current status)") + "\n"
                let groups: [(String, [TaskItem])] = [
                    (lang.t("Míos", "Mine"), tasks.filter(\.isMine)),
                    (lang.t("De los demás", "Others'"), tasks.filter { !$0.isMine && ($0.ownerName != nil || $0.ownerSlug != nil) }),
                    (lang.t("Sin dueño", "No owner"), tasks.filter { !$0.isMine && $0.ownerName == nil && $0.ownerSlug == nil }),
                ]
                for (heading, items) in groups where !items.isEmpty {
                    md += "\n### \(heading)\n\n" + items.map { taskLine($0, showOwner: !$0.isMine) }.joined(separator: "\n") + "\n"
                }
            }
        }
        if options.includeTranscript {
            if let thread {
                md += "\n## " + lang.t("Correos del hilo", "Emails in the thread") + "\n"
                for e in thread {
                    guard let raw = e.rawPath, let text = try? vault.read(raw) else { continue }
                    md += "\n" + emailSection(text, language: language) + "\n"
                }
            } else if let raw = src.rawPath, let text = try? vault.read(raw) {
                if src.kind == .meeting {
                    let names = options.resolveSpeakerNames ? speakerNames(pageText) : [:]
                    md += "\n## " + lang.t("Transcripción", "Transcript") + "\n\n"
                    md += Self.transcriptBody(text, names: names, timestamps: options.includeTimestamps) + "\n"
                } else if !raw.lowercased().hasSuffix(".pdf") {
                    md += "\n## " + lang.t("Texto original", "Original text") + "\n\n" + Self.dropH1(Frontmatter.strip(text)) + "\n"
                }
            }
        }
        if let page { md = await labelBareWikilinks(md, from: page) }
        return (title, md.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression))
    }

    /// `[[2026-10-20-informe-final-espanol-ingles]]` → `[[…|Informe final en español e inglés]]` (the page's real title,
    /// with accents) so exported documents don't show a de-slugged file name. Raw files and unknown targets are left alone.
    private func labelBareWikilinks(_ md: String, from page: String) async -> String {
        let regex = #/\[\[([^\[\]|#]+?)\]\]/#
        let targets = Array(Set(md.matches(of: regex).map { String($0.1) }))
        guard !targets.isEmpty else { return md }
        let resolved = await vault.resolveWikilinksAsync(targets, from: page)
        var titles: [String: String] = [:]
        for (target, path) in resolved {
            if path.contains("/raw/emails/") || path.hasPrefix("_inbox/emails/") {
                // A cited email message: "✉️ Laura Méndez, 21 oct 2026, 16:40".
                guard let text = try? vault.read(path), let from = Frontmatter.field("from", in: text) else { continue }
                let name = from.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces) ?? ""
                var label = "✉️ " + (name.isEmpty ? from.trimmingCharacters(in: CharacterSet(charactersIn: " <>")) : name)
                if let d = Frontmatter.field("date", in: text).flatMap({ SBDate.parseISO($0) }) {
                    label += ", " + SBDate.human(d.date, hasTime: d.hasTime, language: config.uiLanguage)
                }
                if !label.contains("]") { titles[target] = label }
            } else if path.contains("/wiki/") || path.hasPrefix("people/") || path.hasPrefix("wiki/") {
                let t = vault.title(of: path).trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, t != target, !t.contains("]") { titles[target] = t }
            }
        }
        guard !titles.isEmpty else { return md }
        return md.replacing(regex) { m in
            let target = String(m.1)
            return titles[target].map { "[[\(target)|\($0)]]" } ?? String(m.0)
        }
    }

    /// Any wiki page, as is (the Exporter drops the frontmatter unless `keepFrontmatter`).
    func exportDocument(pagePath: String, options: ExportOptions) async throws -> (title: String, markdown: String) {
        let vault = self.vault
        guard let text = try? await Task.detached(operation: { try vault.read(pagePath) }).value else {
            throw EngineError.rawMissing(pagePath)
        }
        return (vault.title(of: pagePath), text)
    }
}

extension BrainEngine {
    /// "**Reunión:** 26 oct 2026, 15:30 · **Duración:** 42 min · **Agregada:** 2 nov 2026, 10:00 · **Proyecto:** X".
    func datesLine(_ src: SourceRecord, thread: [SourceRecord]?, projectName: String?) -> String {
        let language = config.uiLanguage
        func h(_ d: Date, _ time: Bool = true) -> String { SBDate.human(d, hasTime: time, language: language) }
        var parts: [String] = []
        let when = src.timelineDate
        let dateOnly = SBDate.looksDateOnly(when) && src.kind != .meeting && src.kind != .email
        switch src.kind {
        case .meeting:
            parts.append("**\(lang.t("Reunión", "Meeting")):** \(h(when))")
            if let d = src.durationSeconds, d > 0 { parts.append("**\(lang.t("Duración", "Duration")):** \(max(1, Int((d / 60).rounded()))) min") }
        case .email:
            let list = thread ?? [src]
            let dates = list.map(\.timelineDate)
            if list.count > 1, let first = dates.min(), let last = dates.max() {
                parts.append("**\(lang.t("Hilo de correo", "Email thread")):** " + lang.t("\(list.count) correos, del \(h(first)) al \(h(last))",
                                                                                         "\(list.count) emails, \(h(first)) to \(h(last))"))
            } else {
                parts.append("**\(lang.t("Correo enviado", "Email sent")):** \(h(when))")
            }
        case .document: parts.append("**\(lang.t("Fecha del documento", "Document date")):** \(h(when, !dateOnly))")
        case .note: parts.append("**\(lang.t("Fecha", "Date")):** \(h(when, !dateOnly))")
        case .url: parts.append("**\(lang.t("Fecha de la página", "Page date")):** \(h(when, !dateOnly))")
        }
        let added = thread.flatMap { $0.map(\.createdAt).max() } ?? src.createdAt
        parts.append("**\(lang.t("Agregado al cerebro", "Added to the brain")):** \(h(added))")
        if let projectName { parts.append("**\(lang.t("Proyecto", "Project")):** \(projectName)") }
        return parts.joined(separator: " · ")
    }

    /// "Hablante 1" → "Ana García" from the meeting page's `speakers:` mapping (labels without a person are kept).
    func speakerNames(_ pageText: String?) -> [String: String] {
        guard let yaml = pageText.flatMap({ Frontmatter.split($0).yaml }) else { return [:] }
        var names: [String: String] = [:]
        var inSpeakers = false
        var label: String?
        func unquote(_ s: String) -> String {
            var v = s.trimmingCharacters(in: .whitespaces)
            if v.count >= 2, let f = v.first, f == "\"" || f == "'", v.last == f { v = String(v.dropFirst().dropLast()) }
            return v
        }
        for line in yaml.components(separatedBy: "\n") {
            if line.hasPrefix("speakers:") { inSpeakers = true; continue }
            guard inSpeakers else { continue }
            if !line.hasPrefix(" "), !line.hasPrefix("-"), !line.isEmpty { break }
            let t = line.trimmingCharacters(in: .whitespaces)
            if let r = t.range(of: #"^-?\s*label:\s*"#, options: .regularExpression) {
                label = unquote(String(t[r.upperBound...]))
            } else if t.hasPrefix("person:"), let l = label {
                let value = unquote(String(t.dropFirst("person:".count)))
                guard let link = TaskParser.wikilinks(in: value).first else { continue }
                let slug = TaskParser.slugOf(link.target)
                let personTitle = (try? vault.read("people/\(slug).md")).flatMap { Frontmatter.field("title", in: $0) }
                names[l] = link.label ?? personTitle ?? slug
            }
        }
        return names
    }

    /// One email for export: "### 21 oct 2026, 10:15 · Ana García → Jaime" + subject + body (no quoted history).
    func emailSection(_ raw: String, language: String) -> String {
        let from = Frontmatter.field("from", in: raw).flatMap { EmailParser.parseAddresses($0).first }?.display ?? "?"
        let toField = Frontmatter.split(raw).yaml?.components(separatedBy: "\n").first { $0.hasPrefix("to:") }
        let to = toField.map { line -> String in
            let list = String(line.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: " []"))
            return EmailParser.parseAddresses(list.replacingOccurrences(of: "\"", with: "")).map(\.display).joined(separator: ", ")
        } ?? ""
        let date = Frontmatter.field("date", in: raw).flatMap { SBDate.parseISO($0)?.date }
        var head = "### " + (date.map { SBDate.human($0, language: language) } ?? "?") + " · \(Self.literal(from))"
        if !to.isEmpty { head += " → \(Self.literal(to))" }
        var out = head + "\n\n"
        if let subject = Frontmatter.field("subject", in: raw), !subject.isEmpty {
            out += "**\(Lang(language).t("Asunto", "Subject")):** \(Self.literal(subject))\n\n"
        }
        out += Self.literalLines(VaultStore.emailBody(raw).body)
        return out
    }

    /// Plain text (an email someone wrote, speech) as markdown that renders exactly as written: `<b>`, `*`, `#`,
    /// `1.`, `> ` are text, not markup.
    static func literal(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>|~&".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        // Block markers at the start of a line: heading, list, setext/thematic rules ("1." → "1\\.").
        out = out.replacingOccurrences(of: #"^(\s*)([#+=-])"#, with: #"$1\\$2"#, options: .regularExpression)
        out = out.replacingOccurrences(of: #"^(\s*\d{1,9})([.)])"#, with: #"$1\\$2"#, options: .regularExpression)
        return out
    }

    /// `literal` for each line, keeping the line breaks of a plain-text email (markdown would join them).
    static func literalLines(_ text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { literal($0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r"))) }
        return lines.enumerated().map { i, line in
            i + 1 < lines.count && !line.isEmpty && !lines[i + 1].isEmpty ? line + "\\" : line
        }.joined(separator: "\n")
    }

    /// The page without its H1, the date line right under it and the `## Fuente` section (links to raw files).
    static func pageBodyForExport(_ text: String) -> String {
        var lines = dropH1(Frontmatter.strip(text)).components(separatedBy: "\n")
        let dateLine = #"^\*\*(Fecha|Date|Hilo de correo|Email thread)[:*]"#
        if let i = lines.prefix(12).firstIndex(where: { $0.range(of: dateLine, options: .regularExpression) != nil }) {
            lines.remove(at: i)
        }
        if let start = lines.firstIndex(where: { ["## fuente", "## source", "## fuentes", "## sources"].contains($0.trimmingCharacters(in: .whitespaces).lowercased()) }) {
            let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("## ") } ?? lines.count
            lines.removeSubrange(start..<end)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func dropH1(_ body: String) -> String {
        var lines = body.components(separatedBy: "\n")
        if let i = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }), lines[i].hasPrefix("# ") {
            lines.remove(at: i)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `**[00:00:03] Hablante 1:** text` → names mapped; timestamps kept or dropped.
    static func transcriptBody(_ raw: String, names: [String: String], timestamps: Bool) -> String {
        let body = dropH1(Frontmatter.strip(raw))
        return body.components(separatedBy: "\n").map { line in
            guard let m = EmailParser.firstMatch(#"^\*\*\[(\d{1,2}:\d{2}:\d{2})\]\s+(.+?):\*\*\s?(.*)$"#, in: line, options: []),
                  let stamp = m[1], let label = m[2] else { return line }
            let name = names[label] ?? label
            return (timestamps ? "**[\(stamp)] \(name):** " : "**\(name):** ") + (m[3] ?? "")
        }.joined(separator: "\n")
    }
}
