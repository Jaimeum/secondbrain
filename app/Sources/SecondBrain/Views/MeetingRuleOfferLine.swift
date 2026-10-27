import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.3): after the user puts a meeting in a project by hand, one quiet line under the chip they
// used: «¿Las reuniones que organiza ana@acme.com a 🚀 Acme de ahora en adelante?» · Sí, siempre · Solo esta vez →
// "Regla creada · Deshacer". The same `RuleOfferBar` as Correo, in its compact layout.

struct MeetingRuleOfferLine: View {
    let event: CalendarEvent
    let placement: MeetingChipPlacement

    private var model: MeetingsModel { MeetingsModel.shared }

    var body: some View {
        if let target = model.ruleOfferTarget, event.matches(target.eventId), target.placement == placement {
            RuleOfferBar(offer: model.ruleOffer, compact: true)
        }
    }
}
