import Foundation

/// "What happened when" (CONTRACT §11.1): sources by event date, decisions, milestones/deadlines from
/// `wiki/timeline.md`, and tasks with a due date. Ascending.
public extension BrainEngine {
    func timeline(projectSlug: String?) async -> [TimelineEntry] {
        let snapshot = sources.filter { src in
            src.status != .recording && (projectSlug == nil || src.projectSlug == projectSlug)
                && src.kind != .github   // MARK: v0.4 github — repo syncs live in wiki/repos, not on the timeline
        }
        let vault = self.vault, projects = self.projects, language = config.uiLanguage
        return await Task.detached(priority: .userInitiated) {
            let slugs = projectSlug.map { [$0] } ?? projects.list().map(\.slug)
            return TimelineBuilder(vault: vault, language: language).build(sources: snapshot, projectSlugs: slugs)
        }.value
    }
}

struct TimelineBuilder {
    let vault: VaultStore
    let language: String

    private var lang: Lang { Lang(language) }

    func build(sources: [SourceRecord], projectSlugs: [String]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []
        var knownKeys: Set<String> = []          // source keys / thread keys / decision names already listed
        for src in sources {
            entries.append(entry(for: src))
            if let raw = src.rawPath { knownKeys.insert(((raw as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) }
            if src.kind == .inPerson, let key = FileDumpNames.pageKey(of: src) { knownKeys.insert(key.lowercased()) }   // v0.7
            if let thread = src.threadKey { knownKeys.insert(thread.lowercased()) }
        }
        let owner = vault.ownerInfo()
        for slug in projectSlugs {
            let decisions = decisionEntries(slug)
            entries += decisions
            for d in decisions { if let p = d.pagePath { knownKeys.insert(((p as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()) } }
            entries += timelinePageEntries(slug, skipping: knownKeys)
            for task in vault.tasks(projectSlug: slug, owner: owner) {
                guard let due = task.due else { continue }
                var title = task.text
                if let who = task.isMine ? lang.t("yo", "me") : task.ownerName { title += " — \(who)" }
                entries.append(TimelineEntry(id: "task:\(task.id)", date: due, hasTime: false, addedAt: nil, kind: .task, title: title,
                                             projectSlug: slug, pagePath: "projects/\(slug)/wiki/tasks.md", sourceId: nil))
            }
        }
        let order: [TimelineKind] = [.milestone, .decision, .meeting, .email, .document, .note, .url, .task]
        return entries.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            let ra = order.firstIndex(of: a.kind) ?? 9, rb = order.firstIndex(of: b.kind) ?? 9
            return (ra, a.title) < (rb, b.title)
        }
    }

    private func entry(for src: SourceRecord) -> TimelineEntry {
        let kind: TimelineKind
        switch src.kind {
        case .meeting, .inPerson: kind = .meeting   // v0.7 (§17.3): shown as a meeting
        case .email: kind = .email
        case .document, .image: kind = .document
        case .note: kind = .note
        case .url: kind = .url
        case .github: kind = .document   // MARK: v0.4 github (filtered out above; kept exhaustive)
        }
        let page = pagePath(for: src)
        var title = src.title
        if let page, src.kind != .email, let text = try? vault.read(page), let t = Frontmatter.field("title", in: text), !t.isEmpty { title = t }
        if src.kind == .email, let raw = src.rawPath, let text = try? vault.read(raw),
           let from = Frontmatter.field("from", in: text).flatMap({ EmailParser.parseAddresses($0).first }) {
            title += " — " + from.display
        }
        let date = src.timelineDate
        let hasTime = src.kind == .meeting || src.kind == .email || !SBDate.looksDateOnly(date)
        return TimelineEntry(id: "source:\(src.id)", date: date, hasTime: hasTime, addedAt: src.createdAt, kind: kind, title: title,
                             projectSlug: src.projectSlug, pagePath: page ?? src.rawPath, sourceId: src.id)
    }

    private func pagePath(for src: SourceRecord) -> String? {
        guard let slug = src.projectSlug, let raw = src.rawPath else { return nil }
        let key = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidate: String
        switch src.kind {
        case .meeting: candidate = "projects/\(slug)/wiki/meetings/\(key).md"
        case .inPerson: candidate = "projects/\(slug)/wiki/meetings/\(FileDumpNames.pageKey(of: src) ?? key).md"   // v0.7
        case .email: candidate = "projects/\(slug)/wiki/emails/\(src.threadKey ?? key).md"
        default: candidate = "projects/\(slug)/wiki/sources/\(key).md"
        }
        return FileManager.default.fileExists(atPath: vault.url(for: candidate).path) ? candidate : nil
    }

    /// `wiki/decisions/*.md`: frontmatter `date` (when it was decided) and `title`.
    private func decisionEntries(_ slug: String) -> [TimelineEntry] {
        vault.markdownFiles(under: "projects/\(slug)/wiki/decisions").compactMap { path in
            guard let text = try? vault.read(path), let raw = Frontmatter.field("date", in: text),
                  let parsed = SBDate.parseISO(raw) else { return nil }
            var title = Frontmatter.field("title", in: text) ?? vault.title(of: path)
            switch Frontmatter.field("status", in: text)?.lowercased() {
            case "superseded": title += lang.t(" (reemplazada)", " (superseded)")
            case "reversed": title += lang.t(" (revertida)", " (reversed)")
            case "proposed": title += lang.t(" (propuesta)", " (proposed)")
            default: break
            }
            return TimelineEntry(id: "decision:\(path)", date: parsed.date, hasTime: parsed.hasTime, addedAt: nil, kind: .decision,
                                 title: title, projectSlug: slug, pagePath: path, sourceId: nil)
        }
    }

    /// Lines of `wiki/timeline.md`: `- YYYY-MM-DD[ HH:MM] · <emoji> <link or text> — <line>[ · agregada YYYY-MM-DD]`.
    /// Lines about sources/decisions already listed are skipped; the rest are milestones, deadlines, or sources this
    /// Mac has no record of.
    private func timelinePageEntries(_ slug: String, skipping known: Set<String>) -> [TimelineEntry] {
        let path = "projects/\(slug)/wiki/timeline.md"
        guard let text = try? vault.read(path) else { return [] }
        let parsed = Self.parseTimelinePage(text, path: path, projectSlug: slug, skipping: known)
        let resolved = vault.resolveWikilinks(parsed.compactMap(\.pagePath), from: path)   // one vault walk
        return parsed.map { e in
            var e = e
            e.pagePath = e.pagePath.flatMap { resolved[$0] } ?? path
            return e
        }
    }

    /// Pure parser (testable). `pagePath` holds the first wikilink target (resolved by the caller).
    static func parseTimelinePage(_ text: String, path: String, projectSlug: String, skipping known: Set<String>) -> [TimelineEntry] {
        var out: [TimelineEntry] = []
        let kinds: [(String, TimelineKind)] = [("🎙", .meeting), ("🤝", .meeting), ("✉", .email), ("📄", .document), ("🖼", .document),
                                               ("📝", .note), ("🔗", .url),
                                               ("⚖", .decision), ("🚩", .milestone), ("🏁", .milestone), ("📌", .milestone),
                                               ("📅", .task)]
        for (n, line) in Frontmatter.split(text).body.components(separatedBy: "\n").enumerated() {
            guard let m = EmailParser.firstMatch(#"^\s*[-*]\s+(\d{4}-\d{2}-\d{2})(?:[ T](\d{1,2}:\d{2}))?\s*·\s*(.+)$"#, in: line, options: []),
                  let day = m[1], var rest = m[3]?.trimmingCharacters(in: .whitespaces) else { continue }
            let parsed = m[2].flatMap { SBDate.parseISO("\(day) \($0.count == 4 ? "0" + $0 : $0)") } ?? SBDate.parseISO(day)
            guard let parsed else { continue }
            var kind = TimelineKind.milestone
            // Compare scalars: "🎙️" (with VS16) and "🎙" are different grapheme clusters.
            for (emoji, k) in kinds where rest.unicodeScalars.starts(with: emoji.unicodeScalars) {
                kind = k
                rest = String(rest.drop { !$0.isWhitespace }).trimmingCharacters(in: .whitespaces)
                break
            }
            let links = TaskParser.wikilinks(in: rest)
            if let first = links.first, rest.hasPrefix("[["), known.contains(TaskParser.slugOf(first.target).lowercased()),
               kind != .milestone, kind != .task {
                continue
            }
            rest = rest.replacingOccurrences(of: #"\s*·\s*(agregad[ao]|added)\s+\d{4}-\d{2}-\d{2}\s*$"#, with: "", options: .regularExpression)
            // Citations ("[[2026-10-20-1000-kickoff]] 00:00:38", "([[correo]])") are evidence, not part of the title.
            let lead = rest.hasPrefix("[[") ? rest.range(of: "]]").map { String(rest[..<$0.upperBound]) } ?? "" : ""
            var tail = String(rest.dropFirst(lead.count))
            tail = tail.replacingOccurrences(of: #"\[\[[^\]|]+\]\](?:\s*\d{1,2}:\d{2}(?::\d{2})?(?:\s*[;,]\s*\d{1,2}:\d{2}(?::\d{2})?)*)?"#,
                                             with: "", options: .regularExpression)
            tail = tail.replacingOccurrences(of: #"\(\s*[;,]?\s*\)"#, with: "", options: .regularExpression)
            tail = tail.replacingOccurrences(of: #"(\s*[—;,·]\s*)+$"#, with: "", options: .regularExpression)
            let title = TaskParser.plainLinks(lead + tail).trimmingCharacters(in: .whitespaces)
            out.append(TimelineEntry(id: "timeline:\(path)#\(n)", date: parsed.date, hasTime: parsed.hasTime, addedAt: nil, kind: kind,
                                     title: title, projectSlug: projectSlug, pagePath: links.first?.target, sourceId: nil))
        }
        return out
    }
}
