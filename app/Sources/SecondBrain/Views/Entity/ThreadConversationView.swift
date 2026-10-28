import AppKit
import BrainCore
import SwiftUI

/// The conversation of an email thread (CONTRACT §17.4), shown by `EntityView` above the page Claude wrote for
/// `wiki/emails/<thread>.md`: each email in order (sender, date, what's new in it, attachments, "Abrir en …"), mine
/// marked "Tú" on a different background. A bar "Conversación · 7 correos" folds it (remembered); unfolded, it takes
/// at most `maxHeight` and scrolls, opening on the newest email, so Claude's page below stays in sight.
struct ThreadConversationView: View {
    @Environment(AppState.self) private var state
    let threadKey: String
    var scope: Scope = .brain

    struct Loaded: Equatable {
        var info: ThreadInfo
        /// What's new in each message (no quoted history), by file.
        var texts: [String: String]
    }

    @ViewState private var loaded: Loaded?
    @ViewState private var contentHeight: CGFloat = 0
    @AppStorage("thread.conversation.expanded") private var expanded = true

    static let maxHeight: CGFloat = 340

    var body: some View {
        Group {
            if let loaded, loaded.info.key == threadKey, !loaded.info.messages.isEmpty {
                VStack(spacing: 0) {
                    bar(loaded.info)
                    if expanded {
                        messages(loaded)
                    }
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                }
                .background(Brand.color.surface)
            } else {
                Color.clear.frame(height: 0)
            }
        }
        .task(id: "\(threadKey)-\(state.vaultRevision)") { await load() }
    }

    private func load() async {
        let vault = state.engine.vault, key = threadKey
        let result = await Task.detached(priority: .userInitiated) { () -> Loaded? in
            guard let info = vault.threadInfo(key: key) else { return nil }
            var texts: [String: String] = [:]
            for m in info.messages { texts[m.file] = vault.newText(of: m, in: info) }
            return Loaded(info: info, texts: texts)
        }.value
        guard !Task.isCancelled, result != loaded else { return }
        loaded = result
    }

    // MARK: Bar

    private func bar(_ info: ThreadInfo) -> some View {
        HStack(spacing: Brand.spacing.s) {
            Button {
                withAnimation(Brand.motion.animation(fast: true)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(Brand.font(10, .semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(Brand.color.text3)
                        .frame(width: 12)
                    Text(L("thread.conversation"))
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                    Text(ThreadText.caption(count: info.messageCount, last: info.lastDate,
                                            senders: info.senderNames(you: L("thread.you"))))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? L("thread.collapse") : L("thread.expand"))
            Spacer(minLength: Brand.spacing.s)
            // The ficha's header link opens the newest email (§17.7).
            if let last = info.messages.last(where: { $0.webLink != nil }) {
                OpenOriginalButton(link: last.webLink, provider: last.provider, iconOnly: true)
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.s)
    }

    // MARK: Messages

    private func messages(_ loaded: Loaded) -> some View {
        let list = loaded.info.messages
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.spacing.s) {
                    ForEach(list, id: \.file) { m in
                        ThreadMessageCard(message: m, text: loaded.texts[m.file] ?? "", thread: loaded.info)
                            .id(m.file)
                    }
                }
                .padding(.horizontal, Brand.spacing.l)
                .padding(.bottom, Brand.spacing.m)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .frame(height: min(max(contentHeight, 1), Self.maxHeight))
            .onAppear { if let last = list.last { proxy.scrollTo(last.file, anchor: .bottom) } }
            .onChange(of: list.count) { if let last = list.last { proxy.scrollTo(last.file, anchor: .bottom) } }
        }
    }
}

/// One email of the conversation: who and when, what's new in it (folded past a few lines), its saved attachments and
/// "Abrir en Outlook/Gmail". Mine: "Tú", on the accent background, set in from the left.
struct ThreadMessageCard: View {
    @Environment(AppState.self) private var state
    let message: ThreadInfo.Message
    let text: String
    let thread: ThreadInfo

    @ViewState private var showAll = false

    static let foldedLines = 6

    private var sender: String {
        message.isFromOwner ? L("thread.you") : (message.from?.display ?? L("thread.unknownSender"))
    }

    private var isLong: Bool {
        text.components(separatedBy: "\n").count > Self.foldedLines || text.count > 480
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: Brand.spacing.s) {
                Text(sender)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                if !message.isFromOwner, let email = message.from?.email, message.from?.name != nil {
                    Text(email)
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: Brand.spacing.s)
                if let date = message.date {
                    Text(Fmt.dayTime(date))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .help(Fmt.date(date))
                }
                OpenOriginalButton(link: message.webLink, provider: message.provider, iconOnly: true)
                    .controlSize(.small)
            }
            Text(text.isEmpty ? L("thread.noNewText") : text)
                .font(Brand.body)
                .foregroundStyle(text.isEmpty ? Brand.color.text2 : Brand.color.text)
                .lineLimit(showAll ? nil : Self.foldedLines)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isLong {
                Button(showAll ? L("thread.showLess") : L("thread.showMore")) {
                    withAnimation(Brand.motion.animation(fast: true)) { showAll.toggle() }
                }
                .buttonStyle(.borderless)
                .font(Brand.font(11, .medium))
                .foregroundStyle(Brand.color.accent)
            }
            if !message.attachments.isEmpty {
                attachments
            }
        }
        .padding(Brand.spacing.m)
        .background(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
            .fill(message.isFromOwner ? Brand.color.accentSoft : Brand.color.card))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
            .strokeBorder(message.isFromOwner ? Color.clear : Brand.color.line))
        .padding(.leading, message.isFromOwner ? 32 : 0)
        .padding(.trailing, message.isFromOwner ? 0 : 32)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(sender))
    }

    private var attachments: some View {
        // Wraps on narrow fichas: one chip per line when they don't fit side by side.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { attachmentChips }
            VStack(alignment: .leading, spacing: 4) { attachmentChips }
        }
    }

    @ViewBuilder private var attachmentChips: some View {
        ForEach(message.attachments, id: \.file) { a in
            Button {
                NSWorkspace.shared.open(state.engine.vault.url(for: a.file))
            } label: {
                BrandChip(text: "\(a.name) · \(ByteCountFormatter.string(fromByteCount: Int64(a.size), countStyle: .file))",
                          symbol: "paperclip")
            }
            .buttonStyle(.plain)
            .help(L("thread.openAttachment"))
            .contextMenu {
                Button(L("wiki.showInFinder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([state.engine.vault.url(for: a.file)])
                }
            }
        }
    }
}

/// "7 correos · último hace 2 h · Ana, Tú, Luis": a thread as one line (Contenido, Inicio, Timeline, the ficha).
enum ThreadText {
    static func caption(count: Int, last: Date?, senders: [String], now: Date = Date()) -> String {
        var parts = [L("thread.count", count)]
        if let last { parts.append(L("thread.last", ago(last, now: now))) }
        if !senders.isEmpty {
            let shown = senders.prefix(3).joined(separator: ", ")
            parts.append(senders.count > 3 ? shown + " +\(senders.count - 3)" : shown)
        }
        return parts.joined(separator: " · ")
    }

    static func caption(_ summary: TimelineEntry.ThreadSummary, last: Date?) -> String {
        caption(count: summary.messageCount, last: last, senders: summary.senders)
    }

    /// "hace 2 h" / "2 hr. ago" within a week; older, the day ("12 ago"): abbreviated months ("hace 2 m") read as minutes.
    static func ago(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return L("date.justNow") }
        if now.timeIntervalSince(date) > 6 * 86_400 { return Fmt.day(date) }
        let f = RelativeDateTimeFormatter()
        f.locale = Localizer.locale
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: now)
    }
}

extension ThreadConversationView {
    /// `<thread>` of `projects/<p>/wiki/emails/<thread>.md` (or any `wiki/emails/<thread>.md`); nil for other pages.
    static func threadKey(forPage path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[parts.count - 2] == "emails", parts[parts.count - 3] == "wiki",
              parts.last?.hasSuffix(".md") == true else { return nil }
        return ((parts.last ?? "") as NSString).deletingPathExtension
    }
}
