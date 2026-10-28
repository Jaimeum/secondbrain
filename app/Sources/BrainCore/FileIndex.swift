import Foundation

// v0.7 (CONTRACT §17.2): Archivos. Every real file the brain keeps — documents and images uploaded or dropped into a
// project (`raw/docs`, `raw/assets`) and the attachments saved with email threads (`raw/emails/<thread>/attachments/…`),
// plus their `_inbox` equivalents — with what the app knows about each: kind, size, date, project, where it came from
// (an email thread and its sender, an upload, "Agregar al proyecto", the quick capture), the people it involves and the
// wiki page that summarizes it. Incremental: a refresh lists the folders and re-reads only the markdown files (raw
// wrappers and summary pages) whose modification date changed. Pure filtering and sorting live here too, so
// `sb files selftest` pins them.

/// The "Tipo ▾" buckets.
public enum FileType: String, CaseIterable, Codable, Hashable, Sendable {
    case pdf, document, spreadsheet, presentation, image, other

    public static func of(extension raw: String) -> FileType {
        switch raw.lowercased() {
        case "pdf": .pdf
        case "doc", "docx", "rtf", "rtfd", "odt", "pages", "txt", "text", "md", "markdown", "html", "htm", "webarchive":
            .document
        case "xls", "xlsx", "xlsm", "csv", "tsv", "numbers", "ods": .spreadsheet
        case "ppt", "pptx", "key", "odp": .presentation
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "tif", "tiff", "webp", "bmp", "svg": .image
        default: .other
        }
    }

    /// SF Symbol for a row without a thumbnail.
    public var symbol: String {
        switch self {
        case .pdf: "doc.richtext"
        case .document: "doc.text"
        case .spreadsheet: "tablecells"
        case .presentation: "rectangle.on.rectangle"
        case .image: "photo"
        case .other: "doc"
        }
    }
}

/// The "Origen ▾" buckets: Correo · Subido · Agregar al proyecto · Captura.
public enum FileOrigin: String, CaseIterable, Codable, Hashable, Sendable {
    case email, upload, dump, capture

    /// The raw wrapper's front-matter `via:` (written by "Agregar al proyecto" = `dump`, the quick capture =
    /// `capture`); anything else, or nothing, is an upload.
    public static func of(via raw: String?) -> FileOrigin {
        switch raw?.lowercased().trimmingCharacters(in: .whitespaces) {
        case "dump", "file-dump", "agregar": .dump
        case "capture", "captura", "quick-capture": .capture
        case "email", "mail": .email
        default: .upload
        }
    }
}

/// Someone a file involves: the sender/recipients of its email, or a person its summary page names.
public struct FilePerson: Codable, Hashable, Sendable {
    public var name: String
    /// Their person page (`people/<slug>.md`) when known.
    public var path: String?
    public var email: String?
    public init(name: String, path: String? = nil, email: String? = nil) {
        self.name = name; self.path = path; self.email = email
    }
    /// What the "Persona ▾" filter matches on: the page when there is one, else the folded name.
    public var key: String { path ?? "name:" + FileIndex.fold(name) }
}

public struct FileEntry: Codable, Identifiable, Hashable, Sendable {
    /// Vault-relative path of the file itself.
    public var path: String
    public var id: String { path }
    /// Shown name ("Contrato Acme.pdf").
    public var name: String
    public var type: FileType
    public var size: Int
    /// When the email arrived, else when it was imported.
    public var date: Date
    public var projectSlug: String?
    public var origin: FileOrigin
    /// Email attachments: the thread, its subject, the sender and the email file it came with.
    public var threadKey: String?
    public var threadSubject: String?
    public var sender: EmailAddress?
    public var messageFile: String?
    /// The email's provider link and id (`"<provider>:<id>"`), for "Abrir en Outlook/Gmail".
    public var webLink: String?
    public var externalId: String?
    public var people: [FilePerson]
    /// The wiki page that summarizes it (`wiki/sources/<key>.md`), its title and its "En breve".
    public var summaryPath: String?
    public var summaryTitle: String?
    public var summary: String?
    /// The file's own source, when the engine has one.
    public var sourceId: String?
    /// Folded name + thread subject + sender + summary page text (search).
    public var searchText: String

    public var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    /// The thread's wiki page, when the thread lives in a project.
    public var threadPagePath: String? {
        guard let threadKey, let projectSlug else { return nil }
        return "projects/\(projectSlug)/wiki/emails/\(threadKey).md"
    }
}

public enum FileSort: String, CaseIterable, Codable, Hashable, Sendable {
    case date, name, size
}

/// What the Archivos bar asks for. nil = any.
public struct FileQuery: Hashable, Sendable {
    public var text: String
    public var type: FileType?
    public var origin: FileOrigin?
    /// `FilePerson.key`.
    public var person: String?
    public var project: String?
    public var sort: FileSort
    public init(text: String = "", type: FileType? = nil, origin: FileOrigin? = nil, person: String? = nil,
                project: String? = nil, sort: FileSort = .date) {
        self.text = text; self.type = type; self.origin = origin; self.person = person; self.project = project
        self.sort = sort
    }
    public var isFiltered: Bool {
        !text.trimmingCharacters(in: .whitespaces).isEmpty || type != nil || origin != nil || person != nil || project != nil
    }
}

public final class FileIndex: @unchecked Sendable {
    public let vaultRoot: URL

    // MARK: Shared instances

    nonisolated(unsafe) private static var instances: [String: FileIndex] = [:]
    private static let instancesLock = NSLock()

    /// One index per vault (the app's views and the CLI share the incremental cache).
    public static func shared(vaultRoot: URL) -> FileIndex {
        let key = vaultRoot.standardizedFileURL.path
        instancesLock.lock()
        defer { instancesLock.unlock() }
        if let hit = instances[key] { return hit }
        let index = FileIndex(vaultRoot: vaultRoot)
        instances[key] = index
        return index
    }

    public init(vaultRoot: URL) { self.vaultRoot = vaultRoot }

    // MARK: Cache

    /// A markdown file as the index needs it (re-read only when its modification date changes).
    struct ParsedMarkdown {
        var title: String?
        var type: String?
        var sourceId: String?
        var originalFile: String?
        var via: String?
        var date: Date?
        var added: Date?
        /// `sources:` of a summary page (vault-relative, wikilink brackets removed).
        var sources: [String]
        var excerpt: String
        var folded: String
    }

    private let lock = NSLock()
    private var parsed: [String: (mtime: Date, value: ParsedMarkdown)] = [:]
    private var lastEntries: [FileEntry] = []

    /// The entries of the last refresh (no disk access).
    public var entries: [FileEntry] {
        lock.lock(); defer { lock.unlock() }
        return lastEntries
    }

    /// Brings the index up to date and returns every file, newest first. Blocking (lists the raw folders, reads
    /// changed markdown): call it off the main thread. `sources` (the engine's) tie files to their source and summary
    /// page; `entities` (the ficha index) resolves people to their pages and adds the people a summary page names.
    @discardableResult
    public func refresh(sources: [SourceRecord] = [], entities: EntityIndex.Snapshot? = nil) -> [FileEntry] {
        lock.lock()
        defer { lock.unlock() }
        let vault = VaultStore(root: vaultRoot)
        let fm = FileManager.default
        var seenMarkdown = Set<String>()

        func markdown(_ rel: String) -> ParsedMarkdown? {
            let url = vaultRoot.appendingPathComponent(rel)
            guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            else { return nil }
            seenMarkdown.insert(rel)
            if let hit = parsed[rel], hit.mtime == mtime { return hit.value }
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            let value = Self.parse(text)
            parsed[rel] = (mtime, value)
            return value
        }
        func children(_ rel: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: vaultRoot.appendingPathComponent(rel).path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
        }
        func isDir(_ rel: String) -> Bool { fm.isDirectory(vaultRoot.appendingPathComponent(rel)) }
        func attributes(_ rel: String) -> (size: Int, mtime: Date) {
            let values = try? vaultRoot.appendingPathComponent(rel).resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (values?.fileSize ?? 0, values?.contentModificationDate ?? Date())
        }

        // Places: the inbox and every project.
        var places: [(slug: String?, docs: String, assets: String, emails: String, wiki: String?)] = [
            (nil, "_inbox/docs", "_inbox/assets", "_inbox/emails", nil),
        ]
        for slug in children("projects") where isDir("projects/\(slug)") {
            places.append((slug, "projects/\(slug)/raw/docs", "projects/\(slug)/raw/assets", "projects/\(slug)/raw/emails",
                           "projects/\(slug)/wiki"))
        }

        // Summary pages: `wiki/sources/*.md` of every project, by the raw files they cite and by file name.
        var pageBySource: [String: String] = [:]
        var pageByName: [String: String] = [:]
        for place in places {
            guard let wiki = place.wiki else { continue }
            for folder in ["sources", "documents", "docs"] {
                let dir = "\(wiki)/\(folder)"
                for name in children(dir) where name.lowercased().hasSuffix(".md") {
                    let rel = "\(dir)/\(name)"
                    guard let page = markdown(rel) else { continue }
                    for source in page.sources { pageBySource[source.lowercased()] = rel }
                    pageByName[((name as NSString).deletingPathExtension).lowercased() + "|" + (place.slug ?? "")] = rel
                }
            }
        }
        let sourceById = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let sourceByRaw = Dictionary(sources.compactMap { s in s.rawPath.map { ($0.lowercased(), s) } },
                                     uniquingKeysWith: { a, _ in a })
        let ownerEmails = Set(vault.ownerEmails())

        // People: names → person pages (title and aliases, folded).
        var personByName: [String: Entity] = [:]
        for person in entities?.allPeople ?? [] {
            for name in [person.title] + person.aliases { personByName[Self.fold(name)] = person }
        }
        func person(_ address: EmailAddress) -> FilePerson? {
            let name = address.name ?? address.email ?? ""
            guard !name.isEmpty else { return nil }
            let hit = personByName[Self.fold(name)]
            return FilePerson(name: hit?.title ?? name, path: hit?.path, email: address.email)
        }

        func summaryPage(for files: [String], stem: String, slug: String?, sourceId: String?) -> String? {
            for file in files { if let page = pageBySource[file.lowercased()] { return page } }
            if let id = sourceId, let src = sourceById[id], let raw = src.rawPath, let page = pageBySource[raw.lowercased()] {
                return page
            }
            if let id = sourceId, let src = sourceById[id], let raw = src.rawPath {
                let key = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                if let page = pageByName[key + "|" + (src.projectSlug ?? "")] { return page }
            }
            return pageByName[stem.lowercased() + "|" + (slug ?? "")]
        }

        var out: [FileEntry] = []

        func makeEntry(path: String, name: String, slug: String?, origin: FileOrigin, date: Date, sourceId: String?,
                       summary: String?, people: [FilePerson], thread: (key: String, subject: String, sender: EmailAddress?,
                                                                        message: String?, webLink: String?, externalId: String?)? = nil,
                       size: Int) -> FileEntry {
            var people = people
            var summaryTitle: String?, excerpt: String?, summaryText = ""
            if let summary, let page = markdown(summary) {
                summaryTitle = page.title
                excerpt = page.excerpt.isEmpty ? nil : page.excerpt
                summaryText = page.folded
                // People the summary page names (front matter or body), resolved by the ficha index.
                if let entity = entities?.entity(summary) {
                    for link in entity.outgoing {
                        guard let e = entities?.entity(link), e.kind == .person, !e.isOwner,
                              !people.contains(where: { $0.path == link }) else { continue }
                        people.append(FilePerson(name: e.title, path: e.path))
                    }
                }
            }
            let ext = (path as NSString).pathExtension
            let search = [Self.fold(name), thread.map { Self.fold($0.subject) } ?? "",
                          thread?.sender.map { Self.fold($0.display + " " + ($0.email ?? "")) } ?? "",
                          people.map { Self.fold($0.name) }.joined(separator: " "),
                          summaryTitle.map(Self.fold) ?? "", summaryText].joined(separator: "\n")
            return FileEntry(path: path, name: name, type: FileType.of(extension: ext), size: size, date: date,
                             projectSlug: slug, origin: origin, threadKey: thread?.key, threadSubject: thread?.subject,
                             sender: thread?.sender, messageFile: thread?.message, webLink: thread?.webLink,
                             externalId: thread?.externalId, people: people, summaryPath: summary,
                             summaryTitle: summaryTitle, summary: excerpt, sourceId: sourceId, searchText: search)
        }

        // 1. Uploaded / dropped / captured files: raw/docs and raw/assets.
        for place in places {
            for dir in [place.docs, place.assets] {
                let names = children(dir)
                var wrappers: [String: (rel: String, md: ParsedMarkdown)] = [:]   // original file name → its raw .md
                var plain: [(rel: String, md: ParsedMarkdown)] = []
                for name in names where name.lowercased().hasSuffix(".md") {
                    let rel = "\(dir)/\(name)"
                    guard let md = markdown(rel) else { continue }
                    if let original = md.originalFile {
                        wrappers[original] = (rel, md)
                    } else if dir == place.docs, md.type != "url", md.type != "note" {
                        plain.append((rel, md))   // a text document kept as markdown
                    }
                }
                for name in names where !name.lowercased().hasSuffix(".md") {
                    let rel = "\(dir)/\(name)"
                    guard !isDir(rel) else { continue }
                    let attrs = attributes(rel)
                    let wrapper = wrappers[name]
                    let source = wrapper?.md.sourceId.flatMap { sourceById[$0] } ?? sourceByRaw[rel.lowercased()]
                        ?? wrapper.flatMap { sourceByRaw[$0.rel.lowercased()] }
                    let ext = (name as NSString).pathExtension
                    var shown = name
                    if let title = wrapper?.md.title ?? source?.title, !title.isEmpty {
                        shown = title.lowercased().hasSuffix("." + ext.lowercased()) || ext.isEmpty ? title : title + "." + ext
                    }
                    let stem = ((wrapper?.rel ?? rel) as NSString).lastPathComponent
                    let summary = summaryPage(for: [rel, wrapper?.rel].compactMap { $0 },
                                              stem: (stem as NSString).deletingPathExtension, slug: place.slug,
                                              sourceId: source?.id ?? wrapper?.md.sourceId)
                    let date = wrapper?.md.added ?? source?.createdAt ?? wrapper?.md.date ?? attrs.mtime
                    out.append(makeEntry(path: rel, name: shown, slug: place.slug,
                                         origin: FileOrigin.of(via: wrapper?.md.via), date: date,
                                         sourceId: source?.id ?? wrapper?.md.sourceId, summary: summary, people: [],
                                         size: attrs.size))
                }
                for (rel, md) in plain {
                    let attrs = attributes(rel)
                    let source = md.sourceId.flatMap { sourceById[$0] } ?? sourceByRaw[rel.lowercased()]
                    let stem = ((rel as NSString).lastPathComponent as NSString).deletingPathExtension
                    let summary = summaryPage(for: [rel], stem: stem, slug: place.slug, sourceId: source?.id ?? md.sourceId)
                    let title = md.title ?? source?.title ?? summary.flatMap { markdown($0)?.title } ?? stem
                    let date = md.added ?? source?.createdAt ?? md.date ?? attrs.mtime
                    out.append(makeEntry(path: rel, name: title, slug: place.slug, origin: FileOrigin.of(via: md.via),
                                         date: date, sourceId: source?.id ?? md.sourceId, summary: summary, people: [],
                                         size: attrs.size))
                }
            }
        }

        // 2. Email attachments: <thread>/attachments/<YYYY-MM-DD-HHmm>-<from-slug>/<name>.
        for place in places {
            for threadName in children(place.emails) {
                let folder = "\(place.emails)/\(threadName)"
                let attachmentsDir = "\(folder)/attachments"
                guard isDir(attachmentsDir) else { continue }
                var files: [String] = []
                if let walker = fm.enumerator(at: vaultRoot.appendingPathComponent(attachmentsDir),
                                              includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                    for case let url as URL in walker where !fm.isDirectory(url) {
                        if let rel = url.relativePath(from: vaultRoot) { files.append(rel) }
                    }
                }
                guard !files.isEmpty else { continue }
                let meta = vault.threadMeta(at: folder)
                let listed = Dictionary((meta?.attachments ?? []).map { ($0.file, $0) }, uniquingKeysWith: { a, _ in a })
                // Raw wrappers inside the attachments folder (an attachment's own source) point at their file.
                var wrappers: [String: ParsedMarkdown] = [:]
                for rel in files where rel.lowercased().hasSuffix(".md") {
                    if let md = markdown(rel), let original = md.originalFile {
                        wrappers[((rel as NSString).deletingLastPathComponent as NSString).appendingPathComponent(original)] = md
                    }
                }
                let participants = (meta?.participants ?? []).filter { !ownerEmails.contains($0.email ?? "") }
                for rel in files.sorted() {
                    if rel.lowercased().hasSuffix(".md"), let md = markdown(rel), md.originalFile != nil { continue }
                    let attrs = attributes(rel)
                    let listedEntry = listed[rel]
                    let messageFolder = ((rel as NSString).deletingLastPathComponent as NSString).lastPathComponent
                    let messageFile = listedEntry?.message ?? meta?.messages.first {
                        ($0.file as NSString).deletingPathExtension == messageFolder
                    }?.file
                    let message = meta?.messages.first { $0.file == messageFile }
                    let wrapper = wrappers[rel]
                    let sourceId = listedEntry?.sourceId ?? wrapper?.sourceId ?? sourceByRaw[rel.lowercased()]?.id
                    let source = sourceId.flatMap { sourceById[$0] }
                    let date = message?.date ?? Self.stampDate(messageFolder) ?? source?.createdAt ?? attrs.mtime
                    var people: [FilePerson] = []
                    if let from = message?.from, !ownerEmails.contains(from.email ?? ""), let p = person(from) { people.append(p) }
                    for p in participants.compactMap(person) where !people.contains(where: { $0.key == p.key }) {
                        people.append(p)
                    }
                    let name = listedEntry?.name ?? (rel as NSString).lastPathComponent
                    let stem = (name as NSString).deletingPathExtension
                    let summary = summaryPage(for: [rel], stem: stem, slug: place.slug, sourceId: sourceId)
                    let subject = meta?.subject.isEmpty == false ? meta!.subject : threadName
                    out.append(makeEntry(path: rel, name: name, slug: place.slug, origin: .email, date: date,
                                         sourceId: sourceId, summary: summary, people: people,
                                         thread: (threadName, subject, message?.from, messageFile, message?.webLink,
                                                  message?.externalId),
                                         size: listedEntry?.size ?? attrs.size))
                }
            }
        }

        // Forget files that went away.
        for key in parsed.keys where !seenMarkdown.contains(key) { parsed[key] = nil }
        out.sort { a, b in a.date != b.date ? a.date > b.date : a.path < b.path }
        lastEntries = out
        return out
    }

    // MARK: Parsing

    static func parse(_ text: String) -> ParsedMarkdown {
        let parts = Frontmatter.split(text)
        func date(_ key: String) -> Date? { Frontmatter.field(key, in: text).flatMap { SBDate.parseISO($0)?.date } }
        var sources: [String] = []
        if let yaml = parts.yaml {
            var inList = false
            for line in yaml.components(separatedBy: "\n") {
                if line.hasPrefix("sources:") {
                    let value = String(line.dropFirst("sources:".count))
                    sources += quotedValues(value)
                    inList = value.trimmingCharacters(in: .whitespaces).isEmpty
                } else if inList, line.hasPrefix("  -") || line.hasPrefix("- ") {
                    sources += quotedValues(String(line.drop { $0 == " " || $0 == "-" }))
                } else {
                    inList = false
                }
            }
        }
        var title = Frontmatter.field("title", in: text)
        if title == nil {
            title = parts.body.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
                .map { String($0.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        }
        var excerpt = EntityIndex.excerpt(text, max: 360)
        for prefix in ["En breve:", "En breve :", "In short:", "Summary:", "Resumen:"] where excerpt.hasPrefix(prefix) {
            excerpt = String(excerpt.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        return ParsedMarkdown(title: title, type: Frontmatter.field("type", in: text),
                              sourceId: Frontmatter.field("source_id", in: text),
                              originalFile: Frontmatter.field("original_file", in: text),
                              via: Frontmatter.field("via", in: text),
                              date: date("event_date") ?? date("date"), added: date("added"),
                              sources: sources, excerpt: excerpt, folded: fold(parts.body))
    }

    /// `["a", "[[b|x]]"]` / `"a"` / `a` → paths, with `.md` added to bare wikilink targets.
    private static func quotedValues(_ raw: String) -> [String] {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: " []"))
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: ",").compactMap { item in
            var s = item.trimmingCharacters(in: CharacterSet(charactersIn: " \"'[]"))
            if let bar = s.firstIndex(of: "|") { s = String(s[..<bar]) }
            guard !s.isEmpty else { return nil }
            return s
        }.flatMap { s in s.lowercased().hasSuffix(".md") || (s as NSString).pathExtension.count > 0 ? [s] : [s, s + ".md"] }
    }

    /// `2026-10-27-1430-ana-garcia` → 2026-10-27 14:30 local.
    public static func stampDate(_ folder: String) -> Date? {
        guard folder.count >= 15 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmm"
        return f.date(from: String(folder.prefix(15)))
    }

    /// No accents, no case.
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    // MARK: Filtering

    /// The entries `query` asks for, sorted (date: newest first; name: A→Z; size: largest first). Every word of the
    /// text must appear in the name, the thread, the sender, the people or the summary page.
    public static func filter(_ entries: [FileEntry], _ query: FileQuery) -> [FileEntry] {
        let words = fold(query.text).split(whereSeparator: \.isWhitespace).map(String.init)
        let out = entries.filter { e in
            if let t = query.type, e.type != t { return false }
            if let o = query.origin, e.origin != o { return false }
            if let p = query.project, e.projectSlug != p { return false }
            if let person = query.person, !e.people.contains(where: { $0.key == person }) { return false }
            return words.allSatisfy { e.searchText.contains($0) }
        }
        switch query.sort {
        case .date: return out.sorted { a, b in a.date != b.date ? a.date > b.date : a.path < b.path }
        case .name:
            return out.sorted { a, b in
                let c = a.name.localizedStandardCompare(b.name)
                return c != .orderedSame ? c == .orderedAscending : a.path < b.path
            }
        case .size: return out.sorted { a, b in a.size != b.size ? a.size > b.size : a.path < b.path }
        }
    }

    /// The people of `entries` (for "Persona ▾"), by how many files they have, then by name.
    public static func people(in entries: [FileEntry]) -> [FilePerson] {
        var count: [String: Int] = [:]
        var first: [String: FilePerson] = [:]
        for e in entries {
            for p in e.people {
                count[p.key, default: 0] += 1
                if first[p.key] == nil { first[p.key] = p }
            }
        }
        return first.values.sorted { a, b in
            let x = count[a.key, default: 0], y = count[b.key, default: 0]
            return x != y ? x > y : a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The files a ficha lists (§17.2): a thread's attachments; a document page's own file; for a person, the files
    /// they sent, received or are named in; for a company, those of its people; and any file whose summary page links
    /// to the entity or is linked from it.
    public static func files(for path: String, in entries: [FileEntry], snapshot: EntityIndex.Snapshot) -> [FileEntry] {
        let entity = snapshot.entity(path)
        var threadKey: String?
        let parts = path.split(separator: "/").map(String.init)
        if parts.count == 5, parts[0] == "projects", parts[2] == "wiki", parts[3] == "emails" {
            threadKey = (parts[4] as NSString).deletingPathExtension
        }
        let orgPeople: Set<String> = entity?.kind == .org
            ? Set(snapshot.allPeople.filter { snapshot.orgPath($0.org) == path }.map(\.path)) : []
        return entries.filter { e in
            if let threadKey, e.threadKey == threadKey, e.projectSlug == Scope.projectSlug(ofPath: path) { return true }
            if e.summaryPath == path { return true }
            if e.people.contains(where: { $0.path == path || ($0.path.map(orgPeople.contains) ?? false) }) { return true }
            if let summary = e.summaryPath, entity?.isNavigation == false, entity?.kind != .project,
               snapshot.neighbors(of: summary).contains(path) { return true }
            return false
        }
    }
}
