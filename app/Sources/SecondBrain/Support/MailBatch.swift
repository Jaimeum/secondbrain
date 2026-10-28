import BrainCore
import Foundation
import Observation

// v0.7 (CONTRACT §17.6): saving mail backwards. `MailSelection` is Correo's multi-select, `MailBatchModel` feeds the
// confirmation sheet (whole conversations + their attachments with checkboxes preselected by `AttachmentTriage`; no
// Claude backwards), and `MailBatchSaver` saves what was confirmed in the background, its progress in QueueStatusLine.

/// The checked messages of Correo's list (checkbox column, ⌘-click, ⇧-click). Independent of the open message.
@MainActor @Observable
final class MailSelection {
    private(set) var ids: Set<String> = []
    /// Where a ⇧-click range starts: the last message checked or unchecked one by one.
    @ObservationIgnored private var anchor: String?

    var isActive: Bool { !ids.isEmpty }
    var count: Int { ids.count }
    func contains(_ id: String) -> Bool { ids.contains(id) }

    /// The checkbox or ⌘-click. Starting a selection with ⌘-click also takes the message that is open (like Mail).
    func toggle(_ id: String, alsoOpen open: String? = nil) {
        if ids.isEmpty, let open, open != id { ids.insert(open) }
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        anchor = id
    }

    /// ⇧-click: everything between the anchor (else the open message) and `id`, in list order, is checked.
    func extend(to id: String, in order: [String], open: String?) {
        guard let to = order.firstIndex(of: id) else { return }
        let start = (anchor ?? open).flatMap { order.firstIndex(of: $0) } ?? to
        for i in min(start, to)...max(start, to) { ids.insert(order[i]) }
        anchor = id
    }

    /// Messages no longer in the list are dropped (another account, a new search).
    func keepOnly(_ visible: [String]) {
        let set = Set(visible)
        if !ids.isSubset(of: set) { ids.formIntersection(set) }
    }

    func clear() {
        ids.removeAll()
        anchor = nil
    }
}

/// One confirmation sheet: "Guardar en …" for the checked messages, or "Traer anteriores" for a rule.
@MainActor @Observable
final class MailBatchModel: Identifiable {
    enum Origin {
        /// The checked messages of Correo (their whole conversations).
        case selection([MailMessageSummary], ConnectedAccount)
        /// What `rule` would have caught in the last 90 days, in every mail account.
        case rule(RoutingRule)
    }

    enum Phase: Equatable { case searching, loading, ready, failed(String) }

    /// One attachment row: its checkbox starts from the triage (§17.1 backwards).
    struct Attachment: Identifiable {
        var id: String { messageId + "|" + info.id }
        let messageId: String
        let info: AttachmentInfo
        let decision: AttachmentDecision
    }

    /// One conversation of the sheet.
    struct Conversation: Identifiable {
        var id: String { account.id + "|" + threadId }
        let account: ConnectedAccount
        let threadId: String
        var subject: String
        /// The whole conversation, oldest first.
        var messages: [MailMessageFull]
        /// Of those, the ones not in the brain yet (what saving adds).
        var missing: [MailMessageFull]
        /// The conversation already lives in a project (the rest joins it there; nil = new or in Sin asignar).
        var storedProject: String?
        var attachments: [Attachment] = []
        var attachmentsLoading = false
        /// The attachments could not be listed (shown under the row; the mail still saves).
        var attachmentsError: String?

        var isFullySaved: Bool { missing.isEmpty }
        var lastDate: Date { messages.last?.summary.date ?? .distantPast }
    }

    let id = UUID()
    let origin: Origin
    /// Where it goes (selection: the bar's choice; rule: the rule's project).
    var projectSlug: String?
    private(set) var phase: Phase = .loading
    private(set) var conversations: [Conversation] = []
    /// Messages the rule matched (before grouping into conversations).
    private(set) var matchedCount = 0
    var included: Set<String> = []
    var checkedAttachments: Set<String> = []

    /// Called once the save is handed over (Correo clears its checkboxes).
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var task: Task<Void, Never>?

    init(origin: Origin, projectSlug: String?) {
        self.origin = origin
        self.projectSlug = projectSlug
        if case .rule = origin { phase = .searching }
    }

    var rule: RoutingRule? {
        if case .rule(let r) = origin { return r }
        return nil
    }

    // MARK: Totals

    /// Conversations that will be saved (checked and with something missing).
    var chosen: [Conversation] { conversations.filter { included.contains($0.id) && !$0.isFullySaved } }
    var messagesToSave: Int { chosen.reduce(0) { $0 + $1.missing.count } }
    var attachmentsToSave: Int {
        chosen.reduce(0) { n, c in n + c.attachments.filter { checkedAttachments.contains($0.id) }.count }
    }
    var alreadySavedCount: Int { conversations.filter(\.isFullySaved).count }
    var isBusy: Bool { phase == .searching || phase == .loading || conversations.contains { $0.attachmentsLoading } }

    // MARK: Loading

    func start(state: AppState) {
        guard task == nil else { return }
        self.state = state
        task = Task { await load(state: state) }
    }

    func cancel() {
        task?.cancel()
    }

    private func load(state: AppState) async {
        let engine = state.engine
        var seeds: [(ConnectedAccount, [MailMessageSummary])] = []
        switch origin {
        case .selection(let list, let account):
            seeds = [(account, list)]
        case .rule(let rule):
            phase = .searching
            let owners = engine.vault.ownerEmails()
            for account in engine.accounts.mailAccounts {
                let provider = engine.accounts.provider(for: account)
                let ownAndAccount = owners + [account.email.lowercased()]
                do {
                    let found = try await MailBackfill.findMatches(rule: rule, rules: engine.routing.rules, provider: provider,
                                                                   ownerEmails: ownAndAccount,
                                                                   limit: MailBackfill.maxMessages - matchedCount)
                    matchedCount += found.count
                    if !found.isEmpty { seeds.append((account, found)) }
                } catch {
                    guard !Task.isCancelled else { return }
                    if engine.accounts.mailAccounts.count == 1 { phase = .failed(FriendlyError.message(error)); return }
                }
                if matchedCount >= MailBackfill.maxMessages { break }
            }
        }
        guard !Task.isCancelled else { return }
        phase = .loading
        for (account, list) in seeds {
            let provider = engine.accounts.provider(for: account)
            for threadId in MailBackfill.threadIds(list) {
                guard !Task.isCancelled else { return }
                let seedMessages = list.filter { $0.threadId == threadId }
                guard var conversation = await Self.conversation(threadId, seeds: seedMessages, account: account, provider: provider)
                else { continue }
                conversation.missing = engine.unsavedMessages(conversation.messages, account: account)
                conversation.storedProject = engine.storedThread(of: conversation.messages, account: account)?.projectSlug
                conversations.append(conversation)
                if !conversation.isFullySaved { included.insert(conversation.id) }
            }
        }
        guard !Task.isCancelled else { return }
        phase = .ready
        await loadAttachments(engine: engine)
    }

    /// The whole provider conversation (cache first); if it can't be read, the seed messages one by one.
    private static func conversation(_ threadId: String, seeds: [MailMessageSummary], account: ConnectedAccount,
                                     provider: MailCalendarProvider) async -> Conversation? {
        var messages = MailCache.shared.thread(account.id, threadId) ?? []
        if messages.isEmpty {
            messages = (try? await provider.fetchThread(id: threadId)) ?? []
            if !messages.isEmpty { MailCache.shared.store(thread: messages, id: threadId, account: account.id) }
        }
        for seed in seeds where !messages.contains(where: { $0.summary.id == seed.id }) {
            if let full = MailCache.shared.message(account.id, seed.id) {
                messages.append(full)
            } else if let full = try? await provider.fetchMessage(id: seed.id) {
                MailCache.shared.store(message: full, account: account.id)
                messages.append(full)
            }
        }
        guard !messages.isEmpty else { return nil }
        messages.sort { $0.summary.date < $1.summary.date }
        // The conversation's subject without "RE:"/"Fwd:" (the oldest message's, the one that started it).
        let subject = EmailParser.normalizeSubject(messages.first?.summary.subject ?? seeds.first?.subject ?? "")
        return Conversation(account: account, threadId: threadId, subject: subject, messages: messages, missing: messages)
    }

    /// Lists the attachments of every message to save that has any, and ticks them as the triage says. A provider
    /// that can't list them yet (or a failure) leaves the row without attachments: the mail still saves.
    private func loadAttachments(engine: BrainEngine) async {
        for i in conversations.indices where !conversations[i].isFullySaved {
            let withFiles = conversations[i].missing.filter(\.summary.hasAttachments)
            guard !withFiles.isEmpty else { continue }
            conversations[i].attachmentsLoading = true
            let provider = engine.accounts.provider(for: conversations[i].account)
            var rows: [Attachment] = []
            var failure: String?
            for message in withFiles {
                guard !Task.isCancelled else { return }
                do {
                    let list = try await provider.listAttachments(messageId: message.summary.id)
                    for p in MailBackfill.preselection(list, message: message) {
                        let row = Attachment(messageId: message.summary.id, info: p.info, decision: p.decision)
                        rows.append(row)
                        if p.checked { checkedAttachments.insert(row.id) }
                    }
                } catch AttachmentError.notImplemented {
                    continue
                } catch {
                    if failure == nil { failure = FriendlyError.message(error) }
                }
            }
            guard conversations.indices.contains(i) else { return }
            conversations[i].attachments = rows
            conversations[i].attachmentsError = failure
            conversations[i].attachmentsLoading = false
        }
    }

    // MARK: Checkboxes

    func toggle(conversation id: String) {
        if included.contains(id) { included.remove(id) } else { included.insert(id) }
    }

    func toggle(attachment id: String) {
        if checkedAttachments.contains(id) { checkedAttachments.remove(id) } else { checkedAttachments.insert(id) }
    }

    // MARK: Saving

    /// Hands what is checked to `MailBatchSaver` (it keeps going after the sheet closes).
    func save() {
        guard let state, messagesToSave > 0 else { return }
        task?.cancel()
        let jobs = chosen.map { c in
            MailBatchSaver.Job(account: c.account, messages: c.messages, missing: c.missing.count,
                               attachments: Dictionary(grouping: c.attachments, by: \.messageId).mapValues { $0.map(\.info) },
                               confirmed: Set(c.attachments.filter { checkedAttachments.contains($0.id) }.map(\.id)))
        }
        MailBatchSaver.shared.run(jobs, projectSlug: projectSlug, state: state)
        onSaved?()
    }

    // MARK: Debug snapshots

    /// Waits (bounded) until the sheet has everything it lists.
    func waitUntilReady() async {
        for _ in 0..<100 where isBusy { try? await Task.sleep(for: .milliseconds(50)) }
    }

    /// A synthetic contract PDF and a 4 KB logo on the first conversation with attachments, so the snapshots show the
    /// checklist while the demo provider can't list attachments yet. Development only.
    func injectSnapshotAttachments() {
        guard let i = conversations.firstIndex(where: { !$0.isFullySaved }), conversations[i].attachments.isEmpty,
              let message = conversations[i].missing.first(where: \.summary.hasAttachments) ?? conversations[i].missing.first
        else { return }
        let samples = [
            AttachmentInfo(id: "snap-pdf", name: Localizer.language == "en" ? "Contract-Acme-2026.pdf" : "Contrato-Acme-2026.pdf",
                           mimeType: "application/pdf", size: 1_240_000),
            AttachmentInfo(id: "snap-logo", name: "image001.png", mimeType: "image/png", size: 4_096, isInline: true, contentId: "logo"),
            AttachmentInfo(id: "snap-video", name: "Recorrido-planta.mov", mimeType: "video/quicktime", size: 48_000_000),
        ]
        let decisions: [AttachmentDecision] = [.keep, .discard(.inlineImage), .tooBig]
        conversations[i].attachments = zip(samples, decisions).map { info, decision in
            Attachment(messageId: message.summary.id, info: info, decision: decision)
        }
        checkedAttachments.insert(message.summary.id + "|snap-pdf")
    }
}

/// Saves confirmed conversations one by one in the background; `status` feeds QueueStatusLine (§17.6).
@MainActor @Observable
final class MailBatchSaver {
    static let shared = MailBatchSaver()

    struct Job: Sendable {
        let account: ConnectedAccount
        /// The whole conversation (what is already in the brain is skipped).
        let messages: [MailMessageFull]
        /// How many of them are not in the brain yet (the progress counts these).
        let missing: Int
        /// Listed attachments by message id, and the ids left ticked.
        let attachments: [String: [AttachmentInfo]]
        let confirmed: Set<String>
    }

    private(set) var status: QueueStatus?
    /// The last run's problem, if any (Correo shows it under the list until dismissed).
    var lastError: String?
    @ObservationIgnored private var queue: [(Job, String?)] = []
    @ObservationIgnored private var total = 0
    @ObservationIgnored private var done = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    var isRunning: Bool { task != nil }

    func run(_ jobs: [Job], projectSlug: String?, state: AppState) {
        guard !jobs.isEmpty else { return }
        queue += jobs.map { ($0, projectSlug) }
        total += jobs.reduce(0) { $0 + $1.missing }
        lastError = nil
        update()
        guard task == nil else { return }
        task = Task { await drain(state: state) }
    }

    private func update() {
        status = total == 0 ? nil
            : QueueStatus(text: L("batch.progress", min(done + 1, total), total), progress: Double(done) / Double(max(total, 1)))
    }

    private func drain(state: AppState) async {
        let engine = state.engine
        var firstError: String?
        while !queue.isEmpty {
            let (job, project) = queue.removeFirst()
            let provider = engine.accounts.provider(for: job.account)
            do {
                let added = try engine.saveMailConversation(job.messages, account: job.account, projectSlug: project)
                state.bumpVault()
                for src in added {
                    guard let message = job.messages.first(where: {
                        MailImport.externalId(account: job.account, messageId: $0.summary.id) == src.externalId
                    }), let list = job.attachments[message.summary.id] else { continue }
                    let ids = Set(list.map(\.id).filter { job.confirmed.contains(message.summary.id + "|" + $0) })
                    do {
                        _ = try await engine.backfillSaveAttachments(list, confirmed: ids, of: message, emailSource: src,
                                                                     account: job.account, provider: provider)
                    } catch AttachmentError.notImplemented {
                        // The attachment step isn't wired for this account yet: the mail is saved, nothing to report.
                    } catch {
                        if firstError == nil { firstError = FriendlyError.message(error) }
                    }
                }
            } catch {
                if firstError == nil { firstError = FriendlyError.message(error) }
            }
            done += job.missing
            update()
        }
        state.bumpVault()
        lastError = firstError
        status = nil
        total = 0
        done = 0
        task = nil
    }
}
