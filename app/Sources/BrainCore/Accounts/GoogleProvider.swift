import Foundation

/// Gmail + Google Calendar, read-only (CONTRACT §12.3).
public final class GoogleProvider: MailCalendarProvider {
    public let account: ConnectedAccount
    let api: APIClient

    public static let gmail = "https://gmail.googleapis.com/gmail/v1/users/me"
    public static let calendar = "https://www.googleapis.com/calendar/v3/calendars/primary"
    public static let userinfo = "https://www.googleapis.com/oauth2/v3/userinfo"
    static let pageSize = 25
    /// Parallel `messages.get` calls when listing (Gmail's list only returns ids).
    static let parallelFetches = 8

    public init(account: ConnectedAccount, api: APIClient) {
        self.account = account
        self.api = api
    }

    public func profile() async throws -> ConnectedAccount {
        try GmailParser.profile(try await api.get(URL(string: Self.userinfo)!), scopes: AccountProvider.google.scopes)
    }

    public func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        try await list(query: Self.recentQuery(since: since), pageToken: pageToken)
    }

    public func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await list(query: q.isEmpty ? Self.recentQuery(since: Date().addingTimeInterval(-30 * 86_400)) : q,
                              pageToken: pageToken)
    }

    public func fetchMessage(id: String) async throws -> MailMessageFull {
        let url = HTTP.url(Self.gmail + "/messages/" + MicrosoftGraphProvider.pathSegment(id), query: [("format", "full")])
        return try await GmailParser.message(try await api.get(url), account: account)
    }

    public func fetchThread(id: String) async throws -> [MailMessageFull] {
        let url = HTTP.url(Self.gmail + "/threads/" + MicrosoftGraphProvider.pathSegment(id), query: [("format", "full")])
        return try await GmailParser.thread(try await api.get(url), account: account)
    }

    // MARK: v0.7 attachments (§17.1) — v0.7: filled in by attach. Gmail parts with `filename`/`attachmentId` → `users/me/messages/{id}/attachments/{aid}`.
    public func listAttachments(messageId: String) async throws -> [AttachmentInfo] {
        throw AttachmentError.notImplemented
    }

    public func downloadAttachment(messageId: String, id: String) async throws -> Data {
        throw AttachmentError.notImplemented
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var all: [CalendarEvent] = []
        var token: String?
        var pages = 0
        repeat {
            let page = try GoogleCalendarParser.events(try await api.get(Self.eventsURL(from: from, to: to, pageToken: token)),
                                                       accountId: account.id)
            all += page.events
            token = page.next
            pages += 1
        } while token != nil && pages < 5
        return all.sorted { $0.start < $1.start }
    }

    // MARK: Listing

    private func list(query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        let ids = try GmailParser.idList(try await api.get(Self.listURL(query: query, pageToken: pageToken)))
        let api = self.api
        let account = self.account
        var summaries: [Int: MailMessageSummary] = [:]
        try await withThrowingTaskGroup(of: (Int, MailMessageSummary?).self) { group in
            var nextIndex = 0
            func addNext() {
                guard nextIndex < ids.ids.count else { return }
                let i = nextIndex
                let id = ids.ids[i]
                nextIndex += 1
                group.addTask {
                    let data = try await api.get(Self.metadataURL(id: id))
                    return (i, try? GmailParser.visibleSummary(data, account: account))
                }
            }
            for _ in 0..<Self.parallelFetches { addNext() }
            while let (i, summary) = try await group.next() {
                if let summary { summaries[i] = summary }
                addNext()
            }
        }
        let ordered = ids.ids.indices.compactMap { summaries[$0] }
        return (ordered, ids.next)
    }

    // MARK: URLs (public for the self-tests)

    /// "newer_than:30d" for `since` 30 days ago (rounded up to whole days).
    public static func recentQuery(since: Date, now: Date = Date()) -> String {
        let days = max(1, Int((now.timeIntervalSince(since) / 86_400).rounded(.up)))
        return "newer_than:\(days)d"
    }

    public static func listURL(query: String, pageToken: String?) -> URL {
        var q: [(String, String)] = [("q", query), ("maxResults", String(pageSize))]
        if let pageToken, !pageToken.isEmpty { q.append(("pageToken", pageToken)) }
        return HTTP.url(gmail + "/messages", query: q)
    }

    public static func metadataURL(id: String) -> URL {
        HTTP.url(gmail + "/messages/" + MicrosoftGraphProvider.pathSegment(id), query: [
            ("format", "metadata"),
            ("metadataHeaders", "From"), ("metadataHeaders", "To"), ("metadataHeaders", "Subject"), ("metadataHeaders", "Date"),
        ])
    }

    public static func eventsURL(from: Date, to: Date, pageToken: String? = nil) -> URL {
        var q: [(String, String)] = [
            ("timeMin", MicrosoftGraphProvider.iso(from)),
            ("timeMax", MicrosoftGraphProvider.iso(to)),
            ("singleEvents", "true"),
            ("orderBy", "startTime"),
            ("maxResults", "250"),
        ]
        if let pageToken, !pageToken.isEmpty { q.append(("pageToken", pageToken)) }
        return HTTP.url(calendar + "/events", query: q)
    }
}

/// Gmail JSON → shared types.
public enum GmailParser {
    struct Header: Decodable { var name: String; var value: String }
    struct Body: Decodable { var size: Int?; var data: String?; var attachmentId: String? }
    final class Part: Decodable {
        var mimeType: String?
        var filename: String?
        var headers: [Header]?
        var body: Body?
        var parts: [Part]?
    }
    struct Message: Decodable {
        var id: String
        var threadId: String?
        var labelIds: [String]?
        var snippet: String?
        var internalDate: String?
        var payload: Part?
    }
    struct Thread: Decodable { var id: String; var messages: [Message]? }
    struct IdList: Decodable {
        struct Ref: Decodable { var id: String; var threadId: String? }
        var messages: [Ref]?
        var nextPageToken: String?
    }
    struct UserInfo: Decodable { var email: String?; var name: String? }

    public static func profile(_ data: Data, scopes: [String]) throws -> ConnectedAccount {
        let info = try decodeJSON(UserInfo.self, data, provider: .google)
        guard let email = info.email?.nonEmptyString else { throw AccountError.failed("Google didn't return an email address") }
        return ConnectedAccount(provider: .google, email: email, displayName: info.name?.nonEmptyString, scopes: scopes)
    }

    public static func idList(_ data: Data) throws -> (ids: [String], next: String?) {
        let list = try decodeJSON(IdList.self, data, provider: .google)
        return ((list.messages ?? []).map(\.id), list.nextPageToken)
    }

    /// Drafts (never sent), trash and spam: not part of the inbox nor of a conversation to learn from.
    static let hiddenLabels: Set<String> = ["DRAFT", "TRASH", "SPAM"]

    static func isHidden(_ m: Message) -> Bool { !hiddenLabels.isDisjoint(with: m.labelIds ?? []) }

    /// `messages.get` → summary, nil for a draft / trash / spam message.
    public static func visibleSummary(_ data: Data, account: ConnectedAccount) throws -> MailMessageSummary? {
        let m = try decodeJSON(Message.self, data, provider: .google)
        return isHidden(m) ? nil : summary(m, account: account)
    }

    /// `messages.get` (metadata or full) → summary.
    public static func summary(_ data: Data, account: ConnectedAccount) throws -> MailMessageSummary {
        summary(try decodeJSON(Message.self, data, provider: .google), account: account)
    }

    public static func message(_ data: Data, account: ConnectedAccount) async throws -> MailMessageFull {
        try await full(decodeJSON(Message.self, data, provider: .google), account: account)
    }

    /// `threads.get` → messages oldest first (drafts, trash and spam left out).
    public static func thread(_ data: Data, account: ConnectedAccount) async throws -> [MailMessageFull] {
        let thread = try decodeJSON(Thread.self, data, provider: .google)
        var out: [MailMessageFull] = []
        for m in thread.messages ?? [] where !isHidden(m) { out.append(try await full(m, account: account)) }
        return out.sorted { $0.summary.date < $1.summary.date }
    }

    // MARK: Mapping

    static func header(_ m: Message, _ name: String) -> String? {
        m.payload?.headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    static func summary(_ m: Message, account: ConnectedAccount) -> MailMessageSummary {
        let date = m.internalDate.flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
            ?? header(m, "Date").flatMap { EmailParser.parseDate($0) } ?? Date(timeIntervalSince1970: 0)
        let from = header(m, "From").flatMap { EmailParser.parseAddresses($0).first } ?? EmailAddress(name: nil, email: nil)
        let labels = Set(m.labelIds ?? [])
        let thread = m.threadId ?? m.id
        let link = "https://mail.google.com/mail/?authuser=\(HTTP.encodeForm(account.email))#all/\(thread)"
        return MailMessageSummary(
            id: m.id, threadId: thread, from: from,
            to: header(m, "To").map(EmailParser.parseAddresses) ?? [],
            subject: header(m, "Subject").map(decodeMIMEWords) ?? "",
            snippet: HTTP.decodeEntities(m.snippet ?? ""),
            date: date, isRead: !labels.contains("UNREAD"),
            hasAttachments: hasAttachments(m.payload), webLink: link)
    }

    static func full(_ m: Message, account: ConnectedAccount) async throws -> MailMessageFull {
        var text = ""
        if let plain = firstPart(m.payload, mime: "text/plain"), let decoded = decode(plain) {
            text = decoded
        } else if let html = firstPart(m.payload, mime: "text/html"), let decoded = decode(html) {
            text = await MainActor.run { Importer.htmlToText(decoded) }
        } else {
            text = HTTP.decodeEntities(m.snippet ?? "")
        }
        return MailMessageFull(summary: summary(m, account: account),
                               cc: header(m, "Cc").map(EmailParser.parseAddresses) ?? [],
                               bodyText: GraphParser.cleanBody(text))
    }

    /// Depth-first: the first body part of `mime` that is not an attachment.
    static func firstPart(_ part: Part?, mime: String) -> Part? {
        guard let part else { return nil }
        let isAttachment = !(part.filename ?? "").isEmpty
        if !isAttachment, part.mimeType?.lowercased() == mime, part.body?.data != nil { return part }
        for child in part.parts ?? [] { if let hit = firstPart(child, mime: mime) { return hit } }
        return nil
    }

    static func decode(_ part: Part) -> String? {
        guard let data = part.body?.data.flatMap(HTTP.base64urlDecode) else { return nil }
        let charset = part.headers?.first { $0.name.lowercased() == "content-type" }?.value.lowercased() ?? ""
        if charset.contains("iso-8859-1") || charset.contains("latin1") || charset.contains("windows-1252") {
            return String(data: data, encoding: .windowsCP1252) ?? HTTP.text(data)
        }
        return HTTP.text(data)
    }

    static func hasAttachments(_ part: Part?) -> Bool {
        guard let part else { return false }
        if !(part.filename ?? "").isEmpty || part.body?.attachmentId != nil { return true }
        if part.parts == nil, part.mimeType?.lowercased() == "multipart/mixed" { return true }   // metadata format
        return (part.parts ?? []).contains { hasAttachments($0) }
    }

    /// Gmail already decodes RFC 2047 headers; this only guards against a raw `=?utf-8?…?=` slipping through.
    static func decodeMIMEWords(_ s: String) -> String {
        guard s.contains("=?") else { return s }
        let pattern = #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        var out = s
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)).reversed() {
            guard let r = Range(m.range, in: s), let enc = Range(m.range(at: 2), in: s), let txt = Range(m.range(at: 3), in: s) else { continue }
            var decoded: String?
            if s[enc].uppercased() == "B" {
                decoded = Data(base64Encoded: String(s[txt])).map(HTTP.text)
            } else {
                decoded = String(s[txt]).replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "=", with: "%").removingPercentEncoding
            }
            if let decoded { out.replaceSubrange(r, with: decoded) }
        }
        return out
    }
}

/// Google Calendar JSON → shared types.
public enum GoogleCalendarParser {
    struct When: Decodable { var dateTime: String?; var date: String?; var timeZone: String? }
    struct Person: Decodable { var email: String?; var displayName: String?; var resource: Bool? }
    struct EntryPoint: Decodable { var entryPointType: String?; var uri: String? }
    struct Conference: Decodable { var entryPoints: [EntryPoint]? }
    struct Event: Decodable {
        var id: String
        var status: String?
        var summary: String?
        var description: String?
        var location: String?
        var htmlLink: String?
        var hangoutLink: String?
        var conferenceData: Conference?
        var start: When?
        var end: When?
        var organizer: Person?
        var attendees: [Person]?
        var recurringEventId: String?
    }
    struct Page: Decodable { var items: [Event]?; var nextPageToken: String? }

    public static func events(_ data: Data, accountId: String) throws -> (events: [CalendarEvent], next: String?) {
        let page = try decodeJSON(Page.self, data, provider: .google)
        return ((page.items ?? []).compactMap { event($0, accountId: accountId) }, page.nextPageToken)
    }

    static func event(_ e: Event, accountId: String) -> CalendarEvent? {
        guard e.status != "cancelled", let s = e.start, let en = e.end, let start = date(s), let end = date(en) else { return nil }
        let notes = e.description.map(plainText)?.nonEmptyString
        let location = e.location?.nonEmptyString
        let video = e.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri
        let join = JoinLink.https(e.hangoutLink) ?? JoinLink.https(video) ?? JoinLink.find(in: [location, notes])
        func address(_ p: Person?) -> EmailAddress? {
            guard let p, p.email != nil || p.displayName != nil else { return nil }
            return EmailAddress(name: p.displayName?.nonEmptyString, email: p.email?.lowercased())
        }
        let attendees = (e.attendees ?? []).filter { $0.resource != true }.compactMap(address)
        return CalendarEvent(id: e.id, accountId: accountId, seriesId: e.recurringEventId?.nonEmptyString,
                             title: e.summary?.nonEmptyString ?? untitledEvent, start: start, end: end,
                             isAllDay: s.date != nil && s.dateTime == nil, location: location, joinURL: join,
                             organizer: address(e.organizer), attendees: attendees, notes: notes, webLink: e.htmlLink)
    }

    /// `dateTime` with offset, or an all-day `date` (local midnight).
    static func date(_ w: When) -> Date? {
        if let dt = w.dateTime { return GraphParser.parseISO(dt) }
        guard let d = w.date else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: d)
    }

    /// Calendar descriptions carry light HTML (`<br>`, `<a>`, `<b>`); keep the text and the link targets.
    static func plainText(_ html: String) -> String {
        var s = html.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</p>|</div>|</li>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?is)<a\s[^>]*href="([^"]+)"[^>]*>(.*?)</a>"#, with: "$2 ($1)", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(\S+) \(\1\)"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return HTTP.decodeEntities(s).replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
