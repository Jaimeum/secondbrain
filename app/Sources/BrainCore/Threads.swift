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
}

public extension VaultStore {
    /// The thread `key` (its folder in `_inbox/emails` or any project's `raw/emails`), or nil.
    // v0.7: filled in by threads (stub: a plain read of `_thread.json`, no caching).
    func threadInfo(key: String) -> ThreadInfo? {
        guard let folder = threadFolders().first(where: { ($0 as NSString).lastPathComponent == key }) else { return nil }
        return threadInfo(folder: folder)
    }

    /// Every saved thread, newest activity first.
    // v0.7: filled in by threads.
    func allThreads() -> [ThreadInfo] {
        threadFolders().compactMap { threadInfo(folder: $0) }
            .sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
    }

    internal func threadInfo(folder: String) -> ThreadInfo? {
        guard let meta = threadMeta(at: folder) else { return nil }
        let owner = Set(ownerEmails())
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
