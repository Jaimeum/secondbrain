import BrainCore
import SwiftUI

/// "Preguntar" (CONTRACT §16.3): the sidebar item (`.brain`) and a project's tab (`.project`), one view, no scope
/// switch (the sidebar host sets the window title). Saved conversations on the left (200–260 pt, newest first,
/// Renombrar / Eliminar), the conversation in the middle, and the page a citation points at in an inspector on the
/// right, so reading a source never leaves the conversation. "Abrir" in the inspector goes to the page's place.
struct AskView: View {
    @Environment(AppState.self) private var state
    let scope: Scope

    @ViewState private var renaming: ChatThread?
    @ViewState private var renameText = ""
    @ViewState private var deleting: ChatThread?
    @ViewState private var saveFailed = false

    private var conversations: Conversations { state.conversations(for: scope) }

    var body: some View {
        let conversations = self.conversations
        GeometryReader { geo in
            let inspecting = !conversations.inspected.isEmpty
            // With the inspector open the list narrows to 200 pt, and steps aside below ~880 pt: the conversation
            // keeps ≥ 360 pt.
            let listWidth = inspecting ? 200 : ContentLayout.listWidth(for: geo.size.width)
            let inspectorWidth = AskLayout.inspectorWidth(for: geo.size.width)
            let showList = !inspecting || geo.size.width - listWidth - inspectorWidth >= AskLayout.minConversation
            HStack(spacing: 0) {
                if showList {
                    ConversationList(conversations: conversations, onRename: startRename, onDelete: { deleting = $0 })
                        .frame(width: listWidth)
                    Rectangle().fill(Brand.color.line).frame(width: 1)
                }
                ChatView(model: conversations.current, projectSlug: scope.projectSlug,
                         onOpenPage: { inspect($0) }, onSave: save, onNew: newConversation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if inspecting {
                    Rectangle().fill(Brand.color.line).frame(width: 1)
                    CitationInspector(conversations: conversations, scope: scope)
                        .frame(width: inspectorWidth)
                        .transition(.move(edge: .trailing))
                }
            }
            .animation(Brand.motion.fast, value: inspecting)
        }
        .background(Brand.color.surface)
        .task(id: state.vaultGeneration) {
            if !conversations.loaded { await conversations.reload() }
            consumePendingChat()
        }
        .onChange(of: state.pendingChat) { consumePendingChat() }
        .onChange(of: state.engineStarted) { consumePendingChat() }
        .alert(L("ask.renameTitle"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField(L("ask.renamePlaceholder"), text: $renameText)
            Button(L("ask.rename")) {
                if let thread = renaming { conversations.rename(id: thread.id, to: renameText) }
                renaming = nil
            }
            .keyboardShortcut(.defaultAction)
            Button(L("common.cancel"), role: .cancel) { renaming = nil }
        }
        .confirmationDialog(L("ask.deleteTitle"), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            presenting: deleting) { thread in
            Button(L("ask.delete"), role: .destructive) { conversations.delete(id: thread.id) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { thread in
            Text(L("ask.deleteMessage", thread.title))
        }
        .alert(L("ask.saveFailed"), isPresented: $saveFailed) {
            Button(L("common.ok")) {}
        }
    }

    // MARK: Actions

    private func inspect(_ path: String) {
        let conversations = self.conversations
        if conversations.inspected.last != path { conversations.inspected.append(path) }
    }

    private func newConversation() {
        conversations.startNew()
        conversations.inspected = []
    }

    private func startRename(_ thread: ChatThread) {
        renameText = thread.title
        renaming = thread
    }

    /// "Guardar como página" (§16.3): the answer becomes a question page of this scope at once (one undoable
    /// Historial entry), shown in Contenido and ⌘K. No Claude run: the answer is filed as given.
    private func save(_ message: ChatMessage) {
        let conversations = self.conversations
        let model = conversations.current
        guard let index = model.messages.firstIndex(where: { $0.id == message.id }), !model.messages[index].saved else { return }
        model.messages[index].saved = true   // no second click while writing
        let vault = state.engine.vault, history = state.engine.history, scope = self.scope
        let question = message.question, answer = message.text
        let title = L("ask.savedHistoryTitle", ChatStore.title(forQuestion: question))
        Task {
            do {
                let path = try await Task.detached {
                    try SavedAnswers.save(question: question, answer: answer, scope: scope, vault: vault, history: history,
                                          title: title)
                }.value
                conversations.markSaved(messageId: message.id, path: path, in: model)
                state.bumpHistory()
            } catch {
                Log.error("save answer: \(error)")
                if let i = model.messages.firstIndex(where: { $0.id == message.id }) { model.messages[i].saved = false }
                saveFailed = true
            }
        }
    }

    /// The router's request for this scope (⌘K's "Preguntar a todo el cerebro", a notification, a ficha): a saved
    /// conversation, a new one, and/or a question asked at once.
    private func consumePendingChat() {
        guard let request = state.pendingChat, request.scope == scope, state.engineStarted else { return }
        state.pendingChat = nil
        let conversations = self.conversations
        if let id = request.threadId {
            if conversations.open(id: id) { conversations.inspected = [] }
        } else if request.newThread {
            newConversation()
        }
        if let question = request.question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty {
            let model = conversations.current
            if model.isAsking { model.stop() }
            model.draft = question
            model.ask(engine: state.engine, projectSlug: scope.projectSlug)
        }
    }
}

enum AskLayout {
    /// The conversation never gets narrower than this while the list shows.
    static let minConversation: CGFloat = 360
    /// The citation inspector: 300–380 pt, about a third of Preguntar.
    static func inspectorWidth(for total: CGFloat) -> CGFloat { min(380, max(300, (total * 0.36).rounded())) }
}

// MARK: - Conversation list

/// "Nueva conversación" and the saved conversations, most recent first; the open one is highlighted.
private struct ConversationList: View {
    let conversations: Conversations
    var onRename: (ChatThread) -> Void
    var onDelete: (ChatThread) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                conversations.startNew()
                conversations.inspected = []
            } label: {
                Label(L("ask.new"), systemImage: "square.and.pencil")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.brandSecondary)
            .help(L("ask.newHelp"))
            .padding(Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if conversations.loaded && conversations.threads.isEmpty {
                Text(L("ask.listEmpty"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(Brand.spacing.m)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(conversations.threads) { thread in
                            ConversationRow(thread: thread, isSelected: thread.id == conversations.current.threadId,
                                            isAsking: thread.id == conversations.current.threadId && conversations.current.isAsking)
                                .onTapGesture {
                                    if conversations.open(id: thread.id) { conversations.inspected = [] }
                                }
                                .contextMenu {
                                    Button(L("ask.rename")) { onRename(thread) }
                                    Divider()
                                    Button(L("ask.delete"), role: .destructive) { onDelete(thread) }
                                }
                        }
                    }
                    .padding(Brand.spacing.s)
                }
            }
        }
        .background(Brand.color.surface)
    }
}

private struct ConversationRow: View {
    let thread: ChatThread
    let isSelected: Bool
    let isAsking: Bool

    @ViewState private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(thread.title.isEmpty ? L("ask.untitled") : thread.title)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(isAsking ? L("chat.thinking") : Fmt.relative(thread.updatedAt))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(1)
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.55) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(thread.title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

// MARK: - Citation inspector

/// The page a citation points at, read beside the conversation. Links inside move within the panel (Atrás ⌘[);
/// "Abrir" goes to the page's place in the current context (§16.4); ✕ closes the panel.
private struct CitationInspector: View {
    @Environment(AppState.self) private var state
    let conversations: Conversations
    let scope: Scope

    @ViewState private var title = ""

    private var shown: String { conversations.inspected.last ?? "" }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: shown) { next in
                if next != shown { conversations.inspected.append(next) }
            }
        }
        .background(Brand.color.surface)
        .task(id: shown) {
            let vault = state.engine.vault, page = shown
            title = await Task.detached { vault.title(of: page) }.value
        }
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            if conversations.inspected.count > 1 {
                Button { _ = conversations.inspected.popLast() } label: {
                    Image(systemName: "chevron.left")
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Brand.color.text2)
                .keyboardShortcut("[", modifiers: .command)
                .help(L("wiki.back"))
            }
            Image(systemName: SourceLabels.symbol(forPath: shown)).foregroundStyle(Brand.color.text2)
            Text(title)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            let open = Button {
                let target = shown
                conversations.inspected = []
                state.navigate(to: .entity(target, scope))
            } label: {
                Label(L("page.open"), systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.brandSecondary)
            .controlSize(.small)
            .help(L("page.openHelp"))
            ViewThatFits(in: .horizontal) {
                open
                open.labelStyle(.iconOnly)
            }
            Button { conversations.inspected = [] } label: {
                Image(systemName: "xmark")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.color.text2)
            .help(L("ask.closeInspector"))
            .accessibilityLabel(Text(L("ask.closeInspector")))
        }
        .padding(.horizontal, Brand.spacing.m)
        .frame(height: 44)
    }
}
