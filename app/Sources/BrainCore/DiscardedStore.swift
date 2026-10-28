import Foundation

// v0.7 (CONTRACT §17.1): attachments that were not kept (rules, Claude or the user) wait 30 days in
// `data/discarded/<vault>/<id>/` (the file + `meta.json`) so nothing useful is lost: Archivos › "Descartados (n)" can
// rescue them (imported as if they had been saved) or delete them now.

public struct DiscardedItem: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var size: Int
    public var mimeType: String?
    /// Sender, as written in the email ("Ana García <ana@acme.com>").
    public var from: String?
    public var threadKey: String?
    /// The email's source id (the attachment's would-be `parentSourceId`).
    public var messageSourceId: String?
    public var project: String?
    public var reason: DiscardReason
    public var discardedAt: Date
    public init(id: String = UUID().uuidString.lowercased(), name: String, size: Int, mimeType: String? = nil,
                from: String? = nil, threadKey: String? = nil, messageSourceId: String? = nil, project: String? = nil,
                reason: DiscardReason, discardedAt: Date = Date()) {
        self.id = id; self.name = name; self.size = size; self.mimeType = mimeType; self.from = from
        self.threadKey = threadKey; self.messageSourceId = messageSourceId; self.project = project
        self.reason = reason; self.discardedAt = discardedAt
    }
}

/// Safe from any thread (one lock around the folder).
public final class DiscardedStore: @unchecked Sendable {
    /// Discarded files are deleted by themselves after this.
    public static let lifetime: TimeInterval = 30 * 24 * 3600
    public static let metaFile = "meta.json"

    /// `<dataRoot>/discarded/<vaultKey>/`.
    public let dir: URL
    /// Shared by every instance (the engine and the views each make their own on the same folder).
    private static let sharedLock = NSLock()
    private var lock: NSLock { Self.sharedLock }

    public init(dataRoot: URL, vaultRoot: URL) {
        dir = dataRoot.appendingPathComponent("discarded").appendingPathComponent(ChatStore.vaultKey(vaultRoot))
    }

    /// The folder of one item (`<dir>/<id>/`); its file is `<folder>/<name>`.
    public func folder(of id: String) -> URL { dir.appendingPathComponent(id) }
    public func fileURL(of item: DiscardedItem) -> URL { folder(of: item.id).appendingPathComponent(item.name) }

    /// Every discarded item, newest first (expired ones that weren't swept yet are left out).
    public func list(now: Date = Date()) -> [DiscardedItem] {
        lock.lock(); defer { lock.unlock() }
        return unlockedList().filter { now.timeIntervalSince($0.discardedAt) < Self.lifetime }
            .sorted { $0.discardedAt > $1.discardedAt }
    }

    /// One item, or nil.
    public func item(id: String) -> DiscardedItem? {
        lock.lock(); defer { lock.unlock() }
        return Self.load(folder(of: id))
    }

    /// Keeps `data` as a discarded attachment (its name made safe for a file name).
    @discardableResult
    public func add(_ item: DiscardedItem, data: Data) throws -> DiscardedItem {
        var item = item
        item.name = Self.safeName(item.name)
        if item.size <= 0 { item.size = data.count }
        lock.lock(); defer { lock.unlock() }
        let folder = folder(of: item.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try data.write(to: folder.appendingPathComponent(item.name), options: .atomic)
        try JSONEncoder.sb.encode(item).write(to: folder.appendingPathComponent(Self.metaFile), options: .atomic)
        Log.info("discarded attachment kept for 30 days: \(item.id) (\(item.reason))")
        return item
    }

    /// Takes the item out of the store and returns it with the local copy of its file, for the engine to import "as if
    /// it had been saved" (the caller deletes `file` after importing). nil when it's gone.
    public func rescue(id: String) throws -> (item: DiscardedItem, file: URL)? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        let folder = folder(of: id)
        guard let item = Self.load(folder) else { return nil }
        let source = folder.appendingPathComponent(item.name)
        guard fm.fileExists(atPath: source.path) else {
            try? fm.removeItem(at: folder)
            return nil
        }
        let tmp = fm.temporaryDirectory.appendingPathComponent("sb-rescue-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        let file = tmp.appendingPathComponent(item.name)
        try fm.moveItem(at: source, to: file)
        try? fm.removeItem(at: folder)
        return (item, file)
    }

    /// "Eliminar ya".
    public func delete(id: String) {
        lock.lock(); defer { lock.unlock() }
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { return }
        try? FileManager.default.removeItem(at: folder(of: id))
    }

    /// Deletes what is older than `lifetime` (and folders without a readable `meta.json`); returns how many went away.
    @discardableResult
    public func expire(now: Date = Date()) -> Int {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(".") {
            let folder = dir.appendingPathComponent(name)
            guard fm.isDirectory(folder) else { continue }
            if let item = Self.load(folder), now.timeIntervalSince(item.discardedAt) < Self.lifetime { continue }
            if (try? fm.removeItem(at: folder)) != nil { removed += 1 }
        }
        if removed > 0 { Log.info("discarded attachments: \(removed) expired") }
        return removed
    }

    // MARK: Internals

    private func unlockedList() -> [DiscardedItem] {
        let fm = FileManager.default
        return ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") }
            .compactMap { Self.load(dir.appendingPathComponent($0)) }
    }

    private static func load(_ folder: URL) -> DiscardedItem? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(metaFile)) else { return nil }
        return try? JSONDecoder.sb.decode(DiscardedItem.self, from: data)
    }

    /// A file name without path separators or a leading dot ("adjunto" when nothing is left).
    public static func safeName(_ name: String) -> String {
        var s = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        if s.count > 120 {
            let ext = (s as NSString).pathExtension
            let stem = String((s as NSString).deletingPathExtension.prefix(110))
            s = ext.isEmpty ? stem : "\(stem).\(ext)"
        }
        return s.isEmpty ? "adjunto" : s
    }
}
