import Foundation

// v0.7 (CONTRACT §17.1): saving the attachments of an email that is already in the brain. Forward (automatic) the
// deterministic triage decides, Claude settles the ambiguous ones (`/triage-attachments`, read-only) and what is not
// kept waits 30 days in Descartados; backwards (confirmed) the user's ticks decide. Each saved attachment lands next to
// its thread (`<thread>/attachments/<message>/<name>`, immutable), is listed in `_thread.json` and becomes a source of
// its own (`.document`/`.image`, `parentSourceId` = the email, same `threadKey`) that goes through ingest.

/// How `saveAttachments` decides.
public enum AttachmentSaveMode: Sendable, Equatable {
    /// Forward: rules, then Claude for the ambiguous ones; > 25 MB is never downloaded.
    case automatic
    /// Backwards: exactly these attachment ids are saved (the save sheet's ticks, "Guardar", "Guardar de todos modos").
    /// The unticked ones are not downloaded: they stay in the mailbox, "No guardado" in the reader, to save later.
    case confirmed([String])
}

/// What `saveAttachments` did.
public struct AttachmentSaveReport: Sendable, Equatable {
    public var saved: [ThreadAttachment] = []
    /// The attachments' new sources (queued for ingest, or waiting with their thread in Sin asignar).
    public var sourceIds: [String] = []
    public var discarded: [DiscardedItem] = []
    /// Over 25 MB, not downloaded ("Guardar de todos modos").
    public var tooBig: [AttachmentInfo] = []
    /// Already saved or discarded before, or not a file (Graph item/reference attachments).
    public var skipped: [AttachmentInfo] = []
    /// Names that could not be downloaded or stored (retried the next time).
    public var failed: [String] = []
    public init() {}
}

/// Where an attachment of a message stands, for the reader's list (§17.1: Guardado · Descartado (razón) · No guardado ·
/// Muy grande).
public enum AttachmentState: Sendable, Equatable {
    case saved(ThreadAttachment)
    case discarded(DiscardedItem)
    /// Not in the brain; the triage's verdict (for the save sheet's checkbox).
    case notSaved(AttachmentDecision)
    case tooBig
    /// A Graph item/reference attachment: a name, no file.
    case notAFile
}

/// One ambiguous attachment handed to Claude (`path` is absolute, in a folder outside the vault Claude may read).
public struct AttachmentTriageCandidate: Sendable, Equatable, Codable {
    public var name: String
    public var path: String
    public var mime: String
    public var size: Int
}

/// Claude's verdict on one candidate.
public struct AttachmentTriageVerdict: Sendable, Equatable, Codable {
    public var name: String
    public var keep: Bool
    public var reason: String?
    public init(name: String, keep: Bool, reason: String?) { self.name = name; self.keep = keep; self.reason = reason }
}

/// Decides the ambiguous attachments of one email (`emailRawPath` vault-relative). nil = no answer (they are kept: nothing
/// useful is lost). The default runs `/triage-attachments`; tests pass their own.
public typealias AttachmentClaudeTriage = @Sendable (_ emailRawPath: String, _ candidates: [AttachmentTriageCandidate],
                                                    _ folder: URL) async -> [AttachmentTriageVerdict]?

public extension BrainEngine {
    /// The vault's Descartados (`data/discarded/<vault>/`).
    var discardedStore: DiscardedStore { DiscardedStore(dataRoot: paths.root, vaultRoot: vault.root) }

    /// The attachments of a message as the reader shows them. `messageSourceId` = the email's source (nil = the email is
    /// not in the brain: everything is "No guardado").
    func attachmentStates(messageSourceId: String?, attachments: [AttachmentInfo],
                          inlineContentIds: [String]? = nil) -> [String: AttachmentState] {
        var saved: [ThreadAttachment] = []
        var discarded: [DiscardedItem] = []
        if let id = messageSourceId, let src = source(id), let key = src.threadKey, let raw = src.rawPath,
           let folder = threadFolder(key), let meta = vault.threadMeta(at: folder) {
            let file = (raw as NSString).lastPathComponent
            saved = (meta.attachments ?? []).filter { $0.message == file }
            discarded = discardedStore.list().filter { $0.messageSourceId == id }
        }
        let context = AttachmentTriage.Context(inlineContentIds: inlineContentIds.map(Set.init))
        // The provider's attachment id first; then by name, each saved/discarded entry used once (two `image.png` of
        // one email are two attachments: saving one doesn't make the other "Guardado").
        var savedLeft = saved, discardedLeft = discarded
        var savedFor: [String: ThreadAttachment] = [:], discardedFor: [String: DiscardedItem] = [:]
        for a in attachments {
            if let i = savedLeft.firstIndex(where: { $0.attachmentId == a.id }) {
                savedFor[a.id] = savedLeft.remove(at: i)
            } else if let i = discardedLeft.firstIndex(where: { $0.attachmentId == a.id }) {
                discardedFor[a.id] = discardedLeft.remove(at: i)
            }
        }
        for a in attachments where savedFor[a.id] == nil && discardedFor[a.id] == nil {
            if let i = savedLeft.firstIndex(where: { $0.name == a.name }) {
                savedFor[a.id] = savedLeft.remove(at: i)
            } else if let i = discardedLeft.firstIndex(where: { $0.name == DiscardedStore.safeName(a.name) }) {
                discardedFor[a.id] = discardedLeft.remove(at: i)
            }
        }
        var out: [String: AttachmentState] = [:]
        for a in attachments {
            if let s = savedFor[a.id] {
                out[a.id] = .saved(s)
            } else if let d = discardedFor[a.id] {
                out[a.id] = .discarded(d)
            } else if !a.isDownloadable {
                out[a.id] = .notAFile
            } else {
                let decision = AttachmentTriage.classify(a, context: context)
                out[a.id] = decision == .tooBig ? .tooBig : .notSaved(decision)
            }
        }
        return out
    }

    /// Saves the attachments of `message`, which must already be in the brain (`addMailMessages`). See
    /// `AttachmentSaveMode`. `provider`/`attachments` default to the account's provider and its list; `claudeTriage`
    /// to `/triage-attachments`. Never deletes, moves nor marks anything in the mailbox.
    @discardableResult
    func saveAttachments(for message: MailMessageFull, account: ConnectedAccount, mode: AttachmentSaveMode,
                         provider: MailCalendarProvider? = nil, attachments: [AttachmentInfo]? = nil,
                         claudeTriage: AttachmentClaudeTriage? = nil) async throws -> AttachmentSaveReport {
        let externalId = MailImport.externalId(account: account, messageId: message.summary.id)
        guard let email = emailSource(externalId: externalId), email.threadKey != nil else {
            throw EngineError.sourceNotFound(externalId)
        }
        let provider = provider ?? accounts.provider(for: account)
        let list: [AttachmentInfo]
        if let attachments { list = attachments } else { list = try await provider.listAttachments(messageId: message.summary.id) }
        var report = AttachmentSaveReport()
        guard !list.isEmpty else { return report }
        let store = discardedStore
        store.expire()
        Self.sweepAttachmentStaging(dataRoot: paths.root)

        let states = attachmentStates(messageSourceId: email.id, attachments: list, inlineContentIds: message.inlineContentIds)
        let context = AttachmentTriage.Context(inlineContentIds: message.inlineContentIds.map(Set.init))
        let chosen: Set<String>? = { if case .confirmed(let ids) = mode { return Set(ids) } else { return nil } }()
        let project = threadFolder(email.threadKey ?? "").flatMap(VaultStore.projectSlug(of:))
        let duplicateDirs = [rawDir(.document, project), rawDir(.image, project)]
        var taken: Set<String>?
        var ambiguous: [(info: AttachmentInfo, data: Data, hash: String)] = []

        for info in list {
            if Task.isCancelled { break }
            let wanted = chosen.map { $0.contains(info.id) }
            var fromStore: DiscardedItem?
            switch states[info.id] {
            case .saved, .notAFile:
                report.skipped.append(info)
                continue
            case .discarded(let item):
                // Backwards, ticking a discarded one brings it back (its bytes are already here); otherwise it stays.
                guard wanted == true else { report.skipped.append(info); continue }
                fromStore = item
            default: break
            }
            if wanted == false {
                // Unticked in the save sheet: not downloaded; it stays in the mailbox ("No guardado").
                report.skipped.append(info)
                continue
            }
            let decision = AttachmentTriage.classify(info, context: context)
            if decision == .tooBig, wanted != true {
                report.tooBig.append(info)
                continue
            }
            var data: Data?
            if let item = fromStore {
                let url = store.fileURL(of: item)
                data = await Task.detached { try? Data(contentsOf: url) }.value
            }
            if data == nil {
                do {
                    data = try await provider.downloadAttachment(messageId: message.summary.id, id: info.id)
                } catch {
                    if Task.isCancelled || error is CancellationError { break }
                    Log.error("attachments: could not download \(info.name): \(error)")
                    report.failed.append(info.name)   // a discarded one stays in Descartados
                    continue
                }
            }
            guard let data else { continue }
            // Hashing and the duplicate check read files: off the main thread.
            let vault = self.vault
            let (hash, duplicate) = await Task.detached(priority: .utility) { () -> (String, Bool) in
                let hash = AttachmentTriage.sha256(data)
                return (hash, Self.savedAlready(hash: hash, size: data.count, project: project, vault: vault, dirs: duplicateDirs))
            }.value
            if duplicate {
                if fromStore == nil {
                    discard(info, data: data, reason: .duplicate, email: email, into: store, report: &report)
                } else {
                    report.skipped.append(info)   // already saved: the discarded copy stays where it is
                }
                continue
            }
            switch (wanted, decision) {
            case (.some(true), _), (nil, .keep), (nil, .tooBig):
                if await save(info, data: data, hash: hash, email: email, taken: &taken, report: &report), let item = fromStore {
                    store.delete(id: item.id)   // only once it is safely saved
                }
            case (nil, .discard(let r)):
                discard(info, data: data, reason: r, email: email, into: store, report: &report)
            case (nil, .ask):
                ambiguous.append((info, data, hash))
            case (.some(false), _):
                report.skipped.append(info)
            }
        }

        // Forward: Claude settles the ambiguous ones, looking at the email and the files (read-only).
        if !ambiguous.isEmpty {
            let fm = FileManager.default
            let folder = paths.root.appendingPathComponent(Self.attachmentStagingFolder).appendingPathComponent(UUID().uuidString)
            // Each candidate gets a name of its own (two `image.png` become `image.png` and `image (2).png`), so a verdict
            // can only be about one file.
            var names: [String] = []
            for item in ambiguous {
                var name = item.info.name, n = 2
                while names.contains(name) {
                    let ext = (item.info.name as NSString).pathExtension
                    let stem = (item.info.name as NSString).deletingPathExtension
                    name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
                    n += 1
                }
                names.append(name)
            }
            var candidates: [AttachmentTriageCandidate] = []
            var staged: [Int] = []   // index into `ambiguous` of each candidate
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                Log.error("attachments: could not stage files for Claude: \(error)")
            }
            for (i, item) in ambiguous.enumerated() {
                let sub = folder.appendingPathComponent("\(i + 1)")
                let file = sub.appendingPathComponent(DiscardedStore.safeName(item.info.name))
                do {
                    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    try item.data.write(to: file)
                    candidates.append(.init(name: names[i], path: file.path, mime: item.info.mimeType, size: item.data.count))
                    staged.append(i)
                } catch {
                    Log.error("attachments: could not stage \(item.info.name) for Claude (kept): \(error)")
                }
            }
            let triage = claudeTriage ?? defaultClaudeAttachmentTriage()
            let verdicts = candidates.isEmpty ? nil : await triage(email.rawPath ?? "", candidates, folder)
            try? fm.removeItem(at: folder)
            if verdicts == nil { Log.info("attachments: no answer from Claude for \(ambiguous.count) file(s): kept") }
            // By name; by position only when Claude answered every file and none of the names matches.
            let byPosition = verdicts.map { v in
                v.count == candidates.count && !v.contains { verdict in candidates.contains { $0.name == verdict.name } }
            } ?? false
            for (i, item) in ambiguous.enumerated() {
                var verdict: AttachmentTriageVerdict?
                if let c = staged.firstIndex(of: i), let verdicts {
                    verdict = verdicts.first { $0.name == candidates[c].name } ?? (byPosition ? verdicts[c] : nil)
                }
                if let verdict, !verdict.keep {
                    let reason = verdict.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    discard(item.info, data: item.data, reason: .claude(reason), email: email, into: store, report: &report)
                } else {
                    await save(item.info, data: item.data, hash: item.hash, email: email, taken: &taken, report: &report)
                }
            }
        }
        if !report.saved.isEmpty || !report.discarded.isEmpty {
            Log.info("attachments of \(email.id): \(report.saved.count) saved, \(report.discarded.count) discarded, \(report.tooBig.count) too big")
        }
        return report
    }

    /// Forward helper for the auto-import cycle (§17.5): the attachments of just-added messages, automatic mode, in
    /// silence (a failure is logged; the messages stay added).
    func saveNewAttachments(for messages: [MailMessageFull], account: ConnectedAccount,
                            provider: MailCalendarProvider? = nil) async {
        for message in messages where message.summary.hasAttachments {
            do {
                try await saveAttachments(for: message, account: account, mode: .automatic, provider: provider)
            } catch {
                Log.error("attachments: \(message.summary.id) of \(account.id): \(error)")
            }
        }
    }

    /// "Rescatar" (Archivos › Descartados): imports the item as if it had been saved — back into its thread when it
    /// still exists, else as a document/image of its project. Returns the new source. The item leaves Descartados only
    /// once it is imported: when the import fails it is still there to try again.
    @discardableResult
    func rescueDiscarded(id: String) async throws -> SourceRecord? {
        let store = discardedStore
        guard let item = store.item(id: id) else { return nil }
        let file = store.fileURL(of: item)
        guard FileManager.default.fileExists(atPath: file.path) else {
            store.delete(id: id)
            return nil
        }
        let data = try await Task.detached { try Data(contentsOf: file) }.value
        let info = AttachmentInfo(id: item.attachmentId ?? item.id, name: item.name, mimeType: item.mimeType ?? "application/octet-stream",
                                  size: data.count)
        if let parent = item.messageSourceId.flatMap(source), parent.threadKey != nil, let raw = parent.rawPath,
           FileManager.default.fileExists(atPath: vault.url(for: raw).path) {
            var report = AttachmentSaveReport()
            var taken: Set<String>?
            let hash = await Task.detached { AttachmentTriage.sha256(data) }.value
            await save(info, data: data, hash: hash, email: parent, taken: &taken, report: &report)
            if let sid = report.sourceIds.first {
                store.delete(id: id)
                return source(sid)
            }
            if !report.failed.isEmpty { throw EngineError.rawMissing(item.name) }
        }
        // No thread to go back to: a plain import into the project (or Sin asignar).
        let project = validProject(item.project)
        let kind: SourceKind = AttachmentTriage.isImage(info) ? .image : .document
        let imported = try Importer.importFile(file, into: rawDir(kind, project), project: project, title: item.name)
        store.delete(id: id)
        var src = SourceRecord(id: imported.sourceId, kind: kind, title: imported.title, projectSlug: project, status: .queued,
                               rawPath: imported.rawURL.relativePath(from: vault.root))
        src.eventDate = imported.eventDate
        enqueueAfterRaw(&src)
        return src
    }

    /// "Eliminar ya".
    func deleteDiscarded(id: String) { discardedStore.delete(id: id) }

    // MARK: Internals

    /// After deleting an attachment's file: its text sidecar and its `_thread.json` entry go too.
    internal func forgetAttachment(rawPath: String) {
        let fm = FileManager.default
        try? fm.removeItem(at: DocumentText.sidecarURL(for: vault.url(for: rawPath)))
        let parts = rawPath.components(separatedBy: "/attachments/")
        guard parts.count == 2 else { return }
        let dir = vault.url(for: parts[0])
        guard var meta = ThreadMeta.load(from: dir) else { return }
        meta.attachments?.removeAll { $0.file == rawPath }
        try? meta.save(to: dir)
    }

    /// The thread folder of `key` (vault-relative), or nil.
    internal func threadFolder(_ key: String) -> String? {
        vault.threadFolders().first { ($0 as NSString).lastPathComponent == key }
    }

    /// Same bytes already saved in the project (or Sin asignar): an attachment of any of its threads, or a file in its
    /// `raw/docs` / `raw/assets` (`dirs`) of the same size. Reads files: call it off the main thread.
    nonisolated static func savedAlready(hash: String, size: Int, project: String?, vault: VaultStore, dirs: [URL]) -> Bool {
        for folder in vault.threadFolders() where VaultStore.projectSlug(of: folder) == project {
            if let meta = ThreadMeta.load(from: vault.url(for: folder)), meta.attachments?.contains(where: { $0.sha256 == hash }) == true {
                return true
            }
        }
        let fm = FileManager.default
        for dir in dirs {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") && !name.hasSuffix(".md") {
                let url = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path), (attrs[.size] as? Int) == size,
                      let data = try? Data(contentsOf: url) else { continue }
                if AttachmentTriage.sha256(data) == hash { return true }
            }
        }
        return false
    }

    internal func isSavedAlready(hash: String, size: Int, project: String?) -> Bool {
        Self.savedAlready(hash: hash, size: size, project: project, vault: vault,
                          dirs: [rawDir(.document, project), rawDir(.image, project)])
    }

    /// Where ambiguous attachments wait while Claude looks at them (`<data>/attachments-pending/<uuid>/`).
    nonisolated static let attachmentStagingFolder = "attachments-pending"

    /// Staging folders left behind by a quit or a crash while Claude was looking (older than `age`) are deleted.
    nonisolated static func sweepAttachmentStaging(dataRoot: URL, age: TimeInterval = 3_600, now: Date = Date()) {
        let fm = FileManager.default
        let dir = dataRoot.appendingPathComponent(attachmentStagingFolder)
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] {
            let url = dir.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) > age { try? fm.removeItem(at: url) }
        }
    }

    private func discard(_ info: AttachmentInfo, data: Data, reason: DiscardReason, email: SourceRecord, into store: DiscardedStore,
                         report: inout AttachmentSaveReport) {
        let from = email.rawPath.flatMap { try? vault.read($0) }.flatMap { Frontmatter.field("from", in: $0) }
        var item = DiscardedItem(name: info.name, size: data.count, mimeType: info.mimeType, from: from?.nonEmptyString,
                                 threadKey: email.threadKey, messageSourceId: email.id,
                                 project: email.threadKey.flatMap(threadFolder).flatMap(VaultStore.projectSlug(of:)), reason: reason)
        item.attachmentId = info.id
        do {
            report.discarded.append(try store.add(item, data: data))
        } catch {
            Log.error("attachments: could not keep \(info.name) in Descartados: \(error)")
            report.failed.append(info.name)
        }
    }

    /// Writes the file next to its thread (with its text copy, off the main thread), lists it in `_thread.json` and
    /// creates its source. `taken` = page names already used (computed once per call, off the main thread). Returns
    /// whether it was saved.
    @discardableResult
    private func save(_ info: AttachmentInfo, data: Data, hash: String, email: SourceRecord, taken: inout Set<String>?,
                      report: inout AttachmentSaveReport) async -> Bool {
        guard let key = email.threadKey, let folder = threadFolder(key), let raw = email.rawPath else {
            report.failed.append(info.name)
            return false
        }
        let messageFile = (raw as NSString).lastPathComponent
        let messageDir = (messageFile as NSString).deletingPathExtension
        let dirRel = "\(folder)/attachments/\(messageDir)"
        let dir = vault.url(for: dirRel)
        if taken == nil { taken = await attachmentNamesTaken() }
        var names = taken ?? []
        let file = uniqueAttachmentURL(in: dir, name: info.name, taken: names)
        names.insert(Self.stem(file.path))
        taken = names
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try data.write(to: file, options: .withoutOverwriting)
                _ = DocumentText.writeSidecar(for: file)   // textutil / unzip: never on the main thread
            }.value
        } catch {
            Log.error("attachments: could not save \(info.name) in \(dirRel): \(error)")
            report.failed.append(info.name)
            return false
        }
        // The thread may have moved (assigned to a project) while the file was written: write next to it again.
        guard let folderNow = threadFolder(key), folderNow == folder else {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: DocumentText.sidecarURL(for: file))
            report.failed.append(info.name)
            return false
        }
        let project = VaultStore.projectSlug(of: folder)
        let rel = "\(dirRel)/\(file.lastPathComponent)"
        let id = SessionManifest.newId()
        var entry = ThreadAttachment(file: rel, message: messageFile, name: info.name,
                                     mime: info.mimeType, size: data.count, sha256: hash, sourceId: id)
        entry.attachmentId = info.id
        do {
            // Re-read right before writing: an email may have been added to the thread meanwhile.
            var meta = vault.threadMeta(at: folder) ?? ThreadMeta(key: key, subject: email.title, participants: [], messages: [],
                                                                  createdAt: Date())
            meta.attachments = (meta.attachments ?? []) + [entry]
            try meta.save(to: vault.url(for: folder))
        } catch {
            Log.error("attachments: could not list \(info.name) in _thread.json of \(key): \(error)")
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: DocumentText.sidecarURL(for: file))
            report.failed.append(info.name)
            return false
        }
        var src = SourceRecord(id: id, kind: AttachmentTriage.isImage(info) ? .image : .document, title: info.name,
                               projectSlug: project, status: .queued, rawPath: rel)
        src.eventDate = email.eventDate ?? email.createdAt
        src.threadKey = key
        src.parentSourceId = email.id
        if project != nil {
            enqueueAfterRaw(&src)
        } else {
            // Sin asignar: it waits for its thread (assigning the thread moves and queues it; no classify of its own).
            src.status = .needsProject
            upsert(&src)
        }
        report.saved.append(entry)
        report.sourceIds.append(id)
        return true
    }

    nonisolated private static func stem(_ path: String) -> String {
        ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
    }

    /// Page names in use (every markdown file of the vault, walked off the main thread) and the files of other
    /// attachments and images: a saved attachment's page `wiki/sources/<slug>.md` never collides with another one.
    private func attachmentNamesTaken() async -> Set<String> {
        let vault = self.vault
        var taken = await Task.detached(priority: .utility) { Set(vault.allMarkdown().map(Self.stem)) }.value
        for src in sources where src.parentSourceId != nil || src.kind == .image { if let r = src.rawPath { taken.insert(Self.stem(r)) } }
        return taken
    }

    /// `<dir>/<slug>.<ext>`, the slug not in `taken` nor a file of `dir`.
    private func uniqueAttachmentURL(in dir: URL, name: String, taken: Set<String>) -> URL {
        let safe = DiscardedStore.safeName(name)
        let ext = (safe as NSString).pathExtension.lowercased()
        var base = slugify((safe as NSString).deletingPathExtension, maxLength: 60)
        if base.isEmpty { base = "adjunto" }
        var candidate = base, n = 2
        let fm = FileManager.default
        while taken.contains(candidate) || fm.fileExists(atPath: dir.appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)").path) {
            candidate = "\(base)-\(n)"
            n += 1
        }
        return dir.appendingPathComponent(ext.isEmpty ? candidate : "\(candidate).\(ext)")
    }

    /// `/triage-attachments` (read-only, the staged files readable through `--add-dir`): `[{name, keep, reason}]`.
    func defaultClaudeAttachmentTriage() -> AttachmentClaudeTriage {
        let claude = self.claude
        let model = config.ingestModel
        return { emailRaw, candidates, folder in
            let body: [String: Any] = [
                "email": emailRaw,
                "attachments": candidates.map { ["name": $0.name, "path": $0.path, "mime": $0.mime, "size": $0.size] },
            ]
            guard let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                return nil
            }
            do {
                for try await event in claude.run(command: "triage-attachments", arguments: String(decoding: json, as: UTF8.self),
                                                  mode: .readOnly, model: model, extraDirs: [folder]) {
                    if case .done(let result, let isError) = event {
                        return isError ? nil : BrainEngine.parseAttachmentTriage(result)
                    }
                }
            } catch {
                Log.error("attachments: /triage-attachments failed: \(error)")
            }
            return nil
        }
    }

    /// The last JSON array in Claude's answer → verdicts (nil when there is none).
    nonisolated static func parseAttachmentTriage(_ text: String) -> [AttachmentTriageVerdict]? {
        var search = text[...]
        while let close = search.lastIndex(of: "]") {
            var open = search[..<close].lastIndex(of: "[")
            while let o = open {
                let slice = text[o...close]
                if let data = slice.data(using: .utf8),
                   let array = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    let verdicts = array.compactMap { obj -> AttachmentTriageVerdict? in
                        guard let name = obj["name"] as? String else { return nil }
                        let keep = (obj["keep"] as? Bool) ?? ((obj["keep"] as? String).map { $0.lowercased() == "true" } ?? true)
                        return AttachmentTriageVerdict(name: name, keep: keep, reason: obj["reason"] as? String)
                    }
                    return verdicts
                }
                open = text[..<o].lastIndex(of: "[")
            }
            search = text[..<close]
        }
        return nil
    }
}
