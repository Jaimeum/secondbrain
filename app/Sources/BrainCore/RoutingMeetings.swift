import Foundation

// v0.4 routing (CONTRACT §14.2–§14.4) for the app's screens: which project a meeting belongs to (manual choice > rule >
// default project > suggestion), the rule offered after a manual meeting assignment, the rule editor's checks and its
// "Probar". Pure and testable; the app only adds the words.

// MARK: - Meetings (§14.2)

/// The project of a calendar event and why. Confirmed origins (manual, rule, default) need no ✓/✗ question and are
/// where a recording goes; a suggestion is only a question.
public struct MeetingProjectResolution: Equatable, Sendable {
    public enum Origin: Equatable, Sendable {
        /// The user picked this project for the event (or its series).
        case manual
        /// The user picked "Sin proyecto".
        case manualNone
        /// A rule decided (its project, or an explicit "Sin asignar" when the rule has none).
        case rule(RoutingRule)
        /// No rule matched: the vault's default project.
        case defaultProject
        /// "¿Es de 🚀 Acme?" from people pages / the title.
        case suggestion(MeetingSuggestion)
        /// Nothing known.
        case none
    }

    public var projectSlug: String?
    public var origin: Origin

    public init(projectSlug: String?, origin: Origin) { self.projectSlug = projectSlug; self.origin = origin }

    public var isConfirmed: Bool {
        switch origin {
        case .manual, .manualNone, .rule, .defaultProject: true
        case .suggestion, .none: false
        }
    }

    /// The project a recording of this meeting goes to (a suggestion doesn't count).
    public var recordingProject: String? { isConfirmed ? projectSlug : nil }

    /// The deciding rule, if a rule decided.
    public var rule: RoutingRule? {
        if case .rule(let r) = origin { return r }
        return nil
    }

    /// §14.2 for meetings: 1. the user's choice (a choice of a deleted project is ignored), 2. the first matching rule
    /// (a rule without project = explicit "Sin asignar"; a rule to a deleted project is skipped, like for mail),
    /// 3. the default project, 4. the suggestion (asked, never assumed).
    public static func resolve(choice: MeetingProjectChoice?, rule: RoutingDecision?, defaultProject: String?,
                               projectExists: (String) -> Bool,
                               suggestion: () -> MeetingSuggestion?) -> MeetingProjectResolution {
        switch choice {
        case .noProject: return MeetingProjectResolution(projectSlug: nil, origin: .manualNone)
        case .project(let slug) where projectExists(slug): return MeetingProjectResolution(projectSlug: slug, origin: .manual)
        default: break
        }
        if let rule {
            if let slug = rule.projectSlug {
                if projectExists(slug) { return MeetingProjectResolution(projectSlug: slug, origin: .rule(rule.rule)) }
            } else {
                return MeetingProjectResolution(projectSlug: nil, origin: .rule(rule.rule))
            }
        }
        if let slug = defaultProject, projectExists(slug) {
            return MeetingProjectResolution(projectSlug: slug, origin: .defaultProject)
        }
        if let s = suggestion(), projectExists(s.projectSlug) {
            return MeetingProjectResolution(projectSlug: s.projectSlug, origin: .suggestion(s))
        }
        return MeetingProjectResolution(projectSlug: nil, origin: .none)
    }
}

// MARK: - Offer after a manual assignment (§14.3)

public enum MeetingRuleOffers {
    /// The rule to offer after the user put `event` in `projectSlug` by hand, or nil: no project, the project came from a
    /// rule (or a rule matches the meeting at all), nothing sensible to propose (only the owner), or an equivalent rule
    /// already exists (`RoutingStore.offeredRule`).
    public static func forMeeting(_ event: CalendarEvent, projectSlug: String?, previous: MeetingProjectResolution?,
                                  ownerEmails: [String], existing: [RoutingRule], language: String,
                                  projectName: String? = nil) -> RoutingRule? {
        if previous?.rule != nil { return nil }   // it came from a rule: the user is correcting it, not teaching one
        return RoutingStore.offeredRule(for: .meeting(event, ownerEmails: ownerEmails), projectSlug: projectSlug,
                                        existing: existing, language: language, projectName: projectName)
    }
}

// MARK: - Editor checks (§14.4)

public enum RuleValueIssue: Equatable, Sendable {
    /// Nothing to look for.
    case empty
    /// An address or a domain with spaces in it ("acme .com").
    case hasSpaces
}

public enum RuleValidation {
    /// Fields whose value is an address or a domain.
    public static func isAddressField(_ f: RuleField) -> Bool {
        switch f {
        case .senderEmail, .senderDomain, .recipient, .attendeeEmail, .attendeeDomain, .organizerEmail: true
        case .senderName, .subject, .title, .anyText: false
        }
    }

    public static func issue(_ c: RuleCondition) -> RuleValueIssue? {
        let v = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
        if RuleMatcher.fold(v).isEmpty { return .empty }
        if isAddressField(c.field), v.contains(where: { $0.isWhitespace }) { return .hasSpaces }
        return nil
    }

    /// At least one condition and none with an issue.
    public static func isValid(_ conditions: [RuleCondition]) -> Bool {
        !conditions.isEmpty && conditions.allSatisfy { issue($0) == nil }
    }

    /// The rule as saved: values and name trimmed.
    public static func cleaned(_ rule: RoutingRule) -> RoutingRule {
        var r = rule
        r.name = r.name.trimmingCharacters(in: .whitespacesAndNewlines)
        r.conditions = r.conditions.map {
            RuleCondition(field: $0.field, op: $0.op, value: $0.value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return r
    }
}

// MARK: - "Probar" (§14.4)

public struct RuleTestResult: Equatable, Sendable {
    public var mails: [MailMessageSummary]
    public var events: [CalendarEvent]
    public var checkedMails: Int
    public var checkedEvents: Int
    public init(mails: [MailMessageSummary] = [], events: [CalendarEvent] = [], checkedMails: Int = 0, checkedEvents: Int = 0) {
        self.mails = mails; self.events = events; self.checkedMails = checkedMails; self.checkedEvents = checkedEvents
    }
}

public enum RuleTester {
    public static let mailLimit = 50

    /// What the rule would catch among the latest mail (newest first, at most `mailLimit`) and the given events. The
    /// rule is tested even when it is turned off.
    public static func run(_ rule: RoutingRule, mails: [MailMessageSummary], events: [CalendarEvent],
                           ownerEmails: [String]) -> RuleTestResult {
        let latest = Array(mails.sorted { $0.date > $1.date }.prefix(mailLimit))
        return RuleTestResult(
            mails: latest.filter { RuleMatcher.matches(rule, .mail($0, ownerEmails: ownerEmails)) },
            events: events.filter { RuleMatcher.matches(rule, .meeting($0, ownerEmails: ownerEmails)) },
            checkedMails: latest.count, checkedEvents: events.count)
    }
}

// MARK: - Names

public extension RoutingStore {
    /// The rule without its destination, for "por la regla «…»" next to a project that is already shown (Correo,
    /// Reuniones, the chips): the rule's own name, else its conditions ("Reuniones de ana@acme.com", "El asunto
    /// contiene «Nubia» y de @acme.com").
    nonisolated static func conditionSummary(_ rule: RoutingRule, language: String) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let l = Lang(language)
        let parts = rule.conditions.enumerated().map { phrase($1, l, first: $0 == 0) }
        return parts.isEmpty ? l.t("Sin condiciones", "No conditions") : parts.joined(separator: l.t(" y ", " and "))
    }
}
