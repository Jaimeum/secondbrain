import BrainCore
import SwiftUI

/// "Preguntar" (CONTRACT §16.3): the sidebar item (`.brain`) and a project's tab (`.project`), one view, no scope
/// switch (the sidebar host sets the window title). v0.6: filled in by A (Ask) — conversation list on the left (saved in `data/chats/…` by ChatStore), the
/// conversation on the right and the citation inspector. For now it hosts the scope's `ChatModel` in `ChatView`.
struct AskView: View {
    @Environment(AppState.self) private var state
    let scope: Scope

    /// A cited page, read over the conversation (A replaces this with the inspector panel).
    @ViewState private var cited: VaultPageItem?

    private var model: ChatModel { state.chat(for: scope) }

    var body: some View {
        ChatView(model: model, projectSlug: scope.projectSlug, onOpenPage: { cited = VaultPageItem(path: $0) })
            .sheet(item: $cited) { PageSheet(path: $0.path, scope: scope) }
            .onAppear(perform: consumePendingChat)
            .onChange(of: state.pendingChat) { consumePendingChat() }
    }

    /// The router's request for this scope (⌘K's "Preguntar a todo el cerebro", a notification, a ficha): a new
    /// conversation and/or a question asked at once. `threadId` is A's (saved conversations).
    private func consumePendingChat() {
        guard let request = state.pendingChat, request.scope == scope, state.engineStarted else { return }
        state.pendingChat = nil
        if request.newThread { model.clear() }
        if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            if model.isAsking { model.stop() }
            model.draft = question
            model.ask(engine: state.engine, projectSlug: scope.projectSlug)
        }
    }
}
