import Foundation

// v0.7 (CONTRACT §17.7): "Abrir en Outlook/Gmail/Google Calendar/Outlook Calendar". Every email of a connected account
// keeps its provider link (`web_link:` in the raw email, `webLink` per message in `_thread.json`); a recorded meeting
// tied to a calendar event keeps the event's (`SourceRecord.webLink`). Mail saved before v0.7 gets its link lazily, when
// its thread is opened (`BrainEngine.fillMissingWebLinks`). Pasted mail has none.

public enum OriginalLinks {
    /// Gmail has no per-message web link in its API: the conversation in the account's mailbox.
    /// `https://mail.google.com/mail/u/<email>/#all/<threadId>` (`u/0` when the account is unknown).
    public static func gmailThread(accountEmail: String?, threadId: String) -> String {
        let user = accountEmail?.trimmingCharacters(in: .whitespaces).lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed).flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        let id = threadId.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? threadId
        return "https://mail.google.com/mail/u/\(user)/#all/\(id)"
    }

    /// `"microsoft:AAMk…"` → (.microsoft, "AAMk…"). nil for anything else.
    public static func split(externalId: String?) -> (provider: AccountProvider, messageId: String)? {
        guard let externalId, let colon = externalId.firstIndex(of: ":") else { return nil }
        guard let provider = AccountProvider(rawValue: String(externalId[..<colon])), provider.hasMail else { return nil }
        let id = String(externalId[externalId.index(after: colon)...])
        return id.isEmpty ? nil : (provider, id)
    }

    /// The provider of an account id (`"google:ana@x.com"`, `"local:calendar"`).
    public static func provider(ofAccountId id: String?) -> AccountProvider? {
        guard let id, let colon = id.firstIndex(of: ":") else { return nil }
        return AccountProvider(rawValue: String(id[..<colon]))
    }

    /// The provider whose web app a link opens (by host), for links stored without their account.
    public static func provider(forLink link: String?) -> AccountProvider? {
        guard let host = link.flatMap(URL.init(string:))?.host?.lowercased() else { return nil }
        if host.hasSuffix("google.com") { return .google }
        if host.contains("outlook") || host.hasSuffix("office.com") || host.hasSuffix("office365.com")
            || host.hasSuffix("live.com") || host.hasSuffix("microsoft.com") { return .microsoft }
        return nil
    }

    /// Only http(s) links are opened.
    public static func isOpenable(_ link: String?) -> Bool {
        guard let scheme = link.flatMap(URL.init(string:))?.scheme?.lowercased() else { return false }
        return scheme == "https" || scheme == "http"
    }

    /// A stored email's link and provider: its `webLink`, else (Gmail) the conversation URL built from the thread's
    /// provider id (or the message id). nil for pasted mail and for Outlook mail whose link isn't known yet.
    public static func link(for message: ThreadInfo.Message, in thread: ThreadInfo) -> (link: String, provider: AccountProvider)? {
        guard let ext = split(externalId: message.externalId) else { return nil }
        if let web = message.webLink, isOpenable(web) { return (web, ext.provider) }
        guard ext.provider == .google else { return nil }
        let account = thread.providerThreadIds.first { provider(ofAccountId: $0.key) == .google }
        let email = account.map { String($0.key.drop { $0 != ":" }.dropFirst()) }
        return (gmailThread(accountEmail: email, threadId: account?.value ?? ext.messageId), .google)
    }

    /// The newest message of the thread that has a link ("Abrir en …" in the thread's header).
    public static func latestLink(in thread: ThreadInfo) -> (link: String, provider: AccountProvider)? {
        for m in thread.messages.reversed() { if let l = link(for: m, in: thread) { return l } }
        return nil
    }

    /// A calendar event's link and provider (nil for the Mac calendar, which has no web app).
    public static func link(for event: CalendarEvent) -> (link: String, provider: AccountProvider)? {
        guard let web = event.webLink, isOpenable(web) else { return nil }
        guard let provider = provider(ofAccountId: event.accountId) ?? provider(forLink: web), provider != .local else { return nil }
        return (web, provider)
    }
}

// MARK: - Graph: just the link

extension MicrosoftGraphProvider {
    /// `GET /me/messages/{id}?$select=webLink` (the lazy migration of §17.7: one small call per message).
    public func webLink(messageId: String) async throws -> String? {
        struct Item: Decodable { var webLink: String? }
        let url = HTTP.url(Self.base + "/me/messages/" + Self.pathSegment(messageId), query: [("$select", "webLink")])
        return try JSONDecoder().decode(Item.self, from: try await api.get(url)).webLink
    }
}

// MARK: - Lazy migration

public extension VaultStore {
    /// Stores `links` (email file name → web link) in the thread's `_thread.json`; only messages without one change.
    /// Returns how many changed.
    @discardableResult
    func setWebLinks(_ links: [String: String], threadKey: String) throws -> Int {
        guard !links.isEmpty,
              let folder = threadFolders().first(where: { ($0 as NSString).lastPathComponent == threadKey }),
              var meta = threadMeta(at: folder) else { return 0 }
        var changed = 0
        for i in meta.messages.indices where meta.messages[i].webLink == nil {
            if let link = links[meta.messages[i].file], OriginalLinks.isOpenable(link) {
                meta.messages[i].webLink = link
                changed += 1
            }
        }
        if changed > 0 { try meta.save(to: url(for: folder)) }
        return changed
    }
}

public extension BrainEngine {
    /// Messages of `threadKey` that came from a connected account (`externalId`) but have no `webLink` get one, saved in
    /// `_thread.json`: Outlook asks Graph (one call per message), Gmail builds the conversation URL, other providers
    /// (the demo) read the message. Accounts no longer connected are skipped. Returns how many links were added.
    @discardableResult
    func fillMissingWebLinks(threadKey: String, accounts: [ConnectedAccount],
                             provider: (ConnectedAccount) -> MailCalendarProvider) async -> Int {
        guard let thread = vault.threadInfo(key: threadKey) else { return 0 }
        let missing = thread.messages.filter { $0.webLink == nil && OriginalLinks.split(externalId: $0.externalId) != nil }
        guard !missing.isEmpty else { return 0 }
        let participants = Set(thread.participants.compactMap { $0.email?.lowercased() })
        func account(for p: AccountProvider) -> ConnectedAccount? {
            let list = accounts.filter { $0.provider == p }
            if let byThread = list.first(where: { thread.providerThreadIds[$0.id] != nil }) { return byThread }
            return list.first { participants.contains($0.email) } ?? list.first
        }
        var links: [String: String] = [:]
        for m in missing {
            guard let ext = OriginalLinks.split(externalId: m.externalId) else { continue }
            let acc = account(for: ext.provider)
            if ext.provider == .google {
                let threadId = acc.flatMap { thread.providerThreadIds[$0.id] } ?? ext.messageId
                links[m.file] = OriginalLinks.gmailThread(accountEmail: acc?.email, threadId: threadId)
                continue
            }
            guard let acc else { continue }
            let p = provider(acc)
            do {
                let link: String?
                if let graph = p as? MicrosoftGraphProvider {
                    link = try await graph.webLink(messageId: ext.messageId)
                } else {
                    link = try await p.fetchMessage(id: ext.messageId).summary.webLink
                }
                if let link { links[m.file] = link }
            } catch {
                Log.info("webLink of \(m.file) in \(threadKey) not available: \(error)")
            }
        }
        do { return try vault.setWebLinks(links, threadKey: threadKey) } catch {
            Log.error("webLink: could not save _thread.json of \(threadKey): \(error)")
            return 0
        }
    }

    /// Same, with the connected accounts. Once per thread per session (opening it again doesn't call again).
    @discardableResult
    func fillMissingWebLinks(threadKey: String) async -> Int {
        guard !WebLinkFill.tried.contains(threadKey) else { return 0 }
        WebLinkFill.tried.insert(threadKey)
        let store = accounts
        return await fillMissingWebLinks(threadKey: threadKey, accounts: store.accounts.filter(\.provider.hasMail)) {
            store.provider(for: $0)
        }
    }
}

@MainActor enum WebLinkFill {
    static var tried: Set<String> = []
}
