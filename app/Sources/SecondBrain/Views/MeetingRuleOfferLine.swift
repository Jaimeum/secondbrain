import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.3, worded per §15.4): after the user puts a meeting in a project by hand, one quiet line
// under the chip they used: «¿Mandar siempre las reuniones de Laura Méndez a **☁️ Migración a la nube**?» · Sí, siempre
// · Solo esta vez → "Regla creada · Deshacer". Same `RuleOffer` (timings, accept/undo, one offer in the app) and the
// same "Regla creada" line as Correo; only the question is worded here, because a meeting knows its people: they are
// named (the attendee's name, else the person page, else the address's local part), never shown as a raw address,
// and only the project is bold. At most two lines.

struct MeetingRuleOfferLine: View {
    let event: CalendarEvent
    let placement: MeetingChipPlacement

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        if let target = model.ruleOfferTarget, event.matches(target.eventId), target.placement == placement {
            if let current = model.ruleOffer.current, current.phase == .asking {
                MeetingRuleQuestion(offer: model.ruleOffer, rule: current.rule, event: event)
            } else {
                RuleOfferBar(offer: model.ruleOffer, compact: true)
            }
        }
    }
}

/// The asking phase of the offer under a meeting chip: `RuleOfferBar`'s compact look (accentSoft, icon, question,
/// "Sí, siempre" · "Solo esta vez"), with the meeting's own wording.
private struct MeetingRuleQuestion: View {
    @Environment(AppState.self) private var state
    let offer: RuleOffer
    let rule: RoutingRule
    let event: CalendarEvent

    var body: some View {
        let question = MeetingRuleOfferText.question(for: rule, event: event, projectLabel: state.projectName(rule.projectSlug),
                                                     people: MeetingsModel.shared.people)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                icon
                Text(question).foregroundStyle(Brand.color.text).lineLimit(1)
                Spacer(minLength: 8)
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    icon
                    Text(question)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                buttons
            }
        }
        .font(Brand.body)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
        .transition(.opacity)
        .help(String(question.characters))
    }

    private var icon: some View {
        Image(systemName: "arrow.triangle.branch").foregroundStyle(Brand.color.accent)
    }

    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { always; once }.fixedSize()
            VStack(alignment: .leading, spacing: 6) { always; once }
        }
    }

    private var always: some View {
        Button(L("rules.offer.always")) { offer.accept(state: state) }.buttonStyle(.brandPrimary)
    }

    private var once: some View {
        Button(L("rules.offer.once")) { offer.dismiss() }.buttonStyle(.brandSecondary)
    }
}

/// Wording of a meeting's rule offer (§15.4): who by name, the project in bold.
enum MeetingRuleOfferText {
    static func question(for rule: RoutingRule, event: CalendarEvent, projectLabel: String,
                         people: MeetingPeopleIndex) -> AttributedString {
        // A very long project name is shortened so the question still fits two lines; it reads as one name.
        let short = projectLabel.count > 32
            ? String(projectLabel.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : projectLabel
        var project = AttributedString(short.replacingOccurrences(of: " ", with: "\u{00A0}"))
        project.inlinePresentationIntent = .stronglyEmphasized
        guard let condition = rule.conditions.first else { return project }
        let key: String
        switch condition.field {
        case .organizerEmail, .senderEmail, .senderDomain: key = "rules.meetingOffer.organizer"
        default: key = "rules.meetingOffer.with"
        }
        let who = whoLabel(condition, event: event, people: people)
        // Neither value is read as format or Markdown: the project goes in through a marker.
        let marker = "\u{1}"
        var out = AttributedString()
        let parts = L(key, who, marker).components(separatedBy: marker)
        for (i, part) in parts.enumerated() {
            out += AttributedString(part)
            if i < parts.count - 1 { out += project }
        }
        return out
    }

    /// "Laura Méndez" for an address of the meeting; "@contoso.com" for a domain; the value itself otherwise.
    static func whoLabel(_ condition: RuleCondition, event: CalendarEvent, people: MeetingPeopleIndex) -> String {
        let value = condition.value.trimmingCharacters(in: .whitespaces)
        let isAddress = value.contains("@") && !value.hasPrefix("@")
        switch condition.field {
        case .organizerEmail, .attendeeEmail, .senderEmail, .recipient, .attendeeDomain, .senderDomain:
            if isAddress { return personName(email: value, event: event, people: people) }
            return value.hasPrefix("@") ? value : "@" + value
        default:
            return "«\(value)»"
        }
    }

    /// The attendee's (or organizer's) name from the event, else the person page's title, else the local part of the
    /// address, capitalized ("laura.mendez@contoso.com" → "Laura Mendez").
    static func personName(email: String, event: CalendarEvent, people: MeetingPeopleIndex) -> String {
        let lower = email.lowercased()
        let everyone = ([event.organizer].compactMap { $0 }) + event.attendees
        let match = everyone.first { $0.email?.lowercased() == lower }
        if let name = match?.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") { return name }
        if let person = people.person(for: match ?? EmailAddress(name: nil, email: lower)) {
            let title = person.title.trimmingCharacters(in: .whitespaces)
            if !title.isEmpty, !title.contains("@") { return title }
        }
        return localPartName(lower)
    }

    static func localPartName(_ email: String) -> String {
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let words = local.split(whereSeparator: { ".-_+".contains($0) }).filter { !$0.isEmpty }
        guard !words.isEmpty else { return local }
        return words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}
