import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.3): after the user puts a meeting in a project by hand, one quiet line under the chip they
// used: «¿Las reuniones que organiza ana@acme.com a 🚀 Acme?» · Sí, siempre · Solo esta vez → "Regla creada · Deshacer".

struct MeetingRuleOfferLine: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    let placement: MeetingChipPlacement

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        if let offer = model.ruleOffer, event.matches(offer.eventId), offer.placement == placement {
            Group {
                if offer.createdRuleId != nil {
                    HStack(spacing: 8) {
                        Label(L("rules.meetingOffer.created"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Button(L("rules.meetingOffer.undo")) { model.undoRuleOffer(state: state) }
                            .buttonStyle(.link)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { question(offer); buttons }
                        VStack(alignment: .leading, spacing: 6) { question(offer); buttons }
                    }
                }
            }
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
            .transition(.opacity)
        }
    }

    private func question(_ offer: MeetingRuleOffer) -> some View {
        Text(Self.question(for: offer.rule, project: state.projectName(offer.rule.projectSlug)))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var buttons: some View {
        HStack(spacing: 8) {
            Button(L("rules.meetingOffer.always")) { model.acceptRuleOffer(state: state) }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
            Button(L("rules.meetingOffer.once")) { model.dismissRuleOffer() }
                .controlSize(.small)
                .buttonStyle(.bordered)
        }
        .fixedSize()
    }

    /// «¿Las reuniones que organiza **ana@acme.com** a 🚀 Acme?» (who in bold).
    static func question(for rule: RoutingRule, project: String) -> AttributedString {
        guard let c = rule.conditions.first else { return AttributedString(project) }
        let key: String
        var who = c.value
        switch c.field {
        case .organizerEmail, .senderEmail: key = "rules.meetingOffer.organizer"
        case .attendeeDomain, .senderDomain:
            key = "rules.meetingOffer.with"
            who = "@" + who
        default: key = "rules.meetingOffer.with"
        }
        let marker = "\u{1}"
        let text = L(key, marker, project)
        var out = AttributedString()
        let parts = text.components(separatedBy: marker)
        for (i, part) in parts.enumerated() {
            out += AttributedString(part)
            if i < parts.count - 1 {
                var bold = AttributedString(who)
                bold.inlinePresentationIntent = .stronglyEmphasized
                out += bold
            }
        }
        return out
    }
}
