import Foundation

/// One JSON file per source in data/sources/.
public final class SourceStore: @unchecked Sendable {
    public let dir: URL

    public init(dir: URL) { self.dir = dir }

    /// All sources, newest first.
    public func loadAll() -> [SourceRecord] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.sb.decode(SourceRecord.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    public func save(_ record: SourceRecord) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(record).write(to: dir.appendingPathComponent("\(record.id).json"), options: .atomic)
    }

    public func delete(id: String) {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }
}

/// How a job attempt ended, for rescheduling.
public enum JobOutcome: Equatable, Sendable {
    case success
    case rateLimited(resetAt: Date?)
    /// Retrying will not help (Claude missing, not logged in, bad input).
    case fatal(String)
    case retryable(String)
}

/// Persistent serial queue (data/jobs/<id>.json). Scheduling only; the engine executes jobs.
public final class JobQueue: @unchecked Sendable {
    public static let maxAttempts = 3
    /// A job whose run was cut short this many times (the process died while it ran) is failed instead of
    /// requeued, so a job that crashes the app can't crash it again on every launch.
    public static let maxInterruptions = 2
    public static let rateLimitWait: TimeInterval = 15 * 60
    /// Backoff after the n-th failed attempt: 30 s, 60 s, 120 s…
    public static func backoff(afterAttempt n: Int) -> TimeInterval { 30 * pow(2, Double(max(0, n - 1))) }

    public let dir: URL
    public private(set) var jobs: [Job] = []

    public init(dir: URL) { self.dir = dir }

    /// Loads jobs from disk. With `resetRunning` (only the process holding the queue lock may do this),
    /// anything left `running` by a crash is counted as interrupted and requeued with a backoff, or failed once it
    /// keeps dying (see `replace`). Returns the jobs failed that way; `interruptedError` becomes their error.
    @discardableResult
    public func load(resetRunning: Bool = true, interruptedError: String = "") -> [Job] {
        replace(with: Self.readAll(dir: dir), resetRunning: resetRunning, interruptedError: interruptedError)
    }

    /// Jobs on disk, oldest first (no side effects; safe from any thread).
    public static func readAll(dir: URL) -> [Job] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.sb.decode(Job.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    /// Replaces the in-memory list (e.g. after another process changed the queue). With `resetRunning`, a job
    /// still `running` was cut short by a dead process (a clean quit requeues its job first): its interruption
    /// is counted and it waits out a backoff, or it is failed after `maxInterruptions` / `maxAttempts` so it
    /// can't crash every launch. Returns the jobs failed here.
    @discardableResult
    public func replace(with loaded: [Job], resetRunning: Bool, interruptedError: String = "", now: Date = Date()) -> [Job] {
        jobs = loaded
        guard resetRunning else { return [] }
        var failed: [Job] = []
        for i in jobs.indices where jobs[i].status == .running {
            let n = (jobs[i].interruptions ?? 0) + 1
            jobs[i].interruptions = n
            jobs[i].updatedAt = now
            jobs[i].progress = nil
            if n >= Self.maxInterruptions || jobs[i].attempts >= Self.maxAttempts {
                jobs[i].status = .failed
                jobs[i].notBefore = nil
                jobs[i].error = interruptedError
                failed.append(jobs[i])
            } else {
                jobs[i].status = .queued
                jobs[i].notBefore = now.addingTimeInterval(Self.backoff(afterAttempt: max(1, jobs[i].attempts)))
            }
            persist(jobs[i])
        }
        return failed
    }

    public func upsert(_ job: Job) {
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.append(job) }
        persist(job)
    }

    public func remove(id: String) {
        jobs.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(id).json"))
    }

    public func job(id: String) -> Job? { jobs.first { $0.id == id } }

    /// Oldest queued job whose `notBefore` has passed.
    public func nextRunnable(now: Date = Date()) -> Job? {
        jobs.first { $0.status == .queued && ($0.notBefore ?? .distantPast) <= now }
    }

    /// Earliest future `notBefore` among queued jobs.
    public func nextWakeDate(now: Date = Date()) -> Date? {
        jobs.filter { $0.status == .queued }.compactMap(\.notBefore).filter { $0 > now }.min()
    }

    public var hasPending: Bool { jobs.contains { $0.status == .queued || $0.status == .running } }

    /// Applies the retry policy to a job that just ran. Returns the updated job. `attempts` was already counted
    /// (and saved) when the run started, so a crash mid-run still counts; a usage limit gives it back.
    public static func reschedule(_ job: Job, outcome: JobOutcome, now: Date = Date()) -> Job {
        var job = job
        job.updatedAt = now
        // The run ended without killing the process: only back-to-back crashes count toward `maxInterruptions`.
        job.interruptions = nil
        switch outcome {
        case .success:
            job.status = .done
            job.error = nil
            job.notBefore = nil
        case .rateLimited(let resetAt):
            job.status = .queued
            job.attempts = max(0, job.attempts - 1)
            if let resetAt, resetAt > now {
                job.notBefore = resetAt.addingTimeInterval(30)
            } else {
                job.notBefore = now.addingTimeInterval(rateLimitWait)
            }
        case .fatal(let message):
            job.status = .failed
            job.error = message
            job.notBefore = nil
        case .retryable(let message):
            job.error = message
            if job.attempts >= maxAttempts {
                job.status = .failed
                job.notBefore = nil
            } else {
                job.status = .queued
                job.notBefore = now.addingTimeInterval(backoff(afterAttempt: job.attempts))
            }
        }
        return job
    }

    private func persist(_ job: Job) {
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try JSONEncoder.sb.encode(job).write(to: dir.appendingPathComponent("\(job.id).json"), options: .atomic)
        } catch {
            Log.error("could not save job \(job.id): \(error)")
        }
    }
}

/// Cross-process "one queue processor" lock: `flock` on `data/queue.lock` (CONTRACT [P-core]). The kernel drops
/// it when the process dies, so a crash never leaves the queue locked. The file holds the owner's pid.
public final class QueueLock: @unchecked Sendable {
    public let url: URL
    private let mutex = NSLock()
    private var fd: Int32 = -1

    public init(url: URL) { self.url = url }

    public var isHeld: Bool { mutex.lock(); defer { mutex.unlock() }; return fd >= 0 }

    /// Non-blocking. True when this instance holds the lock (already or now).
    public func tryLock() -> Bool {
        mutex.lock()
        defer { mutex.unlock() }
        if fd >= 0 { return true }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let f = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard f >= 0 else {
            Log.error("could not open queue lock \(url.path): errno \(errno)")
            return false
        }
        guard flock(f, LOCK_EX | LOCK_NB) == 0 else {
            close(f)
            return false
        }
        let pid = Array(String(ProcessInfo.processInfo.processIdentifier).utf8)
        _ = ftruncate(f, 0)
        _ = pid.withUnsafeBytes { pwrite(f, $0.baseAddress, $0.count, 0) }
        fd = f
        return true
    }

    public func unlock() {
        mutex.lock()
        defer { mutex.unlock() }
        guard fd >= 0 else { return }
        _ = flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Pid written by the current (or last) holder.
    public func holderPid() -> Int32? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }

    /// Executable name of the live holder ("sb", "SecondBrain"), nil when nobody holds the lock.
    public func holderName() -> String? {
        guard let pid = holderPid(), pid > 0, kill(pid, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    deinit { if fd >= 0 { close(fd) } }
}
