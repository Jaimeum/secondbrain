import BrainCore
import Foundation

/// `SB_SNAPSHOT_WINDOW=1` (`window-ask-thread-…`, `window-project-ask-thread-…`): Preguntar with saved conversations
/// and a citation open in the inspector (CONTRACT §16.13). Writes two sample conversations into the snapshot's own
/// data folder (never a real one: snapshots run on an isolated config) and opens the newest with its first citation.
@MainActor
enum AskSnapshots {
    private static var seeded: Set<String> = []

    static func seed(state: AppState, scope: Scope) {
        let conversations = state.conversations(for: scope)
        guard seeded.insert(scope.key).inserted else { return }   // once per scope: every size and theme shows the same
        let vault = state.engine.vault
        let pages = vault.pages(projectSlug: scope.projectSlug ?? state.projects.first?.slug)
        let people = vault.pages(projectSlug: nil).filter { $0.path.hasPrefix("people/") && !$0.path.hasSuffix("README.md") }
        let cited = pages.first { $0.path.contains("/meetings/") } ?? pages.first { $0.path.hasSuffix("overview.md") } ?? pages.first
        let person = people.first
        func link(_ page: WikiPage?) -> String {
            guard let page else { return "" }
            return "[[\(((page.path as NSString).lastPathComponent as NSString).deletingPathExtension)]]"
        }
        let now = Date()
        let older = ChatThread(scope: scope, title: "Qué pendientes hay y de quién…", createdAt: now.addingTimeInterval(-86_400 * 2),
                               messages: [.init(role: .user, text: "¿Qué pendientes hay y de quién son?"),
                                          .init(role: .assistant, text: "Tienes 3 pendientes abiertos.", question: "¿Qué pendientes hay y de quién son?")])
        let question = "¿Qué decidimos en la última reunión?"
        let answer = """
        En la última reunión acordaron cerrar el alcance de la primera fase y mover la presentación al 3 de noviembre \
        (\(link(cited))).

        - **Responsable:** \(person.map { $0.title } ?? "Ana") \(link(person))
        - **Siguiente paso:** enviar la propuesta revisada antes del viernes.
        """
        let latest = ChatThread(scope: scope, title: ChatStore.title(forQuestion: question), createdAt: now.addingTimeInterval(-600),
                                messages: [.init(role: .user, text: question), .init(role: .assistant, text: answer, question: question)])
        try? conversations.store.save(older)
        try? conversations.store.save(latest)
        Task {
            await conversations.reload()
            conversations.open(id: latest.id)
            conversations.inspected = cited.map { [$0.path] } ?? []
        }
    }
}
