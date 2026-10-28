import Foundation

// v0.7 "Agregar al proyecto" (CONTRACT §17.3): files and/or free text dropped into a project. The files become sources
// (`raw/docs`, `raw/assets`; audio/video still become recordings), the text a note `raw/notes/<date>-dump-<slug>.md`;
// then ONE `/file-dump` run (edit mode, one Historial entry) classifies and files everything — note, in-person meeting
// (`wiki/meetings/<date>-presencial-<slug>.md`, `SourceKind.inPerson`), document, decision, tasks, people — and answers
// "Lo archivé así: …". The last drops of each project (`DumpStore`) show that summary with Deshacer.

// MARK: - Names

public enum FileDumpNames {
    /// Marker between the date and the slug of a dump note: `2026-10-27-dump-visita-planta`.
    public static let noteMarker = "-dump-"
    public static let meetingMarker = "-presencial-"

    /// `YYYY-MM-DD-dump-<slug>` for a note written on `date` with this title.
    public static func noteBase(title: String, date: Date) -> String {
        let slug = slugify(title, maxLength: 40)
        return Fmt.local(date, "yyyy-MM-dd") + noteMarker + (slug.isEmpty ? "nota" : slug)
    }

    /// `visita-planta` from `…/2026-10-27-dump-visita-planta.md` (nil when it isn't a dump note).
    public static func noteSlug(rawPath: String) -> String? {
        let key = ((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let r = key.range(of: noteMarker) else { return nil }
        let slug = String(key[r.upperBound...])
        return slug.isEmpty ? nil : slug
    }

    /// The page key of an in-person meeting: `<day it happened>-presencial-<slug>` (the day from `eventDate`, else the
    /// note's own date). A raw that isn't a dump note keeps its own key.
    public static func meetingKey(rawPath: String, eventDate: Date?) -> String {
        let key = ((rawPath as NSString).lastPathComponent as NSString).deletingPathExtension
        guard let slug = noteSlug(rawPath: rawPath) else { return key }
        let day = eventDate.map { Fmt.local($0, "yyyy-MM-dd") } ?? String(key.prefix(10))
        return day + meetingMarker + slug
    }

    /// The wiki page key (file name without `.md`) of a source of any kind except email threads and repo syncs.
    public static func pageKey(of src: SourceRecord) -> String? {
        guard let raw = src.rawPath else { return nil }
        if src.kind == .inPerson { return meetingKey(rawPath: raw, eventDate: src.eventDate) }
        return ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tif", "tiff", "bmp"]

    /// Images go to `raw/assets` as `.image`; everything else (that isn't audio/video) to `raw/docs` as `.document`.
    public static func kind(of file: URL) -> SourceKind {
        imageExtensions.contains(file.pathExtension.lowercased()) ? .image : .document
    }
}

// MARK: - Records

public enum DumpStatus: String, Codable, Sendable { case queued, done, failed, undone }

/// One file of a drop.
public struct DumpFile: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var sourceId: String
    public var kind: SourceKind
    public init(name: String, sourceId: String, kind: SourceKind) { self.name = name; self.sourceId = sourceId; self.kind = kind }
}

/// A page `/file-dump` wrote or updated ("items" of its answer).
public struct DumpFiled: Codable, Equatable, Hashable, Sendable {
    /// `in-person` | `note` | `document` | `image` | `decision` | `tasks` | `person` | `org` | `topic`.
    public var kind: String
    public var title: String
    public var page: String?
    public var raw: String?
    public init(kind: String, title: String, page: String?, raw: String?) {
        self.kind = kind; self.title = title; self.page = page; self.raw = raw
    }
}

/// One "Agregar" of the box.
public struct DumpRecord: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var projectSlug: String
    public var createdAt: Date
    /// The first ~300 characters of the text (nil = only files).
    public var textPreview: String?
    public var noteSourceId: String?
    public var files: [DumpFile]
    /// Audio/video files of the drop: they became recordings (transcribed and ingested on their own).
    public var recordings: [DumpFile]
    /// "in-person" when the owner marked the text as an in-person meeting.
    public var hint: String?
    public var jobId: String?
    public var status: DumpStatus
    /// "Lo archivé así: …" (markdown with wikilinks).
    public var summary: String?
    public var items: [DumpFiled]
    public var historyId: String?
    public var error: String?

    public init(id: String = UUID().uuidString.lowercased(), projectSlug: String, createdAt: Date = Date()) {
        self.id = id; self.projectSlug = projectSlug; self.createdAt = createdAt
        files = []; recordings = []; items = []; status = .queued
    }

    /// Every source `/file-dump` files (the note first).
    public var sourceIds: [String] { (noteSourceId.map { [$0] } ?? []) + files.map(\.sourceId) }
}

/// `data/dumps/<vaultKey>.json`: the drops of every project of a vault, newest last (the latest 30 per project).
public final class DumpStore: @unchecked Sendable {
    public static let keepPerProject = 30
    public let fileURL: URL
    private let lock = NSLock()

    public init(dataRoot: URL, vaultRoot: URL) {
        fileURL = dataRoot.appendingPathComponent("dumps").appendingPathComponent(ChatStore.vaultKey(vaultRoot) + ".json")
    }

    public func all() -> [DumpRecord] {
        lock.lock(); defer { lock.unlock() }
        return load()
    }

    /// A project's drops, newest first.
    public func list(projectSlug: String, limit: Int = 10) -> [DumpRecord] {
        // Stored oldest first; dates have second precision, so the stored order breaks ties.
        let mine = all().enumerated().filter { $0.element.projectSlug == projectSlug }
        return Array(mine.sorted { ($0.element.createdAt, $0.offset) > ($1.element.createdAt, $1.offset) }.map(\.element).prefix(limit))
    }

    public func get(_ id: String) -> DumpRecord? { all().first { $0.id == id } }

    public func save(_ record: DumpRecord) {
        lock.lock(); defer { lock.unlock() }
        var list = load()
        if let i = list.firstIndex(where: { $0.id == record.id }) { list[i] = record } else { list.append(record) }
        // Keep the latest N per project.
        let mine = list.filter { $0.projectSlug == record.projectSlug }.sorted { $0.createdAt > $1.createdAt }
        if mine.count > Self.keepPerProject {
            let drop = Set(mine.dropFirst(Self.keepPerProject).map(\.id))
            list.removeAll { drop.contains($0.id) }
        }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder.sb.encode(list) { try? data.write(to: fileURL, options: .atomic) }
    }

    public func update(_ id: String, _ change: (inout DumpRecord) -> Void) {
        guard var r = get(id) else { return }
        change(&r)
        save(r)
    }

    private func load() -> [DumpRecord] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder.sb.decode([DumpRecord].self, from: data)) ?? []
    }
}

// MARK: - /file-dump answer

public struct FileDumpResult: Equatable, Sendable {
    public var summary: String
    public var items: [DumpFiled]
    /// The note was an in-person meeting: the day (and time) it happened, and its title.
    public var meetingDate: Date?
    public var meetingTitle: String?
    public var isMeeting: Bool

    /// The command's final message: one JSON object `{summary, items, meeting}` (also inside a code fence or after
    /// some text); anything else is taken as a markdown summary.
    public static func parse(_ text: String) -> FileDumpResult {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let open = trimmed.firstIndex(of: "{"), let close = trimmed.lastIndex(of: "}"), open < close,
           let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed[open...close].utf8))) as? [String: Any] {
            let summary = (obj["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let items: [DumpFiled] = ((obj["items"] as? [[String: Any]]) ?? []).compactMap { item in
                guard let kind = item["as"] as? String ?? item["kind"] as? String else { return nil }
                let page = (item["page"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                let title = (item["title"] as? String) ?? page.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension } ?? kind
                return DumpFiled(kind: kind, title: title, page: page, raw: item["raw"] as? String)
            }
            var date: Date?, title: String?
            let meeting = obj["meeting"] as? [String: Any]
            if let meeting {
                title = meeting["title"] as? String
                if let day = meeting["date"] as? String {
                    let time = (meeting["time"] as? String).flatMap { $0.count >= 4 ? $0 : nil }
                    date = SBDate.parseISO(time.map { "\(day) \($0.count == 4 ? "0" + $0 : $0)" } ?? day)?.date
                }
            }
            let isMeeting = meeting != nil || items.contains { $0.kind == "in-person" }
            return FileDumpResult(summary: summary.isEmpty ? Self.fallbackSummary(items) : summary, items: items,
                                  meetingDate: date, meetingTitle: title, isMeeting: isMeeting)
        }
        return FileDumpResult(summary: trimmed, items: [], meetingDate: nil, meetingTitle: nil, isMeeting: false)
    }

    private static func fallbackSummary(_ items: [DumpFiled]) -> String {
        items.map { item in
            guard let page = item.page else { return "- " + item.title }
            return "- [[\(((page as NSString).lastPathComponent as NSString).deletingPathExtension)|\(item.title)]]"
        }.joined(separator: "\n")
    }
}

// MARK: - Engine

public extension BrainEngine {
    /// Payload keys of a `.fileDump` job.
    static let dumpIdKey = "dumpId"
    static let dumpSourcesKey = "sourceIds"

    /// The drops of a project, newest first (the box shows 10).
    func dumps(projectSlug: String, limit: Int = 10) -> [DumpRecord] {
        dumpStore.list(projectSlug: projectSlug, limit: limit)
    }

    /// "Agregar" (§17.3): imports `files` (images → `raw/assets`, the rest → `raw/docs`; audio/video → recordings) and
    /// `text` (→ `raw/notes/<date>-dump-<slug>.md`) into `projectSlug`, then queues one `/file-dump`. `inPerson`: the
    /// owner marked the text as an in-person meeting. Throws when nothing could be imported (the first error).
    @discardableResult
    func addToProject(_ projectSlug: String, files: [URL], text: String, inPerson: Bool = false) async throws -> DumpRecord {
        guard let slug = validProject(projectSlug) else { throw EngineError.invalidTemplate(lang.t("Ese proyecto no existe.", "That project doesn't exist.")) }
        var record = DumpRecord(projectSlug: slug)
        record.hint = inPerson ? "in-person" : nil
        var firstError: Error?
        let origin = [("origin", "dump")]
        for url in files {
            do {
                if await Task.detached(operation: { AudioPrep.isMedia(url) }).value {
                    try importFile(url, projectSlug: slug, eventDate: nil)
                    if let id = sources.last?.id { record.recordings.append(DumpFile(name: url.lastPathComponent, sourceId: id, kind: .meeting)) }
                    continue
                }
                let kind = FileDumpNames.kind(of: url)
                let dir = rawDir(kind, slug)
                let imported = Importer.mainThreadText.contains(url.pathExtension.lowercased())
                    ? try Importer.importFile(url, into: dir, project: slug, kind: kind, extra: origin)
                    : try await Task.detached(priority: .userInitiated) {
                        try Importer.importFile(url, into: dir, project: slug, kind: kind, extra: origin)
                    }.value
                var src = SourceRecord(id: imported.sourceId, kind: kind, title: imported.title, projectSlug: slug, status: .queued,
                                       rawPath: imported.rawURL.relativePath(from: vault.root))
                src.eventDate = imported.eventDate
                upsert(&src)
                record.files.append(DumpFile(name: url.lastPathComponent, sourceId: src.id, kind: kind))
            } catch {
                Log.error("dump: couldn't import \(url.lastPathComponent): \(error)")
                if firstError == nil { firstError = error }
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let now = Date()
            let title = CaptureDetector.noteTitle(trimmed) ?? lang.t("Nota del ", "Note of ") + Fmt.local(now, "yyyy-MM-dd")
            let imported = try Importer.writeNote(title: title, body: trimmed, into: rawDir(.note, slug), project: slug, eventDate: now,
                                                  base: FileDumpNames.noteBase(title: title, date: now), extra: origin)
            var src = SourceRecord(id: imported.sourceId, kind: inPerson ? .inPerson : .note, title: imported.title,
                                   projectSlug: slug, status: .queued, rawPath: imported.rawURL.relativePath(from: vault.root))
            src.eventDate = imported.eventDate
            upsert(&src)
            record.noteSourceId = src.id
            record.textPreview = String(trimmed.prefix(300))
        }
        if record.sourceIds.isEmpty && record.recordings.isEmpty, let firstError { throw firstError }
        if record.sourceIds.isEmpty {
            record.status = .done   // only recordings: they follow their own path
            dumpStore.save(record)
            return record
        }
        let job = Job(kind: .fileDump, projectSlug: slug,
                      payload: [Self.dumpIdKey: record.id, Self.dumpSourcesKey: record.sourceIds.joined(separator: ",")])
        record.jobId = job.id
        if let firstError { record.error = (firstError as? LocalizedError)?.errorDescription ?? firstError.localizedDescription }
        dumpStore.save(record)
        enqueue(job)
        Log.info("dump \(record.id): \(record.files.count) file(s), text: \(record.noteSourceId != nil), recordings: \(record.recordings.count)")
        return record
    }

    /// The `/file-dump` arguments (JSON) for a drop.
    func fileDumpArguments(_ record: DumpRecord, today: Date = Date()) -> String {
        func original(_ raw: String) -> String? {
            guard let text = try? vault.read(raw), let name = Frontmatter.field("original_file", in: text), !name.isEmpty else { return nil }
            return ((raw as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name)
        }
        let files: [[String: Any]] = record.files.compactMap { f in
            guard let raw = source(f.sourceId)?.rawPath else { return nil }
            return ["raw": raw, "original": original(raw) ?? NSNull(), "name": f.name, "kind": f.kind == .image ? "image" : "document"]
        }
        var note: Any = NSNull()
        if let id = record.noteSourceId, let raw = source(id)?.rawPath {
            note = ["raw": raw, "slug": FileDumpNames.noteSlug(rawPath: raw) ?? ""]
        }
        let body: [String: Any] = ["project": record.projectSlug, "today": Fmt.local(today, "yyyy-MM-dd"),
                                   "hint": record.hint ?? NSNull(), "files": files, "note": note]
        let data = (try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Source ids a queued or running `/file-dump` will file (they have no job of their own).
    func dumpPendingSourceIds() -> Set<String> {
        Set(queue.jobs.filter { $0.kind == .fileDump && ($0.status == .queued || $0.status == .running) }
            .flatMap { ($0.payload[Self.dumpSourcesKey] ?? "").split(separator: ",").map(String.init) })
    }

    internal func runFileDump(_ job: Job) async throws {
        guard let id = job.payload[Self.dumpIdKey], var record = dumpStore.get(id) else {
            throw EngineError.sourceNotFound(job.payload[Self.dumpIdKey] ?? "")
        }
        let ids = record.sourceIds.filter { source($0) != nil }
        guard !ids.isEmpty else { return }   // deleted meanwhile
        for sid in ids {
            guard var src = source(sid) else { continue }
            src.status = .ingesting
            src.error = nil
            upsert(&src)
        }
        let name = projects.get(record.projectSlug)?.name ?? record.projectSlug
        let args = fileDumpArguments(record)
        let title = lang.t("Archivé lo que agregaste a \(name)", "Filed what you added to \(name)")
        let simulated = FileDumpSimulator.run
        let vaultRoot = vault.root
        var output = ""
        let entry = try await tracked(job, title: title, kind: .fileDump, sourceId: nil, projectSlug: record.projectSlug) {
            if let simulated {
                output = try simulated(args, vaultRoot)
            } else {
                output = try await self.runClaude(job, command: "file-dump", arguments: args, mode: .edit, model: self.config.ingestModel)
            }
            return output
        }
        let result = FileDumpResult.parse(output)
        applyFileDump(&record, result: result, historyId: entry?.id)
        // The Historial entry shows the summary as written (the JSON is for the app).
        if let entry, !result.summary.isEmpty { try? history.setSummary(result.summary, entryId: entry.id) }
    }

    /// After `/file-dump`: sources learned (one Historial entry for all), the note becomes an in-person meeting when Claude
    /// filed it as one (its day and title too), the record keeps the summary.
    internal func applyFileDump(_ record: inout DumpRecord, result: FileDumpResult, historyId: String?) {
        for sid in record.sourceIds {
            guard var src = source(sid) else { continue }
            if sid == record.noteSourceId, result.isMeeting || record.hint == "in-person" {
                src.kind = .inPerson
                if let date = result.meetingDate { src.eventDate = date }
                if let t = result.meetingTitle?.trimmingCharacters(in: .whitespaces), !t.isEmpty { src.title = t }
            } else if sid == record.noteSourceId, src.kind == .inPerson, !result.isMeeting {
                src.kind = .note
            }
            src.status = .done
            src.progress = nil
            src.error = nil
            src.historyId = historyId ?? src.historyId
            upsert(&src)
        }
        record.status = .done
        record.summary = result.summary
        record.items = result.items
        record.historyId = historyId
        record.error = nil
        dumpStore.save(record)
    }

    /// The job gave up (`finish` with a failed job): the drop and its sources show the error.
    internal func fileDumpFailed(_ job: Job) {
        guard let id = job.payload[Self.dumpIdKey] else { return }
        dumpStore.update(id) { r in
            r.status = .failed
            r.error = job.error
        }
        guard let record = dumpStore.get(id) else { return }
        for sid in record.sourceIds {
            guard var src = source(sid), src.status != .done else { continue }
            src.status = .failed
            src.error = job.error
            upsert(&src)
        }
    }

    /// A retry is coming: its sources wait again (not "learning").
    internal func fileDumpWillRetry(_ job: Job) {
        guard let id = job.payload[Self.dumpIdKey], let record = dumpStore.get(id) else { return }
        for sid in record.sourceIds {
            guard var src = source(sid), src.status == .ingesting else { continue }
            src.status = .queued
            upsert(&src)
        }
    }

    /// "Deshacer" of a drop: undoes its Historial entry (unless already undone in Historial) and removes its sources and
    /// raw files; a drop still waiting is simply cancelled. Recordings of the drop are left alone (Fuentes has them).
    func undoDump(id: String) throws {
        guard var record = dumpStore.get(id) else { return }
        if let jobId = record.jobId, let job = queue.job(id: jobId) {
            guard job.status != .running else { throw EngineError.busy }
            removeJob(id: jobId)
        }
        if let hid = record.historyId, history.entry(id: hid)?.undone == false {
            try undo(historyId: hid)
        }
        for sid in record.sourceIds where source(sid) != nil {
            if var src = source(sid), src.historyId != nil {
                src.historyId = nil
                upsert(&src)
            }
            try delete(sourceId: sid)
        }
        record.status = .undone
        dumpStore.save(record)
        Log.info("dump \(id) undone")
    }

    /// Re-queues a failed drop.
    func retryDump(id: String) {
        guard var record = dumpStore.get(id), record.status == .failed else { return }
        let ids = record.sourceIds.filter { source($0) != nil }
        guard !ids.isEmpty else { return }
        for sid in ids {
            guard var src = source(sid) else { continue }
            src.status = .queued
            src.error = nil
            upsert(&src)
        }
        if let old = record.jobId { removeJob(id: old) }   // the failed one
        let job = Job(kind: .fileDump, projectSlug: record.projectSlug,
                      payload: [Self.dumpIdKey: record.id, Self.dumpSourcesKey: ids.joined(separator: ",")])
        record.jobId = job.id
        record.status = .queued
        record.error = nil
        dumpStore.save(record)
        enqueue(job)
    }

    internal var dumpStore: DumpStore { DumpStore(dataRoot: paths.root, vaultRoot: vault.root) }
}

/// `sb dump selftest`: stands in for Claude (`args` = the /file-dump JSON, `vault` = the vault root; returns the final
/// message). nil in the app.
public enum FileDumpSimulator {
    nonisolated(unsafe) public static var run: ((_ arguments: String, _ vault: URL) throws -> String)?
}
