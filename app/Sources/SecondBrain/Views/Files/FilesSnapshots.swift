import AppKit
import BrainCore
import Foundation

/// v0.7 (§17.8) snapshots of Archivos: a file selected (its panel), and Descartados with two sample items. Only ever
/// runs under `SB_SNAPSHOT_DIR` with an isolated config (DebugSnapshots refuses otherwise).
@MainActor
enum FilesSnapshots {
    /// Loads the index and, when the store is empty, seeds two discarded attachments (an inline logo, an invite).
    static func prepare(state: AppState) async {
        let model = FilesModel.shared
        let store = model.discardedStore(state)
        if store.list().isEmpty {
            let slug = state.projects.first?.slug
            let thread = model.entries.first { $0.origin == .email }
            _ = try? store.add(DiscardedItem(name: "image001.png", size: 6_200, mimeType: "image/png",
                                             from: "Ana García <ana@acme.com>", threadKey: thread?.threadKey,
                                             project: slug, reason: .inlineImage,
                                             discardedAt: Date().addingTimeInterval(-3 * 86_400)),
                               data: Data(repeating: 0, count: 6_200))
            _ = try? store.add(DiscardedItem(name: "invite.ics", size: 2_100, mimeType: "text/calendar",
                                             from: "Luis Torres <luis@dive.ai>", project: slug, reason: .junkType,
                                             discardedAt: Date().addingTimeInterval(-12 * 86_400)),
                               data: Data("BEGIN:VCALENDAR\nEND:VCALENDAR\n".utf8))
        }
        await model.refresh(state: state, force: true)
    }

    /// Sets what the next window shows: a file selected, or Descartados.
    static func preset(_ name: String, state: AppState) {
        let model = FilesModel.shared
        model.pendingFile = nil
        model.pendingDiscarded = false
        model.selection = [:]
        model.discardedShown = []
        switch name {
        case "files-panel":
            model.pendingFile = (model.entries.first { $0.origin == .email && $0.type == .pdf } ?? model.entries.first)?.path
        case "project-files-panel":
            let slug = state.projects.first?.slug
            model.pendingFile = (model.entries.first { $0.projectSlug == slug && $0.type == .image }
                ?? model.entries.first { $0.projectSlug == slug })?.path
        case "files-discarded":
            model.pendingDiscarded = true
        default:
            break
        }
    }
}
