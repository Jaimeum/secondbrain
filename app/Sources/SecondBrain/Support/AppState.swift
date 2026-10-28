import AppKit
import BrainCore
import Observation
import Recorder
import Transcription

// SidebarItem, HomeRoute, Destination and the router: Support/Navigation.swift (CONTRACT §16.12).

/// "Nueva nota" from ⌘K (MainView presents `NoteSheet`).
struct NoteRequest: Identifiable, Equatable {
    let id = UUID()
    var projectSlug: String?
}

/// "Agregar correo": which thread (fixed when adding the next email of a thread) and project to start with.
struct EmailRequest: Identifiable, Equatable {
    let id = UUID()
    var threadKey: String?
    var projectSlug: String?
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
    /// Waiting for the running job to finish before the engine moves to another vault ("Terminando la tarea actual…").
    private(set) var isSwitchingVault = false
    /// Bumped after the engine moved to another vault: views holding pages, chats or history start fresh.
    private(set) var vaultGeneration = 0

    private(set) var modelProgress: ModelPrepProgress?
    private(set) var modelsReady = false
    private(set) var modelError: String?
    var isPreparingModels: Bool { modelTask != nil }

    private(set) var rateLimitedUntil: Date?
    var recordingError: String?
    var restartNeeded = false
    var selection: SidebarItem? = .home

    var recordingProjectSlug: String? {
        didSet {
            guard isRecording else { return }
            recorder.updateCurrent(title: recordingTitleOrNil, projectSlug: recordingProjectSlug)
            // The source follows too ("Sin proyecto" mid-recording must send it to Inbox).
            if let id = currentRecordingId { engine.setRecordingProject(sourceId: id, projectSlug: recordingProjectSlug) }
        }
    }
    var recordingTitle = "" {
        didSet { if isRecording { recorder.updateCurrent(title: recordingTitleOrNil, projectSlug: recordingProjectSlug) } }
    }
    /// "Formato" chosen in the menu bar panel (nil = the project's default).
    var recordingTemplateId: String? {
        didSet {
            if isRecording, let id = currentRecordingId { engine.setTemplate(sourceId: id, templateId: recordingTemplateId) }
        }
    }
    @ObservationIgnored private var currentRecordingId: String?

    /// Templates ("formatos") of the vault, refreshed after every change.
    private(set) var templates: [TemplateInfo] = []
    /// My overdue tasks across every project (sidebar badge of "Mis pendientes").
    private(set) var overdueCount = 0
    /// Bumped when tasks changed (a checkbox toggled here, or Claude finished a job).
    private(set) var tasksRevision = 0
    /// Open the "Agregar correo" sheet (menu bar, ⌘⇧V, sidebar, thread view).
    var emailRequest: EmailRequest?
    /// The vault was updated to the new version and kept something of the user's (engine.migrationNotice).
    var migrationNotice: String? {
        guard let notice = engine.migrationNotice, notice != dismissedMigrationNotice else { return nil }
        return notice
    }
    private var dismissedMigrationNotice = UserDefaults.standard.string(forKey: "migration.dismissed")
    // MARK: v0.6 navigation (CONTRACT §16.12) — requests left by `navigate(to:)` for the screen it selects. Only the
    // router sets them (it clears them all first); the screen that consumes one clears it.
    /// A vault page to open: a project's own page in Contenido, a foreign page as a ficha filtered to the project
    /// (ProjectView), a person in Personas (PeopleView).
    var pendingPage: String?
    /// A page to center the Grafo on (GraphView of the brain, or ProjectView's Grafo tab).
    var pendingGraphFocus: String?
    /// MeetingsView selects this event and clears it.
    var pendingEventId: String?
    /// With `pendingEventId`: open the event on its preparation ("Prepararme" from Inicio), not the plain detail.
    var pendingEventPrepare = false
    /// ProjectView switches to this tab and clears it.
    var pendingProjectTab: ProjectTab?
    /// TasksView highlights this task (`TaskItem.id`) and clears it.
    var pendingTaskId: String?
    /// AskView (or a project's Preguntar tab) opens this conversation / asks this question and clears it.
    var pendingChat: ChatRequest?
    /// InboxView (Sin asignar) highlights this source's row and clears it ("failed" notification).
    var pendingSourceHighlight: String?
    /// A screen to push inside Inicio's NavigationStack; HomeView consumes it and clears it.
    var homeRoute: HomeRoute?
    /// Bumped by "Inicio" (sidebar row re-selected, ⌘1) while Inicio is on screen: HomeView pops back to its root.
    var homePopToken = 0
    /// "Editar" on a page or ficha (§16.6): MainView presents the editor over everything while set.
    var editingPage: String?
    /// The first "Grabar" waiting for RecordingIntroSheet (§16.11; MainView presents it while set).
    var recordingIntro: RecordingIntroRequest?
    /// SwiftUI's `openWindow(id: "main")`, left by the menu bar icon (always on screen): the main window can be
    /// reopened from code that has no view (⌥⌘R, the menu bar's Grabar) after the user closed it.
    @ObservationIgnored var openMainWindowAction: (() -> Void)?
    /// "Historial" over any screen (MainView presents `ActivitySheet`).
    var historyRequest: HistoryRequest?
    /// "Enlace…" from the sidebar's "+ Agregar".
    var linkRequest: LinkRequest?
    /// The ⌘K palette is on screen.
    var searchPresented = false
    /// "Nuevo proyecto" sheet (⌘N, sidebar, ⌘K).
    var showNewProject = false
    /// "Nueva nota" from ⌘K.
    var noteRequest: NoteRequest?
    /// v0.6 ask (§16.3): Preguntar's saved conversations per scope ("brain" / "project:<slug>"), kept while the app
    /// runs so an answer keeps streaming off screen. Created on first use; dropped when the vault changes.
    @ObservationIgnored private var conversationsByScope: [String: Conversations] = [:]
    /// v0.3: bumped when connected accounts change (connect / disconnect), so Correo and Reuniones reload.
    var accountsRevision = 0
    @ObservationIgnored private var overdueReload: Task<Void, Never>?

    @ObservationIgnored private var modelTask: Task<Void, Never>?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var notified = Set<String>()
    @ObservationIgnored private var vaultSwitch: Task<Void, Never>?
    @ObservationIgnored private var projectsReload: Task<Void, Never>?

    private init() {
        // Snapshots seed chats and migrate the vault: never against the owner's real config.
        let env = ProcessInfo.processInfo.environment
        if !(env["SB_SNAPSHOT_DIR"] ?? "").isEmpty, (env["SB_CONFIG"] ?? "").isEmpty {
            FileHandle.standardError.write(Data("SB_SNAPSHOT_DIR needs SB_CONFIG pointing at an isolated config.json\n".utf8))
            exit(64)
        }
        let config = AppConfig.load()
        self.config = config
        menuLanguageAtLaunch = config.uiLanguage
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
        Self.applyAppearance(config.appearance)
        // Development snapshots (SB_SNAPSHOT_DIR) never start Claude jobs, download models, register the hot key or
        // ask for any system permission.
        let snapshot = DebugSnapshots.directory != nil
        if snapshot { engine.autoProcess = false }
        if !snapshot {
            Notifier.requestAuthorization()
            applyHotKey()
            QuickCapturePanel.shared.applyHotKey(state: self)   // MARK: v0.6 capture — ⌥⌘N or the recorded one (§16.10)
        }
        if config.onboardingComplete {
            startEngine()
            // v0.6 (§16.11): the transcription model waits for the first "Grabar" (or Ajustes); once recording was
            // set up it loads at launch as before.
            if !snapshot, recordingIntroDone { prepareModels() }
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
        reloadProjectsNow()
        reloadTemplates()
        refreshTasks()
        MeetingsModel.shared.start(state: self)   // MARK: v0.3 meetings — agenda for Reuniones and the banners
        GitHubModel.shared.start(state: self)   // MARK: v0.4 github — keeps the followed repos up to date (§13.4)
        MailAutoImporter.shared.start(state: self)   // MARK: v0.4 routing — §14.5 auto-add of mail by rule
        for manifest in Recorder.recoverInterruptedSessions(in: engine.paths.sessions) {
            engine.recordingFinished(manifest)
        }
    }

    func completeOnboarding() {
        update { $0.onboardingComplete = true }
        startEngine()
    }

    /// Quits and opens SecondBrain again. The new instance starts only after this process has exited, so two
    /// engines never share the queue (a quick `open -n` while we are still shutting down could run a job twice).
    func relaunch() {
        let pid = String(ProcessInfo.processInfo.processIdentifier)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let wait = "i=0; while kill -0 \"$1\" 2>/dev/null && [ $i -lt 300 ]; do sleep 0.1; i=$((i+1)); done; "
        if Bundle.main.bundleURL.pathExtension == "app" {
            process.arguments = ["-c", wait + "/usr/bin/open -n \"$0\"", Bundle.main.bundlePath, pid]
        } else if let exe = Bundle.main.executablePath {
            // Bare `swift build` binary (development): start it detached, keeping the environment (SB_CONFIG).
            process.arguments = ["-c", wait + "nohup \"$0\" >/dev/null 2>&1 &", exe, pid]
        } else {
            return
        }
        do { try process.run() } catch { return }
        NSApp.terminate(nil)
    }

    // MARK: Connected accounts (CONTRACT §12.3)

    /// Opens the browser to sign in and adds the account. Throws `AccountError` (`.notConfigured`, `.cancelled`,
    /// `.consentRequired` → show `OrgAccessHelpSheet`). Cancel by cancelling the calling task.
    @discardableResult
    func connectAccount(_ provider: AccountProvider) async throws -> ConnectedAccount {
        let registration = OAuthAppRegistration.effective(config: config)
        let account = try await engine.accounts.connect(provider, registration: registration) { url in
            DispatchQueue.main.async { NSWorkspace.shared.open(url) }
        }
        accountsRevision += 1
        return account
    }

    func disconnectAccount(_ id: String) throws {
        try engine.accounts.disconnect(id)
        accountsRevision += 1
    }

    // MARK: Appearance (CONTRACT §12.1)

    /// "system" follows macOS; "light" / "dark" force it for every window, sheet and web view, without a restart.
    static func applyAppearance(_ mode: String) {
        let appearance: NSAppearance? = switch mode {
        case "light": NSAppearance(named: .aqua)
        case "dark": NSAppearance(named: .darkAqua)
        default: nil
        }
        NSApplication.shared.appearance = appearance
    }

    // MARK: Menu language

    /// The language AppKit/SwiftUI menus (Edit, View, Window…) were built with at launch.
    let menuLanguageAtLaunch: String

    /// Menus follow `AppleLanguages`, read once when the app launches: set it before NSApplication finishes launching.
    nonisolated static func applyMenuLanguage(_ language: String) {
        let lang = language == "en" ? "en" : "es"
        UserDefaults.standard.set([lang], forKey: "AppleLanguages")
    }

    /// The UI switched language live, but the system menus keep the launch language until a restart.
    var menuLanguageNeedsRestart: Bool { config.uiLanguage != menuLanguageAtLaunch }

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
            Self.applyMenuLanguage(next.uiLanguage)
        }
        if next.hotkeyEnabled != old.hotkeyEnabled { applyHotKey() }
        if next.captureHotkeyEnabled != old.captureHotkeyEnabled || next.captureHotkey != old.captureHotkey {   // MARK: v0.6 capture
            QuickCapturePanel.shared.applyHotKey(state: self)
        }
        if next.appearance != old.appearance { Self.applyAppearance(next.appearance) }

        let modelChanged = next.whisperModel != old.whisperModel
        if !engineStarted {
            if next.dataPath != old.dataPath || modelChanged || next.vaultPath != old.vaultPath {
                rebuildEngine(modelChanged: next.dataPath != old.dataPath || modelChanged)
            }
        } else if next.dataPath != old.dataPath {
            // The recorder writes sessions under the data folder for the life of the app: restart for this one.
            restartNeeded = true
        } else if next.vaultPath != old.vaultPath || modelChanged {
            switchEngine(to: next, modelChanged: modelChanged, vaultChanged: next.vaultPath != old.vaultPath)
        } else {
            try? engine.updateConfig(next)
        }
    }

    /// Moves the running engine to another vault (or transcription model) without a restart: it stops taking
    /// jobs, lets the current one finish (the UI says "Terminando la tarea actual…"), then reopens everything.
    private func switchEngine(to next: AppConfig, modelChanged: Bool, vaultChanged: Bool) {
        var newTranscriber: WhisperTranscriber?
        if modelChanged {
            modelTask?.cancel()
            modelTask = nil
            modelsReady = false
            modelProgress = nil
            modelError = nil
            let t = WhisperTranscriber(modelName: next.whisperModel, modelsDir: DataPaths(root: next.dataURL).models)
            t.messageLanguage = next.uiLanguage
            transcriber = t
            newTranscriber = t
        }
        let previous = vaultSwitch
        isSwitchingVault = true
        vaultSwitch = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.engine.reload(config: next, transcriber: newTranscriber)
            } catch {
                // Could not save the config: fall back to the old behaviour (apply on restart).
                self.restartNeeded = true
            }
            // A newer change may have arrived while waiting; only the last one settles the UI.
            guard self.config.vaultPath == next.vaultPath, self.config.whisperModel == next.whisperModel else { return }
            self.isSwitchingVault = false
            self.vaultSwitch = nil
            self.didSwitchVault(vaultChanged: vaultChanged)
            if modelChanged { self.prepareModels() }
        }
    }

    private func didSwitchVault(vaultChanged: Bool) {
        reloadProjectsNow()
        reloadTemplates()
        refreshTasks()
        if case .project(let slug) = selection, project(slug) == nil { selection = .home }
        if let slug = recordingProjectSlug, project(slug) == nil { recordingProjectSlug = nil }
        // Conversations were about the other vault's pages: start fresh (an answer still streaming is stopped).
        // A transcription-model change alone keeps them.
        if vaultChanged {
            for conversations in conversationsByScope.values { conversations.stopAll() }
            conversationsByScope.removeAll()
            clearPending()
        }
        vaultGeneration += 1
        bumpHistory()
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
            hotKey = GlobalHotKey { [weak self] in self?.recordNow(placement: .menuBar) }
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

    /// Re-reads `projects/*/project.json` off the main thread (called after every finished job).
    func reloadProjects() {
        guard engineStarted else { return }
        projectsReload?.cancel()
        let manager = engine.projects
        projectsReload = Task { [weak self] in
            let list = await manager.listAsync()
            guard let self, !Task.isCancelled, manager === self.engine.projects else { return }
            let sorted = Self.sorted(list)
            if sorted != self.projects { self.projects = sorted }
        }
    }

    /// Synchronous variant for the moments the UI needs the list right away (start, vault switch).
    private func reloadProjectsNow() {
        guard engineStarted else { return }
        projectsReload?.cancel()
        projects = Self.sorted(engine.projects.list())
    }

    private static func sorted(_ list: [Project]) -> [Project] {
        list.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult
    func createProject(name: String, description: String, emoji: String) throws -> Project {
        let project = try engine.projects.create(name: name, description: description, emoji: emoji)
        // Callers select the new project immediately: it must already be in the list.
        projects = Self.sorted(projects.filter { $0.slug != project.slug } + [project])
        reloadProjects()
        vaultRevision += 1
        return project
    }

    /// "Editar proyecto…": name, emoji, description (the slug never changes).
    func updateProject(_ project: Project) throws {
        try engine.projects.update(project)
        projects = Self.sorted(projects.map { $0.slug == project.slug ? project : $0 })
        reloadProjects()
        vaultRevision += 1
    }

    /// Preguntar's conversations of a scope (saved under `data/chats/<vault>/`, §16.3: per vault).
    func conversations(for scope: Scope) -> Conversations {
        if let existing = conversationsByScope[scope.key] { return existing }
        let conversations = Conversations(scope: scope, store: ChatStore(dataRoot: config.dataURL, vaultRoot: config.vaultURL))
        conversationsByScope[scope.key] = conversations
        return conversations
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

    // MARK: Templates, tasks, emails (v0.2)

    /// Read once per vault: remembered so the same notice doesn't come back on every launch.
    func dismissMigrationNotice() {
        let notice = engine.migrationNotice
        UserDefaults.standard.set(notice, forKey: "migration.dismissed")
        dismissedMigrationNotice = notice
        engine.dismissMigrationNotice()
    }

    func reloadTemplates() {
        guard engineStarted else { return }
        let list = engine.templates(scope: nil)
        if list != templates { templates = list }
    }

    /// Templates usable for a kind of source (scope matches or "any"), builtin "estándar" first.
    func templates(for scope: TemplateScope) -> [TemplateInfo] {
        templates.filter { $0.scope == scope || $0.scope == .any }
    }

    func template(_ id: String?) -> TemplateInfo? {
        guard let id else { return nil }
        return templates.first { $0.id == id }
    }

    /// Re-reads tasks (my overdue count) off the main thread's critical path; also tells task lists to reload.
    func refreshTasks() {
        guard engineStarted else { return }
        tasksRevision += 1
        overdueReload?.cancel()
        let engine = self.engine
        overdueReload = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let all = await engine.tasks(projectSlug: nil)
            guard let self, !Task.isCancelled, engine === self.engine else { return }
            let count = all.filter { $0.isMine && $0.isOverdue }.count
            if count != self.overdueCount { self.overdueCount = count }
        }
    }

    /// "Agregar correo" from anywhere: starts in the project being viewed.
    func requestEmail(threadKey: String? = nil, projectSlug: String? = nil) {
        var slug = projectSlug
        if slug == nil, threadKey == nil, case .project(let current) = selection { slug = current }
        emailRequest = EmailRequest(threadKey: threadKey, projectSlug: slug)
    }

    /// The source a `[[key]]` citation points at: the raw file name, or an email thread key.
    func source(forKey key: String) -> SourceRecord? {
        engine.sources.first { $0.sourceKey == key } ?? engine.sources.last { $0.threadKey == key }
    }

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

    /// The one "Grabar" behind every plain path (⌥⌘R, ⌘K › Grabar, the empty Inicio, RecordControl): stops a running
    /// recording; else records the meeting on now (its title, attendees and project, like its own "Grabar"); else a
    /// plain recording. `.sidebar` (the main window) sends a plain recording to the project on screen; `.menuBar`
    /// (and the hot key) keeps what "Detalles" says. `meeting: false` is "o grabar otra cosa".
    func recordNow(placement: RecordControlPlacement, meeting: Bool = true) {
        guard !isRecorderBusy else { return }
        if isRecording {
            Task { await stopRecording() }
            return
        }
        if meeting, let live = MeetingBanner.recordableNow(state: self, now: Date()) {
            Task { await MeetingsModel.shared.record(live, state: self) }
            return
        }
        if placement == .sidebar { recordingProjectSlug = currentProjectSlug }
        Task { await startRecording() }
    }

    // MARK: v0.3 meetings — optional calendar event + attendees (see AppState+Meetings.swift)
    func startRecording(calendarEventId: String? = nil, attendees: [String]? = nil) async {
        guard engineStarted else {
            recordingError = L("record.finishSetupFirst")
            return
        }
        // v0.6: the first recording goes through RecordingIntroSheet (permissions, consent, model), then runs.
        if await needsRecordingIntro(then: { [weak self] in
            await self?.startRecording(calendarEventId: calendarEventId, attendees: attendees)
        }) { return }
        recordingError = nil
        do {
            let manifest = try await recorder.start(title: recordingTitleOrNil, projectSlug: recordingProjectSlug,
                                                    captureMic: config.captureMic,
                                                    calendarEventId: calendarEventId, attendees: attendees)
            engine.recordingStarted(manifest)
            currentRecordingId = manifest.id
            if let template = recordingTemplateId { engine.setTemplate(sourceId: manifest.id, templateId: template) }
        } catch {
            let permissions = await Recorder.permissions()
            if !permissions.screenAudio {
                recordingError = L("record.needsPermission")
            } else {
                recordingError = (error as? LocalizedError)?.errorDescription ?? L("record.couldNotStart")
            }
        }
    }

    /// "Reparar permiso" under the permission error: macOS forgets the app's recording permissions and asks again
    /// (Recorder.repairPermissions). The system dialogs take over from here; macOS itself offers to reopen the app.
    func repairRecordingPermission() {
        recordingError = nil
        Task {
            if !(await Recorder.repairPermissions()) { recordingError = L("record.repairFailed") }
        }
    }

    func stopRecording() async {
        do {
            let manifest = try await recorder.stop()
            engine.recordingFinished(manifest)
            currentRecordingId = nil
            // The next recording starts clean: no title, project or format inherited from this one (didSet only
            // forwards these while recording).
            recordingTitle = ""
            recordingProjectSlug = nil
            recordingTemplateId = nil
        } catch {
            recordingError = L("record.couldNotStop")
        }
    }

    // MARK: Queue status

    func queueStatus(now: Date = Date()) -> QueueStatus? {
        if let saving = MailBatchSaver.shared.status { return saving }   // MARK: v0.7 backfill — §17.6 progress
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
            case .reformat: return QueueStatus(text: L("queue.reformatting", title), progress: nil)
            case .makeTemplate:
                let name = job.payload["name"] ?? ""
                return QueueStatus(text: name.isEmpty ? L("queue.makingTemplateUnnamed") : L("queue.makingTemplate", name), progress: nil)
            case .manualEdit: return QueueStatus(text: L("queue.savingEdit"), progress: nil)
            }
        }
        let queued = jobs.filter { $0.status == .queued }
        guard !queued.isEmpty else { return nil }
        // A job held for Correo's "Deshacer" (a few seconds) is not waiting for Claude.
        let waits = queued.map { $0.payload[BrainEngine.heldForUndoKey] != nil && $0.attempts == 0 ? .distantPast : ($0.notBefore ?? .distantPast) }
        if let earliest = waits.min(), earliest > now {
            return QueueStatus(text: L("queue.waitingClaude", Fmt.time(earliest)), progress: nil, waiting: true)
        }
        if let until = rateLimitedUntil, until > now {
            return QueueStatus(text: L("queue.waitingClaude", Fmt.time(until)), progress: nil, waiting: true)
        }
        return QueueStatus(text: L("queue.processing", queued.count), progress: nil)
    }

    // MARK: Engine events

    private func handle(_ event: EngineEvent) {
        switch event {
        case .sourceUpdated(let source):
            switch source.status {
            case .done:
                vaultRevision += 1
                reloadProjects()
                refreshTasks()
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
            refreshTasks()
            if entry.kind == .makeTemplate || entry.kind == .reformat { reloadTemplates() }
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
