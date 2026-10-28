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
    /// Backwards: exactly these attachment ids are saved (the save sheet's ticks, "Guardar", "Guardar de todos modos");
    /// the rest of the downloadable ones go to Descartados.
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
        var out: [String: AttachmentState] = [:]
        for a in attachments {
            if let s = saved.first(where: { $0.name == a.name }) {
                out[a.id] = .saved(s)
            } else if let d = discarded.first(where: { $0.name == DiscardedStore.safeName(a.name) }) {
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

        let states = attachmentStates(messageSourceId: email.id, attachments: list, inlineContentIds: message.inlineContentIds)
        let context = AttachmentTriage.Context(inlineContentIds: message.inlineContentIds.map(Set.init))
        let chosen: Set<String>? = { if case .confirmed(let ids) = mode { return Set(ids) } else { return nil } }()
        var ambiguous: [(info: AttachmentInfo, data: Data)] = []

        for info in list {
            if Task.isCancelled { break }
            switch states[info.id] {
            case .saved, .notAFile:
                report.skipped.append(info)
                continue
            case .discarded(let item):
                // Backwards, ticking a discarded one brings it back; otherwise it stays where it is.
                guard chosen?.contains(info.id) == true else { report.skipped.append(info); continue }
                store.delete(id: item.id)
            default: break
            }
            let decision = AttachmentTriage.classify(info, context: context)
            let wanted = chosen.map { $0.contains(info.id) }
            if decision == .tooBig, wanted != true {
                report.tooBig.append(info)
                continue
            }
            let data: Data
            do {
                data = try await provider.downloadAttachment(messageId: message.summary.id, id: info.id)
            } catch {
                if Task.isCancelled || error is CancellationError { break }
                Log.error("attachments: could not download \(info.name): \(error)")
                report.failed.append(info.name)
                continue
            }
            let hash = AttachmentTriage.sha256(data)
            let project = threadFolder(email.threadKey ?? "").flatMap(VaultStore.projectSlug(of:))
            let duplicate = isSavedAlready(hash: hash, size: data.count, project: project)
            switch (wanted, decision) {
            case (.some(false), let d):
                // Unticked in the save sheet: kept 30 days in Descartados, with the rules' reason when they had one.
                var reason = DiscardReason.user
                if case .discard(let r) = d { reason = r }
                discard(info, data: data, reason: duplicate ? .duplicate : reason, email: email, into: store, report: &report)
            case (_, _) where duplicate:
                discard(info, data: data, reason: .duplicate, email: email, into: store, report: &report)
            case (.some(true), _), (nil, .keep), (nil, .tooBig):
                save(info, data: data, hash: hash, email: email, report: &report)
            case (nil, .discard(let r)):
                discard(info, data: data, reason: r, email: email, into: store, report: &report)
            case (nil, .ask):
                ambiguous.append((info, data))
            }
        }

        // Forward: Claude settles the ambiguous ones, looking at the email and the files (read-only).
        if !ambiguous.isEmpty {
            let fm = FileManager.default
            let folder = paths.root.appendingPathComponent("attachments-pending").appendingPathComponent(UUID().uuidString)
            var candidates: [AttachmentTriageCandidate] = []
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
                for (i, item) in ambiguous.enumerated() {
                    let sub = folder.appendingPathComponent("\(i + 1)")
                    try fm.createDirectory(at: sub, withIntermediateDirectories: true)
                    let file = sub.appendingPathComponent(DiscardedStore.safeName(item.info.name))
                    try item.data.write(to: file)
                    candidates.append(.init(name: item.info.name, path: file.path, mime: item.info.mimeType, size: item.data.count))
                }
            } catch {
                Log.error("attachments: could not stage files for Claude: \(error)")
            }
            let triage = claudeTriage ?? defaultClaudeAttachmentTriage()
            let verdicts = candidates.count == ambiguous.count
                ? await triage(email.rawPath ?? "", candidates, folder) : nil
            try? fm.removeItem(at: folder)
            if verdicts == nil { Log.info("attachments: no answer from Claude for \(ambiguous.count) file(s): kept") }
            for (i, item) in ambiguous.enumerated() {
                let verdict = verdicts?.first { $0.name == item.info.name } ?? (verdicts?.indices.contains(i) == true ? verdicts?[i] : nil)
                if let verdict, !verdict.keep {
                    let reason = verdict.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    discard(item.info, data: item.data, reason: .claude(reason), email: email, into: store, report: &report)
                } else {
                    save(item.info, data: item.data, hash: AttachmentTriage.sha256(item.data), email: email, report: &report)
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
    /// still exists, else as a document/image of its project. Returns the new source.
    @discardableResult
    func rescueDiscarded(id: String) throws -> SourceRecord? {
        guard let (item, file) = try discardedStore.rescue(id: id) else { return nil }
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let data = try Data(contentsOf: file)
        let info = AttachmentInfo(id: item.id, name: item.name, mimeType: item.mimeType ?? "application/octet-stream", size: data.count)
        if let parent = item.messageSourceId.flatMap(source), parent.threadKey != nil, let raw = parent.rawPath,
           FileManager.default.fileExists(atPath: vault.url(for: raw).path) {
            var report = AttachmentSaveReport()
            save(info, data: data, hash: AttachmentTriage.sha256(data), email: parent, report: &report)
            if let sid = report.sourceIds.first { return source(sid) }
            if !report.failed.isEmpty { throw EngineError.rawMissing(item.name) }
        }
        // No thread to go back to: a plain import into the project (or Sin asignar).
        let project = validProject(item.project)
        let kind: SourceKind = AttachmentTriage.isImage(info) ? .image : .document
        let imported = try Importer.importFile(file, into: rawDir(kind, project), project: project, title: item.name)
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
    /// `raw/docs` / `raw/assets` of the same size.
    internal func isSavedAlready(hash: String, size: Int, project: String?) -> Bool {
        for folder in vault.threadFolders() where VaultStore.projectSlug(of: folder) == project {
            if let meta = ThreadMeta.load(from: vault.url(for: folder)), meta.attachments?.contains(where: { $0.sha256 == hash }) == true {
                return true
            }
        }
        let fm = FileManager.default
        for kind in [SourceKind.document, .image] {
            let dir = rawDir(kind, project)
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") && !name.hasSuffix(".md") {
                let url = dir.appendingPathComponent(name)
                guard let attrs = try? fm.attributesOfItem(atPath: url.path), (attrs[.size] as? Int) == size,
                      let data = try? Data(contentsOf: url) else { continue }
                if AttachmentTriage.sha256(data) == hash { return true }
            }
        }
        return false
    }

    private func discard(_ info: AttachmentInfo, data: Data, reason: DiscardReason, email: SourceRecord, into store: DiscardedStore,
                         report: inout AttachmentSaveReport) {
        let from = email.rawPath.flatMap { try? vault.read($0) }.flatMap { Frontmatter.field("from", in: $0) }
        let item = DiscardedItem(name: info.name, size: data.count, mimeType: info.mimeType, from: from?.nonEmptyString,
                                 threadKey: email.threadKey, messageSourceId: email.id,
                                 project: email.threadKey.flatMap(threadFolder).flatMap(VaultStore.projectSlug(of:)), reason: reason)
        do {
            report.discarded.append(try store.add(item, data: data))
        } catch {
            Log.error("attachments: could not keep \(info.name) in Descartados: \(error)")
            report.failed.append(info.name)
        }
    }

    /// Writes the file next to its thread, lists it in `_thread.json` and creates its source.
    private func save(_ info: AttachmentInfo, data: Data, hash: String, email: SourceRecord, report: inout AttachmentSaveReport) {
        guard let key = email.threadKey, let folder = threadFolder(key), let raw = email.rawPath else {
            report.failed.append(info.name)
            return
        }
        let fm = FileManager.default
        let messageFile = (raw as NSString).lastPathComponent
        let messageDir = (messageFile as NSString).deletingPathExtension
        let dirRel = "\(folder)/attachments/\(messageDir)"
        let dir = vault.url(for: dirRel)
        let project = VaultStore.projectSlug(of: folder)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let file = uniqueAttachmentURL(in: dir, name: info.name)
            try data.write(to: file, options: .withoutOverwriting)
            DocumentText.writeSidecar(for: file)
            let rel = "\(dirRel)/\(file.lastPathComponent)"
            let id = SessionManifest.newId()
            let entry = ThreadAttachment(file: rel, message: messageFile, name: info.name,
                                         mime: info.mimeType, size: data.count, sha256: hash, sourceId: id)
            // Re-read right before writing: an email may have been added to the thread meanwhile.
            var meta = vault.threadMeta(at: folder) ?? ThreadMeta(key: key, subject: email.title, participants: [], messages: [],
                                                                  createdAt: Date())
            meta.attachments = (meta.attachments ?? []) + [entry]
            try meta.save(to: vault.url(for: folder))
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
        } catch {
            Log.error("attachments: could not save \(info.name) in \(dirRel): \(error)")
            report.failed.append(info.name)
        }
    }

    /// `<dir>/<slug>.<ext>`, the slug unique among wiki page names and other attachments, so its page
    /// `wiki/sources/<slug>.md` never collides with another one.
    private func uniqueAttachmentURL(in dir: URL, name: String) -> URL {
        let safe = DiscardedStore.safeName(name)
        let ext = (safe as NSString).pathExtension.lowercased()
        var base = slugify((safe as NSString).deletingPathExtension, maxLength: 60)
        if base.isEmpty { base = "adjunto" }
        func stem(_ path: String) -> String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() }
        var taken = Set(vault.allMarkdown().map(stem))
        for src in sources where src.parentSourceId != nil || src.kind == .image { if let r = src.rawPath { taken.insert(stem(r)) } }
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
