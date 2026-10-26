import BrainCore
import SwiftUI

/// "Prepararme" (CONTRACT §12.5): what the brain knows about the attendees, open commitments, a suggested agenda and
/// questions; then a free chat about the meeting.
///
/// SKELETON (v0.3): the meetings engineer runs `engine.ask` with the prep prompt and reuses ChatView's rendering.
struct MeetingPrepView: View {
    let event: CalendarEvent

    var body: some View {
        EmptyStateView(symbol: "sparkles", title: L("prep.title", event.title), message: L("prep.loading"))
    }
}
