import AppKit
import BrainCore
import SwiftUI

/// "Qué sabemos de X" (CONTRACT §16.4): the ficha of any vault page — person, org, topic, decision, meeting, email,
/// document, project, saved question, repo. Opened in `scope`: from a global place it shows everything; inside a
/// project its sections are filtered to that project.
/// v0.6: filled in by B (entity pages) — header chips and "En 🚀 X · Ver todo →", the structured sections from
/// `EntityIndex` (Proyectos · Reuniones · Correos · Documentos y notas · Decisiones · Pendientes · Relacionados).
/// For now: the header (title, Editar, Ver en el grafo, Finder) over the page Claude wrote.
struct EntityView: View {
    @Environment(AppState.self) private var state
    let path: String
    var scope: Scope = .brain
    /// A link inside the page (default: the router, in this scope — a push in the host's stack).
    var onOpen: ((String) -> Void)? = nil

    @ViewState private var title: String?

    private var shownTitle: String {
        title ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: path, hideType: false) { next in
                if let onOpen { onOpen(next) } else { state.navigate(to: .entity(next, scope)) }
            }
        }
        .background(Brand.color.surface)
        .navigationTitle(shownTitle)
        .task(id: "\(path)-\(state.vaultRevision)") {
            let vault = state.engine.vault, path = self.path
            title = await Task.detached { vault.title(of: path) }.value
        }
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            Image(systemName: SourceLabels.symbol(forPath: path)).foregroundStyle(Brand.color.text2)
            Text(shownTitle)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(shownTitle)
            Spacer(minLength: Brand.spacing.s)
            ViewThatFits(in: .horizontal) {
                actions(iconOnly: false)
                actions(iconOnly: true)
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }

    private func actions(iconOnly: Bool) -> some View {
        HStack(spacing: Brand.spacing.s) {
            if EntityView.isEditable(path) {
                let edit = Button { state.editPage(path) } label: { Label(L("entity.edit"), systemImage: "pencil") }
                    .buttonStyle(.brandSecondary)
                    .help(L("entity.editHelp"))
                if iconOnly { edit.labelStyle(.iconOnly) } else { edit.labelStyle(.titleAndIcon) }
            }
            Button { state.navigate(to: .graph(scope, path)) } label: {
                Image(systemName: "point.3.connected.trianglepath.dotted")
            }
            .buttonStyle(.borderless)
            .help(L("graph.seeInGraph"))
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: path)])
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            .help(L("wiki.showInFinder"))
        }
        .foregroundStyle(Brand.color.text2)
    }

    /// Wiki pages and fichas can be edited; sources under `raw/` never (§16.6).
    static func isEditable(_ path: String) -> Bool {
        path.hasSuffix(".md") && !path.hasPrefix("raw/") && !path.contains("/raw/")
    }
}
