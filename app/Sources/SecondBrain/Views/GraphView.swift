import BrainCore
import SwiftUI

/// "Grafo" tab (CONTRACT §12.2): how everything the brain learned connects, colored by cluster.
/// `focus` = a vault-relative page to center on ("Ver en el grafo"); `onOpen` opens a page.
///
/// SKELETON (v0.3): the graph engineer replaces the body with the WKWebView (`web/graph.*`, D3 already vendored).
struct GraphView: View {
    @Environment(AppState.self) private var state
    let scope: WikiScope
    var focus: String?
    var onOpen: (String) -> Void

    @ViewState private var graph: KnowledgeGraph?

    var body: some View {
        Group {
            if let graph, !graph.isEmpty {
                // TODO(graph engineer): GraphWebView(payload: graph + labels, focus: focus, onOpen: onOpen)
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: L("graph.title"),
                               message: L("graph.count", graph.nodes.count, graph.edges.count))
            } else if graph == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: L("graph.empty.title"),
                               message: L("graph.empty.message"), actionTitle: L("record.start")) {
                    if case .project(let slug) = scope { state.recordingProjectSlug = slug }
                    state.toggleRecording()
                }
            }
        }
        .task(id: state.vaultRevision) { graph = await state.engine.graph(projectSlug: projectSlug) }
    }

    private var projectSlug: String? {
        if case .project(let slug) = scope { return slug }
        return nil
    }
}
