import Foundation
import BrainCore

// MARK: v0.7.3 transcribe crash — a job that crashes the process must not run again on every launch.

private final class CrashNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}

/// A fresh engine on the same data folder, like the app launching again after a crash.
@MainActor private func launch(_ root: URL) -> BrainEngine {
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: CrashNoTranscriber())
    engine.autoProcess = false   // nothing runs: the test plays the part of `runNext` crashing
    engine.start()
    return engine
}

/// What `runNext` leaves on disk when the process dies inside `execute`: `running`, attempt already counted.
private func simulateCrashMidRun(_ jobsDir: URL, id: String) throws {
    let url = jobsDir.appendingPathComponent("\(id).json")
    var job = try JSONDecoder.sb.decode(Job.self, from: Data(contentsOf: url))
    job.status = .running
    job.attempts += 1
    job.notBefore = nil
    try JSONEncoder.sb.encode(job).write(to: url, options: .atomic)
}

@MainActor func testQueueCrashLoop(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let audio = root.appendingPathComponent("llamada.m4a")
        try Data(repeating: 7, count: 2048).write(to: audio)

        // Launch 1: a recording is queued for transcription.
        var engine = launch(root)
        let jobsDir = engine.paths.jobs
        try engine.importFile(audio, projectSlug: nil)
        guard let src = engine.sources.first(where: { $0.kind == .meeting }),
              let job = engine.jobs.first(where: { $0.sourceId == src.id && $0.kind == .transcribe }) else {
            t.check(false, "meeting imported with a transcribe job"); return
        }
        let sessionDir = engine.paths.sessions.appendingPathComponent(src.id)
        func sessionFiles() -> [String] { ((try? fm.contentsOfDirectory(atPath: sessionDir.path)) ?? []).sorted() }
        let filesBefore = sessionFiles()
        t.check(filesBefore.contains { $0.hasPrefix("original") } || fm.fileExists(atPath: audio.path),
                "session keeps the audio: \(filesBefore)")

        // Crash during attempt 1, launch 2: requeued with a backoff, interruption counted.
        try simulateCrashMidRun(jobsDir, id: job.id)
        engine = launch(root)
        var j = engine.jobs.first { $0.id == job.id }
        t.eq(j?.status, .queued, "1st interrupted run → queued again")
        t.eq(j?.attempts, 1, "1st interrupted run counted as an attempt")
        t.eq(j?.interruptions, 1, "1st interruption counted")
        t.check((j?.notBefore ?? .distantPast) > Date(), "1st interrupted run waits out a backoff (no instant re-crash)")
        let onDisk = try? JSONDecoder.sb.decode(Job.self, from: Data(contentsOf: jobsDir.appendingPathComponent("\(job.id).json")))
        t.eq(onDisk?.interruptions, 1, "interruption persisted")

        // Crash during attempt 2, launch 3: quarantined, shown as a failed source.
        try simulateCrashMidRun(jobsDir, id: job.id)
        engine = launch(root)
        j = engine.jobs.first { $0.id == job.id }
        t.eq(j?.status, .failed, "2nd interrupted run → job failed")
        t.eq(j?.attempts, 2, "attempts after 2 crashes")
        t.eq(j?.interruptions, 2, "2 interruptions")
        t.check(j?.error?.contains("se cerró") == true, "Spanish error on the job: \(j?.error ?? "nil")")
        let failedSrc = engine.source(src.id)
        t.eq(failedSrc?.status, .failed, "source failed (\"Con problema\" + Reintentar)")
        t.check(failedSrc?.error?.isEmpty == false, "source has an error for the retry help")
        t.check(!engine.jobs.contains { $0.sourceId == src.id && ($0.status == .queued || $0.status == .running) },
                "no new transcribe job enqueued")
        t.eq(sessionFiles(), filesBefore, "session audio kept")

        // Launch 4: repairs must not undo the quarantine.
        engine = launch(root)
        t.eq(engine.source(src.id)?.status, .failed, "still failed on the next launch")
        t.check(!engine.jobs.contains { $0.sourceId == src.id && $0.status == .queued }, "still no automatic retry")

        // Manual retry: a fresh job.
        engine.retry(sourceId: src.id)
        let fresh = engine.jobs.filter { $0.sourceId == src.id }
        t.eq(fresh.count, 1, "retry leaves one job")
        t.check(fresh.first?.kind == .transcribe && fresh.first?.status == .queued && fresh.first?.attempts == 0
                && fresh.first?.interruptions == nil && fresh.first?.id != job.id, "retry enqueues a fresh transcribe job")
        t.eq(engine.source(src.id)?.status, .queued, "retry → source queued")

    } catch {
        t.check(false, "queue crash-loop test threw: \(error)")
    }

    // Retry policy: the attempt is counted when the run starts; a usage limit gives it back.
    var job = Job(kind: .ingest)
    job.attempts = 1   // as saved by runNext
    let limited = JobQueue.reschedule(job, outcome: .rateLimited(resetAt: nil))
    t.eq(limited.attempts, 0, "rate limit doesn't use an attempt")
    t.eq(limited.status, .queued, "rate limited → queued")
    let retry = JobQueue.reschedule(job, outcome: .retryable("x"))
    t.eq(retry.attempts, 1, "retryable doesn't count twice")
    t.eq(retry.status, .queued, "1st retryable failure → queued")
    job.attempts = JobQueue.maxAttempts
    t.eq(JobQueue.reschedule(job, outcome: .retryable("x")).status, .failed, "retryable at maxAttempts → failed")
    job.attempts = 1
    let fatal = JobQueue.reschedule(job, outcome: .fatal("x"))
    t.check(fatal.attempts == 1 && fatal.status == .failed, "fatal → failed, attempt not double counted")

    // A run that ends normally clears the interruption count: an old force quit plus an unrelated later crash
    // must not add up to a quarantine (only back-to-back crashes do).
    job.interruptions = 1
    t.eq(JobQueue.reschedule(job, outcome: .retryable("x")).interruptions, nil, "retryable run clears interruptions")
    t.eq(JobQueue.reschedule(job, outcome: .rateLimited(resetAt: nil)).interruptions, nil, "rate-limited run clears interruptions")
    let q2 = JobQueue(dir: root.appendingPathComponent("reset-interruptions"))
    var survivor = Job(kind: .ingest)
    survivor.interruptions = 1
    survivor.attempts = 1
    survivor = JobQueue.reschedule(survivor, outcome: .retryable("x"))   // ran to the end after the old crash
    survivor.status = .running                                           // …then a new, unrelated crash
    survivor.attempts = 2
    let afterOne = q2.replace(with: [survivor], resetRunning: true, interruptedError: "boom")
    t.check(afterOne.isEmpty && q2.jobs.first?.status == .queued && q2.jobs.first?.interruptions == 1,
            "crash after a completed run → requeued, not quarantined")
    job.interruptions = nil

    // Old job files (no `interruptions`) still decode.
    let legacy = #"{"id":"a","kind":"transcribe","status":"running","payload":{},"attempts":0,"createdAt":"2026-11-02T19:17:51Z","updatedAt":"2026-11-02T19:17:51Z"}"#
    let decoded = try? JSONDecoder.sb.decode(Job.self, from: Data(legacy.utf8))
    t.check(decoded != nil && decoded?.interruptions == nil, "job JSON without interruptions decodes")

    // attempts already at the cap: one interruption is enough to stop it.
    let q = JobQueue(dir: root.appendingPathComponent("capped"))
    var capped = Job(kind: .ingest)
    capped.status = .running
    capped.attempts = JobQueue.maxAttempts
    let stopped = q.replace(with: [capped], resetRunning: true, interruptedError: "boom")
    t.check(stopped.count == 1 && q.jobs.first?.status == .failed && q.jobs.first?.error == "boom", "crash on the last attempt → failed")
    var other = Job(kind: .ingest)
    other.status = .running
    t.check(q.replace(with: [other], resetRunning: false).isEmpty && q.jobs.first?.status == .running,
            "without the queue lock running jobs are left alone")
}

// MARK: v0.7.3 engine-start burst — only the process that owns the queue at start runs one-time startup repairs.

@MainActor func testQueueOwnerAtStart(_ t: Tester, root: URL) async {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let lockURL = root.appendingPathComponent("data").appendingPathComponent("queue.lock")

    // Another live process holds the queue (a second app copy, `sb`): this engine must not own it.
    let other = QueueLock(url: lockURL)
    t.check(other.tryLock(), "stand-in process takes the queue lock")
    let second = launch(root)
    t.eq(second.ownsQueueAtStart, false, "engine started while the queue is held → not owner (skips recovery)")
    t.check(second.queueBusyElsewhere, "engine reports the queue busy elsewhere")
    t.eq(other.holderPid(), getpid(), "lock file names the holder pid")
    t.check(other.holderName() != nil, "holder is a live process")

    // A second lock on the same file (what a second app copy does with data/app.lock) is refused.
    let again = QueueLock(url: lockURL)
    t.eq(again.tryLock(), false, "second flock on the same file is refused while held")

    // Holder gone: the next engine owns the queue and does the startup repairs.
    other.unlock()
    let first = launch(root)
    t.eq(first.ownsQueueAtStart, true, "engine started with the queue free → owner")
}
