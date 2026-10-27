import Foundation

// v0.4 "Agregar solos" (CONTRACT §14.5): new mail of the connected accounts that falls on a rule with `autoAddMail`
// is added by itself, one message at a time (never the whole conversation). The cycle lives here so `sb selftest` can
// run it against `DemoProvider`; the app's `MailAutoImporter` schedules it (every 15 min, on opening Correo) and
// posts one notification per cycle.

/// What one cycle did.
public struct MailAutoImportReport: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var projectSlug: String?   // nil = Sin asignar
        public var count: Int
    }
    /// Added messages per destination, in the order first seen.
    public var added: [Entry] = []
    public var sourceIds: [String] = []
    /// Accounts whose mail could not be read (expired session…): skipped in silence, Correo shows "Vuelve a conectar".
    public var failedAccounts: [String] = []
    /// The cap (or the fetch budget) stopped the cycle: the rest waits for the next one.
    public var reachedCap = false
    /// Nothing to do: the switch is off, there are no auto rules or no mail accounts.
    public var idle = false

    public var total: Int { sourceIds.count }

    public init() {}

    mutating func record(_ src: SourceRecord) {
        sourceIds.append(src.id)
        if let i = added.firstIndex(where: { $0.projectSlug == src.projectSlug }) {
            added[i].count += 1
        } else {
            added.append(Entry(projectSlug: src.projectSlug, count: 1))
        }
    }
}

public extension BrainEngine {
    /// Messages added per cycle at most; the rest go in the next one.
    nonisolated static let mailAutoImportCap = 20
    /// The first cycle (and a cursor that fell far behind) looks back at most this far.
    nonisolated static let mailAutoImportLookback: TimeInterval = 7 * 86_400

    /// One auto-add cycle. Per mail account: lists the mail since its cursor (`mailSyncCursors`; the first time since
    /// the oldest auto rule was created, at most 7 days back), oldest first; skips what is already in the brain
    /// (`externalId`); routes each message (the list row first, the full message when a rule may need it) and adds the
    /// ones whose deciding rule has `autoAddMail` (`addMailMessages(…routeIfUnassigned: true)`: same precedence as by
    /// hand, the hit is counted). The cursor advances to the last message looked at. Never throws: an account that fails
    /// is skipped and reported. `accounts`/`provider` default to the connected ones (tests pass their own).
    @discardableResult
    func runMailAutoImport(now: Date = Date(), cap: Int = BrainEngine.mailAutoImportCap, maxFetches: Int = 60,
                           accounts accountList: [ConnectedAccount]? = nil,
                           provider makeProvider: ((ConnectedAccount) -> MailCalendarProvider)? = nil) async -> MailAutoImportReport {
        var report = MailAutoImportReport()
        let autoRules = routing.autoAddRules
        let mailAccounts = (accountList ?? accounts.mailAccounts).filter { $0.provider.hasMail }
        guard routing.settings.autoImportEnabled, !autoRules.isEmpty, !mailAccounts.isEmpty, cap > 0 else {
            report.idle = true
            return report
        }
        let floor = now.addingTimeInterval(-Self.mailAutoImportLookback)
        let firstStart = max(autoRules.map(\.createdAt).min() ?? now, floor)
        // Rules on fields the list row doesn't carry (cc, body) need the full message to be judged.
        let rowBlind: Set<RuleField> = [.anyText, .recipient, .attendeeEmail, .attendeeDomain]
        let needsFull = routing.rules.contains { $0.enabled && $0.conditions.contains { rowBlind.contains($0.field) } }
        let owners = vault.ownerEmails()
        var budget = cap
        var fetches = 0

        accountLoop: for account in mailAccounts {
            guard budget > 0, fetches < maxFetches else {
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
            var seen = Set<String>()
            let fresh = summaries.filter { $0.date >= since && seen.insert($0.id).inserted }.sorted { $0.date < $1.date }
            var cursor: Date?
            for summary in fresh {
                if Task.isCancelled { break accountLoop }
                guard budget > 0 else {
                    report.reachedCap = true
                    break
                }
                let externalId = MailImport.externalId(account: account, messageId: summary.id)
                if emailSource(externalId: externalId) != nil {
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
                guard let decision = routing.match(.mail(parsed, ownerEmails: owners)), decision.rule.autoAddMail else {
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
                    for src in added { report.record(src) }
                    budget -= added.count
                } catch {
                    Log.error("auto-add: could not add a message of \(account.id): \(error)")
                }
                cursor = summary.date
            }
            if let cursor, cursor > (routing.settings.mailSyncCursors[account.id] ?? .distantPast) {
                do { try routing.setMailSyncCursor(cursor, for: account.id) } catch { Log.error("auto-add: cursor not saved: \(error)") }
            }
        }
        if report.total > 0 { Log.info("auto-add: \(report.total) message(s) added") }
        return report
    }
}
