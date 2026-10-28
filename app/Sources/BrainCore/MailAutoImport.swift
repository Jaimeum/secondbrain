import Foundation

// v0.4 "Agregar solos" (CONTRACT §14.5): new mail of the connected accounts that falls on a rule with `autoAddMail`
// is added by itself, one message at a time (never the whole conversation). The cycle lives here so `sb selftest` can
// run it against `DemoProvider`; the app's `MailAutoImporter` schedules it (every 15 min, on opening Correo) and
// posts one notification per cycle.
//
// v0.7 (CONTRACT §17.5): the same cycle follows every saved thread. Mail of a connected account whose provider thread
// id (`conversationId`/`threadId`) belongs to a saved thread joins it by itself — the owner's own replies (sent mail is
// listed too) and everyone else's — without a rule and without the rules' cap (safety cap 100 per cycle). Replies to
// mail that is not saved are left alone unless a rule takes them.

/// What one cycle did.
public struct MailAutoImportReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var projectSlug: String?   // nil = Sin asignar
        public var count: Int
    }
    /// Added messages per destination, in the order first seen (by rule).
    public var added: [Entry] = []
    /// Added by rule.
    public var sourceIds: [String] = []
    /// Accounts whose mail could not be read (expired session…): skipped in silence, Correo shows "Vuelve a conectar".
    public var failedAccounts: [String] = []
    /// The cap (or the fetch budget) stopped the cycle: the rest waits for the next one.
    public var reachedCap = false
    /// Nothing to do: the switch is off, there are no auto rules nor followed threads, or no mail accounts.
    public var idle = false

    // MARK: v0.7 replies (§17.5)
    /// Messages that joined a saved thread they continue (no rule), per thread in the order first seen.
    public struct ThreadEntry: Sendable, Equatable {
        public var threadKey: String
        public var subject: String
        public var projectSlug: String?
        /// Sent by the owner (their own replies).
        public var ownReplies = 0
        public var others = 0
        /// The newest message added (the notification opens its thread).
        public var lastSourceId: String
        public var count: Int { ownReplies + others }
    }
    public var followed: [ThreadEntry] = []
    public var followedSourceIds: [String] = []

    /// Everything added this cycle: by rule and by following saved threads.
    public var total: Int { sourceIds.count + followedSourceIds.count }

    public init() {}

    mutating func record(_ src: SourceRecord) {
        sourceIds.append(src.id)
        if let i = added.firstIndex(where: { $0.projectSlug == src.projectSlug }) {
            added[i].count += 1
        } else {
            added.append(Entry(projectSlug: src.projectSlug, count: 1))
        }
    }

    mutating func recordFollow(_ src: SourceRecord, subject: String, isFromOwner: Bool) {
        followedSourceIds.append(src.id)
        let key = src.threadKey ?? src.id
        let i: Int
        if let found = followed.firstIndex(where: { $0.threadKey == key }) {
            i = found
        } else {
            followed.append(ThreadEntry(threadKey: key, subject: subject, projectSlug: src.projectSlug, lastSourceId: src.id))
            i = followed.count - 1
        }
        if isFromOwner { followed[i].ownReplies += 1 } else { followed[i].others += 1 }
        followed[i].lastSourceId = src.id
        followed[i].projectSlug = src.projectSlug
    }
}

/// Saved threads whose provider thread id an older version didn't record were already asked about in this run of the
/// app (a message id another account of the same provider doesn't know is not asked again every cycle).
@MainActor private var threadFollowMigrationTried: Set<String> = []

public extension BrainEngine {
    /// Messages added per cycle at most; the rest go in the next one.
    nonisolated static let mailAutoImportCap = 20
    /// The first cycle (and a cursor that fell far behind) looks back at most this far.
    nonisolated static let mailAutoImportLookback: TimeInterval = 7 * 86_400
    /// v0.7 (§17.5): messages added to saved threads per cycle at most (a safety cap, not the rules' 20).
    nonisolated static let threadFollowCap = 100
    /// v0.7: saved threads of older versions (no provider thread id in `_thread.json`) learn it with one fetch each, at
    /// most this many per cycle.
    nonisolated static let threadFollowMigrationsPerCycle = 10

    /// One auto-add cycle. Per mail account: lists the mail since its cursor (`mailSyncCursors`; the first time at most
    /// 7 days back), sent mail included, oldest first; skips what is already in the brain (`externalId`). A message of a
    /// saved thread (its provider thread id, §17.5) joins that thread with no rule (`followCap` per cycle). Otherwise it
    /// is routed (the list row first, the full message when a rule may need it) and added when the deciding rule has
    /// `autoAddMail` and the message is not older than the oldest auto rule (`addMailMessages(…routeIfUnassigned:
    /// true)`: same precedence as by hand, the hit is counted). The cursor advances to the last message looked at. Never
    /// throws: an account that fails is skipped and reported. `accounts`/`provider` default to the connected ones
    /// (tests pass their own).
    @discardableResult
    func runMailAutoImport(now: Date = Date(), cap: Int = BrainEngine.mailAutoImportCap, maxFetches: Int = 60,
                           followCap: Int = BrainEngine.threadFollowCap,
                           accounts accountList: [ConnectedAccount]? = nil,
                           provider makeProvider: ((ConnectedAccount) -> MailCalendarProvider)? = nil) async -> MailAutoImportReport {
        var report = MailAutoImportReport()
        routing.refresh()   // a rule added by `sb rules add` or another Mac meanwhile counts too
        // A rule whose project was deleted adds nothing (its mail would land in the default project or Sin asignar).
        let autoRules = routing.autoAddRules.filter { $0.projectSlug == nil || validProject($0.projectSlug) != nil }
        let mailAccounts = (accountList ?? accounts.mailAccounts).filter { $0.provider.hasMail }
        // §17.5: a saved message of a connected account means there is a thread to follow.
        let follows = hasFollowableThreads
        guard routing.settings.autoImportEnabled, !autoRules.isEmpty || follows, !mailAccounts.isEmpty, cap > 0 || follows else {
            report.idle = true
            return report
        }
        let floor = now.addingTimeInterval(-Self.mailAutoImportLookback)
        // Rules never take mail older than the oldest auto rule; following a thread looks back the whole window.
        let ruleStart = max(autoRules.map(\.createdAt).min() ?? now, floor)
        let firstStart = follows ? floor : ruleStart
        // Rules on fields the list row doesn't carry (cc, body) need the full message to be judged.
        let rowBlind: Set<RuleField> = [.anyText, .recipient, .attendeeEmail, .attendeeDomain]
        let needsFull = routing.rules.contains { $0.enabled && $0.conditions.contains { rowBlind.contains($0.field) } }
        let owners = vault.ownerEmails()
        let savedThreads = follows ? vault.allThreads() : []
        var budget = autoRules.isEmpty ? 0 : cap
        var followBudget = followCap
        var fetches = 0
        var migrations = Self.threadFollowMigrationsPerCycle

        accountLoop: for account in mailAccounts {
            guard autoRules.isEmpty || budget > 0, followBudget > 0, fetches < maxFetches else {
                report.reachedCap = true
                break
            }
            let since = max(routing.settings.mailSyncCursors[account.id] ?? firstStart, floor)
            let provider = makeProvider?(account) ?? accounts.provider(for: account)
            var summaries: [MailMessageSummary] = []
            do {
                var token: String?
                var pages = 0
                repeat {
                    let page = try await provider.listMessages(since: since, pageToken: token)
                    summaries += page.messages
                    token = page.next
                    pages += 1
                } while token != nil && pages < 20
            } catch {
                if Task.isCancelled { return report }
                Log.error("auto-add: could not list \(account.id): \(error)")
                report.failedAccounts.append(account.id)
                continue
            }
            // MARK: v0.7 replies — provider thread id → saved thread (§17.4/§17.5).
            var followed = followIndex(savedThreads, account: account)
            if follows, migrations > 0 {
                for (threadId, key) in await migrateFollowIndex(savedThreads, account: account, provider: provider, limit: &migrations) {
                    followed[threadId] = key
                }
            }
            var seen = Set<String>()
            let fresh = summaries.filter { $0.date >= since && seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
            var cursor: Date?
            for summary in fresh {
                if Task.isCancelled { break accountLoop }
                // The rules' cap stops the account here (the cursor stays at the last message added); the rest, threads
                // included, waits for the next cycle.
                guard autoRules.isEmpty || budget > 0 else {
                    report.reachedCap = true
                    break
                }
                let externalId = MailImport.externalId(account: account, messageId: summary.id)
                if let stored = emailSource(externalId: externalId) {
                    // Saved by hand (or by an older version): its conversation is followed from now on.
                    if let key = stored.threadKey, followed[summary.threadId] == nil, !summary.threadId.isEmpty,
                       vault.threadInfo(key: key) != nil {
                        followed[summary.threadId] = key
                        linkThread(key, account: account, providerThreadId: summary.threadId)
                    }
                    cursor = summary.date
                    continue
                }
                // §17.5: the conversation is a saved thread → it joins it, no rule.
                if let key = followed[summary.threadId] {
                    guard followBudget > 0, fetches < maxFetches + followCap else {
                        report.reachedCap = true
                        break
                    }
                    fetches += 1
                    let full: MailMessageFull
                    do {
                        full = try await provider.fetchMessage(id: summary.id)
                    } catch {
                        if Task.isCancelled { break accountLoop }
                        Log.error("follow: could not read a message of \(account.id): \(error)")
                        report.failedAccounts.append(account.id)
                        break   // the cursor stays before it: retried next cycle
                    }
                    do {
                        let added = try addMailMessages([full], account: account, threadKey: key, projectSlug: nil, routeIfUnassigned: false)
                        let isFromOwner = MailImport.parsedEmail(full, account: account, ownerEmails: owners).isFromOwner
                        let subject = vault.threadInfo(key: key)?.subject ?? summary.subject
                        for src in added {
                            report.recordFollow(src, subject: subject, isFromOwner: isFromOwner)
                            await saveIncomingAttachments(full, source: src, account: account, provider: provider)
                        }
                        followBudget -= added.count
                        linkThread(key, account: account, providerThreadId: summary.threadId,
                                   owned: added.map { ($0.id, isFromOwner) })
                    } catch EngineError.emptyEmail, EngineError.duplicateEmail {
                        // Nothing to add, now or later.
                    } catch EngineError.threadNotFound {
                        followed[summary.threadId] = nil   // the thread was deleted meanwhile: not followed any more
                        Log.info("follow: thread \(key) is gone")
                    } catch {
                        Log.error("follow: could not add a message of \(account.id): \(error)")
                        break   // the cursor stays before it: retried next cycle
                    }
                    cursor = summary.date
                    continue
                }
                // Rules (§14.5): only mail not older than the oldest auto rule.
                guard !autoRules.isEmpty, summary.date >= ruleStart else {
                    cursor = summary.date
                    continue
                }
                let quick = routing.match(.mail(summary, ownerEmails: owners))
                if quick?.rule.autoAddMail != true, !needsFull {
                    cursor = summary.date
                    continue
                }
                guard fetches < maxFetches else {
                    report.reachedCap = true
                    break
                }
                fetches += 1
                let full: MailMessageFull
                do {
                    full = try await provider.fetchMessage(id: summary.id)
                } catch {
                    if Task.isCancelled { break accountLoop }
                    Log.error("auto-add: could not read a message of \(account.id): \(error)")
                    report.failedAccounts.append(account.id)
                    break   // the cursor stays before it: retried next cycle
                }
                let parsed = MailImport.parsedEmail(full, account: account, ownerEmails: owners, language: config.uiLanguage)
                guard let decision = routing.match(.mail(parsed, ownerEmails: owners)), decision.rule.autoAddMail, decides(decision) else {
                    cursor = summary.date
                    continue
                }
                // A conversation already in the brain is continued (and keeps its project, §14.2 step 2). Its earlier
                // messages may predate the window: ask for the conversation (best effort).
                var conversation = summaries.filter { $0.threadId == summary.threadId && $0.id != summary.id }.map(\.id)
                if fetches < maxFetches, let thread = try? await provider.fetchThread(id: summary.threadId) {
                    fetches += 1
                    conversation += thread.map(\.summary.id).filter { $0 != summary.id }
                }
                let threadKey = conversation.lazy
                    .compactMap { self.emailSource(externalId: MailImport.externalId(account: account, messageId: $0))?.threadKey }
                    .first
                do {
                    let added = try addMailMessages([full], account: account, threadKey: threadKey, projectSlug: nil, routeIfUnassigned: true)
                    for src in added {
                        report.record(src)
                        await saveIncomingAttachments(full, source: src, account: account, provider: provider)
                        // §17.5: the thread is saved now, so the rest of its conversation follows it.
                        if let key = src.threadKey, !summary.threadId.isEmpty {
                            followed[summary.threadId] = key
                            linkThread(key, account: account, providerThreadId: summary.threadId,
                                       owned: [(src.id, parsed.isFromOwner)])
                        }
                    }
                    budget -= added.count
                    if !added.isEmpty { await saveNewAttachments(for: [full], account: account, provider: provider) }   // v0.7 §17.1
                } catch EngineError.emptyEmail, EngineError.duplicateEmail {
                    // Nothing to add, now or later.
                } catch {
                    Log.error("auto-add: could not add a message of \(account.id): \(error)")
                    break   // the cursor stays before it: retried next cycle
                }
                cursor = summary.date
            }
            if let cursor, cursor > (routing.settings.mailSyncCursors[account.id] ?? .distantPast) {
                do { try routing.setMailSyncCursor(cursor, for: account.id) } catch { Log.error("auto-add: cursor not saved: \(error)") }
            }
        }
        if report.total > 0 {
            Log.info("auto-add: \(report.sourceIds.count) message(s) by rule, \(report.followedSourceIds.count) in followed threads")
        }
        return report
    }
}

// MARK: - v0.7 replies: following saved threads (§17.5)

extension BrainEngine {
    /// A message of a connected account is in the brain with its thread: there is something to follow.
    public var hasFollowableThreads: Bool {
        sources.contains { $0.kind == .email && $0.externalId != nil && $0.threadKey != nil }
    }

    /// Provider thread id → saved thread key, for `account`, from `_thread.json` (`providerThreadIds`).
    func followIndex(_ threads: [ThreadInfo], account: ConnectedAccount) -> [String: String] {
        var out: [String: String] = [:]
        for thread in threads {
            guard let id = thread.providerThreadIds[account.id], !id.isEmpty, out[id] == nil else { continue }
            out[id] = thread.key
        }
        return out
    }

    /// Saved threads of an older version know their messages (`externalId`) but not the provider's thread id: ask the
    /// provider for their newest message of this provider, once per thread and run of the app, `limit` per cycle; the
    /// id found is written to `_thread.json`. Threads that already have an id for any account are left alone.
    func migrateFollowIndex(_ threads: [ThreadInfo], account: ConnectedAccount, provider: MailCalendarProvider,
                            limit: inout Int) async -> [String: String] {
        let prefix = account.provider.rawValue + ":"
        var out: [String: String] = [:]
        for thread in threads where thread.providerThreadIds.isEmpty && limit > 0 {
            guard let message = thread.messages.last(where: { $0.externalId?.hasPrefix(prefix) == true }),
                  let externalId = message.externalId else { continue }
            let tried = "\(vault.root.path)|\(account.id)|\(thread.key)"
            guard threadFollowMigrationTried.insert(tried).inserted else { continue }
            limit -= 1
            guard let full = try? await provider.fetchMessage(id: String(externalId.dropFirst(prefix.count))) else { continue }
            let threadId = full.summary.threadId
            guard !threadId.isEmpty else { continue }
            out[threadId] = thread.key
            linkThread(thread.key, account: account, providerThreadId: threadId)
        }
        return out
    }

    /// Records in `_thread.json` that the account's provider thread `providerThreadId` is this thread (§17.4), and marks
    /// the messages just added (`owned`: source id → sent by the owner) so the conversation shows "Tú". Idempotent;
    /// never fails the cycle.
    func linkThread(_ key: String, account: ConnectedAccount, providerThreadId: String, owned: [(String, Bool)] = []) {
        guard !providerThreadId.isEmpty,
              let folder = vault.threadFolders().first(where: { ($0 as NSString).lastPathComponent == key }) else { return }
        let dir = vault.url(for: folder)
        guard var meta = ThreadMeta.load(from: dir) else { return }
        var changed = false
        if meta.providerThreadIds?[account.id] != providerThreadId {
            var ids = meta.providerThreadIds ?? [:]
            ids[account.id] = providerThreadId
            meta.providerThreadIds = ids
            changed = true
        }
        for (sourceId, isFromOwner) in owned {
            guard let i = meta.messages.firstIndex(where: { $0.sourceId == sourceId }), meta.messages[i].isFromOwner != isFromOwner else { continue }
            meta.messages[i].isFromOwner = isFromOwner
            changed = true
        }
        guard changed else { return }
        do { try meta.save(to: dir) } catch { Log.error("follow: _thread.json of \(key) not saved: \(error)") }
    }

    /// §17.1 forward: the attachments of a message the cycle just added (by rule or by following its thread).
    // v0.7 integration: the attach area's automatic save (triage → keep / Claude for the ambiguous / Descartados) plugs
    // in here. Until then this only asks the provider for the list (the v0.7 stubs throw `.notImplemented`).
    func saveIncomingAttachments(_ message: MailMessageFull, source: SourceRecord, account: ConnectedAccount,
                                 provider: MailCalendarProvider) async {
        guard message.summary.hasAttachments else { return }
        do {
            let list = try await provider.listAttachments(messageId: message.summary.id)
            if !list.isEmpty { Log.info("follow: \(list.count) attachment(s) on \(source.id), not saved yet") }
        } catch AttachmentError.notImplemented {
            // Attachments not available yet.
        } catch {
            Log.error("follow: attachments of \(source.id) not listed: \(error)")
        }
    }
}
