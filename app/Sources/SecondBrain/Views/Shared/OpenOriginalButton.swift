import AppKit
import BrainCore
import SwiftUI

/// What an "Abrir en …" link opens (CONTRACT §17.7).
enum OriginalKind: Hashable {
    case mail, event
}

/// "Abrir en Outlook" / "Abrir en Gmail" / "Abrir en Google Calendar" / "Abrir en Outlook Calendar": opens the item in
/// the browser. Draws nothing without a link (pasted mail, the Mac calendar).
// v0.7: filled in by links (stub: a plain button; links adds the Gmail fallback URL and styling per place).
struct OpenOriginalButton: View {
    let link: String?
    let provider: AccountProvider?
    var kind: OriginalKind = .mail
    var iconOnly = false

    var body: some View {
        if let url = link.flatMap(URL.init(string:)), let title = Self.title(provider: provider, kind: kind) {
            let button = Button { NSWorkspace.shared.open(url) } label: {
                Label(title, systemImage: "arrow.up.right.square")
            }
            .buttonStyle(.brandSecondary)
            .help(title)
            if iconOnly { button.labelStyle(.iconOnly) } else { button.labelStyle(.titleAndIcon) }
        }
    }

    /// nil for providers with no web app (the Mac calendar).
    static func title(provider: AccountProvider?, kind: OriginalKind) -> String? {
        switch (provider, kind) {
        case (.microsoft, .mail): L("original.outlook")
        case (.google, .mail): L("original.gmail")
        case (.microsoft, .event): L("original.outlookCalendar")
        case (.google, .event): L("original.googleCalendar")
        default: nil
        }
    }
}
