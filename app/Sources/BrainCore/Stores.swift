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
    public static let rateLimitWait: TimeInterval = 15 * 60
    /// Backoff after the n-th failed attempt: 30 s, 60 s, 120 s…
    public static func backoff(afterAttempt n: Int) -> TimeInterval { 30 * pow(2, Double(max(0, n - 1))) }

    public let dir: URL
    public private(set) var jobs: [Job] = []

    public init(dir: URL) { self.dir = dir }

    /// Loads jobs from disk; anything left `running` by a crash goes back to `queued`.
    public func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        jobs = files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder.sb.decode(Job.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
        for i in jobs.indices where jobs[i].status == .running {
            jobs[i].status = .queued
            jobs[i].updatedAt = Date()
            persist(jobs[i])
        }
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

    /// Applies the retry policy to a job that just ran. Returns the updated job.
    public static func reschedule(_ job: Job, outcome: JobOutcome, now: Date = Date()) -> Job {
        var job = job
        job.updatedAt = now
        switch outcome {
        case .success:
            job.status = .done
            job.error = nil
            job.notBefore = nil
        case .rateLimited(let resetAt):
            job.status = .queued
            if let resetAt, resetAt > now {
                job.notBefore = resetAt.addingTimeInterval(30)
            } else {
                job.notBefore = now.addingTimeInterval(rateLimitWait)
            }
        case .fatal(let message):
            job.attempts += 1
            job.status = .failed
            job.error = message
            job.notBefore = nil
        case .retryable(let message):
            job.attempts += 1
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
