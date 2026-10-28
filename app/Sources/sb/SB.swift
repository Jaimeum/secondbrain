import ArgumentParser
import BrainCore
import Foundation
import Transcription

@main
struct SB: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sb",
        abstract: "SecondBrain from the terminal: record → transcribe → Claude keeps your wiki.",
        discussion: "Set SB_CONFIG=/path/config.json to use an alternate configuration.",
        subcommands: [Init.self, ProjectCmd.self, Projects.self, Owner.self, Simulate.self, Run.self, Status.self, Import.self,
                      Note.self, Assign.self, Retry.self, Delete.self, Ask.self, Lint.self, History.self, Diff.self,
                      Undo.self, Models.self, EmailCmd.self, TasksCmd.self, TaskCmd.self, TemplatesCmd.self, TemplateCmd.self,
                      Reformat.self, TimelineCmd.self, SetDate.self, Export.self, SelfTest.self,
                      DemoVaultCmd.self, GraphCmd.self,  // MARK: v0.3 graph
                      GitHubCmd.self]  // MARK: v0.4 github
                      + [RulesCmd.self, RouteCmd.self]  // MARK: v0.4 routing
                      + [FactsCmd.self]  // MARK: v0.6 facts
                      + [EntityCmd.self]  // MARK: v0.6 entity
                      + [ChatCmd.self]  // MARK: v0.6 ask
                      + [SearchCmd.self]  // MARK: v0.6 search
                      + [RepliesCmd.self]  // MARK: v0.7 replies
    )
}

// MARK: - Shared

@MainActor
func makeEngine(_ config: AppConfig = AppConfig.load()) -> BrainEngine {
    let transcriber = WhisperTranscriber(modelName: config.whisperModel, modelsDir: DataPaths(root: config.dataURL).models)
    transcriber.messageLanguage = config.uiLanguage
    let engine = BrainEngine(config: config, transcriber: transcriber)
    engine.autoProcess = false
    engine.start()
    return engine
}

struct CLIError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

func eprint(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func stamp(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.string(from: d)
}

/// Prints queue progress while `runUntilIdle` works. Only one process works through the queue at a time
/// (`data/queue.lock`): if the app (or another `sb`) has it, this says so and returns, or waits with `wait`.
@MainActor
func runQueue(_ engine: BrainEngine, wait: Bool = false) async {
    var lastMessage: [String: String] = [:]
    var lastStatus: [String: SourceStatus] = [:]
    engine.onJobUpdate = { job in
        let line = "[\(job.kind.rawValue)] \(job.status.rawValue)"
            + (job.progress.map { String(format: " %3.0f%%", $0 * 100) } ?? "")
            + (job.message.map { " — \($0)" } ?? "")
        if lastMessage[job.id] != line {
            lastMessage[job.id] = line
            print(line)
        }
    }
    engine.onEvent = { event in
        switch event {
        case .sourceUpdated(let s):
            guard lastStatus[s.id] != s.status else { return }
            lastStatus[s.id] = s.status
            print("  · \(s.title) [\(s.id)] → \(s.status.rawValue)" + (s.error.map { " (\($0))" } ?? ""))
        case .jobFailed(let j):
            print("✗ \(j.kind.rawValue) failed: \(j.error ?? "?")")
        case .rateLimited(let until):
            print("⏸ Claude usage limit — jobs resume at \(stamp(until))")
        case .historyAdded(let e):
            print("✓ \(e.title): \(e.changes.count) files changed (history \(e.id))")
            if let summary = engine.history.summary(entryId: e.id) { print(summary.split(separator: "\n").map { "    " + $0 }.joined(separator: "\n")) }
        }
    }
    if engine.queueBusyElsewhere, wait { print(busyMessage(engine) + " " + (es(engine) ? "Esperando…" : "Waiting…")) }
    guard await engine.runUntilIdle(waitForLock: wait) else {
        print(busyMessage(engine) + " " + (es(engine) ? "Lo que encolaste lo procesará esa instancia (o usa --wait)."
                                                      : "That instance will process what you queued (or use --wait)."))
        return
    }
    let waiting = engine.jobs.filter { $0.status == .queued }
    if !waiting.isEmpty {
        print("\(waiting.count) job(s) still waiting" + (waiting.compactMap(\.notBefore).min().map { " until \(stamp($0))" } ?? ""))
    } else {
        print("Queue is empty.")
    }
}

@MainActor func es(_ engine: BrainEngine) -> Bool { !engine.config.uiLanguage.lowercased().hasPrefix("en") }

@MainActor func busyMessage(_ engine: BrainEngine) -> String {
    let otherSB = engine.queueHolderName() == "sb"
    if es(engine) {
        return otherSB ? "Otra instancia (otro `sb`) está procesando la cola." : "Otra instancia (la app) está procesando la cola."
    }
    return otherSB ? "Another instance (another `sb`) is processing the queue." : "Another instance (the app) is processing the queue."
}

// MARK: - Setup

struct Init: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create/update the config and install the vault template.")
    @Option(help: "Vault folder") var vault: String?
    @Option(help: "Data folder") var data: String?
    @Option(help: "es | en") var language: String?
    @Option var ingestModel: String?
    @Option var queryModel: String?
    @Option var whisperModel: String?
    @Option var claudePath: String?

    @MainActor func run() async throws {
        var config = AppConfig.load()
        if let vault { config.vaultPath = vault }
        if let data { config.dataPath = data }
        if let language { config.uiLanguage = language }
        if let ingestModel { config.ingestModel = ingestModel }
        if let queryModel { config.queryModel = queryModel }
        if let whisperModel { config.whisperModel = whisperModel }
        if let claudePath { config.claudePath = claudePath }
        try config.save()
        let engine = makeEngine(config)
        print("config: \(AppConfig.configURL.path)")
        print("vault:  \(engine.config.vaultURL.path)")
        print("data:   \(engine.paths.root.path)")
        let hasSchema = FileManager.default.fileExists(atPath: engine.vault.url(for: "CLAUDE.md").path)
        print("schema: \(hasSchema ? "CLAUDE.md installed" : "missing (vault template not found)")")
        print("claude: \(ClaudeSetup.locate(config: config)?.path ?? "not found")")
    }
}

struct ProjectCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "project", abstract: "Manage projects.",
                                                    subcommands: [Create.self])

    struct Create: AsyncParsableCommand {
        @Argument var name: String
        @Option var description: String = ""
        @Option var emoji: String = "📁"

        @MainActor func run() async throws {
            let p = try makeEngine().projects.create(name: name, description: description, emoji: emoji)
            print("\(p.emoji) \(p.name) → projects/\(p.slug)")
        }
    }
}

struct Projects: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List projects.")
    @MainActor func run() async throws {
        let list = makeEngine().projects.list()
        if list.isEmpty { print("No projects yet. Create one with: sb project create \"Name\"") }
        for p in list { print("\(p.emoji) \(p.slug)\t\(p.name)\(p.description.isEmpty ? "" : " — \(p.description)")") }
    }
}

struct Owner: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show or set your name (who «Yo» is in transcripts).")
    @Argument var name: String?

    @MainActor func run() async throws {
        let engine = makeEngine()
        engine.start()
        if let name { try engine.vault.setOwnerName(name) }
        print(engine.vault.ownerName() ?? "(not set)")
    }
}

// MARK: - Pipeline

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Process the job queue until it is idle.",
                                                    discussion: "If the app (or another sb) is processing the queue, exits 0 unless --wait.")
    @Flag(help: "Wait until the other instance releases the queue") var wait = false
    @Option(help: ArgumentHelp("Behave like the app for N seconds (auto-processing + watching data/); for tests", visibility: .hidden))
    var serve: Int?
    @Option(help: ArgumentHelp("With --serve: after 3 s switch to this config via reload(config:)", visibility: .hidden))
    var reloadConfig: String?

    @MainActor func run() async throws {
        guard let serve else { return await runQueue(makeEngine(), wait: wait) }
        let config = AppConfig.load()
        let transcriber = WhisperTranscriber(modelName: config.whisperModel, modelsDir: DataPaths(root: config.dataURL).models)
        transcriber.messageLanguage = config.uiLanguage
        let engine = BrainEngine(config: config, transcriber: transcriber)
        engine.onEvent = { event in
            if case .sourceUpdated(let s) = event { print("  · \(s.title) [\(s.id)] → \(s.status.rawValue)") }
        }
        engine.onJobUpdate = { job in print("[\(job.kind.rawValue)] \(job.status.rawValue)") }
        engine.start()
        var wasBusy: Bool?
        for tick in 0..<(serve * 2) {
            if tick == 6, let reloadConfig {
                let data = try Data(contentsOf: URL(fileURLWithPath: reloadConfig))
                let next = try JSONDecoder().decode(AppConfig.self, from: data)
                print("reloading: \(engine.sources.count) sources at \(engine.paths.root.path)")
                try await engine.reload(config: next)
                print("reloaded: \(engine.sources.count) sources at \(engine.paths.root.path), vault \(engine.vault.root.path)")
            }
            if wasBusy != engine.queueBusyElsewhere {
                wasBusy = engine.queueBusyElsewhere
                print("queueBusyElsewhere=\(engine.queueBusyElsewhere) processing=\(engine.isProcessing)")
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        print("serve done: \(engine.jobs.count) job(s) left")
    }
}

struct Status: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show sources and jobs.")
    @Option(help: "How many sources to show") var limit = 20

    @MainActor func run() async throws {
        let engine = makeEngine()
        print("Sources:")
        if engine.sources.isEmpty { print("  (none)") }
        for s in engine.sources.prefix(limit) {
            var line = "  \(s.id)  \(s.kind.rawValue)\t\(s.status.rawValue)\t\(s.projectSlug ?? "—")\t\(s.title)"
            line += "  (happened \(stamp(s.timelineDate)), added \(stamp(s.createdAt)))"
            if let sug = s.suggestedProject { line += "  [suggested: \(sug)]" }
            if let err = s.error { line += "  ! \(err)" }
            print(line)
        }
        print("Jobs:")
        if engine.jobs.isEmpty { print("  (none)") }
        for j in engine.jobs {
            var line = "  \(j.id.prefix(8))  \(j.kind.rawValue)\t\(j.status.rawValue)\tattempts=\(j.attempts)"
            if let nb = j.notBefore { line += "  not before \(stamp(nb))" }
            if let err = j.error { line += "  ! \(err)" }
            print(line)
        }
    }
}

struct Import: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Import a file or URL as a source.")
    @Argument var target: String
    @Option var project: String?
    @Option(help: "When it happened (default: the file's own date)") var date: String?
    @Option(help: "Format (template id) for a recording's page") var template: String?
    @Flag(help: "Process the queue right away") var run = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        let eventDate = try date.map(parseUserDate)
        if let url = URL(string: target), let scheme = url.scheme, ["http", "https"].contains(scheme.lowercased()) {
            try await engine.importURL(url, projectSlug: project, eventDate: eventDate)
        } else {
            let path = (target as NSString).expandingTildeInPath
            guard FileManager.default.fileExists(atPath: path) else { throw CLIError("File not found: \(path)") }
            try await engine.importFileAsync(URL(fileURLWithPath: path), projectSlug: project, eventDate: eventDate, templateId: template)
        }
        if let s = engine.sources.first {
            let target = s.kind == .meeting ? "meeting, to transcribe" : (s.rawPath ?? "?")
            print("Imported \(s.title) [\(s.id)] → \(target) (\(s.status.rawValue))")
        }
        if run { await runQueue(engine) }
    }
}

struct Note: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Add a text note as a source.")
    @Argument var title: String
    @Argument var text: String
    @Option var project: String?
    @Option(help: "When it happened (default: now)") var date: String?
    @Flag(help: "Process the queue right away") var run = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        try engine.addNote(title: title, body: text, projectSlug: project, eventDate: try date.map(parseUserDate))
        if let s = engine.sources.first { print("Note \(s.title) [\(s.id)] → \(s.rawPath ?? "?") (\(s.status.rawValue))") }
        if run { await runQueue(engine) }
    }
}

struct Assign: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "File an unassigned source under a project.")
    @Argument var sourceId: String
    @Argument var slug: String
    @Flag(help: "Process the queue right away") var run = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        try engine.assign(sourceId: sourceId, to: slug)
        print("Assigned \(sourceId) → \(slug): \(engine.source(sourceId)?.rawPath ?? "")")
        if run { await runQueue(engine) }
    }
}

struct Retry: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Retry a failed source.")
    @Argument var sourceId: String
    @Flag(help: "Process the queue right away") var run = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        engine.retry(sourceId: sourceId)
        print("\(sourceId): \(engine.source(sourceId)?.status.rawValue ?? "not found")")
        if run { await runQueue(engine) }
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete a source record (and leftover audio).")
    @Argument var sourceId: String
    @MainActor func run() async throws {
        try makeEngine().delete(sourceId: sourceId)
        print("Deleted \(sourceId)")
    }
}

// MARK: - Simulate

struct Simulate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Create a recording session from audio files, as the recorder would.")
    @Option(help: "System-audio track (WAV/AIFF/any AVAudioFile format)") var system: String
    @Option(help: "Microphone track") var mic: String?
    @Option var project: String?
    @Option var title: String?
    @Option(help: "Seconds per chunk") var chunkSeconds = 300
    @Option(help: "When the recording started (ISO or e.g. 2026-10-20 10:00; default: now minus its duration)") var started: String?
    @Flag(help: "Process the queue right away") var run = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        let startOverride = try started.map(parseUserDate)
        let rate = 16_000
        var systemSamples = try await AudioPrep.loadMono16k(URL(fileURLWithPath: (system as NSString).expandingTildeInPath))
        var micSamples: [Int16]?
        if let mic { micSamples = try await AudioPrep.loadMono16k(URL(fileURLWithPath: (mic as NSString).expandingTildeInPath)) }
        let total = max(systemSamples.count, micSamples?.count ?? 0)
        systemSamples += [Int16](repeating: 0, count: total - systemSamples.count)
        if let m = micSamples { micSamples = m + [Int16](repeating: 0, count: total - m.count) }

        let duration = Double(total) / Double(rate)
        let end = startOverride.map { $0.addingTimeInterval(duration) } ?? Date()
        let start = startOverride ?? end.addingTimeInterval(-duration)
        let id = SessionManifest.newId(at: start)
        let dir = engine.paths.sessions.appendingPathComponent(id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        var tracks: [String: [String]] = [:]
        tracks["system"] = try AudioPrep.writeChunks(systemSamples, prefix: "system", chunkSeconds: chunkSeconds, sampleRate: rate, dir: dir)
        if let micSamples {
            tracks["mic"] = try AudioPrep.writeChunks(micSamples, prefix: "mic", chunkSeconds: chunkSeconds, sampleRate: rate, dir: dir)
        }
        var manifest = SessionManifest(id: id, title: title, projectSlug: project, startedAt: start,
                                       sampleRate: rate, chunkSeconds: chunkSeconds, tracks: tracks, micCaptured: micSamples != nil)
        try manifest.save(to: dir)
        engine.recordingStarted(manifest)
        manifest.endedAt = end
        try manifest.save(to: dir)
        engine.recordingFinished(manifest)
        print(String(format: "Session %@ (%.1f s, %d chunk(s)/track) queued for transcription.", id, duration, tracks["system"]?.count ?? 0))
        if run { await runQueue(engine) } else { print("Run `sb run` to process it.") }
    }
}

// MARK: - Claude

struct Ask: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Ask your wiki a question (streams the answer).")
    @Argument var question: String
    @Option var project: String?
    @Flag(help: "Show which files Claude reads") var verbose = false
    @Flag(help: "Save the answer into the wiki afterwards") var save = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        var printed = false
        var answer = ""
        for try await event in engine.ask(question, projectSlug: project) {
            switch event {
            case .text(let t):
                print(t)
                printed = true
            case .tool(_, let detail):
                if verbose { eprint("  … \(detail)") }
            case .done(let result, let isError):
                answer = result
                if isError { throw CLIError(result) }
                if !printed { print(result) }
            }
        }
        if save, !answer.isEmpty {
            engine.saveAnswer(question: question, answer: answer, projectSlug: project)
            await runQueue(engine)
        }
    }
}

struct Lint: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Let Claude check and tidy the wiki.")
    @Option var project: String?
    @Flag(help: "Only enqueue; don't process now") var noRun = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        engine.lint(projectSlug: project)
        if noRun { print("Lint queued.") } else { await runQueue(engine) }
    }
}

// MARK: - History

struct History: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List changes Claude made to the vault.")
    @MainActor func run() async throws {
        let entries = makeEngine().history.entries()
        if entries.isEmpty { print("No changes yet.") }
        for e in entries {
            print("\(e.id)  \(stamp(e.createdAt))  \(e.undone ? "[undone] " : "")\(e.title)  (\(e.changes.count) files)")
        }
    }
}

struct Diff: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show what a history entry changed.")
    @Argument var historyId: String
    @Option(help: "Only this vault-relative path") var path: String?

    @MainActor func run() async throws {
        let engine = makeEngine()
        guard let entry = engine.history.entries().first(where: { $0.id == historyId }) else { throw CLIError("No such entry") }
        print("\(entry.title)\n")
        if let summary = engine.history.summary(entryId: historyId) { print(summary + "\n") }
        let dir = engine.paths.history.appendingPathComponent(historyId)
        for change in entry.changes where path == nil || change.path == path {
            let before = change.change == .added ? "/dev/null" : dir.appendingPathComponent("before/\(change.path)").path
            let after = change.change == .deleted ? "/dev/null" : dir.appendingPathComponent("after/\(change.path)").path
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/diff")
            p.arguments = ["-u", "--label", "a/\(change.path)", "--label", "b/\(change.path)", before, after]
            try p.run()
            p.waitUntilExit()
        }
    }
}

struct Undo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Undo the changes of a history entry.")
    @Argument var historyId: String
    @Flag(help: "Undo even if those files changed later") var force = false

    @MainActor func run() async throws {
        do {
            try makeEngine().undo(historyId: historyId, force: force)
            print("Undone \(historyId)")
        } catch HistoryError.conflict(let paths) {
            throw CLIError("These files changed afterwards:\n  " + paths.joined(separator: "\n  ") + "\nUse --force to undo anyway.")
        }
    }
}

// MARK: - Models

struct Models: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Transcription models.", subcommands: [Prepare.self])

    struct Prepare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Download and load the WhisperKit/SpeakerKit models.")
        @MainActor func run() async throws {
            let config = AppConfig.load()
            let transcriber = WhisperTranscriber(modelName: config.whisperModel, modelsDir: DataPaths(root: config.dataURL).models)
            transcriber.messageLanguage = config.uiLanguage
            try await transcriber.prepare { p in
                print(String(format: "%3.0f%% %@", p.fraction * 100, p.message))
            }
            print("Models ready (\(config.whisperModel)).")
        }
    }
}
