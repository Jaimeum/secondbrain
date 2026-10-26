import Foundation

// Shared v0.2 types (docs/CONTRACT.md §11). Same rule as Models.swift: owners may add members,
// never change or remove existing public ones.

// MARK: - Emails

public struct EmailAddress: Codable, Hashable, Sendable {
    public var name: String?
    public var email: String?             // lowercased
    public init(name: String?, email: String?) { self.name = name; self.email = email }
    public var display: String { name ?? email ?? "?" }
}

public struct ParsedEmail: Codable, Equatable, Sendable {
    public var subject: String?
    public var from: EmailAddress?
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var date: Date?                // from the Date/Fecha/Enviado header, with its timezone
    public var body: String               // the new content (quoted history removed)
    public var quotedHistory: String?     // "On … wrote:" / "El … escribió:" / "-----Original Message-----" onward
    public var raw: String                // exactly what the user pasted
    public var isFromOwner: Bool          // from matches one of the owner's addresses
    public init(subject: String?, from: EmailAddress?, to: [EmailAddress] = [], cc: [EmailAddress] = [], date: Date?,
                body: String, quotedHistory: String?, raw: String, isFromOwner: Bool = false) {
        self.subject = subject; self.from = from; self.to = to; self.cc = cc; self.date = date
        self.body = body; self.quotedHistory = quotedHistory; self.raw = raw; self.isFromOwner = isFromOwner
    }
}

public struct EmailThread: Codable, Identifiable, Hashable, Sendable {
    public var key: String                // folder name, e.g. "contrato-proveedor-acme"
    public var subject: String            // normalized subject (no Re:/Fwd:)
    public var projectSlug: String?       // nil = _inbox
    public var participants: [EmailAddress]
    public var messageCount: Int
    public var firstDate: Date?
    public var lastDate: Date?
    public var folderPath: String         // vault-relative: projects/<p>/raw/emails/<key> or _inbox/emails/<key>
    public var id: String { key }
    public init(key: String, subject: String, projectSlug: String?, participants: [EmailAddress], messageCount: Int,
                firstDate: Date?, lastDate: Date?, folderPath: String) {
        self.key = key; self.subject = subject; self.projectSlug = projectSlug; self.participants = participants
        self.messageCount = messageCount; self.firstDate = firstDate; self.lastDate = lastDate; self.folderPath = folderPath
    }
}

public struct ThreadMatch: Equatable, Sendable {
    public var thread: EmailThread
    public var score: Double              // 0...1; ≥ 0.8 = strong (preselect), 0.5–0.8 = suggest
    public var reason: String             // human, localized ("Mismo asunto y participantes")
    public init(thread: EmailThread, score: Double, reason: String) { self.thread = thread; self.score = score; self.reason = reason }
}

// MARK: - Templates ("formatos")

public enum TemplateScope: String, Codable, Sendable { case meeting, email, any }

public struct TemplateInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: String                 // filename stem in vault/templates/
    public var name: String
    public var description: String
    public var scope: TemplateScope
    public var isBuiltIn: Bool            // shipped preset (editing it makes a user copy)
    public var body: String               // markdown structure + <!-- instructions -->
    public init(id: String, name: String, description: String, scope: TemplateScope, isBuiltIn: Bool, body: String) {
        self.id = id; self.name = name; self.description = description; self.scope = scope; self.isBuiltIn = isBuiltIn; self.body = body
    }
    public static let standardId = "estandar"
}

// MARK: - Tasks / agreements

public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String                 // stable: "<tasks.md path>#<normalized text hash>"
    public var projectSlug: String
    public var text: String               // the action, without owner/date/citation markup
    public var ownerSlug: String?         // people/<slug>.md
    public var ownerName: String?
    public var isMine: Bool               // owner is the vault owner ("Yo"/"Me")
    public var due: Date?                 // 📅 (date only, local)
    public var done: Bool
    public var doneDate: Date?            // ✅
    public var sourceKeys: [String]       // wikilink targets in the citation, e.g. meeting keys
    public var line: String               // exact original line in tasks.md
    public init(id: String, projectSlug: String, text: String, ownerSlug: String?, ownerName: String?, isMine: Bool,
                due: Date?, done: Bool, doneDate: Date?, sourceKeys: [String], line: String) {
        self.id = id; self.projectSlug = projectSlug; self.text = text; self.ownerSlug = ownerSlug; self.ownerName = ownerName
        self.isMine = isMine; self.due = due; self.done = done; self.doneDate = doneDate; self.sourceKeys = sourceKeys; self.line = line
    }
    public var isOverdue: Bool {
        guard !done, let due else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
}

// MARK: - Timeline

public enum TimelineKind: String, Codable, Sendable { case meeting, email, document, note, url, decision, milestone, task }

public struct TimelineEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var date: Date                 // when it HAPPENED
    public var hasTime: Bool              // false = date-only (show without hour)
    public var addedAt: Date?             // when it was added to the brain (sources only)
    public var kind: TimelineKind
    public var title: String
    public var projectSlug: String?
    public var pagePath: String?          // vault-relative page to open
    public var sourceId: String?
    public init(id: String, date: Date, hasTime: Bool, addedAt: Date?, kind: TimelineKind, title: String,
                projectSlug: String?, pagePath: String?, sourceId: String?) {
        self.id = id; self.date = date; self.hasTime = hasTime; self.addedAt = addedAt; self.kind = kind; self.title = title
        self.projectSlug = projectSlug; self.pagePath = pagePath; self.sourceId = sourceId
    }
}

// MARK: - Export

public enum ExportFormat: String, Codable, CaseIterable, Sendable {
    case markdown, text, docx, pdf, html, rtf
    public var fileExtension: String {
        switch self { case .markdown: "md"; case .text: "txt"; case .docx: "docx"; case .pdf: "pdf"; case .html: "html"; case .rtf: "rtf" }
    }
}

public struct ExportOptions: Codable, Equatable, Sendable {
    public var includeSummary = true      // the wiki page (meeting summary / thread page)
    public var includeTasks = true        // that source's commitments as a checklist (mine / theirs)
    public var includeTranscript = false  // raw transcript / email bodies
    public var includeTimestamps = true   // in the transcript
    public var resolveSpeakerNames = true // "Hablante 1" → "Ana García" when the meeting page maps it
    public var keepFrontmatter = false    // markdown only
    public var keepWikilinks = false      // markdown only; otherwise [[x|Label]] → Label
    public init() {}
}
