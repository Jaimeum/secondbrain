import Foundation

// Knowledge graph of the vault (CONTRACT §12.2).

public extension BrainEngine {
    /// Nodes and edges of the whole brain (`projectSlug == nil`) or of one project. Runs off the main thread and is
    /// cached per vault revision.
    func graph(projectSlug: String?) async -> KnowledgeGraph {
        // TODO(graph engineer): build from wiki/** + people/*.md + global index.md (not raw/), resolve wikilinks with
        // VaultStore.resolveWikilinks, add synthetic "project:<slug>" nodes, cache by vault revision.
        KnowledgeGraph.empty
    }
}
