import Foundation

// "Proyecto por reunión" (CONTRACT §12.5, §12.7): which project a calendar event belongs to, remembered per series in
// `data/meetings.json`, plus a suggestion without Claude (attendees' people pages, words of the title).

/// What the user chose for an event: a project, or explicitly none (the recording goes to Inbox).
public enum MeetingProjectChoice: Equatable, Sendable {
    case project(String)
    case noProject

    public var projectSlug: String? {
        if case .project(let slug) = self { return slug }
        return nil
    }
}

/// `data/meetings.json`: `{"events": {eventId: slug}, "series": {seriesId: slug}}`; `""` = "Sin proyecto".
/// A choice made on an event of a series is remembered for the whole series. Thread-safe.
public final class MeetingLinks: @unchecked Sendable {
    struct Stored: Codable, Equatable {
        var events: [String: String] = [:]
        var series: [String: String] = [:]
    }

    public let fileURL: URL
    private let lock = NSLock()
    private var stored = Stored()

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL) {
            do {
                stored = try JSONDecoder().decode(Stored.self, from: data)
            } catch {
                Log.error("could not read \(fileURL.lastPathComponent): \(error)")
            }
        }
    }

    /// The event's own choice, else its series'. nil = nothing chosen yet (a suggestion may be shown).
    public func choice(for event: CalendarEvent) -> MeetingProjectChoice? {
        lock.lock(); defer { lock.unlock() }
        let value = event.allIds.lazy.compactMap { self.stored.events[$0] }.first ?? event.seriesId.flatMap { stored.series[$0] }
        return value.map { $0.isEmpty ? .noProject : .project($0) }
    }

    /// Remembers `choice` for the event's series (or the event alone when it isn't recurring); nil forgets it.
    public func set(_ choice: MeetingProjectChoice?, for event: CalendarEvent) throws {
        let value: String? = choice.map { $0.projectSlug ?? "" }
        let snapshot: Stored = {
            lock.lock(); defer { lock.unlock() }
            if let series = event.seriesId {
                stored.series[series] = value
                stored.events[event.id] = nil
            } else {
                for alias in event.aliasIds { stored.events[alias] = nil }   // one choice per meeting, under its kept id
                stored.events[event.id] = value
            }
            return stored
        }()
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }
}

// MARK: - People pages (for suggestions and prep)

/// The vault's `people/*.md` pages, read once, to recognize meeting attendees.
public struct MeetingPeopleIndex: Sendable {
    public struct Person: Sendable, Hashable {
        public var slug: String
        public var title: String
        public var path: String            // "people/ana-garcia.md"
        public var aliases: [String]       // as written (names, emails)
        public var projects: [String]      // slugs from `projects:` and from links to projects/<slug>/…
        public var isOwner: Bool
        public init(slug: String, title: String, path: String, aliases: [String] = [], projects: [String] = [], isOwner: Bool = false) {
            self.slug = slug; self.title = title; self.path = path; self.aliases = aliases; self.projects = projects; self.isOwner = isOwner
        }
    }

    public var people: [Person]
    public init(people: [Person] = []) { self.people = people }

    public static func load(vault: VaultStore) -> MeetingPeopleIndex {
        let fm = FileManager.default
        let files = ((try? fm.contentsOfDirectory(atPath: vault.url(for: "people").path)) ?? [])
            .filter { $0.hasSuffix(".md") && $0 != "README.md" }
            .sorted()
        var people: [Person] = []
        for file in files {
            let path = "people/\(file)"
            guard let text = try? vault.read(path) else { continue }
            let slug = String(file.dropLast(3))
            let title = Frontmatter.field("title", in: text) ?? slug
            var projects = yamlList("projects", in: text).map { TaskParser.slugOf($0) }
            for match in text.matches(of: #/\[\[projects/([^/\]|#]+)/#) {
                let s = String(match.1)
                if !projects.contains(s) { projects.append(s) }
            }
            people.append(Person(slug: slug, title: title, path: path, aliases: yamlList("aliases", in: text),
                                 projects: projects, isOwner: Frontmatter.field("owner", in: text)?.lowercased() == "true"))
        }
        return MeetingPeopleIndex(people: people)
    }

    /// The people page of an attendee: by email (an alias), else by full name (title, alias or file name).
    public func person(for address: EmailAddress) -> Person? {
        if let email = address.email?.lowercased(), !email.isEmpty,
           let p = people.first(where: { $0.aliases.contains { $0.lowercased() == email } }) {
            return p
        }
        guard let name = address.name.map(Self.norm), !name.isEmpty, !name.contains("@") else { return nil }
        return people.first { Self.norm($0.title) == name || $0.aliases.contains { Self.norm($0) == name } }
            ?? people.first { $0.slug == slugify(name) }
    }

    static func norm(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    /// `key: ["a", "b"]` or a block list (`key:` then `  - a`), unquoted. Wikilinks keep their target.
    static func yamlList(_ key: String, in text: String) -> [String] {
        guard let yaml = Frontmatter.split(text).yaml else { return [] }
        let lines = yaml.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return [] }
        let inline = lines[i].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        var items: [String] = []
        if inline.hasPrefix("[") {
            var body = inline.dropFirst()
            if let close = body.lastIndex(of: "]") { body = body[..<close] }
            items = splitFlowList(String(body))
        } else if inline.isEmpty {
            for line in lines[(i + 1)...] {
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix("- ") else { break }
                items.append(String(t.dropFirst(2)))
            }
        } else {
            items = [inline]
        }
        return items.map(unquote).filter { !$0.isEmpty && $0 != "null" }
    }

    /// Splits `"a", "b, c", d` at commas outside quotes and brackets.
    private static func splitFlowList(_ s: String) -> [String] {
        var out: [String] = [], current = ""
        var quote: Character?
        var depth = 0
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch; current.append(ch)
            } else if ch == "[" {
                depth += 1; current.append(ch)
            } else if ch == "]" {
                depth -= 1; current.append(ch)
            } else if ch == ",", depth == 0 {
                out.append(current); current = ""
            } else {
                current.append(ch)
            }
        }
        out.append(current)
        return out.map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static func unquote(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { s = String(s.dropFirst().dropLast()) }
        if s.hasPrefix("[["), s.hasSuffix("]]") {
            s = String(s.dropFirst(2).dropLast(2))
            if let bar = s.firstIndex(of: "|") { s = String(s[..<bar]) }
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Suggestion

/// "¿Es de 🚀 Acme?": why a project is suggested for an event.
public struct MeetingSuggestion: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The title names the project ("Llamada con Acme — propuesta").
        case title
        /// These attendees' people pages belong to the project.
        case people([String])
    }
    public var projectSlug: String
    public var reason: Reason
    public init(projectSlug: String, reason: Reason) { self.projectSlug = projectSlug; self.reason = reason }
}

/// Suggests a project for an event without Claude: attendees whose people page lists the project, and project names in
/// the title. Build it once (off the main thread) and ask for many events.
public struct MeetingProjectSuggester: Sendable {
    public var people: MeetingPeopleIndex
    public var projects: [Project]
    /// The owner's addresses (connected accounts + people/README): they are in every meeting, so they never count.
    public var ownerEmails: Set<String>

    public init(people: MeetingPeopleIndex, projects: [Project], ownerEmails: Set<String>) {
        self.people = people; self.projects = projects; self.ownerEmails = Set(ownerEmails.map { $0.lowercased() })
    }

    public func suggestProject(for event: CalendarEvent) -> MeetingSuggestion? {
        guard !projects.isEmpty else { return nil }
        let titleTokens = Self.tokens(event.title)
        var best: (slug: String, score: Int, title: Bool, names: [String])?
        var tie = false
        for project in projects {
            let byTitle = Self.titleMentions(project, tokens: titleTokens)
            var names: [String] = []
            for attendee in event.attendees {
                if let email = attendee.email?.lowercased(), ownerEmails.contains(email) { continue }
                guard let person = people.person(for: attendee), !person.isOwner, person.projects.contains(project.slug) else { continue }
                if !names.contains(person.title) { names.append(person.title) }
            }
            let score = (byTitle ? 3 : 0) + names.count
            guard score > 0 else { continue }
            if let b = best, b.score == score {
                tie = true
            } else if best == nil || score > best!.score {
                best = (project.slug, score, byTitle, names)
                tie = false
            }
        }
        guard let best, !tie else { return nil }
        return MeetingSuggestion(projectSlug: best.slug, reason: best.title ? .title : .people(best.names))
    }

    /// The project's name (or slug) appears as whole words in the title.
    static func titleMentions(_ project: Project, tokens titleTokens: [String]) -> Bool {
        let nameTokens = tokens(project.name)
        let slugTokens = project.slug.split(separator: "-").map(String.init)
        for candidate in [nameTokens, slugTokens] where !candidate.isEmpty && candidate.joined().count >= 3 {
            if contains(titleTokens, candidate) { return true }
        }
        return false
    }

    static func tokens(_ s: String) -> [String] {
        MeetingPeopleIndex.norm(s)
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    private static func contains(_ haystack: [String], _ needle: [String]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        for i in 0...(haystack.count - needle.count) where Array(haystack[i..<(i + needle.count)]) == needle { return true }
        return false
    }
}

// MARK: - Engine

public extension BrainEngine {
    /// Ties a recording to its calendar event: the source keeps `calendarEventId` and happened when the event started
    /// (CONTRACT §12.5 "Después de grabar").
    func linkCalendarEvent(sourceId: String, event: CalendarEvent) {
        guard var src = source(sourceId) else { return }
        src.calendarEventId = event.id
        if !event.isAllDay { src.eventDate = event.start }
        upsert(&src)
    }

    /// The newest source recorded for this calendar event (under any id it was merged from), if any.
    func meetingSource(for event: CalendarEvent) -> SourceRecord? {
        sources.last { event.matches($0.calendarEventId) }
    }

    /// The newest source recorded for this calendar event, if any.
    func meetingSource(forEvent eventId: String) -> SourceRecord? {
        sources.last { $0.calendarEventId == eventId }
    }
}
