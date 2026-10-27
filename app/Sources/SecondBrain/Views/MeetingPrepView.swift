import AppKit
import BrainCore
import SwiftUI

/// "Prepararme" (CONTRACT §12.7): first, instant cards from the vault (no Claude) — each attendee with the last meeting
/// they were in and their open tasks, my tasks in the project, the last decision. Then "Preparar con Claude" streams
/// Quiénes / Pendientes abiertos / Para preguntar + agenda, which stays visible (also while recording). Below, a folded
/// free chat "Pregúntame algo más…".
struct MeetingPrepView: View {
    @Environment(AppState.self) private var state
    let event: CalendarEvent
    var onClose: (() -> Void)? = nil
    /// A page outside any project (people, global) to show in place; project pages open in their project.
    var onShowPage: (String) -> Void = { _ in }

    @ViewState private var data: MeetingPrepData?
    @ViewState private var prep: ChatModel
    @ViewState private var chat: ChatModel
    @ViewState private var showMore = false
    @ViewState private var showReconnect = false

    init(event: CalendarEvent, onClose: (() -> Void)? = nil, onShowPage: @escaping (String) -> Void = { _ in }) {
        self.event = event
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
            .padding(22)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: "\(event.id)|\(projectSlug ?? "")|\(state.vaultRevision)") { await load() }
        .sheet(isPresented: $showReconnect) { ReconnectClaudeSheet() }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let onClose {
                    Button(action: onClose) {
                        Label(L("prep.back"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                MeetingActionButton(event: event, showsPrepare: false, onPrepare: {}, onShowPage: onShowPage)
                if let join = event.joinURL, JoinLink.isSafe(join) {
                    Button { NSWorkspace.shared.open(join) } label: { Label(L("meetings.join"), systemImage: "video.fill") }
                }
            }
            Text(L("prep.title", event.title))
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Label(MeetingTimes.when(event), systemImage: "calendar")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                MeetingProjectChip(event: event, placement: .prep)
            }
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
                                InitialsCircle(address: EmailAddress(name: a.name, email: a.email), size: 20)
                                Text(a.name).font(.callout).lineLimit(1)
                            }
                            .padding(.leading, 3)
                            .padding(.trailing, 10)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.05), in: Capsule())
                        }
                    }
                }
                Label(L(data.attendees.isEmpty ? "prep.knowNothing" : "prep.knowNoOne"), systemImage: "leaf")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let data {
            VStack(alignment: .leading, spacing: 12) {
                if !data.attendees.isEmpty {
                    sectionTitle(L("prep.who"), symbol: "person.2")
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(data.attendees) { attendeeCard($0) }
                    }
                }
                if !data.myTasks.isEmpty {
                    card {
                        VStack(alignment: .leading, spacing: 6) {
                            Label(L("prep.myTasks", state.projectName(data.projectSlug)), systemImage: "checklist")
                                .font(.subheadline.weight(.semibold))
                            ForEach(data.myTasks.prefix(5)) { taskLine($0) }
                            if data.myTasks.count > 5 {
                                Text(L("prep.more", data.myTasks.count - 5)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let decision = data.lastDecision {
                    card {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(L("prep.lastDecision"), systemImage: "checkmark.seal")
                                .font(.subheadline.weight(.semibold))
                            Button { open(decision.path) } label: {
                                Text(decision.title).multilineTextAlignment(.leading)
                            }
                            .buttonStyle(.link)
                            if let date = decision.date {
                                Text(Fmt.relativeDay(date).meetingCapitalized).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("prep.loading")).foregroundStyle(.secondary)
            }
        }
    }

    private func attendeeCard(_ a: MeetingPrepData.Attendee) -> some View {
        card {
            HStack(alignment: .top, spacing: 10) {
                InitialsCircle(address: EmailAddress(name: a.name, email: a.email), size: 32)
                VStack(alignment: .leading, spacing: 4) {
                    if let path = a.personPath {
                        Button(a.name) { open(path) }
                            .buttonStyle(.link)
                            .font(.body.weight(.medium))
                            .help(L("meetings.openPerson"))
                    } else {
                        Text(a.name).font(.body.weight(.medium))
                    }
                    if let last = a.lastMeeting {
                        Button { open(last.path) } label: {
                            Text(L("prep.lastTime", last.title, last.date.map { Fmt.relativeDay($0) } ?? "—"))
                                .font(.caption)
                                .multilineTextAlignment(.leading)
                        }
                        .buttonStyle(.link)
                    } else {
                        Text(a.personPath == nil ? L("prep.unknownPerson") : L("prep.firstMeeting"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !a.openTasks.isEmpty {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(L("prep.theirTasks", a.openTasks.count)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            ForEach(a.openTasks.prefix(3)) { taskLine($0, small: true) }
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func taskLine(_ task: TaskItem, small: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "circle").font(.system(size: small ? 7 : 9)).foregroundStyle(.secondary)
            Text(task.text).lineLimit(2)
            if let due = task.due {
                Text("📅 " + Fmt.relativeDay(due))
                    .foregroundStyle(task.isOverdue ? Color.red : .secondary)
                    .fixedSize()
            }
        }
        .font(small ? .caption : .callout)
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol).font(.headline)
    }

    private func card(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
    }

    // MARK: Claude

    @ViewBuilder private var claudeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let answer = prep.messages.last(where: { $0.role == .assistant }) {
                HStack {
                    sectionTitle(L("prep.withClaude"), symbol: "sparkles")
                    Spacer()
                    if !prep.isAsking {
                        Button { askClaude() } label: { Label(L("prep.again"), systemImage: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                }
                MessageView(message: answer, baseRelPath: basePath, onOpenPage: open,
                            onSave: { save(answer, in: prep) }, onReconnect: { showReconnect = true })
                    .padding(14)
                    .background(Color.accentColor.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Button { askClaude() } label: {
                        Label(L("prep.withClaudeButton"), systemImage: "sparkles")
                            .padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Text(L("prep.withClaudeHint")).font(.caption).foregroundStyle(.secondary)
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
                        .lineLimit(1...4)
                        .padding(8)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                        .onSubmit { chat.ask(engine: state.engine, projectSlug: projectSlug) }
                    if chat.isAsking {
                        Button { chat.stop() } label: { Image(systemName: "stop.circle.fill").font(.system(size: 22)) }
                            .buttonStyle(.plain)
                            .help(L("chat.stop"))
                    } else {
                        Button { chat.ask(engine: state.engine, projectSlug: projectSlug) } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 22))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label(L("prep.askMore"), systemImage: "bubble.left.and.text.bubble.right")
                .font(.callout.weight(.medium))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showMore.toggle() } }
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

/// Left-aligned rows that wrap (attendee chips; v0.4 github: branch chips in ReposView).
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
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [(indices: [Int], width: CGFloat, height: CGFloat)] {
        var rows: [(indices: [Int], width: CGFloat, height: CGFloat)] = []
        var current: (indices: [Int], width: CGFloat, height: CGFloat) = ([], 0, 0)
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
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
