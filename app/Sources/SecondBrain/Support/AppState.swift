import AppKit
import BrainCore
import Observation
import Recorder
import Transcription

enum SidebarItem: Hashable {
    case project(String)
    case inbox
    case people
    case brain
}

struct QueueStatus: Equatable {
    var text: String
    var progress: Double?
    var waiting = false
}

@MainActor @Observable
final class AppState {
    static let shared = AppState()

    private(set) var config: AppConfig
    private(set) var engine: BrainEngine
    private(set) var transcriber: WhisperTranscriber
    let recorder: Recorder

    private(set) var projects: [Project] = []
    /// Bumped whenever the vault likely changed on disk, so lists of pages refresh.
    private(set) var vaultRevision = 0
    private(set) var historyRevision = 0
    private(set) var engineStarted = false

    private(set) var modelProgress: ModelPrepProgress?
    private(set) var modelsReady = false
    private(set) var modelError: String?
    var isPreparingModels: Bool { modelTask != nil }

    private(set) var rateLimitedUntil: Date?
    var recordingError: String?
    var restartNeeded = false
    var selection: SidebarItem? = .brain

    var recordingProjectSlug: String? {
        didSet { if isRecording { recorder.updateCurrent(title: recordingTitleOrNil, projectSlug: recordingProjectSlug) } }
    }
    var recordingTitle = "" {
        didSet { if isRecording { recorder.updateCurrent(title: recordingTitleOrNil, projectSlug: recordingProjectSlug) } }
    }

    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var notified = Set<String>()

    private init() {
        let config = AppConfig.load()
        self.config = config
        Localizer.language = config.uiLanguage
        let paths = DataPaths(root: config.dataURL)
        let transcriber = WhisperTranscriber(modelName: config.whisperModel, modelsDir: paths.models)
        transcriber.messageLanguage = config.uiLanguage
        self.transcriber = transcriber
        engine = BrainEngine(config: config, transcriber: transcriber)
        recorder = Recorder(sessionsDir: paths.sessions)
    }

    // MARK: Lifecycle

    func launch() {
        Notifier.requestAuthorization()
        applyHotKey()
        if config.onboardingComplete {
            startEngine()
            prepareModels()
        }
    }

    /// Starts the engine once: installs the vault template, resumes the queue, re-enqueues recordings cut short by a crash.
    func startEngine() {
        guard !engineStarted else { return }
        engineStarted = true
        try? DataPaths(root: config.dataURL).ensureExist()
        engine.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        engine.start()
        reloadProjects()
        for manifest in Recorder.recoverInterruptedSessions(in: engine.paths.sessions) {
            engine.recordingFinished(manifest)
        }
    }

    func completeOnboarding() {
        update { $0.onboardingComplete = true }
        startEngine()
        prepareModels()
    }

    func relaunch() {
        let target = Bundle.main.bundleURL.pathExtension == "app" ? Bundle.main.bundlePath : nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        if let target {
            process.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", target]
        } else if let exe = Bundle.main.executablePath {
            process.arguments = ["-c", "sleep 1; \"$0\" >/dev/null 2>&1 &", exe]
        }
        try? process.run()
        NSApp.terminate(nil)
    }

    // MARK: Config

    func update(_ change: (inout AppConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        let old = config
        config = next
        try? next.save()

        if next.uiLanguage != old.uiLanguage {
            Localizer.language = next.uiLanguage
            transcriber.messageLanguage = next.uiLanguage
        }
        if next.hotkeyEnabled != old.hotkeyEnabled { applyHotKey() }

        let structural = next.vaultPath != old.vaultPath || next.dataPath != old.dataPath || next.whisperModel != old.whisperModel
        if structural {
            // A running engine owns the vault and the queue; swapping it live risks two queues. Ask for a restart instead.
            if engineStarted { restartNeeded = true } else { rebuildEngine(modelChanged: next.whisperModel != old.whisperModel) }
        } else if engineStarted {
            try? engine.updateConfig(next)
        }
    }

    private func rebuildEngine(modelChanged: Bool) {
        if modelChanged {
            modelTask?.cancel()
            modelTask = nil
            modelsReady = false
            modelProgress = nil
            transcriber = WhisperTranscriber(modelName: config.whisperModel, modelsDir: DataPaths(root: config.dataURL).models)
            transcriber.messageLanguage = config.uiLanguage
        }
        engine = BrainEngine(config: config, transcriber: transcriber)
    }

    private func applyHotKey() {
        hotKey?.unregister()
        hotKey = nil
        if config.hotkeyEnabled {
            hotKey = GlobalHotKey { [weak self] in self?.toggleRecording() }
        }
    }

    // MARK: Models

    func prepareModels() {
        guard modelTask == nil, !modelsReady else { return }
        if transcriber.isReady { modelsReady = true; return }
        modelError = nil
        let transcriber = self.transcriber
        modelTask = Task { [weak self] in
            do {
                try await transcriber.prepare { progress in
                    Task { @MainActor in self?.modelProgress = progress }
                }
                self?.modelsReady = true
            } catch is CancellationError {
            } catch {
                self?.modelError = L("models.error")
            }
            self?.modelTask = nil
        }
    }

    // MARK: Projects

    func reloadProjects() {
        guard engineStarted else { return }
        projects = engine.projects.list().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createProject(name: String, description: String, emoji: String) throws -> Project {
        let project = try engine.projects.create(name: name, description: description, emoji: emoji)
        reloadProjects()
        vaultRevision += 1
        return project
    }

    func project(_ slug: String?) -> Project? {
        guard let slug else { return nil }
        return projects.first { $0.slug == slug }
    }

    func projectName(_ slug: String?) -> String {
        guard let slug else { return L("inbox.title") }
        if let p = project(slug) { return "\(p.emoji) \(p.name)" }
        return slug
    }

    func inProgressCount(_ slug: String) -> Int {
        engine.sources.filter { $0.projectSlug == slug && $0.status.isInProgress }.count
    }

    var inboxCount: Int { engine.sources.filter { $0.status == .needsProject }.count }

    func bumpVault() { vaultRevision += 1 }
    func bumpHistory() { historyRevision += 1; vaultRevision += 1 }

    // MARK: Recording

    var isRecording: Bool {
        if case .recording = recorder.state { return true }
        return false
    }

    var recordingSince: Date? {
        if case .recording(let since) = recorder.state { return since }
        return nil
    }

    /// Problems during a recording that don't stop it (mic gone, system audio lost, disk).
    var recorderWarning: String? {
        switch recorder.warning {
        case .microphoneUnavailable: L("record.warnMic")
        case .systemAudioLost: L("record.warnSystemAudio")
        case .diskWriteFailed: L("record.warnDisk")
        case nil: nil
        }
    }

    var isRecorderBusy: Bool { recorder.state == .starting || recorder.state == .stopping }

    private var recordingTitleOrNil: String? {
        let t = recordingTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func toggleRecording() {
        guard !isRecorderBusy else { return }
        Task { isRecording ? await stopRecording() : await startRecording() }
    }

    func startRecording() async {
        guard engineStarted else {
            recordingError = L("record.finishSetupFirst")
            return
        }
        recordingError = nil
        do {
            let manifest = try await recorder.start(title: recordingTitleOrNil, projectSlug: recordingProjectSlug,
                                                    captureMic: config.captureMic)
            engine.recordingStarted(manifest)
        } catch {
            let permissions = await Recorder.permissions()
            if !permissions.screenAudio {
                recordingError = L("record.needsPermission")
            } else {
                recordingError = (error as? LocalizedError)?.errorDescription ?? L("record.couldNotStart")
            }
        }
    }

    func stopRecording() async {
        do {
            let manifest = try await recorder.stop()
            engine.recordingFinished(manifest)
            recordingTitle = ""
        } catch {
            recordingError = L("record.couldNotStop")
        }
    }

    // MARK: Queue status

    func queueStatus(now: Date = Date()) -> QueueStatus? {
        let jobs = engine.jobs
        if let job = jobs.first(where: { $0.status == .running }) {
            let title = engine.sources.first { $0.id == job.sourceId }?.title ?? ""
            switch job.kind {
            case .transcribe:
                let progress = job.progress ?? engine.sources.first { $0.id == job.sourceId }?.progress
                let text = progress.map { L("queue.transcribingPercent", title, Fmt.percent($0)) } ?? L("queue.transcribing", title)
                return QueueStatus(text: text, progress: progress)
            case .ingest: return QueueStatus(text: L("queue.ingesting", title), progress: nil)
            case .classify: return QueueStatus(text: L("queue.classifying", title), progress: nil)
            case .lint: return QueueStatus(text: L("queue.linting"), progress: nil)
            case .saveAnswer: return QueueStatus(text: L("queue.savingAnswer"), progress: nil)
            }
        }
        let queued = jobs.filter { $0.status == .queued }
        guard !queued.isEmpty else { return nil }
        let waits = queued.map { $0.notBefore ?? .distantPast }
        if let earliest = waits.min(), earliest > now {
            return QueueStatus(text: L("queue.waitingClaude", Fmt.time(earliest)), progress: nil, waiting: true)
        }
        if let until = rateLimitedUntil, until > now {
            return QueueStatus(text: L("queue.waitingClaude", Fmt.time(until)), progress: nil, waiting: true)
        }
        return QueueStatus(text: queued.count == 1 ? L("queue.oneWaiting") : L("queue.manyWaiting", queued.count), progress: nil)
    }

    // MARK: Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .sourceUpdated(let source):
            switch source.status {
            case .done:
                vaultRevision += 1
                reloadProjects()
                notifyOnce("done-\(source.id)-\(source.historyId ?? "")",
                           title: L("notify.doneTitle"), body: L("notify.doneBody", source.title))
            case .failed:
                notifyOnce("failed-\(source.id)-\(source.updatedAt.timeIntervalSince1970)",
                           title: L("notify.failedTitle"), body: L("notify.failedBody", source.title))
            case .needsProject:
                notifyOnce("inbox-\(source.id)", title: L("notify.inboxTitle"), body: L("notify.inboxBody", source.title))
            default:
                break
            }
        case .jobFailed(let job):
            guard job.sourceId == nil else { return }
            let body = job.kind == .lint ? L("notify.lintFailed") : L("notify.jobFailed")
            notifyOnce("job-\(job.id)", title: L("notify.failedTitle"), body: body)
        case .rateLimited(let until):
            rateLimitedUntil = until
            notifyOnce("rate-\(Int(until.timeIntervalSince1970 / 60))",
                       title: L("notify.rateTitle"), body: L("notify.rateBody", Fmt.time(until)))
        case .historyAdded(let entry):
            bumpHistory()
            switch entry.kind {
            case .lint: notifyOnce("hist-\(entry.id)", title: L("notify.lintTitle"), body: L("notify.lintBody", entry.changes.count))
            case .saveAnswer: notifyOnce("hist-\(entry.id)", title: L("notify.savedTitle"), body: entry.title)
            default: break
            }
        }
    }

    private func notifyOnce(_ key: String, title: String, body: String) {
        guard notified.insert(key).inserted else { return }
        Notifier.post(title: title, body: body, id: key)
    }
}
