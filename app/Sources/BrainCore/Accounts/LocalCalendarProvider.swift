import EventKit
import Foundation

/// The Mac's own Calendar through EventKit (CONTRACT §12.7 "Calendario sin OAuth"): whatever accounts the user already
/// added to Calendar.app (iCloud, Exchange, Google…), with one system permission and no sign-in. Calendar only.
public final class LocalCalendarProvider: MailCalendarProvider, @unchecked Sendable {
    public static let accountId = "local:calendar"
    public let account: ConnectedAccount
    private let store: EKEventStore

    public init(account: ConnectedAccount = LocalCalendarProvider.makeAccount()) {
        self.account = account
        self.store = EKEventStore()
    }

    /// The fixed account (id "local:calendar").
    public static func makeAccount(now: Date = Date()) -> ConnectedAccount {
        ConnectedAccount(provider: .local, email: "calendar", displayName: nil, connectedAt: now, scopes: [])
    }

    // MARK: Permission

    public static var hasAccess: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    /// The user (or a profile) already said no: only System Settings can change it.
    public static var isDenied: Bool {
        let s = EKEventStore.authorizationStatus(for: .event)
        return s == .denied || s == .restricted || s == .writeOnly
    }

    /// Shows the system prompt the first time; afterwards just reports the current answer. Never call from tests.
    public static func requestAccess() async throws -> Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: return true
        case .notDetermined:
            do { return try await EKEventStore().requestFullAccessToEvents() } catch {
                throw AccountError.failed(error.localizedDescription)
            }
        default: return false
        }
    }

    static var noAccessMessage: String {
        OAuthClient.lang.t("SecondBrain no tiene permiso para ver tu calendario. Actívalo en Ajustes del Sistema → Privacidad y seguridad → Calendarios.",
                           "SecondBrain can't see your calendar. Turn it on in System Settings → Privacy & Security → Calendars.")
    }

    // MARK: MailCalendarProvider

    public func profile() async throws -> ConnectedAccount { account }

    public func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        throw AccountError.failed("no mail")
    }
    public func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) {
        throw AccountError.failed("no mail")
    }
    public func fetchMessage(id: String) async throws -> MailMessageFull { throw AccountError.failed("no mail") }
    public func fetchThread(id: String) async throws -> [MailMessageFull] { throw AccountError.failed("no mail") }

    public func events(from: Date, to: Date) async throws -> [CalendarEvent] {
        guard Self.hasAccess else { throw AccountError.failed(Self.noAccessMessage) }
        let store = self.store
        let accountId = account.id
        return await Task.detached(priority: .userInitiated) {
            let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
            return store.events(matching: predicate)
                .filter { $0.status != .canceled }
                .map { Self.event(from: Fields($0), accountId: accountId) }
                .sorted { $0.start < $1.start }
        }.value
    }

    // MARK: Mapping (pure, so it can be tested without EventKit access)

    /// What we read from an `EKEvent`.
    public struct Fields: Sendable {
        public var identifier: String
        public var externalIdentifier: String?
        public var isRecurring: Bool
        public var title: String?
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        public var location: String?
        public var url: URL?
        public var notes: String?
        public var organizer: EmailAddress?
        public var attendees: [EmailAddress]

        public init(identifier: String, externalIdentifier: String? = nil, isRecurring: Bool = false, title: String?,
                    start: Date, end: Date, isAllDay: Bool = false, location: String? = nil, url: URL? = nil, notes: String? = nil,
                    organizer: EmailAddress? = nil, attendees: [EmailAddress] = []) {
            self.identifier = identifier; self.externalIdentifier = externalIdentifier; self.isRecurring = isRecurring
            self.title = title; self.start = start; self.end = end; self.isAllDay = isAllDay; self.location = location
            self.url = url; self.notes = notes; self.organizer = organizer; self.attendees = attendees
        }

        init(_ e: EKEvent) {
            self.init(identifier: e.eventIdentifier ?? e.calendarItemIdentifier,
                      externalIdentifier: e.calendarItemExternalIdentifier,
                      isRecurring: e.hasRecurrenceRules || e.isDetached,
                      title: e.title, start: e.startDate, end: e.endDate, isAllDay: e.isAllDay,
                      location: e.location, url: e.url, notes: e.notes,
                      organizer: e.organizer.flatMap(LocalCalendarProvider.address),
                      attendees: (e.attendees ?? []).filter { $0.participantType != .room && $0.participantType != .resource }
                        .compactMap(LocalCalendarProvider.address))
        }
    }

    public static func event(from f: Fields, accountId: String = accountId) -> CalendarEvent {
        // Every occurrence of a repeating event shares `eventIdentifier`: add the start so ids stay unique.
        let id = f.isRecurring ? "\(f.identifier)@\(Int(f.start.timeIntervalSince1970))" : f.identifier
        let notes = f.notes?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        let location = f.location?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmptyString
        let join = JoinLink.isJoinLink(f.url) ? f.url : JoinLink.find(in: [location, notes, f.url?.absoluteString])
        return CalendarEvent(id: id, accountId: accountId,
                             seriesId: f.isRecurring ? (f.externalIdentifier?.nonEmptyString ?? f.identifier) : nil,
                             title: f.title?.nonEmptyString ?? untitledEvent, start: f.start, end: f.end, isAllDay: f.isAllDay,
                             location: location, joinURL: join, organizer: f.organizer, attendees: f.attendees,
                             notes: notes, webLink: nil)
    }

    /// `mailto:` participant → address (EventKit has no plain email property).
    static func address(_ p: EKParticipant) -> EmailAddress? {
        var email: String?
        if p.url.scheme?.lowercased() == "mailto" {
            email = (p.url as NSURL).resourceSpecifier?.removingPercentEncoding?.lowercased()
        }
        let name = p.name?.nonEmptyString
        guard name != nil || email != nil else { return nil }
        return EmailAddress(name: name, email: email)
    }
}
