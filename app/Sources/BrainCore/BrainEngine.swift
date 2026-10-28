import Foundation
import Observation

public enum EngineError: Error, LocalizedError {
    case sourceNotFound(String)
    case sessionMissing(String)
    case rawMissing(String)
    case busy
    case alreadyIngested
    case download(String)
    case taskNotFound(String)
    case invalidTemplate(String)
    case emptyEmail
    case duplicateEmail(String)
    case threadNotFound(String)
    case invalidDate

    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .sourceNotFound(let id): return lang.t("No encontré esa fuente (\(id)).", "Source not found: \(id)")
        case .sessionMissing: return lang.t("No encontré los archivos de audio de esta grabación.",
                                            "I couldn't find the audio files of this recording.")
        case .rawMissing(let path): return lang.t("No encontré el archivo original: \(path)", "Original file not found: \(path)")
        case .busy: return lang.t("Estoy trabajando en esto ahora mismo; inténtalo en un momento.",
                                  "I'm working on this right now; try again in a moment.")
        case .alreadyIngested: return lang.t("Ya aprendí de esta fuente. Deshaz ese cambio en Actividad para moverla.",
                                             "I already learned from this source. Undo that change in Activity to move it.")
        case .download(let msg): return msg
        case .taskNotFound(let text):
            return lang.t("No encontré el pendiente «\(text)»: puede que Claude lo haya cambiado. Vuelve a abrir la lista.",
                          "I couldn't find the task “\(text)”: Claude may have changed it. Reopen the list.")
        case .invalidTemplate(let msg): return msg
        case .emptyEmail: return lang.t("El correo está vacío.", "The email is empty.")
        case .duplicateEmail(let title):
            return lang.t("Ese correo ya estaba guardado (en «\(title)»).", "That email was already saved (in “\(title)”).")
        case .threadNotFound(let key): return lang.t("No encontré el hilo de correo «\(key)».", "Email thread not found: \(key)")
        case .invalidDate: return lang.t("Esa fecha no es válida.", "That date isn't valid.")
        }
    }
}

private final class ConfigBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: AppConfig
    init(_ value: AppConfig) { self.value = value }
    func get() -> AppConfig { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ v: AppConfig) { lock.lock(); value = v; lock.unlock() }
}

/// Façade used by the app and the `sb` CLI: sources, the persistent job queue and the
/// record → transcribe → ingest pipeline (CONTRACT §4, §5.3).
@MainActor @Observable public final class BrainEngine {
    public private(set) var config: AppConfig
    // `var` only so `reload(config:)` can rebind them; read them as before.
    public private(set) var paths: DataPaths
    public private(set) var vault: VaultStore
    public private(set) var projects: ProjectManager
    public private(set) var history: HistoryStore
    public private(set) var claude: ClaudeRunner
    /// v0.3: connected Microsoft 365 / Google accounts (CONTRACT §12.3).
    public let accounts: AccountStore
    // MARK: v0.4 github
    /// Followed GitHub repos per project (CONTRACT §13).
    public let github: GitHubStore
    // MARK: v0.4 routing
    /// Routing rules of the vault (`.secondbrain/routing.json`, CONTRACT §14).
    public let routing: RoutingStore
    /// The rule that decided the project of the last email added without an explicit project (nil = no rule did:
    /// default project or inbox). Set by `addEmail`/`addEmails`/`addMailMessages(…routeIfUnassigned:)`; transient.
    public var lastRoutingDecision: RoutingDecision?
    /// `addMailMessages(…, routeIfUnassigned: false)`: the wrapped call must not route.
    @ObservationIgnored var routingSuppressed = false
    public private(set) var sources: [SourceRecord] = []
    public private(set) var jobs: [Job] = []
    public private(set) var isProcessing = false
    /// Another process (the app or `sb run`) holds `data/queue.lock` and is processing the queue; this engine
    /// waits and retries on its own.
    public private(set) var queueBusyElsewhere = false
    public var onEvent: ((EngineEvent) -> Void)?
    /// Fires on every job change (status, progress, human message such as "Editando …").
    public var onJobUpdate: ((Job) -> Void)?
    /// When false the queue only runs through `runUntilIdle()` (CLI commands that just enqueue).
    public var autoProcess = true

    /// Set when opening the vault upgraded it and something needs the user's attention (e.g. their edited
    /// CLAUDE.md was kept and the new manual was written next to it). Human, localized; nil = nothing to say.
    public internal(set) var migrationNotice: String?

    @ObservationIgnored private var transcriber: Transcribing
    @ObservationIgnored private var sourceStore: SourceStore
    @ObservationIgnored var queue: JobQueue
    @ObservationIgnored private var queueLock: QueueLock
    @ObservationIgnored private let configBox: ConfigBox
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var started = false
    /// Set by `reload`: no new jobs start.
    @ObservationIgnored private var stopping = false
    /// `runUntilIdle` calls in progress (they hold the queue lock too).
    @ObservationIgnored private var activeRuns = 0
    /// Bumped on every local write of sources/jobs, so a background disk read never overwrites newer state.
    @ObservationIgnored var writeGeneration = 0
    @ObservationIgnored private var watchers: [DispatchSourceFileSystemObject] = []
    @ObservationIgnored private var syncTask: Task<Void, Never>?
    /// Started while another process owned the queue: crash repairs run when we first get the lock.
    @ObservationIgnored private var needsRepair = false

    var lang: Lang { Lang(config.uiLanguage) }

    public init(config: AppConfig, transcriber: Transcribing) {
        self.config = config
        self.transcriber = transcriber
        let paths = DataPaths(root: config.dataURL)
        self.paths = paths
        self.vault = VaultStore(root: config.vaultURL)
        self.projects = ProjectManager(vaultRoot: config.vaultURL)
        let history = HistoryStore(vaultRoot: config.vaultURL, historyDir: paths.history)
        history.gitEnabled = config.gitEnabled
        self.history = history
        let box = ConfigBox(config)
        self.configBox = box
        self.claude = ClaudeRunner(configProvider: { box.get() }, vaultURL: config.vaultURL)
        self.sourceStore = SourceStore(dir: paths.sources)
        self.queue = JobQueue(dir: paths.jobs)
        self.queueLock = QueueLock(url: paths.root.appendingPathComponent("queue.lock"))
        self.accounts = AccountStore(fileURL: paths.accounts)
        self.github = GitHubStore(paths: paths, configProvider: { box.get() })   // MARK: v0.4 github
        self.routing = RoutingStore(fileURL: RoutingStore.fileURL(vaultRoot: config.vaultURL))   // MARK: v0.4 routing
        Log.configure(logsDir: paths.logs)
        // MARK: v0.3 accounts — a connected address joins the owner's emails
        accounts.onConnected = { [weak self] in self?.rememberOwnerEmail(of: $0) }
    }

    // MARK: Lifecycle

    /// Creates folders, installs the vault template if missing, reloads state and resumes the queue.
    public func start() {
        guard !started else { return }
        started = true
        stopping = false
        do { try paths.ensureExist() } catch { Log.error("could not create data folders: \(error)") }
        migrateVault()
        // Crash repairs (stale `running` jobs, half-done sources) belong to whoever owns the queue: another
        // live process may be running those jobs right now.
        let owner = queueLock.tryLock()
        for entry in history.recoverInterrupted() { Log.info("recovered interrupted change \(entry.id): \(entry.title)") }
        sources = sourceStore.loadAll()
        migrateSourceDates()
        queue.load(resetRunning: owner)
        jobs = queue.jobs
        if owner { repairInterruptedSources() }
        needsRepair = !owner
        queueBusyElsewhere = !owner
        Log.info("engine started: \(sources.count) sources, \(jobs.count) jobs, vault=\(config.vaultURL.path)"
                 + (owner ? "" : " (queue owned by pid \(queueLock.holderPid().map(String.init) ?? "?"))"))
        if autoProcess { startWatching() }
        // MARK: v0.4 github — demo repos go under a project this vault has
        if github.isDemo, projects.get(GitHubDemo.projectSlug) == nil { github.adoptDemoProject(projects.list().first?.slug) }
        if !github.isDemo { github.markOrphans(knownProjects: Set(projects.list().map(\.slug))) }   // MARK: v0.4 github
        pruneHistory()
        kick()
        releaseQueueIfIdle()
    }

    /// Saves the config. A different vault/data path needs `reload(config:)` (or a new engine).
    public func updateConfig(_ c: AppConfig) throws {
        try c.save()
        config = c
        configBox.set(c)
        history.gitEnabled = c.gitEnabled
    }

    /// Switches to another config (vault/data paths included) without recreating the engine: stops taking jobs,
    /// waits for the running one to finish, releases the queue lock, rebinds every store to the new paths, saves
    /// the config and starts again if the engine was started. Pass a `transcriber` when the model or the data
    /// folder (where models live) changed. Interactive `ask` streams already running keep the old vault.
    public func reload(config newConfig: AppConfig, transcriber newTranscriber: Transcribing? = nil) async throws {
        try newConfig.save()
        let wasStarted = started
        stopping = true
        sleepTask?.cancel()
        while loopTask != nil || isProcessing || activeRuns > 0 {
            sleepTask?.cancel()
            try? await Task.sleep(for: .milliseconds(100))
        }
        stopWatching()
        syncTask?.cancel()
        syncTask = nil
        queueLock.unlock()

        config = newConfig
        configBox.set(newConfig)
        if let newTranscriber { transcriber = newTranscriber }
        let paths = DataPaths(root: newConfig.dataURL)
        self.paths = paths
        vault = VaultStore(root: newConfig.vaultURL)
        projects = ProjectManager(vaultRoot: newConfig.vaultURL)
        history = HistoryStore(vaultRoot: newConfig.vaultURL, historyDir: paths.history)
        history.gitEnabled = newConfig.gitEnabled
        let box = configBox
        claude = ClaudeRunner(configProvider: { box.get() }, vaultURL: newConfig.vaultURL)
        sourceStore = SourceStore(dir: paths.sources)
        queue = JobQueue(dir: paths.jobs)
        queueLock = QueueLock(url: paths.root.appendingPathComponent("queue.lock"))
        accounts.reload(fileURL: paths.accounts)
        github.reload(paths: paths)   // MARK: v0.4 github
        routing.reload(fileURL: RoutingStore.fileURL(vaultRoot: newConfig.vaultURL))   // MARK: v0.4 routing
        lastRoutingDecision = nil
        Log.configure(logsDir: paths.logs)
        writeGeneration += 1
        sources = []
        jobs = []
        queueBusyElsewhere = false
        started = false
        stopping = false
        Log.info("engine reloaded: vault=\(newConfig.vaultURL.path) data=\(newConfig.dataURL.path)")
        if wasStarted { start() }
    }

    /// Executable name of the process holding the queue lock ("sb", "SecondBrain"), if any.
    public func queueHolderName() -> String? { queueLock.holderName() }

    /// Re-reads sources and jobs from disk (changes made by `sb` or another window). The engine already does this
    /// when it takes the queue lock and when `data/sources` or `data/jobs` change while it runs `autoProcess`.
    public func refreshFromDisk() async {
        await syncFromDisk(resetRunning: false)
    }

    // MARK: Recording pipeline

    public func recordingStarted(_ m: SessionManifest) {
        var src = source(m.id) ?? SourceRecord(id: m.id, kind: .meeting, title: meetingTitle(m), projectSlug: m.projectSlug,
                                               status: .recording, createdAt: m.startedAt)
        src.status = .recording
        if src.eventDate == nil { src.eventDate = m.startedAt }
        upsert(&src)
    }

    /// The project picked for the recording in progress changed (menu bar, Reuniones chip): the source follows it, so
    /// "Sin proyecto" chosen mid-recording sends it to Inbox (`recordingFinished` only applies a non-nil slug).
    public func setRecordingProject(sourceId: String, projectSlug: String?) {
        guard var src = source(sourceId), src.status == .recording else { return }
        let slug = validProject(projectSlug)
        guard src.projectSlug != slug else { return }
        src.projectSlug = slug
        upsert(&src)
    }

    public func recordingFinished(_ m: SessionManifest) {
        var src = source(m.id) ?? SourceRecord(id: m.id, kind: .meeting, title: meetingTitle(m), projectSlug: m.projectSlug,
                                               status: .queued, createdAt: m.startedAt)
        if let title = m.title, !title.isEmpty { src.title = title }
        if let slug = m.projectSlug { src.projectSlug = slug }
        src.status = .queued
        src.error = nil
        if src.eventDate == nil { src.eventDate = m.startedAt }
        if let end = m.endedAt { src.durationSeconds = end.timeIntervalSince(m.startedAt) }
        upsert(&src)
        let id = src.id
        guard !queue.jobs.contains(where: { $0.sourceId == id && $0.kind == .transcribe && $0.status != .failed }) else { return }
        enqueue(Job(kind: .transcribe, sourceId: src.id, projectSlug: src.projectSlug))
    }

    // MARK: Imports

    /// Documents become raw files; audio/video (`AudioPrep.isMedia`) become meetings that get transcribed.
    public func importFile(_ url: URL, projectSlug: String?) throws {
        try importFile(url, projectSlug: projectSlug, eventDate: nil, templateId: nil)
    }

    /// `eventDate` = when it happened, if the user knows it (nil: a recording's own creation date, a document's
    /// date, CONTRACT §11.1). `templateId` = format for a recording's page (nil = default).
    public func importFile(_ url: URL, projectSlug: String?, eventDate: Date?, templateId: String? = nil) throws {
        let project = validProject(projectSlug)
        if AudioPrep.isMedia(url) {
            try importMedia(url, project: project, eventDate: eventDate, templateId: templateId)
            return
        }
        let imported = try Importer.importFile(url, into: rawDir(.document, project), project: project, eventDate: eventDate)
        addImported(kind: .document, imported, project: project, templateId: templateId)
    }

    /// `importFile` with the text extraction (PDF, DOCX…) off the main thread.
    public func importFileAsync(_ url: URL, projectSlug: String?) async throws {
        try await importFileAsync(url, projectSlug: projectSlug, eventDate: nil, templateId: nil)
    }

    public func importFileAsync(_ url: URL, projectSlug: String?, eventDate: Date?, templateId: String? = nil) async throws {
        let project = validProject(projectSlug)
        if await Task.detached(operation: { AudioPrep.isMedia(url) }).value {
            try importMedia(url, project: project, eventDate: eventDate, templateId: templateId)
            return
        }
        let dir = rawDir(.document, project)
        let imported = Importer.mainThreadText.contains(url.pathExtension.lowercased())
            ? try Importer.importFile(url, into: dir, project: project, eventDate: eventDate)
            : try await Task.detached(priority: .userInitiated) {
                try Importer.importFile(url, into: dir, project: project, eventDate: eventDate)
            }.value
        addImported(kind: .document, imported, project: project, templateId: templateId)
    }

    /// An audio/video file becomes a meeting: a session folder with `import.json` pointing at the file (plus an
    /// APFS clone when possible, so moving/deleting the original before the job runs doesn't matter). The WAV
    /// conversion happens at the start of the transcribe job, off the main thread. The original is never touched.
    private func importMedia(_ url: URL, project: String?, eventDate: Date? = nil, templateId: String? = nil) throws {
        let fm = FileManager.default
        guard fm.isReadableFile(atPath: url.path), !fm.isDirectory(url) else { throw EngineError.rawMissing(url.path) }
        let id = SessionManifest.newId()
        let dir = sessionDir(id)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var media = MediaImport(originalPath: url.path, clonedFile: nil, eventDateFromUser: eventDate != nil)
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension.lowercased()
        let clone = dir.appendingPathComponent(MediaImport.clonePrefix + ext)
        if clonefile(url.path, clone.path, 0) == 0 { media.clonedFile = clone.lastPathComponent }
        // The user's date, else the file's date for now; the transcribe job refines it from the recording's own
        // creation-date metadata (needs an async AVAsset load).
        let startedAt = eventDate ?? min(FileDates.fileDate(url) ?? Date(), Date())
        let title = url.deletingPathExtension().lastPathComponent
        do {
            try media.save(to: dir)
            // `endedAt` set so the recorder's crash recovery leaves it alone; fixed after conversion.
            try SessionManifest(id: id, title: title, projectSlug: project, startedAt: startedAt, endedAt: startedAt,
                                tracks: [:], micCaptured: false).save(to: dir)
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        var src = SourceRecord(id: id, kind: .meeting, title: title, projectSlug: project, status: .queued)
        src.eventDate = startedAt
        src.templateId = templateId
        upsert(&src)
        enqueue(Job(kind: .transcribe, sourceId: id, projectSlug: project))
        Log.info("imported media \(url.lastPathComponent) as meeting \(id) (clone: \(media.clonedFile != nil))")
    }

    public func importURL(_ url: URL, projectSlug: String?) async throws {
        try await importURL(url, projectSlug: projectSlug, eventDate: nil)
    }

    /// `eventDate` nil = the page's published date when it declares one, else now.
    public func importURL(_ url: URL, projectSlug: String?, eventDate: Date?) async throws {
        let project = validProject(projectSlug)
        let imported = try await Importer.importURL(url, into: rawDir(.url, project), project: project, eventDate: eventDate)
        addImported(kind: .url, imported, project: project, templateId: nil)
    }

    public func addNote(title: String, body: String, projectSlug: String?) throws {
        try addNote(title: title, body: body, projectSlug: projectSlug, eventDate: nil)
    }

    /// `eventDate` nil = now (when the note is written).
    public func addNote(title: String, body: String, projectSlug: String?, eventDate: Date?) throws {
        let project = validProject(projectSlug)
        let imported = try Importer.writeNote(title: title, body: body, into: rawDir(.note, project), project: project,
                                              eventDate: eventDate)
        addImported(kind: .note, imported, project: project, templateId: nil)
    }

    private func addImported(kind: SourceKind, _ imported: Importer.Imported, project: String?, templateId: String?) {
        var src = SourceRecord(id: imported.sourceId, kind: kind, title: imported.title, projectSlug: project, status: .queued,
                               rawPath: imported.rawURL.relativePath(from: vault.root))
        src.eventDate = imported.eventDate
        src.templateId = templateId
        enqueueAfterRaw(&src)
    }

    // MARK: Source actions

    /// Files a source under a project. Inbox raws move to the project (frontmatter `project:` updated) and get ingested.
    public func assign(sourceId: String, to projectSlug: String) throws {
        guard var src = source(sourceId) else { throw EngineError.sourceNotFound(sourceId) }
        guard projects.get(projectSlug) != nil else { throw ProjectError.notFound(projectSlug) }
        if src.kind == .email, let key = src.threadKey {
            try assignThread(key, to: projectSlug)   // the whole thread moves
            return
        }
        guard src.historyId == nil || src.status != .done else { throw EngineError.alreadyIngested }
        // A running classify only reads; its result is ignored once the source has a project.
        guard !runningAnywhere({ $0.sourceId == sourceId && $0.kind != .classify }) else { throw EngineError.busy }

        src.projectSlug = projectSlug
        src.suggestedProject = nil
        src.suggestionReason = nil
        guard let raw = src.rawPath else {
            upsert(&src)   // still recording/transcribing: the transcript will be written into the project
            return
        }
        if !raw.hasPrefix("projects/\(projectSlug)/") {
            src.rawPath = try moveRaw(raw, kind: src.kind, to: projectSlug)
        }
        removeJobs(for: sourceId) { $0.status != .running }
        src.status = .queued
        src.error = nil
        upsert(&src)
        enqueue(Job(kind: .ingest, sourceId: sourceId, projectSlug: projectSlug))
    }

    public func retry(sourceId: String) {
        guard var src = source(sourceId) else { return }
        guard !queue.jobs.contains(where: { $0.sourceId == sourceId && ($0.status == .queued || $0.status == .running) }) else {
            kick()
            return
        }
        removeJobs(for: sourceId) { _ in true }
        src.error = nil
        if let raw = src.rawPath, FileManager.default.fileExists(atPath: vault.url(for: raw).path) {
            enqueueAfterRaw(&src)
        } else if src.kind == .meeting, FileManager.default.fileExists(atPath: sessionDir(src.id).appendingPathComponent("session.json").path) {
            src.status = .queued
            upsert(&src)
            enqueue(Job(kind: .transcribe, sourceId: src.id, projectSlug: src.projectSlug))
        } else {
            src.status = .failed
            src.error = lang.t("No encontré los archivos de esta fuente.", "I couldn't find the files for this source.")
            upsert(&src)
        }
    }

    /// Removes the record, pending jobs and leftover audio. Raw files are kept once ingested.
    public func delete(sourceId: String) throws {
        guard let src = source(sourceId) else { throw EngineError.sourceNotFound(sourceId) }
        guard !runningAnywhere({ $0.sourceId == sourceId }) else { throw EngineError.busy }
        removeJobs(for: sourceId) { _ in true }
        let fm = FileManager.default
        let session = sessionDir(sourceId)
        if fm.fileExists(atPath: session.path) { try fm.removeItem(at: session) }
        if src.historyId == nil, let raw = src.rawPath {
            let url = vault.url(for: raw)
            if let text = try? String(contentsOf: url, encoding: .utf8), let original = Frontmatter.field("original_file", in: text) {
                try? fm.removeItem(at: url.deletingLastPathComponent().appendingPathComponent(original))
            }
            try? fm.removeItem(at: url)
            if src.kind == .email { forgetEmail(rawPath: raw) }
        }
        writeGeneration += 1
        sourceStore.delete(id: sourceId)
        sources.removeAll { $0.id == sourceId }
        Log.info("deleted source \(sourceId)")
    }

    // MARK: Claude operations

    /// Streams a read-only answer from the wiki (not queued: it is interactive).
    public func ask(_ question: String, projectSlug: String?) -> AsyncThrowingStream<ClaudeEvent, Error> {
        // MARK: v0.4 github — the followed repos' code checkouts are readable (`--add-dir`) and listed after the question.
        let checkouts = github.checkouts(project: projectSlug)
        return claude.run(command: "query", arguments: "scope=\(projectSlug ?? "global") | \(question)" + Self.reposBlock(checkouts),
                          mode: .readOnly, model: config.queryModel, extraDirs: checkouts.map(\.path))
    }

    /// `\n\nrepos:\n- owner/name@branch (sha, synced date) → /abs/path` (empty without checkouts). CONTRACT §13.5.
    public nonisolated static func reposBlock(_ checkouts: [RepoCheckout]) -> String {
        guard !checkouts.isEmpty else { return "" }
        let lines = checkouts.map { c in
            let sha = c.sha.map { String($0.prefix(7)) } ?? "?"
            let synced = c.syncedAt.map { SBDate.iso($0) } ?? "?"
            return "- \(c.repo)@\(c.branch) (\(sha), synced \(synced)) → \(c.path.path)"
        }
        return "\n\nrepos:\n" + lines.joined(separator: "\n")
    }

    /// An answer filed by Claude (`/save-answer`) in the folder of `projectSlug`'s scope (the project's
    /// `wiki/questions/`, or the global `questions/` when nil): never re-filed into another scope.
    public func saveAnswer(question: String, answer: String, projectSlug: String?) {
        enqueue(Job(kind: .saveAnswer, projectSlug: projectSlug,
                    payload: ["question": question, "answer": answer, "scope": projectSlug == nil ? "brain" : "project"]))
    }

    /// "Guardar como página" (§16.3): the page is written at once in `scope`'s folder (one undoable Historial entry,
    /// so it shows in Contenido and ⌘K right away), then `/save-answer` links it from the indexes, the logs and the
    /// related pages (its own Historial entry). Returns the page's path. Refused with `EngineError.busy` while Claude is
    /// editing the brain (the running job's entry would swallow the page and its undo would delete it).
    @discardableResult
    public func saveAnswer(question: String, answer: String, scope: Scope) throws -> String {
        guard !claudeIsEditing else { throw EngineError.busy }
        let short = ChatStore.title(forQuestion: question)
        let title = lang.t("Guardé una respuesta: «\(short)»", "Saved an answer: “\(short)”")
        let path = SavedAnswers.newPath(question: question, scope: scope, vault: vault)
        let entry = try history.recordManualEdit(title: title, projectSlug: scope.projectSlug, path: path, before: nil,
                                                 after: SavedAnswers.page(question: question, answer: answer, scope: scope))
        onEvent?(.historyAdded(entry))
        enqueue(Job(kind: .saveAnswer, projectSlug: scope.projectSlug,
                    payload: ["question": question, "answer": answer, "path": path,
                              "scope": scope.projectSlug == nil ? "brain" : "project"]))
        return path
    }

    public func lint(projectSlug: String?) {
        enqueue(Job(kind: .lint, projectSlug: projectSlug))
    }

    /// Undoing an ingest also detaches it from its source, so the source can be learned from again
    /// (`retry`) or moved to another project.
    public func undo(historyId: String, force: Bool = false) throws {
        guard !runningAnywhere({ [.ingest, .lint, .saveAnswer, .reformat, .makeTemplate, .fileDump].contains($0.kind) }) else { throw EngineError.busy }
        try history.undo(entryId: historyId, force: force)
        // v0.7: a /file-dump entry belongs to every source of the drop.
        for var src in sources where src.historyId == historyId {
            src.historyId = nil
            upsert(&src)
        }
    }

    // MARK: Queue

    /// Processes the queue until nothing is runnable. Waits for retry backoffs that are due within
    /// five minutes; longer waits (e.g. a Claude usage limit) are left queued.
    /// Waits for the queue lock if another process holds it.
    public func runUntilIdle() async {
        _ = await runUntilIdle(waitForLock: true)
    }

    /// Like `runUntilIdle()`; with `waitForLock == false` it returns false right away (doing nothing) when another
    /// process is processing the queue.
    @discardableResult
    public func runUntilIdle(waitForLock: Bool) async -> Bool {
        if !started { start() }
        activeRuns += 1
        defer {
            activeRuns -= 1
            releaseQueueIfIdle()
        }
        while !(await acquireQueue()) {
            guard waitForLock, !stopping else { return false }
            try? await Task.sleep(for: .seconds(2))
        }
        while !stopping {
            if await runNext() { continue }
            if isProcessing {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            guard let wake = queue.nextWakeDate(), wake.timeIntervalSinceNow < 300 else { break }
            try? await Task.sleep(for: .seconds(max(0.1, wake.timeIntervalSinceNow)))
        }
        return true
    }

    public func source(_ id: String) -> SourceRecord? { sources.first { $0.id == id } }

    func enqueue(_ job: Job) {
        writeGeneration += 1
        queue.upsert(job)
        jobs = queue.jobs
        onJobUpdate?(job)
        Log.info("enqueued \(job.kind.rawValue) job \(job.id) source=\(job.sourceId ?? "-")")
        kick()
    }

    /// Delays the queued jobs of these sources until `date` (CONTRACT §12.7: while Correo's "Deshacer" toast shows,
    /// so undoing finds them still queued and simply deletes them instead of hitting a running ingest).
    /// Payload mark of a job held by `hold(sourceIds:until:)` (the queue status shows it as plain waiting, not as Claude's limit).
    public static let heldForUndoKey = "heldForUndo"

    public func hold(sourceIds: [String], until date: Date) {
        let ids = Set(sourceIds)
        var changed = false
        for var job in queue.jobs where job.status == .queued && job.sourceId.map(ids.contains) == true {
            guard (job.notBefore ?? .distantPast) < date else { continue }
            job.notBefore = date
            job.payload[Self.heldForUndoKey] = "1"
            queue.upsert(job)
            changed = true
        }
        guard changed else { return }
        writeGeneration += 1
        jobs = queue.jobs
        kick()
    }

    func kick() {
        guard started, autoProcess, !stopping else { return }
        if loopTask == nil {
            loopTask = Task { [weak self] in await self?.loop() }
        } else {
            sleepTask?.cancel()
        }
    }

    /// Holds the queue lock while there is work (backoff waits included); releases it once idle.
    private func loop() async {
        while !Task.isCancelled, !stopping {
            guard await acquireQueue() else {
                // Another process is working through the queue: retry while we still see work for us.
                guard hasWork else { break }
                await nap(seconds: 3)
                continue
            }
            if await runNext() { continue }
            guard !isProcessing, let wake = queue.nextWakeDate() else { break }
            await nap(seconds: wake.timeIntervalSinceNow)
        }
        loopTask = nil
        releaseQueueIfIdle()
    }

    /// A matching job is running here, or (when another process owns the queue) according to the files on disk.
    func runningAnywhere(_ predicate: (Job) -> Bool) -> Bool {
        if queue.jobs.contains(where: { $0.status == .running && predicate($0) }) { return true }
        guard !queueLock.isHeld else { return false }
        return JobQueue.readAll(dir: paths.jobs).contains { $0.status == .running && predicate($0) }
    }

    private var hasWork: Bool { queue.nextRunnable() != nil || queue.nextWakeDate() != nil }

    /// Cancellable sleep (`kick()` cuts it short).
    private func nap(seconds: TimeInterval) async {
        let nap = Task { _ = try? await Task.sleep(for: .seconds(max(0.1, seconds))) }
        sleepTask = nap
        await nap.value
        sleepTask = nil
    }

    /// Takes the cross-process queue lock. On first acquisition, reloads the queue from disk (another process may
    /// have changed it) and requeues jobs a dead owner left `running`.
    private func acquireQueue() async -> Bool {
        if queueLock.isHeld { return true }
        guard queueLock.tryLock() else {
            if !queueBusyElsewhere { Log.info("queue is being processed by pid \(queueLock.holderPid().map(String.init) ?? "?"); waiting") }
            queueBusyElsewhere = true
            return false
        }
        queueBusyElsewhere = false
        await syncFromDisk(resetRunning: true)
        if needsRepair, queueLock.isHeld, !isProcessing {
            needsRepair = false
            repairInterruptedSources()
        }
        return queueLock.isHeld
    }

    private func releaseQueueIfIdle() {
        guard loopTask == nil, activeRuns == 0, !isProcessing, queueLock.isHeld else { return }
        queueLock.unlock()
    }

    /// Replaces sources/jobs with what is on disk. The read runs off the main thread and is dropped (and retried)
    /// if this engine wrote something meanwhile. Never while a job runs here.
    private func syncFromDisk(resetRunning: Bool) async {
        for _ in 0..<3 {
            guard !isProcessing else { return }
            let generation = writeGeneration
            let store = sourceStore, jobsDir = paths.jobs
            let (loadedSources, loadedJobs) = await Task.detached(priority: .utility) {
                (store.loadAll(), JobQueue.readAll(dir: jobsDir))
            }.value
            guard store === sourceStore else { return }   // reloaded meanwhile
            guard generation == writeGeneration, !isProcessing else { continue }
            queue.replace(with: loadedJobs, resetRunning: resetRunning && queueLock.isHeld)
            if jobs != queue.jobs { jobs = queue.jobs }
            if loadedSources != sources {
                let old = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                sources = loadedSources
                for src in loadedSources where old[src.id] != src { onEvent?(.sourceUpdated(src)) }
            }
            return
        }
    }

    /// Watches `data/sources` and `data/jobs` (atomic writes show up as directory changes) so work enqueued or
    /// finished by `sb` shows up in the app and gets processed.
    private func startWatching() {
        stopWatching()
        for dir in [paths.sources, paths.jobs] {
            let fd = open(dir.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.diskChanged() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
        // MARK: v0.4 routing — rules changed by `sb rules` or by another Mac through a synced vault (the routing screen,
        // `match` and a later reorder must see them). Watched when the vault already has its `.secondbrain` folder.
        let rulesDir = RoutingStore.fileURL(vaultRoot: config.vaultURL).deletingLastPathComponent()
        let fd = open(rulesDir.path, O_EVTONLY)
        if fd >= 0 {
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete],
                                                                   queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.routing.refresh() }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func stopWatching() {
        for w in watchers { w.cancel() }
        watchers = []
    }

    private func diskChanged() {
        guard syncTask == nil else { return }
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))   // debounce bursts of writes
            guard let self, !Task.isCancelled else { return }
            if !self.isProcessing {
                await self.syncFromDisk(resetRunning: false)
                if !self.queueLock.isHeld, self.queueBusyElsewhere, self.queueLock.tryLock() {
                    self.queueBusyElsewhere = false
                    self.releaseQueueIfIdle()
                }
                if self.hasWork { self.kick() }
            }
            self.syncTask = nil
        }
    }

    private func pruneHistory() {
        let history = self.history
        Task.detached(priority: .background) { history.prune() }
    }

    /// Runs the next due job, if any and if nothing else is running.
    private func runNext() async -> Bool {
        guard !isProcessing, !stopping, queueLock.isHeld, var job = queue.nextRunnable() else { return false }
        isProcessing = true
        defer { isProcessing = false }
        job.status = .running
        job.message = initialMessage(for: job)
        job.updatedAt = Date()
        saveJob(job)
        Log.info("running \(job.kind.rawValue) job \(job.id) attempt \(job.attempts + 1)")

        let outcome = await execute(job)
        let current = queue.job(id: job.id) ?? job
        let updated = JobQueue.reschedule(current, outcome: outcome)
        finish(updated, outcome: outcome)
        return true
    }

    private func execute(_ job: Job) async -> JobOutcome {
        do {
            switch job.kind {
            case .transcribe: try await runTranscribe(job)
            case .ingest: try await runIngest(job)
            case .classify: try await runClassify(job)
            case .lint: try await runLint(job)
            case .saveAnswer: try await runSaveAnswer(job)
            case .reformat: try await runReformat(job)
            case .makeTemplate: try await runMakeTemplate(job)
            case .manualEdit: break   // recorded directly by the app (e.g. `setTask`), never queued
            case .fileDump: try await runFileDump(job)   // v0.7 (§17.3)
            }
            return .success
        } catch let error as ClaudeError {
            switch error {
            case .rateLimited(let resetAt): return .rateLimited(resetAt: resetAt)
            case .notInstalled: return .fatal(lang.t("No encontré Claude en esta Mac. Instálalo desde Ajustes.",
                                                     "Claude isn't installed on this Mac. Install it from Settings."))
            case .notAuthenticated: return .fatal(lang.t("Claude no tiene la sesión iniciada. Vuelve a conectarlo desde Ajustes.",
                                                         "Claude isn't signed in. Reconnect it from Settings."))
            case .failed(let msg): return .retryable(lang.t("Claude no pudo terminar: ", "Claude couldn't finish: ") + String(msg.prefix(400)))
            }
        } catch let error as EngineError {
            return .fatal(error.localizedDescription)
        } catch {
            return .retryable(error.localizedDescription)
        }
    }

    private func finish(_ job: Job, outcome: JobOutcome) {
        var job = job
        switch outcome {
        case .success:
            writeGeneration += 1
            queue.remove(id: job.id)
            jobs = queue.jobs
            onJobUpdate?(job)
            Log.info("job \(job.id) done")
        case .rateLimited:
            let until = job.notBefore ?? Date()
            job.message = lang.t("Claude llegó a su límite de uso. Sigo a las ", "Claude hit its usage limit. Resuming at ")
                + Fmt.local(until, "HH:mm")
            saveJob(job)
            if var src = job.sourceId.flatMap(source), !(job.kind == .classify && src.projectSlug != nil) {
                src.status = job.kind == .classify ? .needsProject : .queued
                src.progress = nil
                upsert(&src)
            }
            Log.info("job \(job.id) rate limited until \(until)")
            onEvent?(.rateLimited(until: until))
        case .fatal, .retryable:
            saveJob(job)
            Log.error("job \(job.id) \(job.status == .failed ? "failed" : "will retry"): \(job.error ?? "")")
            if var src = job.sourceId.flatMap(source), !(job.kind == .classify && src.projectSlug != nil) {
                src.progress = nil
                if job.kind == .classify {
                    src.status = .needsProject       // a failed suggestion is not a failed source
                } else if job.status == .failed {
                    src.status = .failed
                    src.error = job.error
                } else {
                    src.status = .queued
                }
                upsert(&src)
            }
            if job.kind == .fileDump { job.status == .failed ? fileDumpFailed(job) : fileDumpWillRetry(job) }   // v0.7
            if job.status == .failed { onEvent?(.jobFailed(job)) }
        }
    }

    // MARK: Job handlers

    private func runTranscribe(_ job: Job) async throws {
        guard var src = job.sourceId.flatMap(source) else { throw EngineError.sourceNotFound(job.sourceId ?? "") }
        if let raw = src.rawPath, FileManager.default.fileExists(atPath: vault.url(for: raw).path) {
            // Transcript already written by an earlier attempt (maybe cut short before the audio was deleted).
            if let m = try? SessionManifest.load(from: sessionDir(src.id)) { deleteAudio(in: sessionDir(src.id), manifest: m) }
            enqueueAfterRaw(&src)
            return
        }
        let dir = sessionDir(src.id)
        guard var manifest = try? SessionManifest.load(from: dir) else { throw EngineError.sessionMissing(src.id) }
        src.status = .transcribing
        src.progress = 0
        upsert(&src)

        let jobId = job.id, sourceId = src.id
        let transcriptExists = FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path)
        if !hasAudio(dir, manifest), !transcriptExists, let media = MediaImport.load(from: dir) {
            manifest = try await convertImported(media, manifest: manifest, dir: dir, jobId: jobId, sourceId: sourceId)
            src = source(sourceId) ?? src
        }
        if !transcriber.isReady {
            updateJob(jobId, message: lang.t("Preparando el modelo de transcripción…", "Preparing the transcription model…"))
            try await transcriber.prepare { [weak self] p in
                Task { @MainActor in self?.updateJob(jobId, message: p.message, progress: p.fraction) }
            }
        }
        let transcriptURL = dir.appendingPathComponent("transcript.json")
        let transcript: Transcript
        if !hasAudio(dir, manifest), let data = try? Data(contentsOf: transcriptURL),
           let saved = try? JSONDecoder.sb.decode(Transcript.self, from: data) {
            transcript = saved   // a crash after the audio was deleted: don't transcribe silence
        } else {
            updateJob(jobId, message: lang.t("Transcribiendo…", "Transcribing…"), progress: 0)
            transcript = try await transcriber.transcribe(sessionDir: dir, manifest: manifest) { [weak self] fraction, message in
                Task { @MainActor in self?.reportTranscription(jobId: jobId, sourceId: sourceId, fraction: fraction, message: message) }
            }
            try JSONEncoder.sb.encode(transcript).write(to: transcriptURL, options: .atomic)
        }

        src = source(sourceId) ?? src        // the user may have assigned a project meanwhile
        let project = validProject(src.projectSlug)
        // The user may have corrected when it happened (`setEventDate`): the transcript's `date:` and name follow it.
        var dated = manifest
        if let event = src.eventDate { dated.startedAt = event }
        let url = try TranscriptWriter.write(transcript: transcript, manifest: dated, title: src.title,
                                             projectSlug: project, language: config.uiLanguage, to: rawDir(.meeting, project),
                                             addedAt: src.createdAt)
        guard let written = try? String(contentsOf: url, encoding: .utf8), !written.isEmpty else {
            throw EngineError.rawMissing(url.path)
        }
        // Record the transcript before the audio goes, so a crash in between can't lose both.
        src.rawPath = url.relativePath(from: vault.root)
        src.projectSlug = project
        src.progress = nil
        if transcript.durationSeconds > 0 { src.durationSeconds = transcript.durationSeconds }
        upsert(&src)
        deleteAudio(in: dir, manifest: manifest)

        if transcript.segments.isEmpty {
            src.status = .done
            src.error = lang.t("No se escuchó a nadie en la grabación.", "Nobody could be heard in the recording.")
            upsert(&src)
            return
        }
        enqueueAfterRaw(&src)
    }

    /// Turns an imported audio/video file into the session's `system_NNN.wav` chunks (CONTRACT §3).
    private func convertImported(_ media: MediaImport, manifest: SessionManifest, dir: URL, jobId: String,
                                 sourceId: String) async throws -> SessionManifest {
        let fm = FileManager.default
        let input = media.clonedFile.map { dir.appendingPathComponent($0) }.flatMap { fm.fileExists(atPath: $0.path) ? $0 : nil }
            ?? URL(fileURLWithPath: media.originalPath)
        guard fm.fileExists(atPath: input.path) else { throw EngineError.rawMissing(media.originalPath) }
        updateJob(jobId, message: lang.t("Preparando el audio…", "Preparing the audio…"), progress: 0)
        let chunkSeconds = manifest.chunkSeconds, rate = manifest.sampleRate
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in self?.updateJob(jobId, message: nil, progress: fraction) }
        }
        let converted: AudioPrep.Converted
        do {
            converted = try await Task.detached(priority: .userInitiated) {
                try await AudioPrep.convertToChunks(input, prefix: "system", chunkSeconds: chunkSeconds, sampleRate: rate,
                                                    dir: dir, progress: report)
            }.value
        } catch let error as AudioPrepError {
            // Fatal (retrying won't help); name the user's file, not our clone.
            let name = (media.originalPath as NSString).lastPathComponent
            switch error {
            case .noAudio: throw EngineError.download(AudioPrepError.noAudio(name).localizedDescription)
            case .unreadable: throw EngineError.download(AudioPrepError.unreadable(name).localizedDescription)
            }
        }
        var manifest = manifest
        if !media.eventDateFromUser {
            // When it was recorded: the file's own creation-date metadata beats the file system date.
            let recorded = await FileDates.mediaEventDate(input)
            manifest.startedAt = recorded
            if var src = source(sourceId), src.eventDate != recorded {
                src.eventDate = recorded
                upsert(&src)
            }
        }
        manifest.tracks = ["system": converted.files]
        manifest.micCaptured = false
        manifest.endedAt = manifest.startedAt.addingTimeInterval(converted.duration)
        try manifest.save(to: dir)
        if let clone = media.clonedFile { try? fm.removeItem(at: dir.appendingPathComponent(clone)) }
        if var src = source(sourceId) {
            src.durationSeconds = converted.duration
            upsert(&src)
        }
        Log.info("converted \((media.originalPath as NSString).lastPathComponent): \(String(format: "%.1f", converted.duration)) s in \(converted.files.count) chunk(s)")
        return manifest
    }

    private func runIngest(_ job: Job) async throws {
        guard var src = job.sourceId.flatMap(source) else { throw EngineError.sourceNotFound(job.sourceId ?? "") }
        guard let raw = src.rawPath, FileManager.default.fileExists(atPath: vault.url(for: raw).path) else {
            throw EngineError.rawMissing(src.rawPath ?? src.id)
        }
        src.status = .ingesting
        src.error = nil
        upsert(&src)
        let args = claudeArguments(raw: raw, templateId: templateId(for: src))
        let entry = try await tracked(job, title: lang.learnedFrom(src.title), kind: .ingest,
                                      sourceId: src.id, projectSlug: src.projectSlug) {
            try await self.runClaude(job, command: "ingest", arguments: args, mode: .edit, model: self.config.ingestModel)
        }
        src = source(src.id) ?? src
        src.status = .done
        src.historyId = entry?.id ?? src.historyId
        src.progress = nil
        upsert(&src)
    }

    private func runClassify(_ job: Job) async throws {
        guard var src = job.sourceId.flatMap(source) else { throw EngineError.sourceNotFound(job.sourceId ?? "") }
        guard src.projectSlug == nil, let raw = src.rawPath else { return }   // assigned meanwhile
        let result = try await runClaude(job, command: "classify", arguments: raw, mode: .readOnly, model: config.ingestModel)
        src = source(src.id) ?? src
        guard src.projectSlug == nil else { return }
        let suggestion = Self.parseClassification(result, validSlugs: Set(projects.list().map(\.slug)))
        src.suggestedProject = suggestion?.project
        src.suggestionReason = suggestion?.reason
        src.status = .needsProject
        upsert(&src)
    }

    private func runLint(_ job: Job) async throws {
        let name = job.projectSlug.map { projects.get($0)?.name ?? $0 }
        _ = try await tracked(job, title: lang.lintTitle(name), kind: .lint, sourceId: nil, projectSlug: job.projectSlug) {
            try await self.runClaude(job, command: "lint", arguments: job.projectSlug ?? "global", mode: .edit,
                                     model: self.config.ingestModel)
        }
    }

    private func runSaveAnswer(_ job: Job) async throws {
        let question = job.payload["question"] ?? ""
        // The scope is explicit: the command files the page in that scope's folder only (§16.3). `path`: the page the
        // app already wrote (it links it and cleans it up; it never creates a second one).
        let path = job.payload["path"].flatMap { $0.isEmpty ? nil : $0 }
        let body: [String: Any] = ["scope": job.payload["scope"] ?? (job.projectSlug == nil ? "brain" : "project"),
                                   "project": job.projectSlug ?? NSNull(), "question": question,
                                   "answer": job.payload["answer"] ?? "", "path": path ?? NSNull()]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        _ = try await tracked(job, title: lang.savedAnswer(question), kind: .saveAnswer, sourceId: nil, projectSlug: job.projectSlug) {
            try await self.runClaude(job, command: "save-answer", arguments: args, mode: .edit, model: self.config.ingestModel)
        }
    }

    /// Wraps a vault-editing Claude run in a history entry. Partial edits are recorded even when the run fails,
    /// so they can be undone.
    func tracked(_ job: Job, title: String, kind: JobKind, sourceId: String?, projectSlug: String?,
                         body: () async throws -> String) async throws -> HistoryEntry? {
        let history = self.history
        let snapshot = try await Task.detached {
            try history.begin(title: title, kind: kind, sourceId: sourceId, projectSlug: projectSlug)
        }.value
        let summary: String
        do {
            summary = try await body()
        } catch {
            if let entry = try? await Task.detached(operation: { try history.commit(snapshot) }).value {
                record(entry, summary: nil, jobId: job.id)
            }
            throw error
        }
        let entry = try await Task.detached { try history.commit(snapshot) }.value
        if let entry { record(entry, summary: summary, jobId: job.id) }
        pruneHistory()
        return entry
    }

    private func record(_ entry: HistoryEntry, summary: String?, jobId: String) {
        if let summary, !summary.isEmpty { try? history.setSummary(summary, entryId: entry.id) }
        if var job = queue.job(id: jobId) {
            job.historyId = entry.id
            saveJob(job)
        }
        onEvent?(.historyAdded(entry))
    }

    /// Consumes a Claude stream, mirroring tool use into the job's message. Returns the final result text.
    func runClaude(_ job: Job, command: String, arguments: String, mode: ClaudeMode, model: String) async throws -> String {
        var steps = 0
        for try await event in claude.run(command: command, arguments: arguments, mode: mode, model: model) {
            switch event {
            case .tool(_, let detail):
                steps += 1
                updateJob(job.id, message: detail)
            case .text:
                break
            case .done(let result, let isError):
                if isError { throw ClaudeError.failed(result) }
                Log.info("\(command) finished after \(steps) tool calls")
                return result
            }
        }
        throw ClaudeError.failed("Claude ended without a result")
    }

    // MARK: Helpers

    /// `{"project":"slug|null","confidence":…,"reason":"…"}` from the last JSON-looking line of the result.
    nonisolated static func parseClassification(_ text: String, validSlugs: Set<String>) -> (project: String, reason: String?)? {
        let candidates = text.components(separatedBy: "\n").reversed()
            .map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
        for line in candidates {
            guard let open = line.firstIndex(of: "{"), let close = line.lastIndex(of: "}"), open < close,
                  let obj = (try? JSONSerialization.jsonObject(with: Data(line[open...close].utf8))) as? [String: Any] else { continue }
            guard let slug = obj["project"] as? String, validSlugs.contains(slug) else { return nil }
            return (slug, obj["reason"] as? String)
        }
        return nil
    }

    func enqueueAfterRaw(_ src: inout SourceRecord) {
        if src.projectSlug != nil {
            src.status = .queued
            upsert(&src)
            enqueue(Job(kind: .ingest, sourceId: src.id, projectSlug: src.projectSlug))
        } else {
            src.status = .needsProject
            upsert(&src)
            enqueue(Job(kind: .classify, sourceId: src.id))
        }
    }

    /// Sources caught mid-step by a crash/quit get their step queued again.
    private func repairInterruptedSources() {
        // Stopped cleanly but the app died before `recordingFinished`: still needs transcribing. Sessions
        // without `endedAt` are left to `Recorder.recoverInterruptedSessions`.
        for src in sources where src.status == .recording && src.kind == .meeting {
            if let m = try? SessionManifest.load(from: sessionDir(src.id)), m.endedAt != nil { recordingFinished(m) }
        }
        let dumping = dumpPendingSourceIds()   // v0.7: sources a queued /file-dump will file
        for var src in sources where [.queued, .transcribing, .ingesting].contains(src.status) {
            let pending = dumping.contains(src.id)
                || queue.jobs.contains { $0.sourceId == src.id && ($0.status == .queued || $0.status == .running) }
            if pending {
                if src.status != .queued {
                    src.status = .queued
                    src.progress = nil
                    upsert(&src)
                }
            } else {
                retry(sourceId: src.id)
            }
        }
    }

    private func moveRaw(_ raw: String, kind: SourceKind, to projectSlug: String) throws -> String {
        let fm = FileManager.default
        let src = vault.url(for: raw)
        guard fm.fileExists(atPath: src.path) else { throw EngineError.rawMissing(raw) }
        let destDir = rawDir(kind, projectSlug)
        try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
        var text = try String(contentsOf: src, encoding: .utf8)
        if let original = Frontmatter.field("original_file", in: text) {
            let from = src.deletingLastPathComponent().appendingPathComponent(original)
            if fm.fileExists(atPath: from.path) {
                let ext = (original as NSString).pathExtension
                let to = fm.uniqueURL(in: destDir, name: (original as NSString).deletingPathExtension, ext: ext)
                try fm.moveItem(at: from, to: to)
                text = Frontmatter.setField("original_file", to: YAML.scalar(to.lastPathComponent), in: text)
            }
        }
        text = Frontmatter.setField("project", to: YAML.scalar(projectSlug), in: text)
        let dest = fm.uniqueURL(in: destDir, name: src.deletingPathExtension().lastPathComponent, ext: src.pathExtension)
        try text.write(to: dest, atomically: true, encoding: .utf8)
        try fm.removeItem(at: src)
        return dest.relativePath(from: vault.root) ?? raw
    }

    func rawDir(_ kind: SourceKind, _ projectSlug: String?) -> URL {
        let sub: String
        switch kind {
        case .meeting: sub = "meetings"
        case .note, .inPerson: sub = "notes"   // v0.7 (§17.3): dump text lands in raw/notes
        case .document, .url: sub = "docs"
        case .image: sub = "assets"            // v0.7 (§17.1/§17.3)
        case .email: sub = "emails"
        case .github: sub = "github"   // MARK: v0.4 github (GitHubSync writes its own <owner>-<repo>/ subfolder)
        }
        if let projectSlug { return vault.root.appendingPathComponent("projects/\(projectSlug)/raw/\(sub)") }
        return vault.root.appendingPathComponent("_inbox/\(sub)")
    }

    func validProject(_ slug: String?) -> String? {
        guard let slug, !slug.isEmpty, projects.get(slug) != nil else { return nil }
        return slug
    }

    func sessionDir(_ id: String) -> URL { paths.sessions.appendingPathComponent(id) }

    private func meetingTitle(_ m: SessionManifest) -> String {
        if let t = m.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        return lang.defaultMeetingTitle(m.startedAt)
    }

    private func hasAudio(_ dir: URL, _ manifest: SessionManifest) -> Bool {
        manifest.tracks.values.joined().contains { FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path) }
    }

    private func deleteAudio(in dir: URL, manifest: SessionManifest) {
        let fm = FileManager.default
        var files = Set(manifest.tracks.values.flatMap { $0 })
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.lowercased().hasSuffix(".wav") {
            files.insert(name)
        }
        for name in files { try? fm.removeItem(at: dir.appendingPathComponent(name)) }
        Log.info("deleted \(files.count) audio files from \(dir.lastPathComponent)")
    }

    private func initialMessage(for job: Job) -> String {
        switch job.kind {
        case .transcribe: return lang.t("Transcribiendo…", "Transcribing…")
        case .ingest:
            let title = job.sourceId.flatMap(source)?.title ?? ""
            return lang.t("Aprendiendo de «\(title)»…", "Learning from “\(title)”…")
        case .classify: return lang.t("Buscando a qué proyecto pertenece…", "Figuring out which project it belongs to…")
        case .lint: return lang.t("Revisando tu cerebro…", "Checking your brain…")
        case .saveAnswer: return lang.t("Guardando la respuesta en el wiki…", "Saving the answer to the wiki…")
        case .reformat:
            let title = job.sourceId.flatMap(source)?.title ?? ""
            let format = job.payload["templateId"].flatMap { vault.template(id: $0)?.name } ?? job.payload["templateId"] ?? ""
            return lang.t("Aplicando el formato «\(format)» a «\(title)»…", "Applying the “\(format)” format to “\(title)”…")
        case .makeTemplate:
            return lang.t("Creando el formato «\(job.payload["name"] ?? "")»…", "Creating the “\(job.payload["name"] ?? "")” format…")
        case .manualEdit: return lang.t("Guardando tu cambio…", "Saving your change…")
        case .fileDump: return lang.t("Archivando lo que agregaste…", "Filing what you added…")
        }
    }

    private func reportTranscription(jobId: String, sourceId: String, fraction: Double, message: String) {
        updateJob(jobId, message: message.isEmpty ? nil : message, progress: fraction)
        if var src = source(sourceId), src.status == .transcribing {
            src.progress = fraction
            upsert(&src, persist: false)
        }
    }

    func updateJob(_ id: String, message: String?, progress: Double? = nil) {
        guard var job = queue.job(id: id) else { return }
        if let message { job.message = message }
        if let progress { job.progress = progress }
        job.updatedAt = Date()
        saveJob(job)
    }

    private func saveJob(_ job: Job) {
        writeGeneration += 1
        queue.upsert(job)
        jobs = queue.jobs
        onJobUpdate?(job)
    }

    /// v0.7: drops one job (a drop's /file-dump cancelled before it ran).
    func removeJob(id: String) {
        writeGeneration += 1
        queue.remove(id: id)
        jobs = queue.jobs
    }

    func removeJobs(for sourceId: String, where predicate: (Job) -> Bool) {
        writeGeneration += 1
        for job in queue.jobs where job.sourceId == sourceId && predicate(job) { queue.remove(id: job.id) }
        jobs = queue.jobs
    }

    func upsert(_ src: inout SourceRecord, persist: Bool = true) {
        writeGeneration += 1
        src.updatedAt = Date()
        if persist {
            do { try sourceStore.save(src) } catch { Log.error("could not save source \(src.id): \(error)") }
        }
        if let i = sources.firstIndex(where: { $0.id == src.id }) {
            sources[i] = src
        } else {
            sources.append(src)
            sources.sort { $0.createdAt > $1.createdAt }
        }
        onEvent?(.sourceUpdated(src))
    }
}

/// `data/sessions/<id>/import.json`: an audio/video file imported as a meeting, converted by the transcribe job.
struct MediaImport: Codable {
    static let fileName = "import.json"
    static let clonePrefix = "original"
    var originalPath: String
    /// Clone of the original inside the session folder (APFS `clonefile`), removed after conversion.
    var clonedFile: String?
    /// The user gave the event date at import: don't replace it with the file's metadata.
    var eventDateFromUser = false

    init(originalPath: String, clonedFile: String?, eventDateFromUser: Bool = false) {
        self.originalPath = originalPath; self.clonedFile = clonedFile; self.eventDateFromUser = eventDateFromUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        originalPath = try c.decode(String.self, forKey: .originalPath)
        clonedFile = try c.decodeIfPresent(String.self, forKey: .clonedFile)
        eventDateFromUser = try c.decodeIfPresent(Bool.self, forKey: .eventDateFromUser) ?? false
    }

    static func load(from dir: URL) -> MediaImport? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(fileName)) else { return nil }
        return try? JSONDecoder.sb.decode(MediaImport.self, from: data)
    }

    func save(to dir: URL) throws {
        try JSONEncoder.sb.encode(self).write(to: dir.appendingPathComponent(Self.fileName), options: .atomic)
    }
}
