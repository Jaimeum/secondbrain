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
    private let lock = NSLock()

    public init(dataRoot: URL, vaultRoot: URL) {
        dir = dataRoot.appendingPathComponent("discarded").appendingPathComponent(ChatStore.vaultKey(vaultRoot))
    }

    /// The folder of one item (`<dir>/<id>/`); its file is `<folder>/<name>`.
    public func folder(of id: String) -> URL { dir.appendingPathComponent(id) }
    public func fileURL(of item: DiscardedItem) -> URL { folder(of: item.id).appendingPathComponent(item.name) }

    // v0.7: filled in by attach — everything below is the stub API (no-ops / empty).

    /// Every discarded item, newest first.
    public func list() -> [DiscardedItem] { [] }

    /// Keeps `data` as a discarded attachment.
    @discardableResult
    public func add(_ item: DiscardedItem, data: Data) throws -> DiscardedItem { item }

    /// Takes the item out of the store and returns it with the local copy of its file, for the engine to import "as if
    /// it had been saved" (the caller deletes `file` after importing). nil when it's gone.
    public func rescue(id: String) throws -> (item: DiscardedItem, file: URL)? { nil }

    /// "Eliminar ya".
    public func delete(id: String) {}

    /// Deletes what is older than `lifetime`; returns how many went away.
    @discardableResult
    public func expire(now: Date = Date()) -> Int { 0 }
}
