import BrainCore
import Foundation
import Observation

/// Correo (CONTRACT §12.4 + §12.7): the inbox of the connected accounts, the message being read and the one smart
/// "Agregar a …" action. Network calls run in cancellable tasks off the main thread; lists are cached per account
/// for 5 minutes (shared by every MailModel, so leaving and coming back is instant).
@MainActor @Observable
final class MailModel {
    enum Filter: String, Hashable { case known, all }

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
    var filter: Filter = .all
    private(set) var messages: [MailMessageSummary] = []
    private(set) var nextToken: String?
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var failure: Failure?
    private(set) var selectedId: String?
    private(set) var detail: Detail?
    private(set) var detailLoading = false
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
    var actionError: String?
    var undoConflict: UndoConflict?
    private(set) var known = KnownPeople()
    /// The user changed the filter: don't switch it on their behalf any more.
    @ObservationIgnored private var filterChosen = false
    @ObservationIgnored private var projectPicked = false
    @ObservationIgnored private var knownRevision = -1

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var listTask: Task<Void, Never>?
    @ObservationIgnored private var moreTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var detailTask: Task<Void, Never>?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored private var knownTask: Task<Void, Never>?

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

    /// Called from `.task`: picks an account, loads (cache first) and the known people.
    func start(state: AppState) {
        self.state = state
        ownerEmails = ownerAddresses()
        if account?.id != accountId || accountId == nil { accountId = account?.id }
        refreshKnown()
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

    func setFilter(_ f: Filter) {
        filterChosen = true
        filter = f
        if let selectedId, !visibleMessages.contains(where: { $0.id == selectedId }) { select(visibleMessages.first?.id) }
    }

    /// Accounts changed (reconnected, added, removed): reload from the network.
    func accountsChanged() {
        if !accounts.contains(where: { $0.id == accountId }) { accountId = accounts.first?.id; messages = []; select(nil) }
        MailCache.shared.clear()
        load(force: true)
    }

    // MARK: List

    var visibleMessages: [MailMessageSummary] {
        guard filter == .known else { return messages }
        let owners = Set(accounts.map(\.email))
        return messages.filter { known.contains($0.from) || owners.contains($0.from.email ?? "") }
    }

    /// Hidden by "Conocidos" in what is loaded so far.
    var hiddenCount: Int { messages.count - visibleMessages.count }

    func load(force: Bool = false) {
        guard let state, let account else { return }
        listTask?.cancel()
        // A "Cargar más" in flight belongs to the old list: drop it, or its spinner would never go away.
        moreTask?.cancel()
        moreTask = nil
        isLoadingMore = false
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
                actionError = FriendlyError.message(error)
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
        autoPickFilter()
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

    // MARK: Known people

    /// Reads people/*.md (off the main thread) when the vault changed and picks the filter (`autoPickFilter`).
    func refreshKnown() {
        guard let state, state.vaultRevision != knownRevision else { return }
        knownRevision = state.vaultRevision
        ownerEmails = ownerAddresses()
        let vault = state.engine.vault
        knownTask?.cancel()
        knownTask = Task {
            let scanned = await Task.detached(priority: .utility) { KnownPeople.scan(vault) }.value
            guard !Task.isCancelled else { return }
            known = scanned
            autoPickFilter()
            if let selectedId, !visibleMessages.contains(where: { $0.id == selectedId }) { select(visibleMessages.first?.id) }
        }
    }

    /// Until the user picks one: "Conocidos" only when something loaded comes from a known person; otherwise
    /// "Todos" (people pages that match nobody in the inbox must not open on an empty list).
    private func autoPickFilter() {
        guard !filterChosen else { return }
        let owners = Set(accounts.map(\.email))
        let anyKnown = known.pageCount > 0
            && messages.contains { known.contains($0.from) && !owners.contains($0.from.email ?? "") }
        filter = anyKnown ? .known : .all
    }

    // MARK: Reading

    func select(_ id: String?) {
        guard id != selectedId || (id != nil && detail == nil && !detailLoading) else { return }
        selectedId = id
        detailTask?.cancel()
        detailError = nil
        projectPicked = false
        guard let id, let state, let account, let summary = messages.first(where: { $0.id == id }) else {
            detail = nil
            detailLoading = false
            return
        }
        if detail?.message.summary.id != id { detail = nil }
        detailLoading = true
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
                if let stored = thread.lazy.compactMap({ engine.emailSource(externalId: MailImport.externalId(account: account, messageId: $0.summary.id)) })
                    .first(where: { $0.threadKey != nil }) {
                    found.existingThreadKey = stored.threadKey
                    found.existingThreadProject = stored.projectSlug
                    found.continuesStoredThread = true
                } else if let match = await engine.matchThreadsAsync(for: parsed).first(where: { $0.score >= 0.8 }) {
                    found.existingThreadKey = match.thread.key
                    found.existingThreadProject = match.thread.projectSlug
                }
                guard !Task.isCancelled else { return }
                detail = found
                if !projectPicked { (projectSlug, destinationReason) = suggestedDestination(for: found) }
            } catch {
                guard !Task.isCancelled, !(error is CancellationError) else { return }
                detailError = FriendlyError.message(error)
            }
            detailLoading = false
        }
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
        guard let state, let account, let detail, !isSaving else { return }
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
                    ruleOffer.propose(subject, projectSlug: project, state: state)
                }
            }
            guard let first = added.first else {
                showToast(Toast(text: L("mail.alreadyInBrain"), sourceIds: []))
                return
            }
            // The rest of this conversation (e.g. after "Solo este mensaje") now joins that thread.
            if self.detail?.message.summary.id == detail.message.summary.id, let key = first.threadKey {
                self.detail?.existingThreadKey = key
                self.detail?.existingThreadProject = first.projectSlug
                self.detail?.continuesStoredThread = true
            }
            // Their ingest (or classify) waits until the toast is gone, so "Deshacer" always finds them still queued
            // and can delete them (a running job can't be deleted).
            state.engine.hold(sourceIds: added.map(\.id), until: Date().addingTimeInterval(Self.toastSeconds + 2))
            showToast(Toast(text: L("mail.learning"), sourceIds: added.map(\.id)))
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
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
    }

    /// "Deshacer": sources not learned yet are deleted (raw too); learned ones are undone first.
    /// The toast goes away only once everything was forgotten, so a failure can be retried.
    func undo() {
        guard let toast, let state else { return }
        if forgetAll(toast.sourceIds.reversed(), state: state) {
            dismissToast()
            if ruleOffer.current?.phase == .asking { ruleOffer.dismiss() }   // the assignment it was about is gone
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

    /// Chip menu "Ver en el proyecto": the thread's page when it exists, else the project (or Sin asignar).
    func open(_ source: SourceRecord) {
        guard let state else { return }
        if let page = SourcePages.summaryPage(for: source, vault: state.engine.vault) { state.pendingPage = page }
        state.selection = source.projectSlug.map { .project($0) } ?? .inbox
    }

    // MARK: Debug snapshots

    /// Waits (bounded) until the list and the open message are loaded.
    func waitUntilReady() async {
        for _ in 0..<60 {
            guard isLoading || detailLoading || (selectedId != nil && detail == nil && detailError == nil) else { return }
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
        model.setFilter(.all)
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
        model.setFilter(.all)
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
        guard let target = model.messages.first(where: { threads[$0.threadId] != nil }) else { return nil }
        model.setFilter(.all)
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
