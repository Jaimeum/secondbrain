import Foundation

/// Microsoft 365 / Outlook.com mail and calendar through Microsoft Graph v1.0 (read-only, CONTRACT §12.3).
public final class MicrosoftGraphProvider: MailCalendarProvider {
    public let account: ConnectedAccount
    let api: APIClient

    public static let base = "https://graph.microsoft.com/v1.0"
    static let summaryFields = "id,conversationId,subject,bodyPreview,receivedDateTime,sentDateTime,isRead,hasAttachments,webLink,from,sender,toRecipients"
    static let eventFields = "id,subject,start,end,isAllDay,isCancelled,location,onlineMeeting,onlineMeetingUrl,organizer,attendees,bodyPreview,webLink,seriesMasterId,type"
    static let textBody = ["Prefer": "outlook.body-content-type=\"text\""]
    static let utc = ["Prefer": "outlook.timezone=\"UTC\""]

    public init(account: ConnectedAccount, api: APIClient) {
        self.account = account
        self.api = api
    }

    public func profile() async throws -> ConnectedAccount {
        let data = try await api.get(HTTP.url(Self.base + "/me", query: [("$select", "displayName,mail,userPrincipalName")]))
        return try GraphParser.profile(data, scopes: AccountProvider.microsoft.scopes)
    }

    public func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        let url = try Self.pageURL(pageToken) ?? Self.listURL(since: since)
        return try GraphParser.messageList(try await api.get(url))
    }

    public func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return try await listMessages(since: Date().addingTimeInterval(-30 * 86_400), pageToken: pageToken) }
        let url = try Self.pageURL(pageToken) ?? Self.searchURL(q)
        return try GraphParser.messageList(try await api.get(url))
    }

    public func fetchMessage(id: String) async throws -> MailMessageFull {
        let url = HTTP.url(Self.base + "/me/messages/" + Self.pathSegment(id),
                           query: [("$select", Self.summaryFields + ",ccRecipients,body")])
        return try await GraphParser.message(try await api.get(url, headers: Self.textBody))
    }

    public func fetchThread(id: String) async throws -> [MailMessageFull] {
        let data = try await api.get(Self.threadURL(conversationId: id), headers: Self.textBody)
        return try await GraphParser.thread(data)
    }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        var url: URL? = Self.calendarURL(from: from, to: to)
        var all: [CalendarEvent] = []
        var pages = 0
        while let next = url, pages < 5 {
            let page = try GraphParser.events(try await api.get(next, headers: Self.utc), accountId: account.id)
            all += page.events
            url = try Self.pageURL(page.next)
            pages += 1
        }
        return all.sorted { $0.start < $1.start }
    }

    // MARK: URLs (public for the self-tests)

    public static func listURL(since: Date) -> URL {
        HTTP.url(base + "/me/messages", query: [
            ("$top", "50"),
            ("$select", summaryFields),
            ("$filter", "receivedDateTime ge \(iso(since))"),
            ("$orderby", "receivedDateTime desc"),
        ])
    }

    public static func searchURL(_ query: String) -> URL {
        let q = query.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "\\", with: " ")
        return HTTP.url(base + "/me/messages", query: [("$search", "\"\(q)\""), ("$top", "25"), ("$select", summaryFields)])
    }

    public static func threadURL(conversationId: String) -> URL {
        HTTP.url(base + "/me/messages", query: [
            ("$filter", "conversationId eq '\(conversationId.replacingOccurrences(of: "'", with: "''"))'"),
            ("$select", summaryFields + ",ccRecipients,body"),
            ("$top", "50"),
        ])
    }

    public static func calendarURL(from: Date, to: Date) -> URL {
        HTTP.url(base + "/me/calendarView", query: [
            ("startDateTime", iso(from)),
            ("endDateTime", iso(to)),
            ("$top", "200"),
            ("$select", eventFields),
            ("$orderby", "start/dateTime"),
        ])
    }

    /// A `@odata.nextLink` handed back as page token; only Graph URLs are followed.
    static func pageURL(_ token: String?) throws -> URL? {
        guard let token, !token.isEmpty else { return nil }
        guard token.hasPrefix(base + "/"), let url = URL(string: token) else { throw AccountError.failed("bad page token") }
        return url
    }

    static func pathSegment(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }
}

/// Microsoft Graph JSON → shared types (public so the self-tests can feed fixtures).
public enum GraphParser {
    struct Address: Decodable { var name: String?; var address: String? }
    struct Recipient: Decodable { var emailAddress: Address? }
    struct Body: Decodable { var contentType: String?; var content: String? }
    struct Message: Decodable {
        var id: String
        var conversationId: String?
        var subject: String?
        var bodyPreview: String?
        var receivedDateTime: String?
        var sentDateTime: String?
        var isRead: Bool?
        var hasAttachments: Bool?
        var webLink: String?
        var from: Recipient?
        var sender: Recipient?
        var toRecipients: [Recipient]?
        var ccRecipients: [Recipient]?
        var body: Body?
    }
    struct DateTimeZone: Decodable { var dateTime: String; var timeZone: String? }
    struct Location: Decodable { var displayName: String? }
    struct OnlineMeeting: Decodable { var joinUrl: String? }
    struct Attendee: Decodable { var type: String?; var emailAddress: Address? }
    struct Event: Decodable {
        var id: String
        var subject: String?
        var start: DateTimeZone?
        var end: DateTimeZone?
        var isAllDay: Bool?
        var isCancelled: Bool?
        var location: Location?
        var onlineMeeting: OnlineMeeting?
        var onlineMeetingUrl: String?
        var organizer: Recipient?
        var attendees: [Attendee]?
        var bodyPreview: String?
        var webLink: String?
        var seriesMasterId: String?
    }
    struct Page<T: Decodable>: Decodable {
        var value: [T]
        var next: String?
        enum CodingKeys: String, CodingKey { case value, next = "@odata.nextLink" }
    }
    struct Me: Decodable { var displayName: String?; var mail: String?; var userPrincipalName: String? }

    public static func profile(_ data: Data, scopes: [String]) throws -> ConnectedAccount {
        let me = try decodeJSON(Me.self, data, provider: .microsoft)
        guard let email = (me.mail?.nonEmptyString ?? me.userPrincipalName?.nonEmptyString) else {
            throw AccountError.failed("Microsoft didn't return an email address")
        }
        return ConnectedAccount(provider: .microsoft, email: email, displayName: me.displayName?.nonEmptyString, scopes: scopes)
    }

    public static func messageList(_ data: Data) throws -> (messages: [MailMessageSummary], next: String?) {
        let page = try decodeJSON(Page<Message>.self, data, provider: .microsoft)
        return (page.value.map(summary), page.next)
    }

    public static func message(_ data: Data) async throws -> MailMessageFull {
        try await full(decodeJSON(Message.self, data, provider: .microsoft))
    }

    /// A conversation, oldest first.
    public static func thread(_ data: Data) async throws -> [MailMessageFull] {
        let page = try decodeJSON(Page<Message>.self, data, provider: .microsoft)
        var out: [MailMessageFull] = []
        for m in page.value { out.append(try await full(m)) }
        return out.sorted { $0.summary.date < $1.summary.date }
    }

    public static func events(_ data: Data, accountId: String) throws -> (events: [CalendarEvent], next: String?) {
        let page = try decodeJSON(Page<Event>.self, data, provider: .microsoft)
        return (page.value.compactMap { event($0, accountId: accountId) }, page.next)
    }

    // MARK: Mapping

    static func address(_ r: Recipient?) -> EmailAddress? {
        guard let a = r?.emailAddress, a.name?.nonEmptyString != nil || a.address?.nonEmptyString != nil else { return nil }
        return EmailAddress(name: a.name?.nonEmptyString, email: a.address?.nonEmptyString?.lowercased())
    }

    static func summary(_ m: Message) -> MailMessageSummary {
        let date = (m.receivedDateTime ?? m.sentDateTime).flatMap(parseISO) ?? Date(timeIntervalSince1970: 0)
        return MailMessageSummary(
            id: m.id, threadId: m.conversationId ?? m.id,
            from: address(m.from) ?? address(m.sender) ?? EmailAddress(name: nil, email: nil),
            to: (m.toRecipients ?? []).compactMap(address),
            subject: m.subject ?? "",
            snippet: (m.bodyPreview ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces),
            date: date, isRead: m.isRead ?? true, hasAttachments: m.hasAttachments ?? false, webLink: m.webLink)
    }

    static func full(_ m: Message) async throws -> MailMessageFull {
        var text = m.body?.content ?? m.bodyPreview ?? ""
        if m.body?.contentType?.lowercased() == "html" {
            let html = text
            text = await MainActor.run { Importer.htmlToText(html) }
        }
        return MailMessageFull(summary: summary(m), cc: (m.ccRecipients ?? []).compactMap(address), bodyText: cleanBody(text))
    }

    static func event(_ e: Event, accountId: String) -> CalendarEvent? {
        guard e.isCancelled != true, let s = e.start, let en = e.end else { return nil }
        let allDay = e.isAllDay ?? false
        guard let start = graphDate(s, allDay: allDay), let end = graphDate(en, allDay: allDay) else { return nil }
        let location = e.location?.displayName?.nonEmptyString
        let notes = e.bodyPreview?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        let join = e.onlineMeeting?.joinUrl.flatMap { URL(string: $0) } ?? e.onlineMeetingUrl.flatMap { URL(string: $0) }
            ?? JoinLink.find(in: [location, notes])
        let attendees = (e.attendees ?? []).filter { $0.type?.lowercased() != "resource" }
            .compactMap { address(Recipient(emailAddress: $0.emailAddress)) }
        return CalendarEvent(id: e.id, accountId: accountId, seriesId: e.seriesMasterId?.nonEmptyString,
                             title: e.subject?.nonEmptyString ?? untitledEvent, start: start, end: end, isAllDay: allDay,
                             location: location, joinURL: join, organizer: address(e.organizer), attendees: attendees,
                             notes: notes, webLink: e.webLink)
    }

    /// `{"dateTime":"2026-10-26T15:00:00.0000000","timeZone":"UTC"}`. All-day events keep their calendar day in local time.
    static func graphDate(_ d: DateTimeZone, allDay: Bool) -> Date? {
        let raw = d.dateTime.split(separator: ".").first.map(String.init) ?? d.dateTime
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        if allDay {
            f.timeZone = .current
        } else {
            f.timeZone = d.timeZone.flatMap { TimeZone(identifier: $0) } ?? TimeZone(identifier: "UTC")
        }
        return f.date(from: raw)
    }

    static func parseISO(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        if s.contains(".") {
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f.date(from: s) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    static func cleanBody(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
