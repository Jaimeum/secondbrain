import Foundation

// v0.7 (CONTRACT §17.4): the email thread as a unit, for the user (one row, one conversation) and for the graph (one
// node). Derived from `<thread folder>/_thread.json` (`ThreadMeta`); Claude never edits that file.

/// A saved attachment, as `_thread.json` lists it (§17.1). `file` is vault-relative
/// (`…/raw/emails/<thread>/attachments/<YYYY-MM-DD-HHmm>-<from-slug>/<name>`); `message` = the email file it came with.
public struct ThreadAttachment: Codable, Hashable, Sendable {
    public var file: String
    public var message: String
    public var name: String
    public var mime: String
    public var size: Int
    public var sha256: String
    /// The attachment's own source (`SourceKind.document` / `.image`, `parentSourceId` = the email).
    public var sourceId: String?
    public init(file: String, message: String, name: String, mime: String, size: Int, sha256: String, sourceId: String? = nil) {
        self.file = file; self.message = message; self.name = name; self.mime = mime; self.size = size
        self.sha256 = sha256; self.sourceId = sourceId
    }
}

public struct ThreadInfo: Codable, Identifiable, Hashable, Sendable {
    public struct Message: Codable, Hashable, Sendable {
        /// The email's file name inside the thread folder.
        public var file: String
        public var sourceId: String?
        public var date: Date?
        public var from: EmailAddress?
        /// Sent by the owner (people/README.md addresses or a connected account): "Tú" in the conversation.
        public var isFromOwner: Bool
        /// `"<provider>:<messageId>"` for mail from a connected account; nil for pasted mail.
        public var externalId: String?
        public var webLink: String?
        public var attachments: [ThreadAttachment]
        public init(file: String, sourceId: String?, date: Date?, from: EmailAddress?, isFromOwner: Bool,
                    externalId: String?, webLink: String?, attachments: [ThreadAttachment]) {
            self.file = file; self.sourceId = sourceId; self.date = date; self.from = from; self.isFromOwner = isFromOwner
            self.externalId = externalId; self.webLink = webLink; self.attachments = attachments
        }
    }

    public var key: String
    public var subject: String
    public var participants: [EmailAddress]
    /// Chronological.
    public var messages: [Message]
    public var projectSlug: String?
    /// Vault-relative: `projects/<p>/raw/emails/<key>` or `_inbox/emails/<key>`.
    public var folderPath: String
    /// Account id → provider conversation/thread id.
    public var providerThreadIds: [String: String]
    public var id: String { key }

    public init(key: String, subject: String, participants: [EmailAddress], messages: [Message], projectSlug: String?,
                folderPath: String, providerThreadIds: [String: String] = [:]) {
        self.key = key; self.subject = subject; self.participants = participants; self.messages = messages
        self.projectSlug = projectSlug; self.folderPath = folderPath; self.providerThreadIds = providerThreadIds
    }


    public var messageCount: Int { messages.count }
    public var firstDate: Date? { messages.compactMap(\.date).min() }
    public var lastDate: Date? { messages.compactMap(\.date).max() }
    public var attachments: [ThreadAttachment] { messages.flatMap(\.attachments) }
    /// The thread's wiki page (`wiki/emails/<key>.md`) when it has a project.
    public var pagePath: String? { projectSlug.map { "projects/\($0)/wiki/emails/\(key).md" } }
    /// The newest message, if any.
    public var lastMessage: Message? { messages.last }
    /// The newest message that has a provider link ("Abrir en Outlook/Gmail" in the ficha's header opens it).
    public var lastWebLink: String? { messages.last { $0.webLink != nil }?.webLink }

    /// Who wrote in it, in order of first message, by short name: `["Ana", you, "Luis"]` (the owner as `you`).
    public func senderNames(you: String) -> [String] {
        var out: [String] = []
        for m in messages {
            let name = m.isFromOwner ? you : (m.from.map(Self.shortName) ?? "")
            if !name.isEmpty, !out.contains(name) { out.append(name) }
        }
        return out
    }

    /// "Ana García" → "Ana"; "ana.garcia@x.com" → "ana.garcia".
    public static func shortName(_ a: EmailAddress) -> String {
        if let name = a.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty {
            return name.split(separator: " ").first.map(String.init) ?? name
        }
        return a.email?.components(separatedBy: "@").first ?? ""
    }
}

public extension ThreadInfo.Message {
    /// The provider of a message from a connected account (`externalId` = `"<provider>:<messageId>"`), nil when pasted.
    var provider: AccountProvider? {
        externalId?.split(separator: ":", maxSplits: 1).first.flatMap { AccountProvider(rawValue: String($0)) }
    }
}

/// Where a message of a connected account came from (§17.4/§17.7): stored in `_thread.json` by `addEmail`.
public struct MailOrigin: Sendable, Hashable {
    /// `ConnectedAccount.id` ("microsoft:ana@x.com").
    public var accountId: String
    /// The provider's conversation (Graph `conversationId`) / thread (Gmail `threadId`) id.
    public var providerThreadId: String?
    public var webLink: String?
    public init(accountId: String, providerThreadId: String?, webLink: String?) {
        self.accountId = accountId; self.providerThreadId = providerThreadId; self.webLink = webLink
    }
}

/// `_thread.json` decoded once per change (file modification date + size): lists, the graph, ⌘K and the duplicate
/// checks read every thread often.
enum ThreadMetaCache {
    private struct Entry { let mtime: TimeInterval; let size: Int; let meta: ThreadMeta }
    nonisolated(unsafe) private static var entries: [String: Entry] = [:]
    private static let lock = NSLock()

    static func load(from dir: URL) -> ThreadMeta? {
        let url = dir.appendingPathComponent(ThreadMeta.fileName)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSinceReferenceDate ?? 0
        let size = (attrs[.size] as? NSNumber)?.intValue ?? 0
        let key = url.standardizedFileURL.path
        lock.lock()
        if let hit = entries[key], hit.mtime == mtime, hit.size == size {
            lock.unlock()
            return hit.meta
        }
        lock.unlock()
        guard let meta = ThreadMeta.load(from: dir) else { return nil }
        lock.lock()
        entries[key] = Entry(mtime: mtime, size: size, meta: meta)
        lock.unlock()
        return meta
    }
}

public extension VaultStore {
    /// The thread `key` (its folder in `_inbox/emails` or any project's `raw/emails`), or nil.
    func threadInfo(key: String) -> ThreadInfo? {
        guard let folder = threadFolders().first(where: { ($0 as NSString).lastPathComponent == key }) else { return nil }
        return threadInfo(folder: folder, owners: Set(ownerEmails()))
    }

    /// Every saved thread, newest activity first. `_thread.json` is decoded only when it changed (`ThreadMetaCache`).
    func allThreads() -> [ThreadInfo] {
        let owners = Set(ownerEmails())
        return threadFolders().compactMap { threadInfo(folder: $0, owners: owners) }
            .sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    /// The saved thread that holds this provider conversation for this account (§17.4), if any.
    func threadKey(accountId: String, providerThreadId: String) -> String? {
        guard !providerThreadId.isEmpty else { return nil }
        for folder in threadFolders() {
            if let meta = threadMeta(at: folder), meta.providerThreadIds?[accountId] == providerThreadId { return meta.key }
        }
        return nil
    }

    /// What a message of the thread says that is new (no quoted history), from its raw. Empty when unreadable.
    func newText(of message: ThreadInfo.Message, in thread: ThreadInfo) -> String {
        guard let text = try? read("\(thread.folderPath)/\(message.file)") else { return "" }
        return Self.emailBody(text).body
    }

    internal func threadInfo(folder: String, owners: Set<String>? = nil) -> ThreadInfo? {
        guard let meta = threadMeta(at: folder) else { return nil }
        let owner = owners ?? Set(ownerEmails())
        let attachments = meta.attachments ?? []
        let messages = meta.messages.map { m in
            ThreadInfo.Message(file: m.file, sourceId: m.sourceId, date: m.date, from: m.from,
                               isFromOwner: m.isFromOwner ?? m.from?.email.map { owner.contains($0.lowercased()) } ?? false,
                               externalId: m.externalId, webLink: m.webLink,
                               attachments: attachments.filter { $0.message == m.file })
        }.sorted { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        return ThreadInfo(key: meta.key, subject: meta.subject, participants: meta.participants, messages: messages,
                          projectSlug: Self.projectSlug(of: folder), folderPath: folder,
                          providerThreadIds: meta.providerThreadIds ?? [:])
    }
}

// MARK: - Graph (§17.4)

/// What ties a thread node to the rest of the graph besides the links Claude wrote: its participants' person pages,
/// their companies (by the person's `org:` or the address's domain) and the pages of its saved attachments.
enum ThreadLinks {
    /// People and companies of the vault, by address, full name and mail domain.
    struct GlobalIndex {
        var personByEmail: [String: String] = [:]
        var personByName: [String: String] = [:]
        var orgByDomain: [String: String] = [:]
        /// Person page → the company pages it may name (checked against the pages that exist).
        var orgsOfPerson: [String: [String]] = [:]
        var paths = Set<String>()

        /// Webmail domains never identify a company.
        static let publicDomains: Set<String> = [
            "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "yahoo.com.mx",
            "icloud.com", "me.com", "mac.com", "proton.me", "protonmail.com", "aol.com", "gmx.com", "hotmail.es", "outlook.es",
        ]

        mutating func add(_ page: KnowledgeGraphBuilder.Page, text: String) {
            paths.insert(page.path)
            let yaml = Frontmatter.split(text).yaml ?? ""
            let lines = [yaml] + text.components(separatedBy: "\n").filter {
                let l = $0.lowercased()
                return l.contains("correo") || l.contains("mail") || l.contains("dominio") || l.contains("domain")
                    || l.contains("web") || l.contains("sitio")
            }
            let addresses = lines.flatMap { Self.addresses(in: $0) }
            if page.path.hasPrefix("people/") {
                for a in addresses where personByEmail[a] == nil { personByEmail[a] = page.path }
                let name = KnownPeople.fold(page.title)
                if name.split(separator: " ").count >= 2, personByName[name] == nil { personByName[name] = page.path }
                orgsOfPerson[page.path] = page.targets.map { t in
                    "orgs/" + slugify(((t as NSString).lastPathComponent as NSString).deletingPathExtension) + ".md"
                }
            } else if page.path.hasPrefix("orgs/") {
                var domains = addresses.compactMap { $0.components(separatedBy: "@").last }
                for key in ["domain", "domains", "dominio", "dominios", "web", "website", "sitio"] {
                    for value in KnowledgeGraphBuilder.listField(key, in: yaml) { if let host = Self.host(value) { domains.append(host) } }
                }
                for d in domains where !Self.publicDomains.contains(d) && orgByDomain[d] == nil { orgByDomain[d] = page.path }
            }
        }

        static func addresses(in s: String) -> [String] {
            s.matches(of: #/[A-Za-z0-9._%+'\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}/#).map { String($0.output).lowercased() }
        }

        /// "https://www.acme.com/x" / "acme.com" → "acme.com".
        static func host(_ value: String) -> String? {
            var v = value.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " \"'<>[]()"))
            if let r = v.range(of: "://") { v = String(v[r.upperBound...]) }
            v = v.components(separatedBy: "/").first ?? v
            if v.hasPrefix("www.") { v = String(v.dropFirst(4)) }
            return v.contains(".") && !v.contains(" ") && !v.contains("@") ? v : nil
        }

        /// The company of an address's domain, or of a subdomain's parent (`mx.acme.com` → `acme.com`).
        func org(forDomain domain: String) -> String? {
            var d = domain
            while true {
                if let hit = orgByDomain[d] { return hit }
                guard let dot = d.firstIndex(of: "."), d[d.index(after: dot)...].contains(".") else { return nil }
                d = String(d[d.index(after: dot)...])
            }
        }
    }

    /// Saved threads that have a page among `pages`, by page path.
    static func threads(vault: VaultStore, pages: [String: KnowledgeGraphBuilder.Page]) -> [String: ThreadInfo] {
        var out: [String: ThreadInfo] = [:]
        for t in vault.allThreads() {
            guard let page = t.pagePath, pages[page] != nil, out[page] == nil else { continue }
            out[page] = t
        }
        return out
    }

    /// Thread page → people, companies and attachment pages it is tied to (the owner left out: they are in every
    /// thread). `via`: thread → company → the person pages that brought it ("" = a participant with no page), so a
    /// person removed from a project by hand (`project.json` exclude) takes their company out with them.
    struct Result {
        var targets: [String: Set<String>] = [:]
        var via: [String: [String: Set<String>]] = [:]

        /// The people and companies a project's graph keeps for its threads.
        func globals(ofThreadsIn slug: String, pages: [String: KnowledgeGraphBuilder.Page], excluded: Set<String>) -> Set<String> {
            var keep = Set<String>()
            for (thread, linked) in targets where pages[thread]?.projectSlug == slug {
                for target in linked where KnowledgeGraphBuilder.isGlobalEntity(target) && !excluded.contains(target) {
                    if target.hasPrefix("orgs/"), let people = via[thread]?[target], people.isSubset(of: excluded) { continue }
                    keep.insert(target)
                }
            }
            return keep
        }
    }

    static func links(_ threads: [String: ThreadInfo], index: GlobalIndex, pages: [String: KnowledgeGraphBuilder.Page],
                      owners: Set<String>) -> Result {
        var result = Result()
        // The owner's company (their own domain) would tie every thread to it: only a person page links there.
        let ownerDomains = Set(owners.compactMap { $0.components(separatedBy: "@").last })
        for (path, thread) in threads {
            var linked = Set<String>()
            for p in thread.participants {
                if let email = p.email?.lowercased(), owners.contains(email) { continue }
                var person = p.email.flatMap { index.personByEmail[$0.lowercased()] }
                if person == nil, let name = p.name.map(KnownPeople.fold), name.split(separator: " ").count >= 2 {
                    person = index.personByName[name]
                }
                var orgs: [String] = []
                if let person {
                    linked.insert(person)
                    orgs += (index.orgsOfPerson[person] ?? []).filter { index.paths.contains($0) }
                }
                if let domain = p.email?.lowercased().components(separatedBy: "@").last, !ownerDomains.contains(domain),
                   let org = index.org(forDomain: domain) {
                    orgs.append(org)
                }
                for org in orgs {
                    linked.insert(org)
                    result.via[path, default: [:]][org, default: []].insert(person ?? "")
                }
            }
            if let slug = thread.projectSlug {
                for a in thread.attachments {
                    let stem = ((a.file as NSString).lastPathComponent as NSString).deletingPathExtension
                    let candidate = "projects/\(slug)/wiki/sources/\(stem).md"
                    if pages[candidate] != nil { linked.insert(candidate) }
                }
            }
            linked.remove(path)
            if !linked.isEmpty { result.targets[path] = linked }
        }
        return result
    }
}
