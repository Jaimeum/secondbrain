import Foundation

// v0.2 engine pieces (CONTRACT §11): event dates, reformat / make-template jobs, vault migration.

public extension BrainEngine {
    // MARK: Dates

    /// Corrects when a source happened: updates the raw `date:` (documented exception to raw immutability, like
    /// `assign`) and, if it was already learned, re-learns it in place so the wiki moves it in the timeline.
    func setEventDate(sourceId: String, date: Date) throws {
        guard var src = source(sourceId) else { throw EngineError.sourceNotFound(sourceId) }
        guard date > Date(timeIntervalSince1970: 0), date < Date().addingTimeInterval(400 * 86_400) else { throw EngineError.invalidDate }
        guard !runningAnywhere({ $0.sourceId == sourceId && $0.kind != .classify }) else { throw EngineError.busy }
        src.eventDate = date
        let fm = FileManager.default
        var hasRaw = false
        if let raw = src.rawPath, fm.fileExists(atPath: vault.url(for: raw).path) {
            hasRaw = true
            let url = vault.url(for: raw)
            let text = try String(contentsOf: url, encoding: .utf8)
            try Frontmatter.setField("date", to: SBDate.iso(date), in: text).write(to: url, atomically: true, encoding: .utf8)
            if src.kind == .email {
                let dir = url.deletingLastPathComponent()
                if var meta = ThreadMeta.load(from: dir), let i = meta.messages.firstIndex(where: { $0.file == url.lastPathComponent }) {
                    meta.messages[i].date = date
                    meta.messages.sort { ($0.date ?? .distantFuture) < ($1.date ?? .distantFuture) }
                    try? meta.save(to: dir)
                }
            }
        } else if src.kind == .meeting {
            // Not transcribed yet: the transcript will be written with this date; an imported file's own metadata
            // must not override it.
            let dir = sessionDir(src.id)
            if var media = MediaImport.load(from: dir) {
                media.eventDateFromUser = true
                try? media.save(to: dir)
            }
        }
        upsert(&src)
        Log.info("event date of \(sourceId) set to \(SBDate.iso(date))")
        // Learned already: learn again in place (the ingest prompt treats it as a re-ingest).
        if hasRaw, src.historyId != nil, src.projectSlug != nil,
           !queue.jobs.contains(where: { $0.sourceId == sourceId && $0.kind == .ingest && $0.status == .queued }) {
            src.status = .queued
            upsert(&src)
            enqueue(Job(kind: .ingest, sourceId: sourceId, projectSlug: src.projectSlug))
        }
    }

    /// Vault-relative wiki page of a source (meeting page, source page or email-thread page), if it exists.
    func pagePath(forSourceId id: String) -> String? {
        guard let src = source(id) else { return nil }
        return pagePath(for: src)
    }

    /// Clears `migrationNotice` (the user read it).
    func dismissMigrationNotice() { migrationNotice = nil }
}

extension BrainEngine {
    func pagePath(for src: SourceRecord) -> String? {
        guard let slug = src.projectSlug, let raw = src.rawPath else { return nil }
        let key = ((raw as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidate: String
        switch src.kind {
        case .meeting: candidate = "projects/\(slug)/wiki/meetings/\(key).md"
        case .email: candidate = "projects/\(slug)/wiki/emails/\(src.threadKey ?? key).md"
        case .document, .note, .url: candidate = "projects/\(slug)/wiki/sources/\(key).md"
        }
        if FileManager.default.fileExists(atPath: vault.url(for: candidate).path) { return candidate }
        let wanted = ((candidate as NSString).lastPathComponent).lowercased()
        return vault.markdownFiles(under: "projects/\(slug)/wiki").first { ($0 as NSString).lastPathComponent.lowercased() == wanted }
    }

    // MARK: Jobs

    func runReformat(_ job: Job) async throws {
        guard var src = job.sourceId.flatMap(source) else { throw EngineError.sourceNotFound(job.sourceId ?? "") }
        guard let raw = src.rawPath, FileManager.default.fileExists(atPath: vault.url(for: raw).path) else {
            throw EngineError.rawMissing(src.rawPath ?? src.id)
        }
        let templateId = job.payload["templateId"] ?? ""
        guard vault.template(id: templateId) != nil else {
            throw EngineError.invalidTemplate(lang.t("No encontré ese formato.", "Format not found."))
        }
        let args = claudeArguments(raw: raw, templateId: templateId)
        _ = try await tracked(job, title: lang.t("Reformateó: \(src.title)", "Reformatted: \(src.title)"), kind: .reformat,
                              sourceId: src.id, projectSlug: src.projectSlug) {
            try await self.runClaude(job, command: "reformat", arguments: args, mode: .edit, model: self.config.ingestModel)
        }
        src = source(src.id) ?? src
        src.templateId = templateId
        upsert(&src)
    }

    func runMakeTemplate(_ job: Job) async throws {
        let name = job.payload["name"] ?? ""
        let body: [String: String] = ["name": name, "id": job.payload["id"] ?? slugify(name),
                                      "description": job.payload["description"] ?? ""]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        _ = try await tracked(job, title: lang.t("Creó el formato: \(name)", "Created the format: \(name)"), kind: .makeTemplate,
                              sourceId: nil, projectSlug: nil) {
            try await self.runClaude(job, command: "make-template", arguments: args, mode: .edit, model: self.config.ingestModel)
        }
    }

    // MARK: Migration

    /// Installs or upgrades the vault template (CONTRACT §11.6) and sets `migrationNotice` when the user must act.
    func migrateVault() {
        do {
            let result = try vault.migrateIfNeeded()
            if result.fromVersion != result.toVersion {
                Log.info("vault upgraded \(result.fromVersion) → \(result.toVersion): \(result.copied.count) files added, "
                         + "\(result.updatedCommands.count) commands updated, CLAUDE.md \(result.replacedClaudeMd ? "replaced" : "kept")")
            }
            if let manual = result.pendingManual {
                migrationNotice = lang.t(
                    "Actualicé tu cerebro. Como habías cambiado las instrucciones (CLAUDE.md), las dejé como estaban y guardé las nuevas en «\(manual)»: compáralas y combínalas cuando puedas (luego borra «\(manual)»).",
                    "I updated your brain. Since you had changed the instructions (CLAUDE.md), I kept yours and saved the new ones as “\(manual)”: compare and merge them when you can (then delete “\(manual)”).")
            } else {
                migrationNotice = nil
            }
        } catch {
            Log.error("could not install/upgrade the vault template: \(error)")
        }
    }

    /// v0.1 sources have no `eventDate`: take it from the raw `date:`, else the session's `startedAt`, else `createdAt`.
    func migrateSourceDates() {
        for var src in sources where src.eventDate == nil && src.status != .recording {
            var date: Date?
            if let raw = src.rawPath, let text = try? vault.read(raw), let value = Frontmatter.field("date", in: text) {
                date = SBDate.parseISO(value)?.date
            }
            if date == nil, src.kind == .meeting, let m = try? SessionManifest.load(from: sessionDir(src.id)) { date = m.startedAt }
            src.eventDate = date ?? src.createdAt
            upsert(&src)
        }
    }
}
