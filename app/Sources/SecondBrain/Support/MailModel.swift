import BrainCore
import Foundation
import Observation

/// Correo (CONTRACT §12.4 + §12.7 + §15.2): the inbox of the connected accounts, the message being read and the one
/// smart "Guardar en …" action. Network calls run in cancellable tasks off the main thread; lists are cached per account
/// for 5 minutes (shared by every MailModel, so leaving and coming back is instant).
@MainActor @Observable
final class MailModel {
    /// Why the list could not load, and what to offer.
    enum Failure: Equatable {
        case reconnect(AccountProvider)        // session expired / not configured → "Vuelve a conectar"
        case organization(AccountProvider)     // the organization must approve SecondBrain → "¿Cómo lo habilito?"
        case other(String)                     // anything else → "Reintentar"
    }

    struct Detail {
        var message: MailMessageFull
        /// The whole conversation, oldest first (at least the message itself).
        var thread: [MailMessageFull]
        var parsed: ParsedEmail
        /// Stored thread this conversation continues (one of its messages is in the brain, or a strong match).
        var existingThreadKey: String?
        /// Project of that stored thread (nil = it lives in Sin asignar).
        var existingThreadProject: String?
        /// Part of this conversation is already in the brain: the rest joins that thread, in its project.
        var continuesStoredThread = false

        /// The destination can't change: the conversation already lives in a project.
        var projectLocked: Bool { continuesStoredThread && existingThreadProject != nil }
    }

    /// A learned email whose undo hits pages changed later: "Deshacer de todos modos" (like Actividad).
    struct UndoConflict: Identifiable {
        let id = UUID()
        var sourceIds: [String]
        var paths: [String]
    }

    /// Why the smart button points where it does (CONTRACT §14.2: picked > thread > rule > default > Sin asignar).
    enum DestinationReason: Equatable {
        case none, picked, thread, rule(RoutingRule), defaultProject
        /// v0.3 behavior when there are no rules nor a default project: the last project used from Correo.
        case lastUsed
    }

    /// "Aprendiendo del correo… · Deshacer" (6 s).
    struct Toast: Identifiable, Equatable {
        let id = UUID()
        var text: String
        var sourceIds: [String]
        var undoable: Bool { !sourceIds.isEmpty }
    }

    // MARK: State

    private(set) var accountId: String?
    var query = "" { didSet { if query != oldValue { scheduleSearch() } } }
    private(set) var messages: [MailMessageSummary] = []
    private(set) var nextToken: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    /// A failed "Cargar más": shown at the end of the list with "Reintentar" (§15.2).
    private(set) var loadMoreError: String?
    private(set) var failure: Failure?
    private(set) var selectedId: String?
    /// The message on screen. While another one loads, the previous one stays (dimmed, its actions off: `isStale`)
    /// instead of blanking the reader; the loader shows only when there is nothing to keep and loading is slow.
    private(set) var detail: Detail?
    private(set) var detailLoading = false
    /// Loading has taken more than 300 ms with nothing on screen: show the loader.
    private(set) var detailSlow = false
    private(set) var detailError: String?
    /// Where the smart button adds to (nil = Sin asignar).
    private(set) var projectSlug: String?
    // MARK: v0.4 routing
    private(set) var destinationReason: DestinationReason = .none
    /// §14.3: «¿Todo lo de @acme.com a 🚀 Acme de ahora en adelante?» after a manual pick.
    let ruleOffer = RuleOffer()
    @ObservationIgnored private var ownerEmails: [String] = []
    private(set) var isSaving = false
    private(set) var toast: Toast?
    /// v0.7 (§17.1 backwards): the emails just saved by hand that have attachments — the sheet that asks which to keep.
    var attachmentReview: AttachmentReview?
    var actionError: String?
    var undoConflict: UndoConflict?
    @ObservationIgnored private var projectPicked = false
    @ObservationIgnored private var ownerRevision = -1
    /// §15.2: one floating message at a time. A rule offer earned by a save waits until its toast is gone, then shows
    /// in the reader's action bar.
    /// It belongs to the message it was earned on: it is dropped if the user moved to another one.
    @ObservationIgnored private var deferredOffer: (messageId: String, subject: RoutingSubject, projectSlug: String)?
    /// Correo is on screen (set by MailView): a deferred offer never pops up from a screen the user left.
    @ObservationIgnored var isOnScreen = false

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var slowTask: Task<Void, Never>?
    /// The stored-thread match of the open message is still running: a save waits for it (`queuedAdd`), so it never
    /// starts a duplicate thread.
    @ObservationIgnored private var matchPending = false
    @ObservationIgnored private var queuedAdd: Bool?

    static let window: TimeInterval = 30 * 86_400
    static let toastSeconds: Double = 6

    // MARK: Accounts

    /// Connected accounts that have mail (the Mac calendar has none).
    var accounts: [ConnectedAccount] {
        (state?.engine.accounts.accounts ?? []).filter { $0.provider.hasMail }
    }

    var account: ConnectedAccount? {
        accounts.first { $0.id == accountId } ?? accounts.first
    }

    // MARK: Lifecycle

    /// Called from `.task`: picks an account and loads (cache first).
    func start(state: AppState) {
        self.state = state
        ownerEmails = ownerAddresses()
        ownerRevision = state.vaultRevision
        if account?.id != accountId || accountId == nil { accountId = account?.id }
        load()
    }

    func selectAccount(_ id: String) {
        guard id != accountId else { return }
        accountId = id
        messages = []
        nextToken = nil
        select(nil)
        load()
    }

    /// Accounts changed (reconnected, added, removed): reload from the network.
    func accountsChanged() {
        if !accounts.contains(where: { $0.id == accountId }) { accountId = accounts.first?.id; messages = []; select(nil) }
        MailCache.shared.clear()
        load(force: true)
    }

    // MARK: List

    /// Every loaded message (§15.2 drops the "Conocidos / Todos" filter).
    var visibleMessages: [MailMessageSummary] { messages }

    func load(force: Bool = false) {
        guard let state, let account else { return }
        listTask?.cancel()
        // A "Cargar más" in flight belongs to the old list: drop it, or its spinner would never go away.
        moreTask?.cancel()
        moreTask = nil
        isLoadingMore = false
        loadMoreError = nil
        let key = MailCache.key(account: account.id, query: query)
        if !force, let cached = MailCache.shared.list(key) {
            apply(cached.messages, next: cached.next, append: false)
            failure = nil
            isLoading = false
            return
        }
        let provider = state.engine.accounts.provider(for: account)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        isLoading = true
        failure = nil
        listTask = Task {
            do {
                let page = q.isEmpty
                    ? try await provider.listMessages(since: Date().addingTimeInterval(-Self.window), pageToken: nil)
                    : try await provider.searchMessages(q, pageToken: nil)
                guard !Task.isCancelled else { return }
                MailCache.shared.store(key, messages: page.messages, next: page.next)
                apply(page.messages, next: page.next, append: false)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                failure = Self.failure(error, provider: account.provider)
            }
            if !Task.isCancelled { isLoading = false }
        }
    }

    func loadMore() {
        guard let state, let account, let token = nextToken, !isLoadingMore else { return }
        let provider = state.engine.accounts.provider(for: account)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MailCache.key(account: account.id, query: query)
        isLoadingMore = true
        loadMoreError = nil
        moreTask = Task {
            do {
                let page = q.isEmpty
                    ? try await provider.listMessages(since: Date().addingTimeInterval(-Self.window), pageToken: token)
                    : try await provider.searchMessages(q, pageToken: token)
                guard !Task.isCancelled else { return }
                apply(page.messages, next: page.next, append: true)
                MailCache.shared.store(key, messages: messages, next: nextToken)
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                loadMoreError = FriendlyError.message(error)
            }
            if !Task.isCancelled { isLoadingMore = false }
        }
    }

    private func apply(_ list: [MailMessageSummary], next: String?, append: Bool) {
        if append {
            let seen = Set(messages.map(\.id))
            messages += list.filter { !seen.contains($0.id) }
        } else {
            messages = list
        }
        nextToken = next
        // Keep reading what was open; otherwise open the newest message, like Mail does.
        if selectedId == nil || !visibleMessages.contains(where: { $0.id == selectedId }) { select(visibleMessages.first?.id) }
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            load()
        }
    }

    private static func failure(_ error: Error, provider: AccountProvider) -> Failure {
        switch error as? AccountError {
        case .unauthorized?, .notConfigured?: return .reconnect(provider)
        case .consentRequired?: return .organization(provider)
        default: return .other(FriendlyError.message(error))
        }
    }

    // MARK: Owner

    /// The vault changed: re-read the owner's addresses (people/README.md) used by the rules.
    func vaultChanged() {
        guard let state, state.vaultRevision != ownerRevision else { return }
        ownerRevision = state.vaultRevision
        ownerEmails = ownerAddresses()
    }

    // MARK: Reading

    /// The reader shows a message other than the selected one (the new one is still loading): dimmed, no actions.
    var isStale: Bool { detail != nil && detail?.message.summary.id != selectedId }

    func select(_ id: String?) {
        guard id != selectedId || (id != nil && detail?.message.summary.id != id && !detailLoading) else { return }
        let changed = id != selectedId
        selectedId = id
        detailTask?.cancel()
        slowTask?.cancel()
        detailSlow = false
        detailError = nil
        actionError = nil   // an error belongs to the message it happened on
        projectPicked = false
        matchPending = false
        queuedAdd = nil
        // §15.2: an offer about the previous message never stays under the next one.
        if changed, ruleOffer.current?.phase == .asking { ruleOffer.dismiss() }
        guard let id, let state, let account, let summary = messages.first(where: { $0.id == id }) else {
            detail = nil
            detailLoading = false
            return
        }
        detailLoading = true
        if detail == nil {
            // Nothing to keep on screen: a loader, but only if this is slow (cached messages render at once).
            slowTask = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, self.detailLoading, self.selectedId == id else { return }
                self.detailSlow = true
            }
        }
        let provider = state.engine.accounts.provider(for: account)
        let engine = state.engine
        let cachedMessage = MailCache.shared.message(account.id, id)
        let cachedThread = MailCache.shared.thread(account.id, summary.threadId)
        detailTask = Task {
            do {
                // Message and conversation in parallel (cache first).
                async let full = Self.fetchMessage(provider, id: id, cached: cachedMessage)
                async let conversation = Self.fetchThread(provider, id: summary.threadId, cached: cachedThread)
                let message = try await full
                var thread = (try? await conversation) ?? []
                guard !Task.isCancelled else { return }
                MailCache.shared.store(message: message, account: account.id)
                if !thread.isEmpty { MailCache.shared.store(thread: thread, id: summary.threadId, account: account.id) }
                if !thread.contains(where: { $0.summary.id == id }) { thread.append(message) }
                thread.sort { $0.summary.date < $1.summary.date }
                let parsed = MailImport.parsedEmail(message, account: account, ownerEmails: engine.vault.ownerEmails(),
                                                    language: engine.config.uiLanguage)
                var found = Detail(message: message, thread: thread, parsed: parsed)
                // A message of this conversation is already in the brain: continue its thread.
                let stored = thread.lazy.compactMap({ engine.emailSource(externalId: MailImport.externalId(account: account, messageId: $0.summary.id)) })
                    .first(where: { $0.threadKey != nil })
                if let stored {
                    found.existingThreadKey = stored.threadKey
                    found.existingThreadProject = stored.projectSlug
                    found.continuesStoredThread = true
                } else if let key = engine.vault.threadKey(accountId: account.id, providerThreadId: summary.threadId),
                          let info = engine.vault.threadInfo(key: key) {
                    // v0.7 (§17.4): the provider's conversation id is saved with a thread: that is its thread, always.
                    found.existingThreadKey = key
                    found.existingThreadProject = info.projectSlug
                    found.continuesStoredThread = true
                }
                // On screen now; the fuzzy thread match (reads every stored email) patches it afterwards.
                show(found)
                guard stored == nil, !found.continuesStoredThread else { finishLoading(); return }
                matchPending = true
                let match = await engine.matchThreadsAsync(for: parsed).first(where: { $0.score >= 0.8 })
                guard !Task.isCancelled, selectedId == id, self.detail?.message.summary.id == id else { return }
                matchPending = false
                if let match {
                    self.detail?.existingThreadKey = match.thread.key
                    self.detail?.existingThreadProject = match.thread.projectSlug
                    if !projectPicked, let detail = self.detail { (projectSlug, destinationReason) = suggestedDestination(for: detail) }
                }
                finishLoading()
                if let onlyThis = queuedAdd { queuedAdd = nil; add(onlyThis: onlyThis) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                detail = nil
                detailError = FriendlyError.message(error)
                finishLoading()
            }
        }
    }

    private func show(_ found: Detail) {
        detail = found
        if !projectPicked { (projectSlug, destinationReason) = suggestedDestination(for: found) }
    }

    private func finishLoading() {
        slowTask?.cancel()
        detailLoading = false
        detailSlow = false
    }

    private nonisolated static func fetchMessage(_ provider: MailCalendarProvider, id: String,
                                                 cached: MailMessageFull?) async throws -> MailMessageFull {
        if let cached { return cached }
        return try await provider.fetchMessage(id: id)
    }

    private nonisolated static func fetchThread(_ provider: MailCalendarProvider, id: String,
                                                cached: [MailMessageFull]?) async throws -> [MailMessageFull] {
        if let cached { return cached }
        return try await provider.fetchThread(id: id)
    }

    /// §14.2: the stored thread's project, else a rule, else the default project (only for a new thread: the default
    /// never moves a thread that lives in Sin asignar), else Sin asignar. Without rules nor a default project, the last
    /// project used from Correo (v0.3).
    private func suggestedDestination(for detail: Detail) -> (String?, DestinationReason) {
        guard let state else { return (nil, .none) }
        if detail.existingThreadKey != nil, let slug = detail.existingThreadProject, state.project(slug) != nil { return (slug, .thread) }
        let preview = state.engine.routingPreview(routingSubject(detail))
        if let decision = preview.decision { return (preview.projectSlug, .rule(decision.rule)) }
        if detail.existingThreadKey == nil, let slug = preview.projectSlug { return (slug, .defaultProject) }
        let routing = state.engine.routing.settings
        if routing.rules.isEmpty, routing.defaultProjectSlug == nil, let last = state.config.lastMailProjectSlug, state.project(last) != nil {
            return (last, .lastUsed)
        }
        return (nil, .none)
    }

    /// people/README.md's addresses plus the connected accounts' (a rule never targets the owner or their colleagues' domain).
    private func ownerAddresses() -> [String] {
        let vault = state?.engine.vault.ownerEmails() ?? []
        return vault + accounts.map { $0.email.lowercased() }.filter { !vault.contains($0) }
    }

    /// The open message as the rules see it (to + cc, the new text).
    func routingSubject(_ detail: Detail) -> RoutingSubject {
        .mail(detail.parsed, ownerEmails: ownerEmails)
    }

    /// Rules changed (a rule was just created, edited in Reglas…): the button follows unless the user picked.
    func routingChanged() {
        guard !projectPicked, let detail else { return }
        (projectSlug, destinationReason) = suggestedDestination(for: detail)
    }

    func pickProject(_ slug: String?) {
        projectPicked = true
        projectSlug = slug
        destinationReason = .picked
    }

    /// A list row's destination by rule or default project (nil = nothing decides it: no chip). No hit is counted.
    func routedDestination(for message: MailMessageSummary) -> (projectSlug: String, rule: RoutingRule?)? {
        guard let state else { return nil }
        let preview = state.engine.routingPreview(.mail(message, ownerEmails: ownerEmails))
        guard let slug = preview.projectSlug else { return nil }
        return (slug, preview.decision?.rule)
    }

    // MARK: In the brain

    func externalId(_ messageId: String) -> String? {
        account.map { MailImport.externalId(account: $0, messageId: messageId) }
    }

    /// The source a message became, if it is in the brain.
    func source(for messageId: String) -> SourceRecord? {
        guard let state, let id = externalId(messageId) else { return nil }
        return state.engine.emailSource(externalId: id)
    }

    /// Messages of the open conversation not in the brain yet.
    var newInThread: [MailMessageFull] {
        guard let detail else { return [] }
        return detail.thread.filter { source(for: $0.summary.id) == nil }
    }

    // MARK: Adding

    /// The smart action: the whole conversation (what is missing of it) unless `onlyThis`.
    func add(onlyThis: Bool) {
        guard let state, let account, let detail, !isSaving, !isStale else { return }
        if matchPending { queuedAdd = onlyThis; return }   // runs as soon as the thread match is in
        let list = onlyThis ? [detail.message] : newInThread
        guard !list.isEmpty else { return }
        actionError = nil
        isSaving = true
        defer { isSaving = false }
        let project = detail.projectLocked ? detail.existingThreadProject : projectSlug
        // Continue the stored thread only when it is (or can move) where the user is adding to.
        var threadKey: String?
        if let key = detail.existingThreadKey, detail.existingThreadProject == nil || detail.existingThreadProject == project {
            threadKey = key
        }
        let subject = routingSubject(detail)
        let reason = destinationReason
        let picked = projectPicked
        do {
            // The button already applied §14.2 and says where it goes: that is what happens (an explicit Sin asignar
            // must not be routed again; a conversation is routed by what the open message says, not its oldest one).
            let added = try state.engine.addMailMessages(list, account: account, threadKey: threadKey, projectSlug: project,
                                                         routeIfUnassigned: false)
            if project != state.config.lastMailProjectSlug { state.update { $0.lastMailProjectSlug = project } }
            state.bumpVault()
            // MARK: v0.4 routing — the rule that chose the destination counts a hit; a manual pick offers a rule.
            if !added.isEmpty, !detail.projectLocked {
                if case .rule = reason, !picked { _ = state.engine.routing.route(subject) }
                let routed = state.engine.routingPreview(subject).projectSlug
                if picked || reason == .lastUsed, let project, project != routed {
                    deferredOffer = (detail.message.summary.id, subject, project)   // shown once the toast is gone
                }
            }
            guard let first = added.first else {
                showToast(Toast(text: L("mail.alreadyInBrain"), sourceIds: []))
                return
            }
            // §17.1 backwards: the saved emails' attachments are confirmed in a sheet (ticks preselected by the triage).
            let addedIds = Set(added.compactMap(\.externalId))
            let withFiles = list.filter {
                $0.summary.hasAttachments && addedIds.contains(MailImport.externalId(account: account, messageId: $0.summary.id))
            }
            if !withFiles.isEmpty { attachmentReview = AttachmentReview(messages: withFiles, account: account) }
            // The rest of this conversation (e.g. after "Solo este mensaje") now joins that thread.
            if self.detail?.message.summary.id == detail.message.summary.id, let key = first.threadKey {
                self.detail?.existingThreadKey = key
                self.detail?.existingThreadProject = first.projectSlug
                self.detail?.continuesStoredThread = true
            }
            // Their ingest (or classify) waits until the toast is gone, so "Deshacer" always finds them still queued
            // and can delete them (a running job can't be deleted).
            state.engine.hold(sourceIds: added.map(\.id), until: Date().addingTimeInterval(Self.toastSeconds + 2))
            // The toast names the email, so "Deshacer" can't look as if it applies to another message on screen.
            showToast(Toast(text: L("mail.learningSubject", Self.shortSubject(detail.message.summary.subject)),
                            sourceIds: added.map(\.id)))
        } catch {
            actionError = FriendlyError.message(error)
        }
    }

    private func showToast(_ t: Toast) {
        toast = t
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(Self.toastSeconds))
            guard !Task.isCancelled else { return }
            toast = nil
            showDeferredOffer()
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// The rule offer a save earned, now that its toast is gone (§15.2: never two messages at once). Only while that
    /// message is still the one on screen.
    private func showDeferredOffer() {
        guard let offer = deferredOffer, let state else { return }
        deferredOffer = nil
        guard isOnScreen, detail?.message.summary.id == offer.messageId, !isStale else { return }
        ruleOffer.propose(offer.subject, projectSlug: offer.projectSlug, state: state)
    }

    /// "«Contrato actualizado — Acme»", shortened so the toast stays one line.
    static func shortSubject(_ subject: String) -> String {
        let s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return L("mail.noSubject") }
        return s.count > 40 ? String(s.prefix(39)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    /// "Deshacer": sources not learned yet are deleted (raw too); learned ones are undone first.
    /// The toast goes away only once everything was forgotten, so a failure can be retried.
    func undo() {
        guard let toast, let state else { return }
        if forgetAll(toast.sourceIds.reversed(), state: state) {
            dismissToast()
            deferredOffer = nil   // the assignment it was about is gone
            if ruleOffer.current?.phase == .asking { ruleOffer.dismiss() }
        }
    }

    /// Chip menu "Quitar".
    func remove(_ source: SourceRecord) {
        guard let state else { return }
        _ = forgetAll([source.id], state: state)
    }

    /// "Deshacer de todos modos" after a conflict: overwrites the later changes to those pages.
    func forceUndo(_ conflict: UndoConflict) {
        undoConflict = nil
        guard let state else { return }
        _ = forgetAll(conflict.sourceIds, force: true, state: state)
    }

    /// Forgets each source in order; stops at the first failure (a conflict asks "¿deshacer de todos modos?").
    private func forgetAll(_ ids: [String], force: Bool = false, state: AppState) -> Bool {
        defer { state.bumpVault() }
        for (i, id) in ids.enumerated() {
            do {
                try forget(id, force: force, engine: state.engine)
            } catch HistoryError.conflict(let paths) {
                undoConflict = UndoConflict(sourceIds: Array(ids[i...]), paths: paths)
                return false
            } catch {
                actionError = FriendlyError.message(error)
                return false
            }
        }
        return true
    }

    private func forget(_ sourceId: String, force: Bool = false, engine: BrainEngine) throws {
        guard let src = engine.source(sourceId) else { return }
        if src.status == .done, let history = src.historyId {
            do {
                try engine.undo(historyId: history, force: force)
            } catch HistoryError.notFound, HistoryError.alreadyUndone {
                // History pruned (or undone in Actividad): nothing left to undo, just forget the source.
            }
        }
        try engine.delete(sourceId: sourceId)
    }

    /// "Guardado · Ver en el proyecto": the thread's page when it exists (looked up off the main thread), else what
    /// `AppState.open(source:)` does (the learned page, the project's Contenido, or Inicio › Sin asignar).
    func open(_ source: SourceRecord) {
        guard let state else { return }
        let vault = state.engine.vault
        Task {
            let page = await Task.detached { SourcePages.summaryPage(for: source, vault: vault) }.value
            if let page { state.open(path: page) } else { state.open(source: source) }
        }
    }

    /// A saved email in Sin asignar gets its project from Correo ("Elegir proyecto ▾" / "Asignar"): the whole thread
    /// moves. A manual choice may earn the §14.3 rule offer (after the toast, if one is showing).
    func assign(_ source: SourceRecord, to slug: String) {
        guard let state else { return }
        actionError = nil
        let subject = state.engine.routingSubject(forSourceId: source.id)
        do {
            try state.engine.assign(sourceId: source.id, to: slug)
        } catch {
            actionError = (error as? EngineError)?.errorDescription ?? L("sources.moveFailed")
            return
        }
        if let detail, detail.existingThreadKey == source.threadKey || detail.existingThreadKey == nil {
            self.detail?.existingThreadKey = source.threadKey
            self.detail?.existingThreadProject = slug
            self.detail?.continuesStoredThread = true
        }
        projectSlug = slug
        destinationReason = .thread
        state.bumpVault()
        guard let subject, slug != state.engine.routingPreview(subject).projectSlug, let messageId = detail?.message.summary.id
        else { return }
        if toast != nil {
            deferredOffer = (messageId, subject, slug)
        } else {
            ruleOffer.propose(subject, projectSlug: slug, state: state)
        }
    }

    // MARK: Debug snapshots

    /// Waits (bounded) until the list and the open message are loaded.
    func waitUntilReady() async {
        for _ in 0..<60 {
            guard isLoading || detailLoading || (selectedId != nil && detail?.message.summary.id != selectedId && detailError == nil)
            else { return }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// `DebugSnapshots` "mail-rule-offer": opens a message from a corporate sender, picks a project by hand and shows
    /// the §14.3 offer (nothing is added nor written). Development only.
    static func snapshotRuleOffer(state: AppState) async -> MailModel? {
        state.engine.autoProcess = false
        let model = MailModel()
        model.start(state: state)
        await model.waitUntilReady()
        guard let project = state.projects.first else { return nil }
        // A sender no rule covers yet, outside the owner's domain and not a webmail: the offer proposes its domain.
        let ownDomains = Set(model.accounts.compactMap { $0.email.split(separator: "@").last.map(String.init) })
        let target = model.messages.first { m in
            guard let e = m.from.email, let d = e.split(separator: "@").last.map(String.init) else { return false }
            return model.routedDestination(for: m) == nil && !ownDomains.contains(d) && !RoutingStore.isPublicDomain(d)
        } ?? model.messages.first
        guard let target else { return nil }
        model.select(target.id)
        await model.waitUntilReady()
        guard let detail = model.detail else { return nil }
        model.pickProject(project.slug)
        model.ruleOffer.propose(model.routingSubject(detail), projectSlug: project.slug, state: state)
        return model
    }

    /// `DebugSnapshots` "mail-rule-routed": opens the first message a rule sends somewhere (the button names the rule's
    /// project with "Por la regla «…»" under it). Writes nothing. Development only.
    static func snapshotRouted(state: AppState) async -> MailModel? {
        let model = MailModel()
        model.start(state: state)
        await model.waitUntilReady()
        guard let target = model.messages.first(where: { model.routedDestination(for: $0)?.rule != nil && model.source(for: $0.id) == nil })
        else { return nil }
        model.select(target.id)
        await model.waitUntilReady()
        return model
    }

    /// `DebugSnapshots` "mail-added": opens the newest message of a conversation and presses the smart button, so the
    /// snapshot shows the ✓ chips and the "Aprendiendo del correo… · Deshacer" toast. Development only.
    static func snapshotAfterAdd(state: AppState) async -> MailModel? {
        state.engine.autoProcess = false   // a snapshot must never start a real Claude ingest
        let model = MailModel()
        model.start(state: state)
        await model.waitUntilReady()
        func threads() -> [String: [MailMessageSummary]] { Dictionary(grouping: model.messages, by: \.threadId).filter { $0.value.count > 1 } }
        for _ in 0..<5 where threads().isEmpty && model.nextToken != nil {
            model.loadMore()
            for _ in 0..<40 where model.isLoadingMore { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let threads = threads()
        // Prefer a conversation (else any message) not in the brain yet, so the snapshot really shows the toast.
        let notInBrain: (MailMessageSummary) -> Bool = { m in (threads[m.threadId] ?? [m]).allSatisfy { model.source(for: $0.id) == nil } }
        guard let target = model.messages.first(where: { threads[$0.threadId] != nil && notInBrain($0) })
            ?? model.messages.first(where: notInBrain) ?? model.messages.first(where: { threads[$0.threadId] != nil })
        else { return nil }
        model.select(target.id)
        await model.waitUntilReady()
        model.add(onlyThis: false)
        return model
    }
}

// MARK: - Cache

/// In-memory cache shared by the Correo screens: list pages for 5 minutes, messages and threads while the app runs.
@MainActor
final class MailCache {
    static let shared = MailCache()
    static let ttl: TimeInterval = 5 * 60

    private var lists: [String: (messages: [MailMessageSummary], next: String?, at: Date)] = [:]
    private var messages: [String: MailMessageFull] = [:]
    private var threads: [String: (list: [MailMessageFull], at: Date)] = [:]

    static func key(account: String, query: String) -> String {
        account + "|" + query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func list(_ key: String) -> (messages: [MailMessageSummary], next: String?)? {
        guard let entry = lists[key], Date().timeIntervalSince(entry.at) < Self.ttl else { return nil }
        return (entry.messages, entry.next)
    }

    func store(_ key: String, messages list: [MailMessageSummary], next: String?) {
        lists[key] = (list, next, Date())
    }

    func message(_ account: String, _ id: String) -> MailMessageFull? { messages[account + "|" + id] }

    func store(message: MailMessageFull, account: String) {
        if messages.count > 500 { messages.removeAll() }
        messages[account + "|" + message.summary.id] = message
    }

    func thread(_ account: String, _ id: String) -> [MailMessageFull]? {
        guard let entry = threads[account + "|" + id], Date().timeIntervalSince(entry.at) < Self.ttl else { return nil }
        return entry.list
    }

    func store(thread: [MailMessageFull], id: String, account: String) {
        threads[account + "|" + id] = (thread, Date())
    }

    func clear() {
        lists.removeAll()
        threads.removeAll()
    }
}

/// The emails whose attachments the review sheet asks about (§17.1 backwards).
struct AttachmentReview: Identifiable {
    let id = UUID()
    let messages: [MailMessageFull]
    let account: ConnectedAccount
}
