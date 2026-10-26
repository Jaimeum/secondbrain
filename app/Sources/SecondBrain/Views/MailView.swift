import BrainCore
import SwiftUI

/// Sidebar "Correo" (CONTRACT §12.4): the connected inbox; add a message or a whole thread to the brain.
///
/// SKELETON (v0.3): the mail engineer builds the list, reader and "Agregar al cerebro" bar.
struct MailView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        Group {
            if state.engine.accounts.accounts.isEmpty {
                ConnectAccountsEmptyState(symbol: "envelope", title: L("mail.empty.title"), message: L("mail.empty.message"),
                                          secondaryTitle: L("mail.pasteInstead")) { state.requestEmail() }
            } else {
                // TODO(mail engineer): MailListView + MailReaderView
                EmptyStateView(symbol: "envelope.open", title: L("mail.title"), message: L("mail.pickMessage"))
            }
        }
        .navigationTitle(L("mail.title"))
        .navigationSubtitle(L("mail.subtitle"))
    }
}
