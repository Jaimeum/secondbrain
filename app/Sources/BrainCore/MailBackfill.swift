import Foundation

// v0.7 (CONTRACT §17.6): mail saved backwards, by hand. "Correo › selección múltiple" saves the whole conversations of
// the checked messages; "Traer anteriores" finds what a mail rule would have caught in the last 90 days. Both go
// through a confirmation sheet whose attachment checkboxes start from `AttachmentTriage` (no Claude backwards).
// Read-only on the mailbox like the rest: only list/search/fetch calls.

public enum MailBackfill {
    /// How far back "Traer anteriores" looks.
    public static let days = 90
    /// At most this many matching messages.
    public static let maxMessages = 200
    /// Pages read per search (a page is 25–50 messages on Graph/Gmail).
    public static let maxPages = 20

    /// A rule that can catch mail: anything but the meeting-only "organiza" field.
    public static func isMailRule(_ rule: RoutingRule) -> Bool {
        !rule.conditions.isEmpty && !rule.conditions.contains { $0.field == .organizerEmail }
    }

    /// The words to ask the provider for, so the mailbox search narrows down before the rule decides: the value of
    /// the first condition that has one ("@acme.com" → "acme.com"). nil = no usable value (the window is listed instead).
    public static func searchHint(for rule: RoutingRule) -> String? {
        for c in rule.conditions where c.field != .organizerEmail {
            var v = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if c.field == .senderDomain || c.field == .attendeeDomain {
                while v.hasPrefix("@") || v.hasPrefix("*") || v.hasPrefix(".") { v.removeFirst() }
            }
            v = v.replacingOccurrences(of: "\"", with: " ").trimmingCharacters(in: .whitespaces)
            if v.count >= 2 { return v }
        }
        return nil
    }

    /// Whether `rule` would have decided `message`: it matches, and no enabled rule above it in `rules` wins first.
    public static func wouldCatch(_ rule: RoutingRule, _ message: MailMessageSummary, rules: [RoutingRule],
                                  ownerEmails: [String]) -> Bool {
        let subject = RoutingSubject.mail(message, ownerEmails: ownerEmails)
        guard RuleMatcher.matches(rule, subject) else { return false }
        guard let winner = RuleMatcher.firstMatch(rules, subject) else { return true }
        return winner.id == rule.id
    }

    /// The messages of the last `days` that `rule` would have caught, newest first, at most `limit`. Searches the
    /// mailbox with `searchHint` (Gmail adds `newer_than:`), else — or when the search fails — lists the window.
    public static func findMatches(rule: RoutingRule, rules: [RoutingRule], provider: MailCalendarProvider,
                                   ownerEmails: [String], now: Date = Date(), days: Int = MailBackfill.days,
                                   limit: Int = MailBackfill.maxMessages,
                                   maxPages: Int = MailBackfill.maxPages) async throws -> [MailMessageSummary] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var found: [MailMessageSummary] = []
        var seen = Set<String>()

        func take(_ page: [MailMessageSummary]) -> Bool {   // true = the page was entirely older than the window
            var allOld = !page.isEmpty
            for m in page where !seen.contains(m.id) {
                seen.insert(m.id)
                guard m.date >= since else { continue }
                allOld = false
                if found.count < limit, wouldCatch(rule, m, rules: rules, ownerEmails: ownerEmails) { found.append(m) }
            }
            return allOld
        }

        if let hint = searchHint(for: rule) {
            let query = provider.account.provider == .google ? "\(hint) newer_than:\(days)d" : hint
            do {
                var token: String?
                for _ in 0..<maxPages {
                    try Task.checkCancellation()
                    let page = try await provider.searchMessages(query, pageToken: token)
                    let old = take(page.messages)
                    token = page.next
                    if token == nil || found.count >= limit || old { break }
                }
                return sorted(found)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The search isn't available (or failed): list the window instead.
                found.removeAll()
                seen.removeAll()
            }
        }
        var token: String?
        for _ in 0..<maxPages {
            try Task.checkCancellation()
            let page = try await provider.listMessages(since: since, pageToken: token)
            _ = take(page.messages)
            token = page.next
            if token == nil || found.count >= limit { break }
        }
        return sorted(found)
    }

    private static func sorted(_ list: [MailMessageSummary]) -> [MailMessageSummary] {
        list.sorted { $0.date > $1.date }
    }

    /// The conversations of `messages`, newest first (each once).
    public static func threadIds(_ messages: [MailMessageSummary]) -> [String] {
        var seen = Set<String>()
        return messages.sorted { $0.date > $1.date }.compactMap { seen.insert($0.threadId).inserted ? $0.threadId : nil }
    }

    /// The attachment checkboxes' first state (§17.1 backwards: keep ✓, ambiguous ✓, discard ☐, too big ☐), never
    /// ticking what is not a file. Keyed by attachment id.
    public static func preselection(_ list: [AttachmentInfo], message: MailMessageFull,
                                    savedHashes: Set<String> = []) -> [(info: AttachmentInfo, decision: AttachmentDecision, checked: Bool)] {
        let cids = message.inlineContentIds.map { Set($0.map { $0.lowercased() }) }
        let context = AttachmentTriage.Context(inlineContentIds: cids, savedHashes: savedHashes)
        return list.map { info in
            let decision = AttachmentTriage.classify(info, context: context)
            return (info, decision, info.isDownloadable && decision.preselected)
        }
    }
}

// MARK: - Engine

extension BrainEngine {
    /// Where a provider conversation already lives in the brain (one of its messages is stored): its thread and project.
    public func storedThread(of messages: [MailMessageFull], account: ConnectedAccount) -> (key: String, projectSlug: String?)? {
        for m in messages {
            if let src = emailSource(externalId: MailImport.externalId(account: account, messageId: m.summary.id)),
               let key = src.threadKey {
                return (key, src.projectSlug)
            }
        }
        return nil
    }

    /// Messages of a conversation not in the brain yet.
    public func unsavedMessages(_ messages: [MailMessageFull], account: ConnectedAccount) -> [MailMessageFull] {
        messages.filter { emailSource(externalId: MailImport.externalId(account: account, messageId: $0.summary.id)) == nil }
    }

    /// §17.6: saves what is missing of one conversation, like Correo's smart button: a conversation that already lives
    /// in a project stays there (the rest joins its thread); one in Sin asignar moves with it to `projectSlug`. No rule
    /// is applied on top (the user chose the destination). Returns the sources created, oldest first.
    @discardableResult
    public func saveMailConversation(_ messages: [MailMessageFull], account: ConnectedAccount,
                                     projectSlug: String?) throws -> [SourceRecord] {
        let missing = unsavedMessages(messages, account: account)
        guard !missing.isEmpty else { return [] }
        var project = projectSlug
        var threadKey: String?
        if let stored = storedThread(of: messages, account: account) {
            if let p = stored.projectSlug { project = p }
            if stored.projectSlug == nil || stored.projectSlug == project { threadKey = stored.key }
        }
        return try addMailMessages(missing, account: account, threadKey: threadKey, projectSlug: project, routeIfUnassigned: false)
    }

    /// v0.7 integration point (backfill → attach): saves the attachments the user left ticked in the backwards sheet
    /// (`confirmed`, attachment ids) of `message`, stored as `emailSource`; the unticked ones are the user's discards.
    /// Returns how many were saved.
    // v0.7: filled in by attach — forward to its `saveAttachments(…, .confirmed(ids))`. Until then nothing is saved.
    public func backfillSaveAttachments(_ attachments: [AttachmentInfo], confirmed: Set<String>, of message: MailMessageFull,
                                        emailSource: SourceRecord, account: ConnectedAccount,
                                        provider: MailCalendarProvider) async throws -> Int {
        guard attachments.contains(where: { confirmed.contains($0.id) }) else { return 0 }
        throw AttachmentError.notImplemented
    }
}
