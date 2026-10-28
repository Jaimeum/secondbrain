import AppKit
import BrainCore
import SwiftUI

/// What an "Abrir en …" link opens (CONTRACT §17.7).
enum OriginalKind: Hashable {
    case mail, event
}

/// "Abrir en Outlook" / "Abrir en Gmail" / "Abrir en Google Calendar" / "Abrir en Outlook Calendar": opens the item in
/// the browser (`NSWorkspace.open`). Draws nothing without a link (pasted mail, the Mac calendar).
/// `.button` = a brand secondary button (headers, action rows); `.link` = accent text (inside a reader or a row).
struct OpenOriginalButton: View {
    enum Style { case button, link }

    let link: String?
    let provider: AccountProvider?
    var kind: OriginalKind = .mail
    var iconOnly = false
    var style: Style = .button
    /// `.link` + `iconOnly`: the side of the icon and its hit area (28 next to header icon buttons; a caption-sized
    /// icon inside a list row passes its own, so clicks around it still select the row).
    var iconSide: CGFloat = 28
    /// Gmail without a link from the API: the conversation, `https://mail.google.com/mail/u/<email>/#all/<threadId>`.
    var gmailThreadId: String? = nil
    var accountEmail: String? = nil

    var body: some View {
        if let url = resolvedLink.flatMap(URL.init(string:)), let title = Self.title(provider: provider, kind: kind) {
            switch style {
            case .button:
                let button = Button { NSWorkspace.shared.open(url) } label: {
                    Label(title, systemImage: "arrow.up.right.square")
                }
                .buttonStyle(.brandSecondary)
                .help(L("original.help", title))
                if iconOnly { button.labelStyle(.iconOnly) } else { button.labelStyle(.titleAndIcon) }
            case .link:
                Button { NSWorkspace.shared.open(url) } label: {
                    if iconOnly {   // sized like the icon buttons it sits with (page headers)
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(Brand.color.accent)
                            .frame(width: iconSide, height: iconSide)
                            .contentShape(Rectangle())
                    } else {
                        HStack(spacing: 3) {
                            Text(title).lineLimit(1)
                            Image(systemName: "arrow.up.right.square").imageScale(.small)
                        }
                        .font(Brand.font(11, .medium))
                        .foregroundStyle(Brand.color.accent)
                        .contentShape(Rectangle())
                    }
                }
                .buttonStyle(.plain)
                .help(L("original.help", title))
                .accessibilityLabel(title)
            }
        }
    }

    /// The link to open: the stored one (http/https only), else the Gmail conversation URL.
    var resolvedLink: String? {
        if OriginalLinks.isOpenable(link) { return link }
        if provider == .google, kind == .mail, let gmailThreadId, !gmailThreadId.isEmpty {
            return OriginalLinks.gmailThread(accountEmail: accountEmail, threadId: gmailThreadId)
        }
        return nil
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

extension OpenOriginalButton {
    /// One email of a saved thread (the conversation, Archivos rows whose origin is an email). Nothing for pasted mail.
    init(message: ThreadInfo.Message, in thread: ThreadInfo, iconOnly: Bool = false, style: Style = .button) {
        let resolved = OriginalLinks.link(for: message, in: thread)
        self.init(link: resolved?.link, provider: resolved?.provider, kind: .mail, iconOnly: iconOnly, style: style)
    }

    /// The thread's newest email that has a link (the thread ficha's header).
    init(latestIn thread: ThreadInfo, iconOnly: Bool = false, style: Style = .button) {
        let resolved = OriginalLinks.latestLink(in: thread)
        self.init(link: resolved?.link, provider: resolved?.provider, kind: .mail, iconOnly: iconOnly, style: style)
    }

    /// A calendar event (nothing for the Mac calendar).
    init(event: CalendarEvent, iconOnly: Bool = false, style: Style = .button) {
        let resolved = OriginalLinks.link(for: event)
        self.init(link: resolved?.link, provider: resolved?.provider, kind: .event, iconOnly: iconOnly, style: style)
    }
}

/// "Abrir en …" in a ficha's header (§17.7): an email thread opens its newest email (and first fills the links of
/// messages saved before v0.7, once); a recorded meeting tied to a calendar event opens the event.
struct EntityOriginalButton: View {
    @Environment(AppState.self) private var state
    let path: String
    var iconOnly = false
    var style: OpenOriginalButton.Style = .button

    @ViewState private var thread: ThreadInfo?

    var body: some View {
        ZStack {   // not a Group: an empty Group drops its .task, and the thread must load to show anything
            if let thread {
                OpenOriginalButton(latestIn: thread, iconOnly: iconOnly, style: style)
            } else if let meeting = meetingLink {
                OpenOriginalButton(link: meeting.link, provider: meeting.provider, kind: .event, iconOnly: iconOnly, style: style)
            }
        }
        .task(id: "\(path)-\(state.vaultRevision)") {
            guard let key = ThreadConversationView.threadKey(forPage: path) else { thread = nil; return }
            let vault = state.engine.vault
            thread = await Task.detached { vault.threadInfo(key: key) }.value
            // Mail saved before v0.7 has no web link yet: ask for it once, then show the button.
            if thread?.messages.contains(where: { $0.webLink == nil && $0.externalId != nil }) == true,
               await state.engine.fillMissingWebLinks(threadKey: key) > 0 {
                thread = await Task.detached { vault.threadInfo(key: key) }.value
                state.bumpVault()
            }
        }
    }

    /// The recording whose page this is, tied to a calendar event: its stored link, else the agenda's copy of the event.
    private var meetingLink: (link: String, provider: AccountProvider)? {
        guard path.contains("/wiki/meetings/") else { return nil }
        guard let source = state.engine.sources.last(where: {
            $0.kind == .meeting && $0.calendarEventId != nil && SourcePages.candidates(for: $0).contains(path)
        }) else { return nil }
        if let link = source.webLink, OriginalLinks.isOpenable(link),
           let provider = OriginalLinks.provider(forLink: link) ?? MeetingsModel.shared.event(id: source.calendarEventId)
               .flatMap({ OriginalLinks.provider(ofAccountId: $0.accountId) }) {
            return (link, provider)
        }
        return MeetingsModel.shared.event(id: source.calendarEventId).flatMap { OriginalLinks.link(for: $0) }
    }
}
