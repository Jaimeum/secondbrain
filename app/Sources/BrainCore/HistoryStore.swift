import CryptoKit
import Foundation

public enum HistoryError: Error, LocalizedError {
    case conflict([String])
    case notFound
    case alreadyUndone

    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .conflict(let paths): return lang.t("Cambiaron después: ", "Changed after this entry: ") + paths.joined(separator: ", ")
        case .notFound: return lang.t("No encontré ese cambio.", "History entry not found")
        case .alreadyUndone: return lang.t("Ese cambio ya se deshizo.", "Already undone")
        }
    }
}

/// State captured by `HistoryStore.begin`: file hashes plus a clone of the vault to recover "before" copies.
public struct HistorySnapshot: Sendable {
    public let id: String
    public let title: String
    public let kind: JobKind
    public let sourceId: String?
    public let projectSlug: String?
    public let createdAt: Date
    let hashes: [String: String]
    let stagingDir: URL
}

/// Tracks every change Claude makes to the vault so it can be shown and undone (CONTRACT §5.5).
///
/// Layout: `history/<id>/entry.json`, `before/<path>`, `after/<path>`, optional `summary.md`.
public final class HistoryStore: @unchecked Sendable {
    public let vaultRoot: URL
    public let historyDir: URL
    /// When true and the vault is a git repo, commits after each commit/undo.
    public var gitEnabled = false

    private let lock = NSLock()
    private var hashCache: [String: (size: Int, mtime: Date, hash: String)] = [:]
    // v0.4: `.secondbrain/` is app state (routing rules and their hit counts change while Claude works): never part of
    // a change, never restored by undo.
    private static let ignoredNames: Set<String> = [".git", ".obsidian", ".DS_Store", ".trash", ".secondbrain"]

    public init(vaultRoot: URL, historyDir: URL) {
        self.vaultRoot = vaultRoot
        self.historyDir = historyDir
    }

    // MARK: Recording changes

    /// Hashes the vault and clones it into `history/<id>/.staging` so "before" copies of whatever Claude edits can be
    /// recovered. `FileManager.copyItem` uses `clonefile` on APFS, so the copy is nearly free there. On volumes without
    /// cloning (HFS+, exFAT, SMB…) every job copies the whole vault once (it is deleted at `commit`); "before" contents
    /// can't be captured lazily because Claude edits the files in place. Logged once per store.
    public func begin(title: String, kind: JobKind, sourceId: String?, projectSlug: String?) throws -> HistorySnapshot {
        let id = SessionManifest.newId()
        let staging = historyDir.appendingPathComponent(id).appendingPathComponent(".staging")
        let fm = FileManager.default
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        warnIfNoCloning()
        let hashes = try scan()
        for path in hashes.keys {
            let dest = staging.appendingPathComponent(path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: vaultRoot.appendingPathComponent(path), to: dest)   // APFS clone when possible
        }
        let snapshot = HistorySnapshot(id: id, title: title, kind: kind, sourceId: sourceId, projectSlug: projectSlug,
                                       createdAt: Date(), hashes: hashes, stagingDir: staging)
        // If the app dies before `commit`, `recoverInterrupted()` turns this into a normal entry.
        let pending = HistoryEntry(id: id, title: title, kind: kind, sourceId: sourceId, projectSlug: projectSlug,
                                   changes: [], createdAt: snapshot.createdAt, undone: false)
        let dir = staging.deletingLastPathComponent()
        try JSONEncoder.sb.encode(pending).write(to: dir.appendingPathComponent("pending.json"), options: .atomic)
        try String(ProcessInfo.processInfo.processIdentifier).write(to: dir.appendingPathComponent("pending.pid"),
                                                                    atomically: true, encoding: .utf8)
        return snapshot
    }

    /// Records the edits of runs cut short by a crash or quit (a staging clone without entry.json), so they
    /// show up in the activity list and can be undone. Call before anything new edits the vault.
    @discardableResult
    public func recoverInterrupted() -> [HistoryEntry] {
        let fm = FileManager.default
        var recovered: [HistoryEntry] = []
        for id in (try? fm.contentsOfDirectory(atPath: historyDir.path)) ?? [] {
            let dir = historyDir.appendingPathComponent(id)
            let staging = dir.appendingPathComponent(".staging")
            guard fm.isDirectory(staging), !fm.fileExists(atPath: dir.appendingPathComponent("entry.json").path) else { continue }
            // Still in flight in another live process (e.g. the app while `sb` starts): not ours to close.
            if let pid = (try? String(contentsOf: dir.appendingPathComponent("pending.pid"), encoding: .utf8)).flatMap({ Int32($0) }),
               pid != ProcessInfo.processInfo.processIdentifier, kill(pid, 0) == 0 { continue }
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("pending.json")),
                  let meta = try? JSONDecoder.sb.decode(HistoryEntry.self, from: data),
                  let hashes = try? Self.hashTree(staging) else {
                try? fm.removeItem(at: dir)
                continue
            }
            let snapshot = HistorySnapshot(id: meta.id, title: meta.title, kind: meta.kind, sourceId: meta.sourceId,
                                           projectSlug: meta.projectSlug, createdAt: meta.createdAt, hashes: hashes,
                                           stagingDir: staging)
            do {
                if let entry = try commit(snapshot) { recovered.append(entry) }
            } catch {
                Log.error("could not recover interrupted history \(id): \(error)")
            }
        }
        return recovered
    }

    /// Diffs the vault against the snapshot. Returns nil (and stores nothing) when nothing changed.
    public func commit(_ snapshot: HistorySnapshot) throws -> HistoryEntry? {
        let fm = FileManager.default
        let dir = historyDir.appendingPathComponent(snapshot.id)
        defer {
            try? fm.removeItem(at: snapshot.stagingDir)
            try? fm.removeItem(at: dir.appendingPathComponent("pending.json"))
            try? fm.removeItem(at: dir.appendingPathComponent("pending.pid"))
        }
        let now = try scan()
        var changes: [FileChange] = []
        for (path, hash) in now {
            if let old = snapshot.hashes[path] {
                if old != hash { changes.append(FileChange(path: path, change: .modified)) }
            } else {
                changes.append(FileChange(path: path, change: .added))
            }
        }
        for path in snapshot.hashes.keys where now[path] == nil {
            changes.append(FileChange(path: path, change: .deleted))
        }
        guard !changes.isEmpty else {
            try? fm.removeItem(at: dir)
            return nil
        }
        changes.sort { $0.path < $1.path }
        for change in changes {
            if change.change != .added {
                try copy(snapshot.stagingDir.appendingPathComponent(change.path), to: dir.appendingPathComponent("before/\(change.path)"))
            }
            if change.change != .deleted {
                try copy(vaultRoot.appendingPathComponent(change.path), to: dir.appendingPathComponent("after/\(change.path)"))
            }
        }
        let entry = HistoryEntry(id: snapshot.id, title: snapshot.title, kind: snapshot.kind, sourceId: snapshot.sourceId,
                                 projectSlug: snapshot.projectSlug, changes: changes, createdAt: snapshot.createdAt, undone: false)
        try save(entry)
        gitCommit(message: snapshot.title)
        Log.info("history \(entry.id): \(changes.count) changes — \(entry.title)")
        return entry
    }

    /// A small edit made by the app itself (e.g. checking a task): writes `after` to `path` and records a
    /// `.manualEdit` entry with before/after copies, without a vault snapshot. Undoable like any other entry.
    @discardableResult
    public func recordManualEdit(title: String, sourceId: String? = nil, projectSlug: String?, path: String,
                                 before: String?, after: String) throws -> HistoryEntry {
        let id = SessionManifest.newId()
        let dir = historyDir.appendingPathComponent(id)
        let fm = FileManager.default
        let target = vaultRoot.appendingPathComponent(path)
        if let before {
            let b = dir.appendingPathComponent("before/\(path)")
            try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
            try before.write(to: b, atomically: true, encoding: .utf8)
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try after.write(to: target, atomically: true, encoding: .utf8)
        try copy(target, to: dir.appendingPathComponent("after/\(path)"))
        let entry = HistoryEntry(id: id, title: title, kind: .manualEdit, sourceId: sourceId, projectSlug: projectSlug,
                                 changes: [FileChange(path: path, change: before == nil ? .added : .modified)],
                                 createdAt: Date(), undone: false)
        try save(entry)
        gitCommit(message: title)
        Log.info("history \(id): manual edit of \(path) — \(title)")
        return entry
    }

    /// v0.6 (§16.6): several files edited by the app in one go (the owner's hand edit applied across the brain, plus
    /// `facts.md`): writes each `after` and records ONE `.manualEdit` entry, so a single Deshacer reverts them all.
    /// `before == nil` means the file is new. Files whose text doesn't change are left out; nil when nothing changed.
    /// All or nothing: the before/after copies are written first; then the vault files; if one of those fails, the ones
    /// already written are put back (or removed when new) and the entry's folder is dropped, so no page is left changed
    /// without a Historial entry to undo it.
    @discardableResult
    public func recordManualEdits(title: String, projectSlug: String?,
                                  files: [(path: String, before: String?, after: String)]) throws -> HistoryEntry? {
        let files = files.filter { $0.before != $0.after }
        guard !files.isEmpty else { return nil }
        let id = SessionManifest.newId()
        let dir = historyDir.appendingPathComponent(id)
        let fm = FileManager.default
        func write(_ text: String, to url: URL) throws {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        // 1. The entry's copies (nothing in the vault changes yet).
        do {
            for file in files {
                if let before = file.before { try write(before, to: dir.appendingPathComponent("before/\(file.path)")) }
                try write(file.after, to: dir.appendingPathComponent("after/\(file.path)"))
            }
        } catch {
            try? fm.removeItem(at: dir)
            throw error
        }
        // 2. The vault, rolled back on the first failure.
        var written: [(path: String, before: String?)] = []
        do {
            for file in files {
                try write(file.after, to: vaultRoot.appendingPathComponent(file.path))
                written.append((file.path, file.before))
            }
            let changes = files.map { FileChange(path: $0.path, change: $0.before == nil ? .added : .modified) }
            let entry = HistoryEntry(id: id, title: title, kind: .manualEdit, sourceId: nil, projectSlug: projectSlug,
                                     changes: changes.sorted { $0.path < $1.path }, createdAt: Date(), undone: false)
            try save(entry)
            gitCommit(message: title)
            Log.info("history \(id): manual edit of \(changes.count) files — \(title)")
            return entry
        } catch {
            for file in written.reversed() {
                let target = vaultRoot.appendingPathComponent(file.path)
                if let before = file.before { try? write(before, to: target) } else { try? fm.removeItem(at: target) }
            }
            try? fm.removeItem(at: dir)
            Log.error("history: manual edit of \(files.count) files rolled back — \(error)")
            throw error
        }
    }

    /// Drops a snapshot without recording anything.
    public func discard(_ snapshot: HistorySnapshot) {
        let dir = historyDir.appendingPathComponent(snapshot.id)
        try? FileManager.default.removeItem(at: snapshot.stagingDir)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("pending.json"))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("pending.pid"))
        if (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?.isEmpty ?? false {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    // MARK: Pruning

    /// Entries kept no matter their age.
    public static let keepRecentCount = 300
    /// Entries younger than this are kept no matter how many there are.
    public static let keepDays = 60

    /// Deletes old entries (their `before/`/`after/` copies included): keeps the newest `keepRecentCount`
    /// and everything from the last `keepDays` days, whichever is more. In-flight changes (`.staging`/pending)
    /// and folders without a readable entry are never touched. Returns how many entries were removed.
    @discardableResult
    public func prune(now: Date = Date()) -> Int {
        let fm = FileManager.default
        let cutoff = now.addingTimeInterval(-Double(Self.keepDays) * 86_400)
        let all = entries()   // newest first
        guard all.count > Self.keepRecentCount else { return 0 }
        var removed = 0
        for entry in all.dropFirst(Self.keepRecentCount) where entry.createdAt < cutoff {
            let dir = historyDir.appendingPathComponent(entry.id)
            guard !fm.fileExists(atPath: dir.appendingPathComponent(".staging").path),
                  !fm.fileExists(atPath: dir.appendingPathComponent("pending.json").path) else { continue }
            do {
                try fm.removeItem(at: dir)
                removed += 1
            } catch {
                Log.error("could not prune history \(entry.id): \(error)")
            }
        }
        if removed > 0 { Log.info("pruned \(removed) old history entries") }
        return removed
    }

    // MARK: Reading

    /// `entries()` on a background task (it reads every entry.json).
    public func entriesAsync() async -> [HistoryEntry] {
        await Task.detached(priority: .userInitiated) { self.entries() }.value
    }

    public func entries() -> [HistoryEntry] {
        let fm = FileManager.default
        guard let ids = try? fm.contentsOfDirectory(atPath: historyDir.path) else { return [] }
        return ids.compactMap { entry(id: $0) }.sorted { $0.createdAt > $1.createdAt }
    }

    public func entry(id: String) -> HistoryEntry? {
        let url = historyDir.appendingPathComponent(id).appendingPathComponent("entry.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder.sb.decode(HistoryEntry.self, from: data)
    }

    public func diff(entryId: String, path: String) -> (before: String?, after: String?) {
        let dir = historyDir.appendingPathComponent(entryId)
        return (try? String(contentsOf: dir.appendingPathComponent("before/\(path)"), encoding: .utf8),
                try? String(contentsOf: dir.appendingPathComponent("after/\(path)"), encoding: .utf8))
    }

    /// Claude's human summary of what changed, stored next to the entry.
    public func summary(entryId: String) -> String? {
        try? String(contentsOf: historyDir.appendingPathComponent(entryId).appendingPathComponent("summary.md"), encoding: .utf8)
    }

    public func setSummary(_ text: String, entryId: String) throws {
        let dir = historyDir.appendingPathComponent(entryId)
        guard FileManager.default.fileExists(atPath: dir.path) else { throw HistoryError.notFound }
        try text.write(to: dir.appendingPathComponent("summary.md"), atomically: true, encoding: .utf8)
    }

    // MARK: Undo

    /// Paths changed since the entry was recorded (what `undo` would clobber).
    public func conflicts(entryId: String) throws -> [String] {
        guard let entry = entry(id: entryId) else { throw HistoryError.notFound }
        let dir = historyDir.appendingPathComponent(entryId)
        let fm = FileManager.default
        var conflicts: [String] = []
        for change in entry.changes {
            let current = vaultRoot.appendingPathComponent(change.path)
            let exists = fm.fileExists(atPath: current.path)
            switch change.change {
            case .added, .modified:
                let after = dir.appendingPathComponent("after/\(change.path)")
                if exists {
                    if try hash(current) != hash(after) { conflicts.append(change.path) }
                } else if change.change == .modified {
                    conflicts.append(change.path)
                }
            case .deleted:
                if exists, try hash(current) != hash(dir.appendingPathComponent("before/\(change.path)")) {
                    conflicts.append(change.path)
                }
            }
        }
        return conflicts
    }

    public func undo(entryId: String, force: Bool = false) throws {
        guard var entry = entry(id: entryId) else { throw HistoryError.notFound }
        guard !entry.undone else { throw HistoryError.alreadyUndone }
        if !force {
            let conflicts = try conflicts(entryId: entryId)
            if !conflicts.isEmpty { throw HistoryError.conflict(conflicts) }
        }
        let dir = historyDir.appendingPathComponent(entryId)
        let fm = FileManager.default
        for change in entry.changes {
            let current = vaultRoot.appendingPathComponent(change.path)
            switch change.change {
            case .added:
                if fm.fileExists(atPath: current.path) { try fm.removeItem(at: current) }
            case .modified, .deleted:
                try copy(dir.appendingPathComponent("before/\(change.path)"), to: current)
            }
        }
        entry.undone = true
        try save(entry)
        gitCommit(message: "Deshacer: \(entry.title)")
        Log.info("history \(entry.id) undone (force=\(force))")
    }

    // MARK: Internals

    private var cloneChecked = false

    private func warnIfNoCloning() {
        lock.lock()
        let first = !cloneChecked
        cloneChecked = true
        lock.unlock()
        guard first else { return }
        let keys: Set<URLResourceKey> = [.volumeSupportsFileCloningKey]
        let vaultClones = (try? vaultRoot.resourceValues(forKeys: keys))?.volumeSupportsFileCloning ?? false
        let historyClones = (try? historyDir.resourceValues(forKeys: keys))?.volumeSupportsFileCloning ?? false
        let sameVolume = (try? vaultRoot.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
            == (try? historyDir.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
        if !(vaultClones && historyClones && sameVolume) {
            Log.info("history snapshots are full copies (vault and data are not on the same APFS volume)")
        }
    }

    private func save(_ entry: HistoryEntry) throws {
        let dir = historyDir.appendingPathComponent(entry.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(entry).write(to: dir.appendingPathComponent("entry.json"), options: .atomic)
    }

    private func copy(_ src: URL, to dest: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: src, to: dest)
    }

    /// SHA256 of every vault file (relative path → hex), skipping .git/.obsidian/.DS_Store.
    func scan() throws -> [String: String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = fm.enumerator(at: vaultRoot, includingPropertiesForKeys: keys) else { return [:] }
        var result: [String: String] = [:]
        lock.lock()
        defer { lock.unlock() }
        for case let url as URL in walker {
            if Self.ignoredNames.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true, let rel = url.relativePath(from: vaultRoot) else { continue }
            let size = values.fileSize ?? -1
            let mtime = values.contentModificationDate ?? .distantPast
            if let cached = hashCache[rel], cached.size == size, cached.mtime == mtime {
                result[rel] = cached.hash
            } else {
                let h = try hash(url)
                hashCache[rel] = (size, mtime, h)
                result[rel] = h
            }
        }
        return result
    }

    private func hash(_ url: URL) throws -> String { try Self.hash(url) }

    private static func hash(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Hashes of every file under `root` (relative path → hex), e.g. a staging clone.
    private static func hashTree(_ root: URL) throws -> [String: String] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let url as URL in walker {
            guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true,
                  let rel = url.relativePath(from: root) else { continue }
            result[rel] = try hash(url)
        }
        return result
    }

    private func gitCommit(message: String) {
        guard gitEnabled, FileManager.default.fileExists(atPath: vaultRoot.appendingPathComponent(".git").path) else { return }
        // /usr/bin/git is a shim that pops an install dialog when developer tools are missing.
        guard ClaudeSetup.runSync("/usr/bin/xcode-select", ["-p"], timeout: 5).status == 0 else { return }
        let repo = vaultRoot.path
        var identity: [String] = []
        if ClaudeSetup.runSync("/usr/bin/git", ["-C", repo, "config", "user.email"], timeout: 10).output
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            identity = ["-c", "user.name=SecondBrain", "-c", "user.email=secondbrain@localhost"]
        }
        guard ClaudeSetup.runSync("/usr/bin/git", ["-C", repo, "add", "-A"], timeout: 30).status == 0 else { return }
        let commit = ClaudeSetup.runSync("/usr/bin/git", identity + ["-C", repo, "commit", "-q", "-m", message], timeout: 30)
        if commit.status != 0 { Log.info("git commit skipped: \(commit.output.prefix(200))") }
    }
}
