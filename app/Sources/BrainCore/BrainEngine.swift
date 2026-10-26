import Foundation
import Observation

public enum EngineError: Error, LocalizedError {
    case sourceNotFound(String)
    case sessionMissing(String)
    case rawMissing(String)
    case busy
    case alreadyIngested
    case download(String)

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
    public let paths: DataPaths
    public let vault: VaultStore
    public let projects: ProjectManager
    public let history: HistoryStore
    public let claude: ClaudeRunner
    public private(set) var sources: [SourceRecord] = []
    public private(set) var jobs: [Job] = []
    public private(set) var isProcessing = false
    public var onEvent: ((EngineEvent) -> Void)?
    /// Fires on every job change (status, progress, human message such as "Editando …").
    public var onJobUpdate: ((Job) -> Void)?
    /// When false the queue only runs through `runUntilIdle()` (CLI commands that just enqueue).
    public var autoProcess = true

    @ObservationIgnored private let transcriber: Transcribing
    @ObservationIgnored private let sourceStore: SourceStore
    @ObservationIgnored private let queue: JobQueue
    @ObservationIgnored private let configBox: ConfigBox
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var sleepTask: Task<Void, Never>?
    @ObservationIgnored private var started = false

    private var lang: Lang { Lang(config.uiLanguage) }

    public init(config: AppConfig, transcriber: Transcribing) {
        self.config = config
        self.transcriber = transcriber
        let paths = DataPaths(root: config.dataURL)
        self.paths = paths
        self.vault = VaultStore(root: config.vaultURL)
        self.projects = ProjectManager(vaultRoot: config.vaultURL)
        self.history = HistoryStore(vaultRoot: config.vaultURL, historyDir: paths.history)
        self.history.gitEnabled = config.gitEnabled
        let box = ConfigBox(config)
        self.configBox = box
        self.claude = ClaudeRunner(configProvider: { box.get() }, vaultURL: config.vaultURL)
        self.sourceStore = SourceStore(dir: paths.sources)
        self.queue = JobQueue(dir: paths.jobs)
        Log.configure(logsDir: paths.logs)
    }

    // MARK: Lifecycle

    /// Creates folders, installs the vault template if missing, reloads state and resumes the queue.
    public func start() {
        guard !started else { return }
        started = true
        do { try paths.ensureExist() } catch { Log.error("could not create data folders: \(error)") }
        do { try vault.installTemplateIfNeeded() } catch { Log.error("could not install vault template: \(error)") }
        for entry in history.recoverInterrupted() { Log.info("recovered interrupted change \(entry.id): \(entry.title)") }
        sources = sourceStore.loadAll()
        queue.load()
        jobs = queue.jobs
        repairInterruptedSources()
        Log.info("engine started: \(sources.count) sources, \(jobs.count) jobs, vault=\(config.vaultURL.path)")
        kick()
    }

    /// Saves the config. A different vault/data path needs a new engine.
    public func updateConfig(_ c: AppConfig) throws {
        try c.save()
        config = c
        configBox.set(c)
        history.gitEnabled = c.gitEnabled
    }

    // MARK: Recording pipeline

    public func recordingStarted(_ m: SessionManifest) {
        var src = source(m.id) ?? SourceRecord(id: m.id, kind: .meeting, title: meetingTitle(m), projectSlug: m.projectSlug,
                                               status: .recording, createdAt: m.startedAt)
        src.status = .recording
        upsert(&src)
    }

    public func recordingFinished(_ m: SessionManifest) {
        var src = source(m.id) ?? SourceRecord(id: m.id, kind: .meeting, title: meetingTitle(m), projectSlug: m.projectSlug,
                                               status: .queued, createdAt: m.startedAt)
        if let title = m.title, !title.isEmpty { src.title = title }
        if let slug = m.projectSlug { src.projectSlug = slug }
        src.status = .queued
        src.error = nil
        if let end = m.endedAt { src.durationSeconds = end.timeIntervalSince(m.startedAt) }
        upsert(&src)
        let id = src.id
        guard !queue.jobs.contains(where: { $0.sourceId == id && $0.kind == .transcribe && $0.status != .failed }) else { return }
        enqueue(Job(kind: .transcribe, sourceId: src.id, projectSlug: src.projectSlug))
    }

    // MARK: Imports

    public func importFile(_ url: URL, projectSlug: String?) throws {
        let project = validProject(projectSlug)
        let imported = try Importer.importFile(url, into: rawDir(.document, project), project: project)
        addImported(kind: .document, title: imported.title, rawURL: imported.rawURL, sourceId: imported.sourceId, project: project)
    }

    public func importURL(_ url: URL, projectSlug: String?) async throws {
        let project = validProject(projectSlug)
        let imported = try await Importer.importURL(url, into: rawDir(.url, project), project: project)
        addImported(kind: .url, title: imported.title, rawURL: imported.rawURL, sourceId: imported.sourceId, project: project)
    }

    public func addNote(title: String, body: String, projectSlug: String?) throws {
        let project = validProject(projectSlug)
        let imported = try Importer.writeNote(title: title, body: body, into: rawDir(.note, project), project: project)
        addImported(kind: .note, title: imported.title, rawURL: imported.rawURL, sourceId: imported.sourceId, project: project)
    }

    private func addImported(kind: SourceKind, title: String, rawURL: URL, sourceId: String, project: String?) {
        var src = SourceRecord(id: sourceId, kind: kind, title: title, projectSlug: project, status: .queued,
                               rawPath: rawURL.relativePath(from: vault.root))
        enqueueAfterRaw(&src)
    }

    // MARK: Source actions

    /// Files a source under a project. Inbox raws move to the project (frontmatter `project:` updated) and get ingested.
    public func assign(sourceId: String, to projectSlug: String) throws {
        guard var src = source(sourceId) else { throw EngineError.sourceNotFound(sourceId) }
        guard projects.get(projectSlug) != nil else { throw ProjectError.notFound(projectSlug) }
        guard src.historyId == nil || src.status != .done else { throw EngineError.alreadyIngested }
        // A running classify only reads; its result is ignored once the source has a project.
        guard !queue.jobs.contains(where: { $0.sourceId == sourceId && $0.status == .running && $0.kind != .classify }) else {
            throw EngineError.busy
        }

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
        guard !queue.jobs.contains(where: { $0.sourceId == sourceId && $0.status == .running }) else { throw EngineError.busy }
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
        }
        sourceStore.delete(id: sourceId)
        sources.removeAll { $0.id == sourceId }
        Log.info("deleted source \(sourceId)")
    }

    // MARK: Claude operations

    /// Streams a read-only answer from the wiki (not queued: it is interactive).
    public func ask(_ question: String, projectSlug: String?) -> AsyncThrowingStream<ClaudeEvent, Error> {
        claude.run(command: "query", arguments: "scope=\(projectSlug ?? "global") | \(question)",
                   mode: .readOnly, model: config.queryModel)
    }

    public func saveAnswer(question: String, answer: String, projectSlug: String?) {
        enqueue(Job(kind: .saveAnswer, projectSlug: projectSlug, payload: ["question": question, "answer": answer]))
    }

    public func lint(projectSlug: String?) {
        enqueue(Job(kind: .lint, projectSlug: projectSlug))
    }

    /// Undoing an ingest also detaches it from its source, so the source can be learned from again
    /// (`retry`) or moved to another project.
    public func undo(historyId: String, force: Bool = false) throws {
        guard !queue.jobs.contains(where: { $0.status == .running && [.ingest, .lint, .saveAnswer].contains($0.kind) }) else {
            throw EngineError.busy
        }
        try history.undo(entryId: historyId, force: force)
        guard var src = sources.first(where: { $0.historyId == historyId }) else { return }
        src.historyId = nil
        upsert(&src)
    }

    // MARK: Queue

    /// Processes the queue until nothing is runnable. Waits for retry backoffs that are due within
    /// five minutes; longer waits (e.g. a Claude usage limit) are left queued.
    public func runUntilIdle() async {
        if !started { start() }
        while true {
            if await runNext() { continue }
            if isProcessing {
                try? await Task.sleep(for: .milliseconds(200))
                continue
            }
            guard let wake = queue.nextWakeDate(), wake.timeIntervalSinceNow < 300 else { return }
            try? await Task.sleep(for: .seconds(max(0.1, wake.timeIntervalSinceNow)))
        }
    }

    public func source(_ id: String) -> SourceRecord? { sources.first { $0.id == id } }

    private func enqueue(_ job: Job) {
        queue.upsert(job)
        jobs = queue.jobs
        onJobUpdate?(job)
        Log.info("enqueued \(job.kind.rawValue) job \(job.id) source=\(job.sourceId ?? "-")")
        kick()
    }

    private func kick() {
        guard started, autoProcess else { return }
        if loopTask == nil {
            loopTask = Task { [weak self] in await self?.loop() }
        } else {
            sleepTask?.cancel()
        }
    }

    private func loop() async {
        while !Task.isCancelled {
            if await runNext() { continue }
            guard !isProcessing, let wake = queue.nextWakeDate() else { break }
            let nap = Task { _ = try? await Task.sleep(for: .seconds(max(0.1, wake.timeIntervalSinceNow))) }
            sleepTask = nap
            await nap.value
            sleepTask = nil
        }
        loopTask = nil
    }

    /// Runs the next due job, if any and if nothing else is running.
    private func runNext() async -> Bool {
        guard !isProcessing, var job = queue.nextRunnable() else { return false }
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
        guard let manifest = try? SessionManifest.load(from: dir) else { throw EngineError.sessionMissing(src.id) }
        src.status = .transcribing
        src.progress = 0
        upsert(&src)

        let jobId = job.id, sourceId = src.id
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
        let url = try TranscriptWriter.write(transcript: transcript, manifest: manifest, title: src.title,
                                             projectSlug: project, language: config.uiLanguage, to: rawDir(.meeting, project))
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

    private func runIngest(_ job: Job) async throws {
        guard var src = job.sourceId.flatMap(source) else { throw EngineError.sourceNotFound(job.sourceId ?? "") }
        guard let raw = src.rawPath, FileManager.default.fileExists(atPath: vault.url(for: raw).path) else {
            throw EngineError.rawMissing(src.rawPath ?? src.id)
        }
        src.status = .ingesting
        src.error = nil
        upsert(&src)
        let entry = try await tracked(job, title: lang.learnedFrom(src.title), kind: .ingest,
                                      sourceId: src.id, projectSlug: src.projectSlug) {
            try await self.runClaude(job, command: "ingest", arguments: raw, mode: .edit, model: self.config.ingestModel)
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
        let body: [String: Any] = ["project": job.projectSlug ?? NSNull(), "question": question,
                                   "answer": job.payload["answer"] ?? ""]
        let args = String(decoding: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]), as: UTF8.self)
        _ = try await tracked(job, title: lang.savedAnswer(question), kind: .saveAnswer, sourceId: nil, projectSlug: job.projectSlug) {
            try await self.runClaude(job, command: "save-answer", arguments: args, mode: .edit, model: self.config.ingestModel)
        }
    }

    /// Wraps a vault-editing Claude run in a history entry. Partial edits are recorded even when the run fails,
    /// so they can be undone.
    private func tracked(_ job: Job, title: String, kind: JobKind, sourceId: String?, projectSlug: String?,
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
    private func runClaude(_ job: Job, command: String, arguments: String, mode: ClaudeMode, model: String) async throws -> String {
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

    private func enqueueAfterRaw(_ src: inout SourceRecord) {
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
        for var src in sources where [.queued, .transcribing, .ingesting].contains(src.status) {
            let pending = queue.jobs.contains { $0.sourceId == src.id && ($0.status == .queued || $0.status == .running) }
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

    private func rawDir(_ kind: SourceKind, _ projectSlug: String?) -> URL {
        let sub: String
        switch kind {
        case .meeting: sub = "meetings"
        case .note: sub = "notes"
        case .document, .url: sub = "docs"
        }
        if let projectSlug { return vault.root.appendingPathComponent("projects/\(projectSlug)/raw/\(sub)") }
        return vault.root.appendingPathComponent("_inbox/\(sub)")
    }

    private func validProject(_ slug: String?) -> String? {
        guard let slug, !slug.isEmpty, projects.get(slug) != nil else { return nil }
        return slug
    }

    private func sessionDir(_ id: String) -> URL { paths.sessions.appendingPathComponent(id) }

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
        }
    }

    private func reportTranscription(jobId: String, sourceId: String, fraction: Double, message: String) {
        updateJob(jobId, message: message.isEmpty ? nil : message, progress: fraction)
        if var src = source(sourceId), src.status == .transcribing {
            src.progress = fraction
            upsert(&src, persist: false)
        }
    }

    private func updateJob(_ id: String, message: String?, progress: Double? = nil) {
        guard var job = queue.job(id: id) else { return }
        if let message { job.message = message }
        if let progress { job.progress = progress }
        job.updatedAt = Date()
        saveJob(job)
    }

    private func saveJob(_ job: Job) {
        queue.upsert(job)
        jobs = queue.jobs
        onJobUpdate?(job)
    }

    private func removeJobs(for sourceId: String, where predicate: (Job) -> Bool) {
        for job in queue.jobs where job.sourceId == sourceId && predicate(job) { queue.remove(id: job.id) }
        jobs = queue.jobs
    }

    private func upsert(_ src: inout SourceRecord, persist: Bool = true) {
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
