import AppKit
import BrainCore
import SwiftUI

/// "Prepararme" (CONTRACT §12.7, §15): first, instant cards from the vault (no Claude) — each attendee with the last
/// meeting they were in and their open tasks, my tasks in the project, the last decision. Then "Preparar con Claude"
/// streams Quiénes / Pendientes abiertos / Para preguntar + agenda, which stays visible (also while recording). Below, a
/// folded free chat "Pregúntame algo más…". Back and the meeting's actions stay pinned above the scroll.
struct MeetingPrepView: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    /// false next to the hero card, which already holds this meeting's Grabar / Unirme (§15.2: one Grabar on screen).
    var showsActions = true
    var onClose: (() -> Void)? = nil
    /// A page outside any project (people, global) to show in place; project pages open in their project.
    var onShowPage: (String) -> Void = { _ in }

    @ViewState private var data: MeetingPrepData?
    @ViewState private var prep: ChatModel
    @ViewState private var chat: ChatModel
    @ViewState private var showMore = false
    @ViewState private var showReconnect = false

    init(event: CalendarEvent, showsActions: Bool = true, onClose: (() -> Void)? = nil,
         onShowPage: @escaping (String) -> Void = { _ in }) {
        self.event = event
        self.showsActions = showsActions
        self.onClose = onClose
        self.onShowPage = onShowPage
        let models = MeetingPrepCache.models(for: event.id)
        _prep = ViewState(initialValue: models.prep)
        _chat = ViewState(initialValue: models.chat)
        _showMore = ViewState(initialValue: !models.chat.messages.isEmpty)
    }

    private var model: MeetingsModel { MeetingsModel.shared }
    /// The event's project, else the suggested one (prep only reads, so a good guess helps more than nothing).
    private var projectSlug: String? {
        model.projectSlug(for: event, state: state) ?? model.suggestion(for: event, state: state)?.projectSlug
    }
    private var basePath: String { projectSlug.map { "projects/\($0)/wiki/index.md" } ?? "index.md" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                localCards
                claudeSection
                freeChat
            }
            .padding(Brand.spacing.content)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) { toolbar }
        .background(Brand.color.surface)
        .task(id: "\(event.id)|\(projectSlug ?? "")|\(state.vaultRevision)") { await load() }
        .sheet(isPresented: $showReconnect) { ReconnectClaudeSheet() }
    }

    // MARK: Header

    /// Pinned: Atrás on the left, the meeting's action + Unirme on the right (icon-only when tight). Nothing pinned
    /// when there is neither (a prep next to the hero, pushed from the list: the stack's back is the way out).
    @ViewBuilder private var toolbar: some View {
        if onClose != nil || showsActions { toolbarBar }
    }

    private var toolbarBar: some View {
        let action = MeetingActionButton(event: event, showsPrepare: false, onPrepare: {}, onShowPage: onShowPage).fixedSize()   // fixed only inside ViewThatFits candidates: it measures true widths
        let join = MeetingJoinButton(event: event).fixedSize()
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                if let onClose {
                    Button(action: onClose) {
                        Label(L("prep.back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .keyboardShortcut(.cancelAction)
                }
                Spacer(minLength: 8)
                if showsActions {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { action; join }
                        HStack(spacing: 8) { action; join }.labelStyle(.iconOnly)
                    }
                }
            }
            .padding(.horizontal, Brand.spacing.content)
            .frame(minHeight: 48)
            Rectangle().fill(Brand.color.line).frame(height: 1)
        }
        .background(Brand.color.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("prep.eyebrow"))
                .font(Brand.font(11, .semibold))
                .tracking(0.6)
                .textCase(.uppercase)
                .foregroundStyle(Brand.color.accent)
                .lineLimit(1)
            Text(event.title)
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            Label(MeetingTimes.when(event), systemImage: "calendar")
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(2)
            MeetingProjectChip(event: event, placement: .prep, showsOffer: false)
                .padding(.top, 2)
            MeetingRuleOfferLine(event: event, placement: .prep)   // v0.4 rules: its own full-width row
        }
    }

    // MARK: Local cards (no Claude)

    @ViewBuilder private var localCards: some View {
        if let data, data.knowsNothing {
            // Nothing known about anyone: one row of people and one sentence, not a card per stranger.
            VStack(alignment: .leading, spacing: 10) {
                if !data.attendees.isEmpty {
                    sectionTitle(L("prep.who"), symbol: "person.2")
                    FlowLayout(spacing: 6) {
                        ForEach(data.attendees) { a in
                            HStack(spacing: 6) {
                                InitialsCircle(address: EmailAddress(name: a.name, email: a.email), size: 20,
                                               ring: Brand.color.cardAlt)
                                Text(a.name)
                                    .font(Brand.body)
                                    .foregroundStyle(Brand.color.text)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            .padding(.leading, 3)
                            .padding(.trailing, 10)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Brand.color.cardAlt))
                        }
                    }
                }
                Label(L(data.attendees.isEmpty ? "prep.knowNothing" : "prep.knowNoOne"), systemImage: "leaf")
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let data {
            VStack(alignment: .leading, spacing: 12) {
                if !data.attendees.isEmpty {
                    sectionTitle(L("prep.who"), symbol: "person.2")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 180), spacing: 10, alignment: .top)],
                              alignment: .leading, spacing: 10) {
                        ForEach(data.attendees) { attendeeCard($0) }
                    }
                }
                if !data.myTasks.isEmpty {
                    BrandCard {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L("prep.myTasks", state.projectName(data.projectSlug)), systemImage: "checklist")
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
                                .lineLimit(2)
                            ForEach(data.myTasks.prefix(5)) { taskLine($0) }
                            if data.myTasks.count > 5 {
                                Text(L("prep.more", data.myTasks.count - 5)).font(Brand.caption).foregroundStyle(Brand.color.text2)
                            }
                        }
                    }
                }
                if let decision = data.lastDecision {
                    BrandCard {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L("prep.lastDecision"), systemImage: "checkmark.seal")
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
                            Button { open(decision.path) } label: {
                                Text(decision.title).multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.color.accent)
                            if let date = decision.date {
                                Text(Fmt.relativeDay(date).meetingCapitalized).font(Brand.caption).foregroundStyle(Brand.color.text2)
                            }
                        }
                    }
                }
            }
        } else {
            HStack(alignment: .top, spacing: 10) {
                BrandLoader(size: 20)
                Text(L("prep.loading"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func attendeeCard(_ a: MeetingPrepData.Attendee) -> some View {
        BrandCard {
            HStack(alignment: .top, spacing: 10) {
                InitialsCircle(address: EmailAddress(name: a.name, email: a.email), size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Group {
                        if let path = a.personPath {
                            PersonLinkButton(name: a.name) { open(path) }
                        } else {
                            Text(a.name).foregroundStyle(Brand.color.text)
                        }
                    }
                    .font(Brand.font(13, .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    if let last = a.lastMeeting {
                        Button { open(last.path) } label: {
                            Text(L("prep.lastTime", last.title, last.date.map { Fmt.relativeDay($0) } ?? "—"))
                                .font(Brand.caption)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.color.accent)
                    } else {
                        // No fixedSize: inside a grid cell it measures at a narrower width than it is placed at and
                        // wraps early; a flexible frame lets the caption use the card's whole text column.
                        Text(a.personPath == nil ? L("prep.unknownPerson") : L("prep.firstMeeting"))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if !a.openTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("prep.theirTasks", a.openTasks.count))
                                .font(Brand.font(11, .semibold))
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                            ForEach(a.openTasks.prefix(3)) { taskLine($0, small: true) }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func taskLine(_ task: TaskItem, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle")
                .font(Brand.font(small ? 7 : 9))
                .foregroundStyle(Brand.color.text3)
            Text(task.text)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
            if let due = task.due {
                Label(Fmt.relativeDay(due), systemImage: "calendar")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(task.isOverdue ? Brand.color.danger : Brand.color.text2)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
        .font(small ? Brand.caption : Brand.body)
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(Brand.section)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
    }

    // MARK: Claude

    @ViewBuilder private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = prep.messages.last(where: { $0.role == .assistant }) {
                HStack(spacing: 8) {
                    sectionTitle(L("prep.briefing"), symbol: "sparkles")
                    Spacer(minLength: 8)
                    if !prep.isAsking {
                        Button { askClaude() } label: { Label(L("prep.again"), systemImage: "arrow.clockwise") }
                            .buttonStyle(.plain)
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.accent)
                            .lineLimit(1)
                    }
                }
                MessageView(message: answer, baseRelPath: basePath, onOpenPage: open,
                            onSave: { save(answer, in: prep) }, onReconnect: { showReconnect = true })
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).fill(Brand.color.accentSoft))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button { askClaude() } label: {
                        Label(L("prep.withClaudeButton"), systemImage: "sparkles")
                    }
                    .buttonStyle(.brandPrimary)
                    .controlSize(.large)
                    Text(L("prep.withClaudeHint"))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func askClaude() {
        guard !prep.isAsking else { return }
        prep.clear()
        let slug = projectSlug
        prep.draft = MeetingPrep.prepPrompt(event: event, language: state.config.uiLanguage,
                                            projectName: state.project(slug).map(\.name),
                                            repos: slug.map { state.engine.github.repos(project: $0).map(\.fullName) } ?? [])   // MARK: v0.4 github
        prep.ask(engine: state.engine, projectSlug: slug)
    }

    // MARK: Free chat

    private var freeChat: some View {
        DisclosureGroup(isExpanded: $showMore) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(chat.messages) { message in
                    MessageView(message: message, baseRelPath: basePath, onOpenPage: open,
                                onSave: { save(message, in: chat) }, onReconnect: { showReconnect = true })
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField(L("prep.askPlaceholder"), text: $chat.draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(Brand.body)
                        .lineLimit(1...4)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).fill(Brand.color.card))
                        .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                            .strokeBorder(Brand.color.line, lineWidth: 1))
                        .onSubmit { chat.ask(engine: state.engine, projectSlug: projectSlug) }
                    if chat.isAsking {
                        Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(Brand.font(22)) }
                            .buttonStyle(.plain)
                            .foregroundStyle(Brand.color.text2)
                            .help(L("chat.stop"))
                    } else {
                        Button { chat.ask(engine: state.engine, projectSlug: projectSlug) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(Brand.font(22))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.color.accent)
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(L("prep.askMore"), systemImage: "bubble.left.and.text.bubble.right")
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(Brand.motion.animation(fast: true)) { showMore.toggle() } }
        }
    }

    // MARK: Actions

    private func load() async {
        guard state.engineStarted else { data = MeetingPrepData(projectSlug: projectSlug); return }
        let result = await state.engine.meetingPrep(for: event, projectSlug: projectSlug)
        guard !Task.isCancelled else { return }
        data = result
    }

    private func open(_ path: String) {
        if !state.openProjectPage(path) { onShowPage(path) }
    }

    private func save(_ message: ChatMessage, in model: ChatModel) {
        let question = model === prep ? L("prep.saveQuestion", event.title) : message.question
        state.engine.saveAnswer(question: question, answer: message.text, projectSlug: projectSlug)
        if let i = model.messages.firstIndex(where: { $0.id == message.id }) { model.messages[i].saved = true }
    }
}

/// The prep and free chat of each event stay for the session (switching meetings or tabs keeps them).
@MainActor
enum MeetingPrepCache {
    private static var cache: [String: (prep: ChatModel, chat: ChatModel)] = [:]

    static func models(for eventId: String) -> (prep: ChatModel, chat: ChatModel) {
        if let models = cache[eventId] { return models }
        let models = (ChatModel(), ChatModel())
        cache[eventId] = models
        return models
    }
}

/// Left-aligned rows that wrap (attendee chips; v0.4 github: branch chips in ReposView). A subview wider than the row
/// is proposed the row's width, so a long chip truncates instead of overflowing.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = clampedSize(subviews[i], width: bounds.width)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    /// The subview's ideal size, its width capped at `width` (height re-measured at that width).
    private func clampedSize(_ subview: LayoutSubview, width: CGFloat) -> CGSize {
        let ideal = subview.sizeThatFits(.unspecified)
        guard width.isFinite, ideal.width > width else { return ideal }
        let fitted = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        return CGSize(width: min(fitted.width, width), height: fitted.height)
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = clampedSize(subviews[i], width: width)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = ([i], size.width, size.height)
            } else {
                current = (current.indices + [i], needed, max(current.height, size.height))
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
