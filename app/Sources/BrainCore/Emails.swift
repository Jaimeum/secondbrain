import Foundation

/// `<thread folder>/_thread.json`: app metadata of an email thread (Claude never edits it).
struct ThreadMeta: Codable, Equatable {
    struct Message: Codable, Equatable {
        var file: String
        var date: Date?
        var from: EmailAddress?
        var sourceId: String?
        var bodyHash: String?
        var added: Date?
        /// v0.3: `"<provider>:<messageId>"` when it came from a connected account.
        var externalId: String? = nil
    }
    var key: String
    var subject: String
    var participants: [EmailAddress]
    var messages: [Message]
    var createdAt: Date

    static let fileName = "_thread.json"

    static func load(from dir: URL) -> ThreadMeta? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.sb.decode(ThreadMeta.self, from: data)
    }

    func save(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }

    mutating func addParticipants(_ list: [EmailAddress]) {
        func sameName(_ x: String?, _ y: String?) -> Bool {
            guard let x, let y, !x.isEmpty else { return false }
            return x.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                == y.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        for a in list where a.email != nil || a.name != nil {
            if let email = a.email {
                if let i = participants.firstIndex(where: { $0.email == email }) {
                    if participants[i].name == nil { participants[i].name = a.name }
                } else if let i = participants.firstIndex(where: { $0.email == nil && sameName($0.name, a.name) }) {
                    participants[i].email = email   // "Diego" seen first without an address, now "Diego <diego@x>"
                } else {
                    participants.append(a)
                }
            } else if !participants.contains(where: { sameName($0.name, a.name) }) {
                participants.append(a)
            }
        }
    }
}

// MARK: - Owner addresses (people/README.md)

public extension VaultStore {
    private static let emailLine = #/^- \*\*(?:Correo|Correos|Email|Emails):\*\*[ \t]*(.*)$/#.anchorsMatchLineEndings()

    /// The owner's addresses from `- **Correo:** a@x.com, b@y.com` in people/README.md (lowercased).
    func ownerEmails() -> [String] {
        guard let text = try? read(Self.ownerFile), let match = text.firstMatch(of: Self.emailLine) else { return [] }
        return Self.addresses(in: String(match.1))
    }

    func setOwnerEmails(_ emails: [String]) throws {
        let url = url(for: Self.ownerFile)
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let clean = emails.flatMap { Self.addresses(in: $0) }.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let line = "- **Correo:** " + (clean.isEmpty ? "_aún no registrado_" : clean.joined(separator: ", "))
        if let match = text.firstMatch(of: Self.emailLine) {
            guard Self.addresses(in: String(match.1)) != clean || clean.isEmpty && !String(match.1).hasPrefix("_") else { return }
            text.replaceSubrange(match.range, with: line)
        } else if let name = text.firstMatch(of: #/^- \*\*(?:Nombre|Name):\*\*.*$/#.anchorsMatchLineEndings()) {
            text.insert(contentsOf: "\n" + line, at: name.range.upperBound)
        } else {
            text += "\n" + line + "\n"
        }
        try text.write(to: url, atomically: true, encoding: .utf8)
        Log.info("owner emails set (\(clean.count))")
    }

    private static func addresses(in s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ",; \t<>()[]"))
            .map { $0.replacingOccurrences(of: "mailto:", with: "").trimmingCharacters(in: CharacterSet(charactersIn: " .\"'")).lowercased() }
            .filter { $0.contains("@") && !$0.hasPrefix("@") && !$0.hasSuffix("@") }
    }
}

// MARK: - Threads

extension VaultStore {
    /// Thread folders: `_inbox/emails/<key>` and `projects/<slug>/raw/emails/<key>` (vault-relative).
    func threadFolders() -> [String] {
        let fm = FileManager.default
        var out: [String] = []
        func scan(_ rel: String) {
            for name in (try? fm.contentsOfDirectory(atPath: url(for: rel).path)) ?? [] where !name.hasPrefix(".") {
                if fm.isDirectory(url(for: "\(rel)/\(name)")) { out.append("\(rel)/\(name)") }
            }
        }
        scan("_inbox/emails")
        for slug in (try? fm.contentsOfDirectory(atPath: url(for: "projects").path)) ?? [] where !slug.hasPrefix(".") {
            scan("projects/\(slug)/raw/emails")
        }
        return out
    }

    /// `_thread.json`, or one rebuilt from the message files when it is missing.
    func threadMeta(at folder: String) -> ThreadMeta? {
        let dir = url(for: folder)
        if let meta = ThreadMeta.load(from: dir) { return meta }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        guard !files.isEmpty else { return nil }
        var meta = ThreadMeta(key: (folder as NSString).lastPathComponent, subject: "", participants: [], messages: [], createdAt: Date())
        for file in files {
            guard let text = try? read("\(folder)/\(file)") else { continue }
            let from = Frontmatter.field("from", in: text).flatMap { EmailParser.parseAddresses($0).first }
            if meta.subject.isEmpty { meta.subject = EmailParser.normalizeSubject(Frontmatter.field("subject", in: text) ?? "") }
            meta.messages.append(.init(file: file, date: Frontmatter.field("date", in: text).flatMap { SBDate.parseISO($0)?.date },
                                       from: from, sourceId: Frontmatter.field("source_id", in: text),
                                       bodyHash: EmailParser.bodyFingerprint(Self.emailBody(text).body), added: nil,
                                       externalId: Frontmatter.field("external_id", in: text)))
            meta.addParticipants([from].compactMap { $0 })
        }
        return meta
    }

    static func thread(from meta: ThreadMeta, folder: String) -> EmailThread {
        let dates = meta.messages.compactMap(\.date)
        return EmailThread(key: meta.key, subject: meta.subject, projectSlug: projectSlug(of: folder),
                           participants: meta.participants, messageCount: meta.messages.count,
                           firstDate: dates.min(), lastDate: dates.max(), folderPath: folder)
    }

    /// Body and quoted history of a stored email raw.
    public static func emailBody(_ text: String) -> (body: String, quoted: String?) {
        let body = Frontmatter.split(text).body
        for marker in ["\n## Historial citado", "\n## Quoted history"] {
            if let r = body.range(of: marker) {
                return (String(body[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines),
                        String(body[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        return (body.trimmingCharacters(in: .whitespacesAndNewlines), nil)
    }
}

public extension BrainEngine {
    /// Parses a pasted email (the newest message when several were pasted).
    func parseEmail(_ pasted: String) -> ParsedEmail {
        EmailParser.parse(pasted, ownerEmails: vault.ownerEmails(), ownerName: vault.ownerName())
    }

    /// Every message of a paste, oldest first (a Gmail conversation copy gives several).
    func parseEmails(_ pasted: String) -> [ParsedEmail] {
        EmailParser.parseAll(pasted, ownerEmails: vault.ownerEmails(), ownerName: vault.ownerName())
    }

    /// Threads of a project (nil = all, inbox included), most recent message first.
    func emailThreads(projectSlug: String?) -> [EmailThread] {
        vault.threadFolders().compactMap { folder -> EmailThread? in
            guard let meta = vault.threadMeta(at: folder) else { return nil }
            let t = VaultStore.thread(from: meta, folder: folder)
            if let projectSlug, t.projectSlug != projectSlug { return nil }
            return t
        }.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    /// Messages of a thread (their sources), oldest first by sent date.
    func emails(inThread key: String) -> [SourceRecord] {
        sources.filter { $0.kind == .email && $0.threadKey == key }.sorted { $0.timelineDate < $1.timelineDate }
    }

    /// Existing threads this email may belong to, best first (score ≥ 0.5; ≥ 0.8 = strong). CONTRACT §11.5.
    /// Reads every stored email: from the UI prefer `matchThreadsAsync`.
    func matchThreads(for email: ParsedEmail) -> [ThreadMatch] {
        ThreadMatcher.matches(for: email, vault: vault, lang: lang)
    }

    /// `matchThreads` off the main thread.
    func matchThreadsAsync(for email: ParsedEmail) async -> [ThreadMatch] {
        let vault = self.vault, lang = self.lang
        return await Task.detached(priority: .userInitiated) { ThreadMatcher.matches(for: email, vault: vault, lang: lang) }.value
    }

    /// The stored email this one duplicates (same sender, same sent minute, same body), if any.
    func duplicateOf(_ email: ParsedEmail) -> SourceRecord? {
        duplicateOf(email, externalId: nil)
    }

    /// v0.3: also matches by `externalId` (`"<provider>:<messageId>"`, a message from a connected account).
    func duplicateOf(_ email: ParsedEmail, externalId: String?) -> SourceRecord? {
        if let externalId {
            if let src = emailSource(externalId: externalId) { return src }
            for folder in vault.threadFolders() {
                guard let meta = vault.threadMeta(at: folder), let m = meta.messages.first(where: { $0.externalId == externalId })
                else { continue }
                return sources.first { $0.id == m.sourceId } ?? SourceRecord(id: m.sourceId ?? m.file, kind: .email, title: meta.subject,
                                                                            projectSlug: VaultStore.projectSlug(of: folder), status: .done,
                                                                            rawPath: "\(folder)/\(m.file)")
            }
        }
        // A provider message is identified by its externalId: the body heuristic (for pasted copies) only compares it
        // with messages that have none, and never on an empty body (two plain forwards in the same minute differ).
        if externalId != nil, email.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let hash = EmailParser.bodyFingerprint(email.body)
        for folder in vault.threadFolders() {
            guard let meta = vault.threadMeta(at: folder) else { continue }
            for m in meta.messages where (externalId == nil || m.externalId == nil) && m.bodyHash == hash
                && Self.sameSender(m.from, email.from) && Self.sameMinute(m.date, email.date) {
                return sources.first { $0.id == m.sourceId } ?? SourceRecord(id: m.sourceId ?? m.file, kind: .email, title: meta.subject,
                                                                            projectSlug: VaultStore.projectSlug(of: folder), status: .done,
                                                                            rawPath: "\(folder)/\(m.file)")
            }
        }
        return nil
    }

    /// Saves one email as an immutable raw in its thread folder and queues it (ingest, or classify in the inbox).
    /// `threadKey` nil = new thread. `projectSlug` is ignored when the thread already lives in a project; an inbox
    /// thread given a project moves there whole. Throws `EngineError.duplicateEmail` for an exact duplicate.
    /// v0.4: `projectSlug` nil + `routeIfUnassigned` → routing rules, then the default project (CONTRACT §14.2);
    /// pass `false` when the user chose the inbox on purpose. `lastRoutingDecision` tells which rule decided.
    @discardableResult
    func addEmail(_ email: ParsedEmail, threadKey: String?, projectSlug: String?, routeIfUnassigned: Bool = true) throws -> SourceRecord {
        lastRoutingDecision = nil
        return try addEmail(email, threadKey: threadKey, projectSlug: projectSlug, externalId: nil, routeIfUnassigned: routeIfUnassigned)
    }

    /// The source added from a connected account's message (`"<provider>:<messageId>"`), if any.
    func emailSource(externalId: String) -> SourceRecord? {
        sources.first { $0.externalId == externalId }
    }

    /// v0.3: same as `addEmail(_:threadKey:projectSlug:)`, remembering where the message came from (`externalId`
    /// = `"<provider>:<messageId>"`): stored in the source, the raw (`external_id:`) and `_thread.json`; adding the
    /// same message again throws `EngineError.duplicateEmail`.
    @discardableResult
    func addEmail(_ email: ParsedEmail, threadKey: String?, projectSlug: String?, externalId: String?,
                  routeIfUnassigned: Bool = true) throws -> SourceRecord {
        guard !email.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !(email.quotedHistory ?? "").isEmpty else {
            throw EngineError.emptyEmail
        }
        if let dup = duplicateOf(email, externalId: externalId) { throw EngineError.duplicateEmail(dup.title) }
        let fm = FileManager.default
        var project = validProject(projectSlug)
        // MARK: v0.4 routing — §14.2 steps 2–4 when nobody chose a project.
        var routed = false
        if projectSlug == nil, routeIfUnassigned, !routingSuppressed {
            let r = routedProject(for: email, threadKey: threadKey)
            if r.evaluated {
                lastRoutingDecision = r.decision
                project = r.project
                routed = r.project != nil
            }
        }
        var folder: String
        var meta: ThreadMeta
        var moveTo: String?   // an inbox thread given a project: the whole thread moves there afterwards
        if let threadKey {
            guard let existing = vault.threadFolders().first(where: { ($0 as NSString).lastPathComponent == threadKey }) else {
                throw EngineError.threadNotFound(threadKey)
            }
            folder = existing
            if let inProject = VaultStore.projectSlug(of: folder) {
                project = inProject
            } else {
                moveTo = project
                project = nil
            }
            meta = vault.threadMeta(at: folder) ?? ThreadMeta(key: threadKey, subject: EmailParser.normalizeSubject(email.subject ?? ""),
                                                              participants: [], messages: [], createdAt: Date())
        } else {
            let key = newThreadKey(for: email)
            folder = project.map { "projects/\($0)/raw/emails/\(key)" } ?? "_inbox/emails/\(key)"
            meta = ThreadMeta(key: key, subject: EmailParser.normalizeSubject(email.subject ?? ""), participants: [], messages: [],
                              createdAt: Date())
        }
        let dir = vault.url(for: folder)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let id = SessionManifest.newId()
        let added = Date()
        let sent = email.date ?? added
        let fromSlug = slugify(email.from?.name ?? email.from?.email?.components(separatedBy: "@").first ?? "", maxLength: 30)
        let base = Fmt.local(sent, "yyyy-MM-dd-HHmm") + (fromSlug.isEmpty ? "" : "-\(fromSlug)")
        let file = fm.uniqueURL(in: dir, name: base, ext: "md")
        var text = """
        ---
        type: email
        source_id: \(id)
        thread: \(meta.key)
        subject: \(YAML.quoted(email.subject ?? ""))
        from: \(YAML.quoted(email.from.map(EmailParser.format) ?? ""))
        to: \(YAML.list(email.to.map(EmailParser.format)))
        cc: \(YAML.list(email.cc.map(EmailParser.format)))
        date: \(SBDate.iso(sent))
        added: \(SBDate.iso(added))
        project: \(YAML.scalar(project))\(externalId.map { "\nexternal_id: \(YAML.quoted($0))" } ?? "")
        ---


        """
        let body = email.body.trimmingCharacters(in: .whitespacesAndNewlines)
        text += body.isEmpty ? lang.t("_(Sin texto nuevo: solo reenvía o cita mensajes anteriores.)_",
                                      "_(No new text: it only forwards or quotes earlier messages.)_") : body
        text += "\n"
        if let quoted = email.quotedHistory?.trimmingCharacters(in: .whitespacesAndNewlines), !quoted.isEmpty {
            text += "\n## Historial citado\n\n" + quoted + "\n"
        }
        try text.write(to: file, atomically: true, encoding: .utf8)

        if meta.subject.isEmpty { meta.subject = EmailParser.normalizeSubject(email.subject ?? "") }
        meta.addParticipants([email.from].compactMap { $0 } + email.to + email.cc)
        meta.messages.append(.init(file: file.lastPathComponent, date: email.date, from: email.from, sourceId: id,
                                   bodyHash: EmailParser.bodyFingerprint(email.body), added: added, externalId: externalId))
        meta.messages.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
        try meta.save(to: dir)

        let subject = email.subject.map(EmailParser.normalizeSubject).flatMap { $0.isEmpty ? nil : $0 }
            ?? lang.t("(sin asunto)", "(no subject)")
        // Messages of one thread share a subject; the sender tells them apart in lists.
        let sender = email.isFromOwner ? lang.t("tú", "you") : email.from.map { $0.name ?? $0.email ?? "" } ?? ""
        let title = sender.isEmpty ? subject : "\(subject) — \(sender)"
        var src = SourceRecord(id: id, kind: .email, title: title, projectSlug: project, status: .queued,
                               rawPath: file.relativePath(from: vault.root), createdAt: added)
        src.eventDate = sent
        src.threadKey = meta.key
        src.externalId = externalId
        enqueueAfterRaw(&src)
        Log.info("email added to thread \(meta.key) (\(folder)) as \(id)")
        if let moveTo {
            if routed {
                // A rule moving an inbox thread: if the thread can't move now, the message still stays in the inbox.
                do { try assignThread(meta.key, to: moveTo) } catch { Log.error("routing: thread \(meta.key) stays in the inbox: \(error)") }
            } else {
                try assignThread(meta.key, to: moveTo)
            }
            return source(id) ?? src
        }
        return src
    }

    // MARK: v0.4 routing

    /// §14.2 for an email without an explicit project. A thread that lives in a project keeps it (step 2, not
    /// evaluated). Otherwise the first matching rule (its hit is recorded; a rule to a deleted project is skipped), then
    /// the default project — the default only for a new thread: an inbox thread is moved by a rule, never by the default.
    internal func routedProject(for email: ParsedEmail, threadKey: String?) -> (project: String?, decision: RoutingDecision?, evaluated: Bool) {
        var inboxThread = false
        if let threadKey {
            guard let folder = vault.threadFolders().first(where: { ($0 as NSString).lastPathComponent == threadKey }) else {
                return (nil, nil, false)
            }
            if let inProject = VaultStore.projectSlug(of: folder) { return (inProject, nil, false) }
            inboxThread = true
        }
        if let d = routing.route(.mail(email, ownerEmails: vault.ownerEmails())) {
            if d.projectSlug == nil { return (nil, d, true) }
            if let p = validProject(d.projectSlug) { return (p, d, true) }
        }
        return (inboxThread ? nil : validProject(routing.settings.defaultProjectSlug), nil, true)
    }

    /// What routing would decide (rule, then default project), without recording a hit: preselection in the UI.
    /// `projectSlug` nil = inbox; `decision` nil = no rule matched (the default project, if any, applies).
    func routingPreview(_ subject: RoutingSubject) -> (projectSlug: String?, decision: RoutingDecision?) {
        if let d = routing.match(subject) {
            if d.projectSlug == nil { return (nil, d) }
            if let p = validProject(d.projectSlug) { return (p, d) }
        }
        return (validProject(routing.settings.defaultProjectSlug), nil)
    }

    /// `addMailMessages` (CONTRACT §12.4) with the §14.2 switch: `routeIfUnassigned: false` when the user chose the
    /// inbox on purpose. The plain call routes (same as `true`).
    @discardableResult
    func addMailMessages(_ messages: [MailMessageFull], account: ConnectedAccount, threadKey: String?, projectSlug: String?,
                         routeIfUnassigned: Bool) throws -> [SourceRecord] {
        lastRoutingDecision = nil
        let saved = routingSuppressed
        routingSuppressed = !routeIfUnassigned
        defer { routingSuppressed = saved }
        return try addMailMessages(messages, account: account, threadKey: threadKey, projectSlug: projectSlug)
    }

    /// Adds several messages (e.g. `parseEmails`) to one thread, oldest first; duplicates are skipped.
    @discardableResult
    func addEmails(_ list: [ParsedEmail], threadKey: String?, projectSlug: String?, routeIfUnassigned: Bool = true) throws -> [SourceRecord] {
        lastRoutingDecision = nil
        var key = threadKey
        var added: [SourceRecord] = []
        for email in list.sorted(by: { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }) {
            do {
                let src = try addEmail(email, threadKey: key, projectSlug: projectSlug, externalId: nil, routeIfUnassigned: routeIfUnassigned)
                key = src.threadKey
                added.append(src)
            } catch EngineError.duplicateEmail {
                continue
            }
        }
        return added
    }

    // MARK: Internals

    private static func sameSender(_ a: EmailAddress?, _ b: EmailAddress?) -> Bool {
        if let ea = a?.email, let eb = b?.email { return ea == eb }
        return a?.name?.lowercased() == b?.name?.lowercased()
    }

    private static func sameMinute(_ a: Date?, _ b: Date?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return abs(a.timeIntervalSince(b)) < 60
    }

    /// Slug of the normalized subject, unique among threads and wiki page names (so `[[key]]` resolves).
    private func newThreadKey(for email: ParsedEmail) -> String {
        var base = slugify(EmailParser.normalizeSubject(email.subject ?? ""), maxLength: 50)
        if base.isEmpty { base = lang.t("correo-", "email-") + Fmt.local(email.date ?? Date(), "yyyy-MM-dd-HHmm") }
        let taken = Set(vault.threadFolders().map { ($0 as NSString).lastPathComponent })
            .union(vault.allMarkdown().map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() })
        var key = base, n = 2
        while taken.contains(key) {
            key = "\(base)-\(n)"
            n += 1
        }
        return key
    }

    /// Moves a whole thread folder into a project (frontmatter `project:` of every message updated, sources too).
    /// Returns the new folder. Doesn't queue anything.
    @discardableResult
    internal func moveThread(_ key: String, to projectSlug: String) throws -> String {
        guard let folder = vault.threadFolders().first(where: { ($0 as NSString).lastPathComponent == key }) else {
            throw EngineError.threadNotFound(key)
        }
        let target = "projects/\(projectSlug)/raw/emails/\(key)"
        guard folder != target else { return folder }
        let fm = FileManager.default
        let from = vault.url(for: folder), to = vault.url(for: target)
        guard !fm.fileExists(atPath: to.path) else { throw EngineError.threadNotFound(key) }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: from, to: to)
        for file in (try? fm.contentsOfDirectory(atPath: to.path)) ?? [] where file.hasSuffix(".md") {
            let url = to.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try Frontmatter.setField("project", to: YAML.scalar(projectSlug), in: text).write(to: url, atomically: true, encoding: .utf8)
        }
        for var src in sources where src.kind == .email && src.threadKey == key {
            if let raw = src.rawPath, raw.hasPrefix(folder + "/") { src.rawPath = target + raw.dropFirst(folder.count) }
            src.projectSlug = projectSlug
            src.suggestedProject = nil
            src.suggestionReason = nil
            upsert(&src)
        }
        Log.info("moved thread \(key): \(folder) → \(target)")
        return target
    }

    /// `assign` for an email: the whole thread moves and each message not learned yet is queued, oldest first.
    internal func assignThread(_ key: String, to projectSlug: String) throws {
        let members = emails(inThread: key)
        guard !runningAnywhere({ job in members.contains { $0.id == job.sourceId } && job.kind != .classify }) else { throw EngineError.busy }
        let alreadyThere = members.allSatisfy { $0.projectSlug == projectSlug }
        if !alreadyThere, members.contains(where: { $0.historyId != nil && $0.status == .done }) { throw EngineError.alreadyIngested }
        try moveThread(key, to: projectSlug)
        for member in emails(inThread: key) where !(member.status == .done && member.historyId != nil) {
            guard var src = source(member.id) else { continue }
            removeJobs(for: src.id) { $0.status != .running }
            src.status = .queued
            src.error = nil
            upsert(&src)
            enqueue(Job(kind: .ingest, sourceId: src.id, projectSlug: projectSlug))
        }
    }

    /// After deleting an email's raw: drop it from `_thread.json`; an empty thread folder goes away.
    internal func forgetEmail(rawPath: String) {
        let folder = (rawPath as NSString).deletingLastPathComponent
        let file = (rawPath as NSString).lastPathComponent
        let dir = vault.url(for: folder)
        guard var meta = ThreadMeta.load(from: dir) else { return }
        meta.messages.removeAll { $0.file == file }
        let fm = FileManager.default
        let remaining = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }
        if meta.messages.isEmpty, remaining.isEmpty {
            try? fm.removeItem(at: dir)
        } else {
            try? meta.save(to: dir)
        }
    }
}

/// Thread suggestions for a pasted email (no main-actor state: safe off the main thread).
enum ThreadMatcher {
    static func matches(for email: ParsedEmail, vault: VaultStore, lang: Lang) -> [ThreadMatch] {
        let owners = Set(vault.ownerEmails())
        let subjectKey = EmailParser.subjectKey(email.subject ?? "")
        let people = Set(([email.from].compactMap { $0 } + email.to + email.cc).compactMap(\.email)).subtracting(owners)
        let quoted = email.quotedHistory.map(EmailParser.normalizedText) ?? ""
        let body = EmailParser.normalizedText(email.body)
        var matches: [ThreadMatch] = []
        for folder in vault.threadFolders() {
            guard let meta = vault.threadMeta(at: folder) else { continue }
            let thread = VaultStore.thread(from: meta, folder: folder)
            var best: (Double, String)?
            func consider(_ score: Double, _ reason: String) { if score > (best?.0 ?? 0) { best = (score, reason) } }

            let threadKey = EmailParser.subjectKey(meta.subject)
            let sameSubject = subjectKey.count >= 3 && subjectKey == threadKey
            let threadPeople = Set(meta.participants.compactMap(\.email)).subtracting(owners)
            let shared = !people.isDisjoint(with: threadPeople)
            if sameSubject, Self.isGenericSubject(subjectKey) {
                // "Re: Hola", "Pregunta", "Seguimiento": many unrelated conversations share these. Only a suggestion,
                // never preselected (< 0.8), and only with people in common.
                if shared {
                    consider(0.6, lang.t("Mismo asunto (muy general) y participantes", "Same (very generic) subject and participants"))
                }
            } else if sameSubject {
                consider(shared ? 0.92 : 0.82, shared ? lang.t("Mismo asunto y participantes", "Same subject and participants")
                                                      : lang.t("Mismo asunto", "Same subject"))
            } else if shared, Self.similarSubjects(subjectKey, threadKey) {
                consider(0.65, lang.t("Participantes en común y asunto parecido", "Shared participants and a similar subject"))
            }
            // Quoted history contains a stored message (or a stored message quotes this one: an older email pasted late).
            if !quoted.isEmpty || body.count >= 25 {
                for m in meta.messages {
                    guard let text = try? vault.read("\(folder)/\(m.file)") else { continue }
                    let stored = VaultStore.emailBody(text)
                    let storedBody = EmailParser.normalizedText(stored.body)
                    if storedBody.count >= 25, quoted.contains(String(storedBody.prefix(200))) {
                        consider(0.95, lang.t("Cita un correo de este hilo", "It quotes an email of this thread"))
                        break
                    }
                    if body.count >= 25, let q = stored.quoted.map(EmailParser.normalizedText), q.contains(String(body.prefix(200))) {
                        consider(0.9, lang.t("Un correo de este hilo lo cita", "An email of this thread quotes it"))
                        break
                    }
                }
            }
            if let best, best.0 >= 0.5 { matches.append(ThreadMatch(thread: thread, score: best.0, reason: best.1)) }
        }
        return matches.sorted { ($0.score, $0.thread.lastDate ?? .distantPast) > ($1.score, $1.thread.lastDate ?? .distantPast) }
    }

    private static let genericSubjects: Set<String> = [
        "hola", "hi", "hello", "hey", "buenas", "buenos dias", "buenas tardes", "saludos", "gracias", "muchas gracias", "thanks",
        "thank you", "pregunta", "una pregunta", "question", "quick question", "pregunta rapida", "duda", "consulta", "info",
        "informacion", "update", "actualizacion", "reunion", "meeting", "junta", "llamada", "call", "seguimiento", "follow up",
        "followup", "test", "prueba", "urgente", "urgent", "importante", "important", "fyi", "aviso", "recordatorio", "reminder",
        "documento", "documentos", "archivo", "archivos", "adjunto", "adjuntos", "attachment", "file", "files", "sin asunto",
        "no subject", "propuesta", "proposal", "cotizacion", "presupuesto", "factura", "invoice", "contrato", "contract",
    ]

    /// A subject too common to identify a conversation on its own ("hola", "pregunta", a single short word).
    static func isGenericSubject(_ key: String) -> Bool {
        if genericSubjects.contains(key) { return true }
        let words = key.split(separator: " ").filter { $0.count > 2 }
        return words.count < 2 && key.count < 12
    }

    static func similarSubjects(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a.count >= 5, b.count >= 5, a.contains(b) || b.contains(a) { return true }
        let ta = Set(a.split(separator: " ").filter { $0.count > 2 }), tb = Set(b.split(separator: " ").filter { $0.count > 2 })
        guard !ta.isEmpty, !tb.isEmpty else { return false }
        return Double(ta.intersection(tb).count) / Double(ta.union(tb).count) >= 0.5
    }
}
