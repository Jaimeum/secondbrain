import AppKit
import BrainCore
import Foundation
import Observation
import QuickLookThumbnailing

/// Archivos' data (CONTRACT §17.2): the vault's `FileIndex` and the discarded attachments, refreshed when the vault
/// changes (`vaultRevision`) and shared by the global view, every project tab and the fichas.
@MainActor @Observable
final class FilesModel {
    static let shared = FilesModel()

    private(set) var entries: [FileEntry] = []
    private(set) var discarded: [DiscardedItem] = []
    private(set) var loaded = false
    /// A file to select when Archivos shows next (⌘K, a ficha's "Archivos" row). The view consumes it.
    var pendingFile: String?
    /// Snapshots only: the view starts on Descartados.
    var pendingDiscarded = false
    /// The selected file and whether Descartados shows, per place (`Scope.key`).
    var selection: [String: String] = [:]
    var discardedShown: Set<String> = []

    @ObservationIgnored private var builtKey: String?

    private func key(_ state: AppState) -> String {
        "\(state.vaultGeneration)-\(state.vaultRevision)-\(state.engine.sources.count)"
    }

    /// Re-reads what changed since the last refresh (off the main thread); `force` after rescuing or deleting.
    func refresh(state: AppState, force: Bool = false) async {
        guard state.engineStarted else { return }
        let key = key(state)
        guard force || key != builtKey else { return }
        let root = state.engine.vault.root, sources = state.engine.sources
        let store = discardedStore(state)
        let snapshot = await EntityIndex.snapshot(vaultRoot: root)
        let (files, gone) = await Task.detached(priority: .userInitiated) {
            (FileIndex.shared(vaultRoot: root).refresh(sources: sources, entities: snapshot), { _ = store.expire(); return store.list() }())
        }.value
        entries = files
        discarded = gone
        builtKey = key
        loaded = true
    }

    func discardedStore(_ state: AppState) -> DiscardedStore {
        DiscardedStore(dataRoot: state.engine.paths.root, vaultRoot: state.engine.vault.root)
    }

    /// Opens Archivos with `path` selected: the project's tab when the file lives in the project on screen (or
    /// `scope` is that project), else the global view.
    static func reveal(_ path: String, scope: Scope = .brain, state: AppState) {
        let slug = Scope.projectSlug(ofPath: path)
        if let slug, scope.projectSlug == slug || (scope.isBrain && state.currentProjectSlug == slug) {
            state.navigate(to: .projectTab(slug, .files))
        } else {
            state.navigate(to: .sidebar(.files))
        }
        shared.pendingFile = path
    }
}

/// Thumbnails of files (QuickLookThumbnailing), cached per path and modification date.
@MainActor
final class FileThumbnails {
    static let shared = FileThumbnails()
    private var cache: [String: NSImage] = [:]

    func image(for url: URL, side: CGFloat) async -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        let key = "\(url.path)|\(mtime?.timeIntervalSince1970 ?? 0)|\(Int(side))"
        if let hit = cache[key] { return hit }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: side, height: side), scale: scale,
                                                   representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else { return nil }
        let image = rep.nsImage
        if cache.count > 600 { cache.removeAll() }
        cache[key] = image
        return image
    }
}
