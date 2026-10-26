import BrainCore
import SwiftUI

/// Sidebar "Reuniones" (CONTRACT §12.5): today and the coming days from the connected calendars; record, join,
/// prepare.
///
/// SKELETON (v0.3): the meetings engineer builds the agenda, detail panel and reminders.
struct MeetingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.engine.accounts.accounts.isEmpty {
                ConnectAccountsEmptyState(symbol: "calendar", title: L("meetings.empty.title"),
                                          message: L("meetings.empty.message"))
            } else {
                // TODO(meetings engineer): agenda grouped by day + detail panel
                EmptyStateView(symbol: "calendar", title: L("meetings.nothing.title"), message: L("meetings.nothing.message"))
            }
        }
        .navigationTitle(L("meetings.title"))
        .navigationSubtitle(L("meetings.subtitle"))
    }
}
