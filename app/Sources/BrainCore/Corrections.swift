import Foundation

// MARK: v0.6 facts — the owner's hand edits, /propagate and confirmed facts (CONTRACT §16.6)

/// One change `/propagate` proposes on another page: replace the exact excerpt `before` (whole lines copied from the
/// page) with `after`. Claude never writes; the app applies the ones the owner keeps.
public struct ProposedEdit: Codable, Hashable, Identifiable, Sendable {
    public var path: String
    public var before: String
    public var after: String
    public var reason: String

    public init(path: String, before: String, after: String, reason: String = "") {
        self.path = path
        self.before = before
        self.after = after
        self.reason = reason
    }

    public var id: String { path + "\u{1}" + before }

    enum CodingKeys: String, CodingKey { case path, before, after, reason }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        before = try c.decode(String.self, forKey: .before)
        after = try c.decodeIfPresent(String.self, forKey: .after) ?? ""
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
    }
}

/// `/propagate`'s answer: `{facts: [String], edits: [{path, before, after, reason}]}`.
public struct Propagation: Codable, Equatable, Sendable {
    public var facts: [String]
    public var edits: [ProposedEdit]

    public init(facts: [String] = [], edits: [ProposedEdit] = []) {
        self.facts = facts
        self.edits = edits
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        facts = try c.decodeIfPresent([String].self, forKey: .facts) ?? []
        edits = try c.decodeIfPresent([ProposedEdit].self, forKey: .edits) ?? []
    }

    enum CodingKeys: String, CodingKey { case facts, edits }
}

public enum CorrectionError: Error, LocalizedError {
    /// A raw source, a manual (CLAUDE.md) or an app file.
    case notEditable
    /// `/propagate` answered without the JSON object.
    case unreadableAnswer
    /// The page isn't UTF-8 text (e.g. a note saved as Latin-1): editing it would lose the original.
    case notText
    /// The page changed on disk since the editor read it (an ingest updated it meanwhile). `current` is its text now.
    case changedOnDisk(current: String)

    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .notEditable: return lang.t("Esta página no se puede editar.", "This page can't be edited.")
        case .unreadableAnswer: return lang.t("No entendí la respuesta de Claude.", "I couldn't read Claude's answer.")
        case .notText: return lang.t("Esta página no es texto UTF-8: ábrela en otro editor para no perder su contenido.",
                                     "This page isn't UTF-8 text: open it in another editor so its content isn't lost.")
        case .changedOnDisk: return lang.t("La página cambió mientras la editabas (Claude la actualizó).",
                                           "The page changed while you were editing it (Claude updated it).")
        }
    }
}

/// What applying a reviewed propagation did.
public struct CorrectionResult: Sendable {
    /// The single undoable Historial entry (edited pages + `facts.md`); nil when nothing was written.
    public var entry: HistoryEntry?
    /// Pages changed (vault-relative, `facts.md` not included).
    public var pages: [String]
    /// Edits that no longer matched their page (it changed since Claude read it): not applied.
    public var stale: [ProposedEdit]
    /// Fact lines added to `facts.md`.
    public var factsAdded: Int
}

public enum Corrections {
    /// "Hechos confirmados por ti" at the vault root.
    public static let factsPath = "facts.md"
    /// At most this many proposed edits are kept (the command is told 30).
    static let maxEdits = 40

    /// Pages the owner may edit by hand: markdown of the wiki, people/, orgs/, global pages and `facts.md`. Raw sources
    /// (`raw/`, `_inbox/`), the manuals (`CLAUDE.md`) and app folders (`.claude/`, `.secondbrain/`) are not.
    public static func isEditable(_ path: String) -> Bool {
        let p = path.trimmingCharacters(in: .whitespaces)
        guard p.lowercased().hasSuffix(".md"), !p.hasPrefix("/"), !p.contains(".."), !p.hasPrefix("."),
              !p.hasPrefix("_inbox/"), !p.contains("/raw/"), !p.hasPrefix("raw/") else { return false }
        return (p as NSString).lastPathComponent != "CLAUDE.md" && !(p as NSString).lastPathComponent.hasPrefix("CLAUDE.v")
    }

    /// Pages `/propagate` may change: editable, not the facts list, not an append-only log, not a template.
    static func isPropagationTarget(_ path: String) -> Bool {
        guard isEditable(path), path != factsPath, !path.hasPrefix("templates/") else { return false }
        return (path as NSString).lastPathComponent != "log.md"
    }

    // MARK: Diff for the command

    /// The changed stretch of lines with `context` lines around it: `-` removed, `+` added, two spaces unchanged.
    /// One hunk from the first to the last changed line (hand edits are small; Claude reads the page anyway).
    public static func diff(before: String, after: String, context: Int = 2) -> String {
        let a = before.components(separatedBy: "\n"), b = after.components(separatedBy: "\n")
        var prefix = 0
        while prefix < a.count, prefix < b.count, a[prefix] == b[prefix] { prefix += 1 }
        guard prefix < a.count || prefix < b.count else { return "" }
        var suffix = 0
        while suffix < a.count - prefix, suffix < b.count - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        var out: [String] = []
        for line in a[max(0, prefix - context)..<prefix] { out.append("  " + line) }
        for line in a[prefix..<(a.count - suffix)] { out.append("- " + line) }
        for line in b[prefix..<(b.count - suffix)] { out.append("+ " + line) }
        for line in a[(a.count - suffix)..<min(a.count, a.count - suffix + context)] { out.append("  " + line) }
        return out.joined(separator: "\n")
    }

    /// `$ARGUMENTS` of `/propagate`: one line of JSON with the page, its project and the diff.
    public static func propagateArguments(path: String, title: String, before: String, after: String) -> String {
        let body: [String: Any] = ["path": path, "title": title,
                                   "project": VaultStore.projectSlug(of: path) ?? NSNull(),
                                   "diff": diff(before: before, after: after)]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Parsing Claude's answer

    /// The JSON object in Claude's final message (bare, fenced, or after some text). nil when there is none.
    public static func parse(_ text: String) -> Propagation? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = s.range(of: "```") {
            // ```json … ``` → what's inside.
            let rest = s[fence.upperBound...]
            if let end = rest.range(of: "```") {
                let inner = rest[..<end.lowerBound]
                s = String(inner.drop { $0 != "\n" && $0 != "{" })
            }
        }
        // Try every `{` from the first, against the last `}` (the object is the last thing in the message).
        guard let close = s.lastIndex(of: "}") else { return nil }
        var start = s.firstIndex(of: "{")
        while let open = start, open < close {
            if let data = String(s[open...close]).data(using: .utf8),
               let decoded = try? JSONDecoder().decode(Propagation.self, from: data) {
                return decoded
            }
            start = s[s.index(after: open)...].firstIndex(of: "{")
        }
        return nil
    }

    /// `text` with `edit` applied, or nil when `before` isn't in it any more. `before` is whole lines of the page: it is
    /// matched only where it starts at a line start and ends at a line end (so "- Ana" never matches inside
    /// "- Ana María"), exactly first, then ignoring trailing spaces and \r at the ends of lines (Claude sometimes loses
    /// those).
    public static func applying(_ edit: ProposedEdit, to text: String) -> String? {
        guard !edit.before.isEmpty else { return nil }
        if let range = lineRange(of: edit.before, in: text) {
            return text.replacingCharacters(in: range, with: edit.after)
        }
        let trimmed = edit.before.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return nil }
        if let range = lineRange(of: trimmed, in: text) {
            return text.replacingCharacters(in: range, with: edit.after.trimmingCharacters(in: .newlines))
        }
        // Line by line, ignoring trailing whitespace.
        func norm(_ l: String) -> String { String(l.reversed().drop { $0 == " " || $0 == "\t" || $0 == "\r" }.reversed()) }
        let lines = text.components(separatedBy: "\n")
        let wanted = trimmed.components(separatedBy: "\n").map(norm)
        guard wanted.count <= lines.count else { return nil }
        for i in 0...(lines.count - wanted.count) where (0..<wanted.count).allSatisfy({ norm(lines[i + $0]) == wanted[$0] }) {
            var out = lines
            out.replaceSubrange(i..<(i + wanted.count), with: edit.after.trimmingCharacters(in: .newlines).components(separatedBy: "\n"))
            return out.joined(separator: "\n")
        }
        return nil
    }

    /// The first occurrence of `needle` in `text` that starts at a line start and ends at a line end (or with a
    /// newline of its own).
    static func lineRange(of needle: String, in text: String) -> Range<String.Index>? {
        var from = text.startIndex
        while from < text.endIndex, let range = text.range(of: needle, range: from..<text.endIndex) {
            let startsLine = range.lowerBound == text.startIndex || text[text.index(before: range.lowerBound)].isNewline
                || needle.hasPrefix("\n")
            let endsLine = range.upperBound == text.endIndex || text[range.upperBound].isNewline || needle.hasSuffix("\n")
            if startsLine && endsLine { return range }
            from = text.index(after: range.lowerBound)
        }
        return nil
    }

    // MARK: facts.md

    /// `- 2026-10-27 · Javier Ruiz no forma parte del equipo de Angela Torres. ([[javier-ruiz]], [[angela-torres]])`.
    /// A fact without any wikilink gets `fallbackLinks` (the pages it came from) appended.
    public static func factLine(_ fact: String, date: Date, fallbackLinks: [String] = []) -> String? {
        var text = fact.replacingOccurrences(of: "\r", with: "")
            .components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
        while text.hasPrefix("- ") || text.hasPrefix("* ") { text = String(text.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        guard !text.isEmpty else { return nil }
        let links = fallbackLinks.filter { !$0.isEmpty }
        if !text.contains("[["), !links.isEmpty {
            text += " (" + links.map { "[[\($0)]]" }.joined(separator: ", ") + ")"
        }
        return "- \(Fmt.local(date, "yyyy-MM-dd")) · \(text)"
    }

    /// The fact of a line of `facts.md`, without the bullet and date, for comparing (case/spacing-insensitive).
    static func factKey(_ line: String) -> String {
        var s = line.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("- ") else { return "" }
        s = String(s.dropFirst(2))
        if let dot = s.range(of: " · "), s[..<dot.lowerBound].count == 10 { s = String(s[dot.upperBound...]) }
        return s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// A new `facts.md` (for a vault without one), in the app's language.
    static func emptyFactsPage(lang: Lang) -> String {
        """
        ---
        type: facts
        title: "\(lang.t("Hechos confirmados por ti", "Facts you confirmed"))"
        project: null
        language: \(lang.en ? "en" : "es")
        updated: null
        ---

        # \(lang.t("Hechos confirmados por ti", "Facts you confirmed"))

        \(lang.t("> **En breve:** lo que confirmaste o corregiste a mano. Manda sobre cualquier fuente.",
                 "> **In short:** what you confirmed or corrected by hand. It wins over any source."))

        ## \(lang.t("Hechos", "Facts"))

        """
    }

    /// `facts.md` with `lines` appended at the bottom (newest last) and `updated:` set; lines already there are skipped.
    /// Returns the new text and how many lines were added.
    static func appending(_ lines: [String], to existing: String?, date: Date, lang: Lang) -> (text: String, added: Int) {
        var text = existing ?? emptyFactsPage(lang: lang)
        var known = Set(text.components(separatedBy: "\n").map(factKey).filter { !$0.isEmpty })
        var added = 0
        for line in lines {
            let key = factKey(line)
            guard !key.isEmpty, known.insert(key).inserted else { continue }
            if !text.hasSuffix("\n") { text += "\n" }
            text += line + "\n"
            added += 1
        }
        if added > 0, Frontmatter.split(text).yaml != nil {
            text = Frontmatter.setField("updated", to: Fmt.local(date, "yyyy-MM-dd"), in: text)
        }
        return (text, added)
    }
}

// MARK: - Vault side (no engine: used by the app through BrainEngine and by `sb facts selftest`)

public extension VaultStore {
    /// Keeps the proposals that can be applied: an editable page (not the one just edited, not `facts.md`, not a log),
    /// that exists, whose `before` is in it, with an actual change; duplicates dropped. Facts are trimmed and capped.
    func validated(_ proposal: Propagation, editedPath: String) -> Propagation {
        var seen = Set<String>()
        var edits: [ProposedEdit] = []
        var texts: [String: String] = [:]
        for var edit in proposal.edits {
            edit.path = edit.path.trimmingCharacters(in: .whitespaces)
            if edit.path.hasPrefix("./") { edit.path.removeFirst(2) }
            if !edit.path.lowercased().hasSuffix(".md") { edit.path += ".md" }
            guard edit.path != editedPath, Corrections.isPropagationTarget(edit.path),
                  edit.before != edit.after, seen.insert(edit.id).inserted else { continue }
            if texts[edit.path] == nil { texts[edit.path] = try? read(edit.path) }
            guard let text = texts[edit.path], Corrections.applying(edit, to: text) != nil else { continue }
            edits.append(edit)
            if edits.count == Corrections.maxEdits { break }
        }
        let facts = editedPath == Corrections.factsPath ? [] :
            proposal.facts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.prefix(5).map { $0 }
        return Propagation(facts: facts, edits: edits)
    }

    /// The owner's hand edit of one page (§16.6): writes it and records a `.manualEdit` Historial entry with
    /// before/after (Deshacer). nil when the text didn't change.
    /// `basedOn`: the text the editor started from (a missing page = ""). When the page on disk differs now (an ingest
    /// updated it meanwhile), nothing is written and `CorrectionError.changedOnDisk` is thrown, so the owner's save never
    /// silently erases what Claude added. A page that exists but isn't UTF-8 is refused (`notText`), never replaced.
    @discardableResult
    func saveHandEdit(path: String, text: String, title: String, history: HistoryStore, basedOn: String? = nil) throws -> HistoryEntry? {
        let before: String?
        if FileManager.default.fileExists(atPath: url(for: path).path) {
            guard let current = try? read(path) else { throw CorrectionError.notText }
            before = current
        } else {
            before = nil
        }
        if let basedOn, (before ?? "") != basedOn { throw CorrectionError.changedOnDisk(current: before ?? "") }
        guard before != text else { return nil }
        return try history.recordManualEdits(title: title, projectSlug: Self.projectSlug(of: path),
                                             files: [(path, before, text)])
    }

    /// Applies the reviewed edits (each re-read and re-matched now: one whose page changed meanwhile is reported
    /// `stale`, not forced) and appends `facts` to `facts.md` — all in ONE undoable Historial entry.
    /// `fallbackLinks`: page names cited by a fact that has no wikilink of its own (the edited page).
    func applyCorrections(_ edits: [ProposedEdit], facts: [String], title: String, projectSlug: String?,
                          fallbackLinks: [String], history: HistoryStore, language: String, date: Date = Date()) throws -> CorrectionResult {
        var originals: [String: String] = [:]
        var current: [String: String] = [:]
        var stale: [ProposedEdit] = []
        for edit in edits where Corrections.isPropagationTarget(edit.path) {
            if current[edit.path] == nil {
                guard let text = try? read(edit.path) else { stale.append(edit); continue }
                originals[edit.path] = text
                current[edit.path] = text
            }
            if let next = Corrections.applying(edit, to: current[edit.path]!) {
                current[edit.path] = next
            } else {
                stale.append(edit)
            }
        }
        var files: [(path: String, before: String?, after: String)] = current.keys.sorted().compactMap { path in
            originals[path] == current[path] ? nil : (path, originals[path], current[path]!)
        }
        let pages = files.map(\.path)
        let lines = facts.compactMap { Corrections.factLine($0, date: date, fallbackLinks: fallbackLinks) }
        var added = 0
        if !lines.isEmpty {
            let existing = try? read(Corrections.factsPath)
            let result = Corrections.appending(lines, to: existing, date: date, lang: Lang(language))
            added = result.added
            if added > 0 { files.append((Corrections.factsPath, existing, result.text)) }
        }
        let entry = try history.recordManualEdits(title: title, projectSlug: projectSlug, files: files)
        return CorrectionResult(entry: entry, pages: pages, stale: stale, factsAdded: added)
    }
}

// MARK: - Engine (the app's entry points)

public extension BrainEngine {
    /// Saves the owner's edit of `path` (Historial entry "Editaste: …", undoable). Refused with `EngineError.busy`
    /// while Claude is editing the brain (its snapshot would swallow this edit).
    /// `basedOn`: the text the editor started from; a page changed on disk since then is refused (`changedOnDisk`).
    @discardableResult
    func saveHandEdit(path: String, text: String, basedOn: String? = nil) throws -> HistoryEntry? {
        guard Corrections.isEditable(path) else { throw CorrectionError.notEditable }
        guard !claudeIsEditing else { throw EngineError.busy }
        let title = lang.t("Editaste: \(vault.title(of: path))", "You edited: \(vault.title(of: path))")
        let entry = try vault.saveHandEdit(path: path, text: text, title: title, history: history, basedOn: basedOn)
        if let entry { onEvent?(.historyAdded(entry)) }
        return entry
    }

    /// Runs `/propagate` (read-only) on the owner's edit and returns the facts and the applicable edits on other pages.
    /// Not queued: the owner is waiting for it.
    func proposeCorrections(path: String, before: String, after: String) async throws -> Propagation {
        let args = Corrections.propagateArguments(path: path, title: vault.title(of: path), before: before, after: after)
        var result: String?
        for try await event in claude.run(command: "propagate", arguments: args, mode: .readOnly, model: config.ingestModel) {
            if case .done(let text, let isError) = event {
                if isError { throw ClaudeError.failed(text) }
                result = text
            }
        }
        guard let result else { throw ClaudeError.failed("Claude ended without a result") }
        guard let proposal = Corrections.parse(result) else {
            Log.error("propagate: no JSON in the answer: \(result.prefix(300))")
            throw CorrectionError.unreadableAnswer
        }
        let vault = self.vault
        let valid = await Task.detached { vault.validated(proposal, editedPath: path) }.value
        Log.info("propagate \(path): \(valid.facts.count) facts, \(valid.edits.count)/\(proposal.edits.count) edits")
        return valid
    }

    /// Writes the edits the owner kept and appends the facts to `facts.md`, as one undoable Historial entry.
    func applyCorrections(_ edits: [ProposedEdit], facts: [String], editedPath: String) throws -> CorrectionResult {
        guard !claudeIsEditing else { throw EngineError.busy }
        let name = ((editedPath as NSString).lastPathComponent as NSString).deletingPathExtension
        let pageTitle = vault.title(of: editedPath)
        let pages = Set(edits.map(\.path)).count
        let title = pages > 0
            ? lang.t("Corregiste el cerebro: \(pageTitle) (+\(pages) páginas)", "You corrected the brain: \(pageTitle) (+\(pages) pages)")
            : lang.t("Hecho confirmado: \(pageTitle)", "Fact confirmed: \(pageTitle)")
        let result = try vault.applyCorrections(edits, facts: facts, title: title,
                                                projectSlug: VaultStore.projectSlug(of: editedPath),
                                                fallbackLinks: editedPath == Corrections.factsPath ? [] : [name],
                                                history: history, language: config.uiLanguage)
        if let entry = result.entry { onEvent?(.historyAdded(entry)) }
        return result
    }

    /// Appends one confirmed fact to `facts.md` (e.g. "Javier Ruiz no forma parte de 🚀 Kickoff" from a project's
    /// Personas tab), as an undoable Historial entry. `about`: page names to link when the fact has no wikilink.
    @discardableResult
    /// Refused with `EngineError.busy` while Claude is editing the brain (its Historial entry would swallow the line,
    /// and undoing it would erase the fact).
    func recordFact(_ fact: String, about: [String] = [], projectSlug: String? = nil) throws -> HistoryEntry? {
        guard !claudeIsEditing else { throw EngineError.busy }
        guard let line = Corrections.factLine(fact, date: Date(), fallbackLinks: about) else { return nil }
        let existing = try? vault.read(Corrections.factsPath)
        let result = Corrections.appending([line], to: existing, date: Date(), lang: lang)
        guard result.added > 0 else { return nil }
        let short = fact.count > 60 ? String(fact.prefix(57)) + "…" : fact
        let entry = try history.recordManualEdits(title: lang.t("Hecho confirmado: \(short)", "Fact confirmed: \(short)"),
                                                  projectSlug: projectSlug,
                                                  files: [(Corrections.factsPath, existing, result.text)])
        if let entry { onEvent?(.historyAdded(entry)) }
        return entry
    }

    /// Claude is changing vault files right now (a hand edit would land in its Historial snapshot). The app checks it
    /// before any write of its own to the vault (a hand edit, a fact, a person added to a project, a saved answer).
    var claudeIsEditing: Bool {
        runningAnywhere { [.ingest, .lint, .saveAnswer, .reformat, .makeTemplate].contains($0.kind) }
    }
}
