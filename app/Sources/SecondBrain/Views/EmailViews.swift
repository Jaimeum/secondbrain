import AppKit
import BrainCore
import SwiftUI

/// "Agregar correo": paste an email (reads the clipboard if it looks like one), check what was understood,
/// pick its thread (suggested automatically) and its project, and save. Sized per §15.3 (ideal 760×520).
struct AddEmailSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let request: EmailRequest
    /// Text to start with instead of reading the clipboard.
    var initialText: String?

    private enum ThreadChoice: Hashable { case new, existing(String) }

    @ViewState private var text = ""
    @ViewState private var parsed: ParsedEmail?
    /// Every message of the paste, oldest first, when it held a whole conversation.
    @ViewState private var all: [ParsedEmail] = []
    @ViewState private var subject = ""
    @ViewState private var from = ""
    @ViewState private var to = ""
    @ViewState private var date = Date()
    @ViewState private var hasDate = false
    @ViewState private var matches: [ThreadMatch] = []
    @ViewState private var allThreads: [EmailThread] = []
    @ViewState private var choice: ThreadChoice = .new
    @ViewState private var userPickedThread = false
    @ViewState private var projectSlug: String?
    @ViewState private var error: String?
    @ViewState private var fromClipboard = false
    @ViewState private var parseTask: Task<Void, Never>?
    @ViewState private var matchTask: Task<Void, Never>?
    @ViewState private var matching = false   // thread suggestion in flight: saving now could start a duplicate thread
    // MARK: v0.4 routing — preselection by rule/default (§14.2) and the §14.3 offer after saving.
    @ViewState private var projectPicked = false
    @ViewState private var routedRule: RoutingRule?
    @ViewState private var routedByDefault = false
    @ViewState private var ruleOffer = RuleOffer()
    @ViewState private var saved = false

    private var fixedThread: EmailThread? {
        guard let key = request.threadKey else { return nil }
        return allThreads.first { $0.key == key }
    }

    private var chosenThread: EmailThread? {
        if let fixedThread { return fixedThread }
        guard case .existing(let key) = choice else { return nil }
        return allThreads.first { $0.key == key } ?? matches.first { $0.thread.key == key }?.thread
    }

    @ViewState private var ownerEmails: [String] = []

    /// Width of the label column of the fields, so Asunto/De/Para/Enviado and Proyecto line up across the cards.
    private static let labelWidth: CGFloat = 64
    @ViewState private var editingFrom = false
    @ViewState private var editingTo = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(fixedThread.map { L("email.nextTitle", $0.subject) } ?? L("email.title"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .padding([.horizontal, .top], 22)
                .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 18) {
                pasteArea.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                ScrollView {
                    details.padding(.trailing, 4).padding(.bottom, 4)
                }
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420)
            }
            .padding(.horizontal, 22)
            .frame(maxHeight: .infinity)

            Rectangle().fill(Brand.color.line).frame(height: 1).padding(.top, 14)
            footer
        }
        .font(Brand.body)
        .background(Brand.color.surface)
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity, minHeight: 440, idealHeight: 520, maxHeight: .infinity)
        .onAppear(perform: start)
        .onChange(of: text) { error = nil; scheduleParse() }
        .onChange(of: subject) { refreshMatches() }
        .onChange(of: from) { refreshMatches() }
    }

    /// Error on its own row; then Cancelar · Guardar, or (after saving with a manual project) the §14.3 offer and Listo.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if saved {
                // Saved: the offer stays until answered or timed out; the sheet closes only with Listo.
                HStack(spacing: 12) {
                    if ruleOffer.current != nil {
                        RuleOfferBar(offer: ruleOffer)
                    } else {
                        Label(L("mail.saved"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Brand.color.success)
                        Spacer(minLength: 0)
                    }
                    // While the offer asks, "Sí, siempre" is the one primary button and Return doesn't answer for it.
                    if ruleOffer.current?.phase == .asking {
                        Button(L("rules.offer.done")) { dismiss() }
                            .buttonStyle(.brandSecondary)
                    } else {
                        Button(L("rules.offer.done")) { dismiss() }
                            .buttonStyle(.brandPrimary)
                            .keyboardShortcut(.defaultAction)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    Button(L("common.cancel")) { dismiss() }
                        .buttonStyle(.brandSecondary)
                        .keyboardShortcut(.cancelAction)
                    Button(L("email.save"), action: save)
                        .buttonStyle(.brandPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil || matching || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .padding(16)
        .animation(Brand.motion.animation(), value: ruleOffer.current)
    }

    // MARK: Left: the pasted text

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(fromClipboard ? L("email.fromClipboard") : L("email.pasteHint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s; fromClipboard = true }
                } label: {
                    Label(L("email.pasteAgain"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.plain)
                .font(Brand.callout)
                .foregroundStyle(Brand.color.accent)
                .lineLimit(1)
                .layoutPriority(1)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .scrollContentBackground(.hidden)
                    .scrollIndicators(.never)   // no legacy scroller strip inside the box (light bar in dark mode)
                    .padding(8)
                if text.isEmpty {
                    Text(L("email.placeholder"))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text3)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                .strokeBorder(Brand.color.line, lineWidth: 1))
        }
    }

    // MARK: Right: what was understood

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            if all.count > 1 {
                Label(L("email.several", all.count), systemImage: "square.stack")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            }
            if parsed == nil {
                VStack(spacing: 10) {
                    Image(systemName: "envelope.open")
                        .font(Brand.font(34))
                        .foregroundStyle(Brand.color.text3)
                    Text(L("email.waiting"))
                        .foregroundStyle(Brand.color.text2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                understood
                threadBox
                projectRow.padding(.horizontal, 12)   // the same field column as inside the cards
            }
        }
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: 10, content: content)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.color.card, in: shape)
            .overlay(shape.strokeBorder(Brand.color.line, lineWidth: 1))
    }

    private func gridLabel(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(Brand.color.text2)
            .lineLimit(1)
            .frame(width: Self.labelWidth, alignment: .leading)
    }

    private var understood: some View {
        card {
            HStack(spacing: 8) {
                Label(L("email.understood"), systemImage: "envelope")
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isMine {
                    BrandChip(text: L("email.isMine"), symbol: "person.fill", active: true)
                        .help(L("email.isMineHelp"))
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    gridLabel(L("email.subject"))
                    TextField("", text: $subject).textFieldStyle(.roundedBorder)
                }
                GridRow {
                    gridLabel(L("email.from"))
                    fromCell
                }
                GridRow {
                    gridLabel(L("email.to"))
                    toCell
                }
                GridRow {
                    gridLabel(L("email.date"))
                    VStack(alignment: .leading, spacing: 4) {
                        DatePicker("", selection: Binding(get: { date }, set: { date = $0; hasDate = true }),
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .fixedSize()   // a system control of fixed width, alone in its cell
                        if !hasDate {
                            Label(L("email.noDate"), systemImage: "exclamationmark.triangle")
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.warning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    /// "De": the name over the address (two lines, readable), editable with the pencil; a plain field when the paste
    /// had no clear sender.
    @ViewBuilder private var fromCell: some View {
        let address = Self.address(from)
        if editingFrom || address.name == nil || address.email == nil {
            TextField("", text: $from).textFieldStyle(.roundedBorder)
        } else {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(address.name ?? "").foregroundStyle(Brand.color.text).lineLimit(1)
                    Text(address.email ?? "")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(from)
                Button { editingFrom = true } label: {
                    Image(systemName: "pencil").foregroundStyle(Brand.color.text2)
                }
                .buttonStyle(.plain)
                .help(L("email.editFrom"))
            }
        }
    }

    /// "Para": the names only ("Ana García, Luis Pérez"; addresses in the tooltip), editable with the pencil.
    @ViewBuilder private var toCell: some View {
        let names = to.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { part -> String in
                let address = Self.address(String(part))
                return address.name ?? address.email ?? String(part).trimmingCharacters(in: .whitespaces)
            }
            .filter { !$0.isEmpty }
        if editingTo || names.isEmpty {
            TextField("", text: $to).textFieldStyle(.roundedBorder)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(names.joined(separator: ", "))
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(to)
                Button { editingTo = true } label: {
                    Image(systemName: "pencil").foregroundStyle(Brand.color.text2)
                }
                .buttonStyle(.plain)
                .help(L("email.editTo"))
            }
        }
    }

    /// One choice, one line: "Se une a «X» · Cambiar ▾" or "Nuevo hilo · Unir a otro ▾". The menu lists "Nuevo hilo"
    /// and the suggested thread first, then the 15 most recent.
    @ViewBuilder private var threadBox: some View {
        card {
            Label(L("email.thread"), systemImage: "bubble.left.and.bubble.right")
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
            if let fixedThread {
                threadSummary(fixedThread)
            } else {
                let best = matches.first.flatMap { $0.score >= 0.5 ? $0 : nil }
                let chosen = chosenThread
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        threadChoiceText(chosen)
                        threadMenu(best: best, joined: chosen != nil)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        threadChoiceText(chosen)
                        threadMenu(best: best, joined: chosen != nil)
                    }
                }
                if let chosen {
                    Text(threadFacts(chosen) + (best?.thread.key == chosen.key ? " · " + (best?.reason ?? "") : ""))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let best {
                    // A possible match the user (or the 0.8 threshold) didn't take: say so, one click away in the menu.
                    Text(L("email.mightBe", best.thread.subject))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func threadChoiceText(_ chosen: EmailThread?) -> some View {
        Text(chosen.map { L("email.joins", $0.subject) } ?? L("email.newThread"))
            .font(Brand.callout)
            .foregroundStyle(Brand.color.text)
            .lineLimit(2)
            .truncationMode(.middle)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// "Cambiar ▾" / "Unir a otro ▾": Nuevo hilo, the suggestion, then the 15 most recent threads; ✓ on the current one.
    private func threadMenu(best: ThreadMatch?, joined: Bool) -> some View {
        let recent = allThreads.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }
            .filter { $0.key != best?.thread.key }.prefix(15)
        return Menu {
            threadButton(L("email.newThread"), selected: choice == .new) { choice = .new }
            if let best {
                Divider()
                threadButton("\(best.thread.subject) — \(state.projectName(best.thread.projectSlug))",
                             selected: choice == .existing(best.thread.key)) { choice = .existing(best.thread.key) }
            }
            if !recent.isEmpty {
                Divider()
                ForEach(Array(recent)) { thread in
                    threadButton("\(thread.subject) — \(state.projectName(thread.projectSlug))",
                                 selected: choice == .existing(thread.key)) { choice = .existing(thread.key) }
                }
            }
        } label: {
            Text(joined ? L("email.changeThread") : L("email.joinOther"))
                .font(Brand.callout)
                .foregroundStyle(Brand.color.accent)
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()   // a short, fixed label
        .disabled(allThreads.isEmpty && best == nil && !joined)
    }

    private func threadButton(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            userPickedThread = true
        } label: {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private func threadSummary(_ thread: EmailThread) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("«\(thread.subject)»")
                .font(Brand.callout)
                .foregroundStyle(Brand.color.text)
                .fixedSize(horizontal: false, vertical: true)
            Text(threadFacts(thread))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// "3 correos · último 24 oct · 🚀 Proyecto".
    private func threadFacts(_ thread: EmailThread) -> String {
        var parts = [L("email.messages", thread.messageCount)]
        if let last = thread.lastDate { parts.append(L("email.last", Fmt.day(last))) }
        parts.append(state.projectName(thread.projectSlug))
        return parts.joined(separator: " · ")
    }

    /// "Proyecto", in the same label column as the fields above. No "Formato" here (§15: the project's default applies).
    @ViewBuilder private var projectRow: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
            GridRow {
                gridLabel(L("menu.project"))
                if let thread = chosenThread {
                    // §14.2: a thread in a project keeps it; one in Sin asignar is moved by a rule (never by the default
                    // project), exactly as the engine does on save.
                    let rule = thread.projectSlug == nil ? inboxThreadRule : nil
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.projectName(rule?.projectSlug ?? thread.projectSlug))
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(1)
                            .help(L("email.projectLocked"))
                        if let rule {
                            Text(L("rules.mail.byRule", ruleLabel(rule.rule)))
                                .font(Brand.caption).foregroundStyle(Brand.color.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(L("email.projectLocked")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Picker("", selection: Binding(get: { projectSlug }, set: {
                            projectSlug = $0
                            projectPicked = true
                            routedRule = nil
                            routedByDefault = false
                        })) {
                            Text(L("inbox.title")).tag(String?.none)
                            Divider()
                            ForEach(state.projects) { project in
                                Text("\(project.emoji) \(project.name)").tag(Optional(project.slug))
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if let rule = routedRule {
                            Text(L("rules.mail.byRule", ruleLabel(rule)))
                                .font(Brand.caption).foregroundStyle(Brand.color.text2)
                                .fixedSize(horizontal: false, vertical: true)
                        } else if routedByDefault {
                            Text(L("rules.mail.byDefault")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                        }
                    }
                }
            }
        }
    }

    /// The rule that will move the chosen Sin asignar thread on save (no hit counted here).
    private var inboxThreadRule: RoutingDecision? {
        guard let email = edited() else { return nil }
        let preview = state.engine.routingPreview(.mail(email, ownerEmails: ownerEmails))
        guard let decision = preview.decision, preview.projectSlug != nil else { return nil }
        return decision
    }

    // MARK: Logic

    private var isMine: Bool {
        let addresses = Set(ownerEmails.map { $0.lowercased() })
        if let email = Self.address(from).email, addresses.contains(email) { return true }
        return parsed?.isFromOwner == true && from == (parsed?.from.map(Self.format) ?? "")
    }

    private func start() {
        allThreads = state.engine.emailThreads(projectSlug: nil)
        ownerEmails = state.engine.vault.ownerEmails()
        projectSlug = request.projectSlug ?? fixedThread?.projectSlug
        if let thread = fixedThread { choice = .existing(thread.key) }
        if let initialText {
            text = initialText
        } else if let clip = NSPasteboard.general.string(forType: .string), Self.looksLikeEmail(clip) {
            text = clip
            fromClipboard = true
        }
    }

    private func scheduleParse() {
        parseTask?.cancel()
        let pasted = text
        let owners = ownerEmails, ownerName = state.engine.vault.ownerName()
        parseTask = Task {
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            // Parsing a huge paste takes a moment: off the main thread.
            let result = await Task.detached(priority: .userInitiated) {
                (EmailParser.parse(pasted, ownerEmails: owners, ownerName: ownerName),
                 EmailParser.parseAll(pasted, ownerEmails: owners, ownerName: ownerName))
            }.value
            guard !Task.isCancelled else { return }
            apply(pasted, email: result.0, all: result.1)
        }
    }

    /// Parses (local, fast) and refreshes the editable fields and the thread suggestion.
    private func apply(_ pasted: String, email: ParsedEmail, all parsedAll: [ParsedEmail]) {
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            parsed = nil
            all = []
            matches = []
            return
        }
        parsed = email
        all = parsedAll
        editingFrom = false
        editingTo = false
        subject = email.subject ?? ""
        from = email.from.map(Self.format) ?? ""
        to = (email.to + email.cc).map(Self.format).joined(separator: ", ")
        if let d = email.date { date = d; hasDate = true } else { date = Date(); hasDate = false }
        refreshMatches()
    }

    private func refreshMatches() {
        guard request.threadKey == nil, let email = edited() else { return }
        matchTask?.cancel()
        matching = true
        // Reads every stored email: debounced (typing in Asunto/De) and off the main thread.
        matchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            let found = await state.engine.matchThreadsAsync(for: email).sorted { $0.score > $1.score }
            guard !Task.isCancelled else { return }
            matching = false
            matches = found
            if !userPickedThread {
                if let best = matches.first, best.score >= 0.8 { choice = .existing(best.thread.key) } else { choice = .new }
            }
            applyRouting(email)
        }
    }

    /// §14.2 preselection: no project asked for, none picked, no thread → the rule (or the default project) decides.
    private func applyRouting(_ email: ParsedEmail) {
        guard request.projectSlug == nil, !projectPicked, chosenThread == nil else { return }
        let preview = state.engine.routingPreview(.mail(email, ownerEmails: ownerEmails))
        projectSlug = preview.projectSlug
        routedRule = preview.decision?.rule
        routedByDefault = preview.decision == nil && preview.projectSlug != nil
    }

    /// The parsed email with the user's corrections applied.
    private func edited() -> ParsedEmail? {
        guard var email = parsed else { return nil }
        let s = subject.trimmingCharacters(in: .whitespaces)
        email.subject = s.isEmpty ? nil : s
        let f = from.trimmingCharacters(in: .whitespaces)
        email.from = f.isEmpty ? nil : Self.address(f)
        let original = Set((email.to + email.cc).map(Self.format))
        let typed = to.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if Set(typed) != original {
            email.to = typed.map(Self.address)
            email.cc = []
        }
        email.date = hasDate ? date : nil
        email.isFromOwner = isMine
        return email
    }

    private func save() {
        error = nil
        guard var email = edited() else { return }
        if email.date == nil { email.date = date }
        do {
            let thread = chosenThread
            let project = thread == nil ? projectSlug : nil
            // The picker already shows the §14.2 result: a new thread goes exactly there (an explicit Sin asignar is not
            // routed again); an existing thread follows the engine's precedence.
            let route = thread != nil
            let added: [SourceRecord]
            if all.count > 1 {
                // The whole conversation, oldest first; the newest one carries the user's corrections.
                var list = all
                list[list.count - 1] = email
                added = try state.engine.addEmails(list, threadKey: thread?.key, projectSlug: project, routeIfUnassigned: route)
                if added.isEmpty { throw EngineError.duplicateEmail(email.subject ?? "") }
            } else {
                added = [try state.engine.addEmail(email, threadKey: thread?.key, projectSlug: project, routeIfUnassigned: route)]
            }
            state.bumpVault()
            // MARK: v0.4 routing — the deciding rule counts a hit; a manual project offers a rule (§14.3).
            let subject = RoutingSubject.mail(email, ownerEmails: ownerEmails)
            if thread == nil, routedRule != nil, !projectPicked { _ = state.engine.routing.route(subject) }
            if thread == nil, let project, projectPicked || request.projectSlug != nil,
               project != state.engine.routingPreview(subject).projectSlug,
               ruleOffer.propose(subject, projectSlug: project, state: state) {
                saved = true
                return
            }
            dismiss()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    static func format(_ address: EmailAddress) -> String {
        switch (address.name, address.email) {
        case let (name?, email?): "\(name) <\(email)>"
        case let (name?, nil): name
        case let (nil, email?): email
        default: ""
        }
    }

    /// "Ana García <ana@acme.com>" / "ana@acme.com" / "Ana García".
    static func address(_ text: String) -> EmailAddress {
        let t = text.trimmingCharacters(in: .whitespaces)
        if let m = t.firstMatch(of: #/^(.*?)\s*<([^>]+)>$/#) {
            let name = String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            return EmailAddress(name: name.isEmpty ? nil : name, email: String(m.2).lowercased())
        }
        if t.contains("@"), !t.contains(" ") { return EmailAddress(name: nil, email: t.lowercased()) }
        return EmailAddress(name: t, email: nil)
    }

    /// Clipboard text that has email headers (From/De + Subject/Asunto/Date…), so we can prefill.
    static func looksLikeEmail(_ text: String) -> Bool {
        guard text.count > 20, text.count < 400_000 else { return false }
        let head = String(text.prefix(4000)).lowercased()
        let fromHeader = head.contains("from:") || head.contains("de:") || head.contains("\nfrom ") || head.contains("<") && head.contains("@")
        let other = ["subject:", "asunto:", "date:", "fecha:", "enviado:", "sent:", "to:", "para:", "para mí", "to me"]
            .contains { head.contains($0) }
        return fromHeader && other && head.contains("@")
    }
}

/// One email of a thread as stored in the vault (raw file frontmatter + body).
struct ThreadMessage: Identifiable {
    let source: SourceRecord
    var from: String
    var to: String
    var date: Date
    var body: String
    var quoted: String?
    var id: String { source.id }

    /// Reads `projects/<p>/raw/emails/<thread>/<file>.md`: frontmatter, body, then `## Historial citado`.
    static func load(_ source: SourceRecord, vault: VaultStore) -> ThreadMessage {
        var message = ThreadMessage(source: source, from: "", to: "", date: source.timelineDate, body: "", quoted: nil)
        guard let raw = source.rawPath, let text = try? vault.read(raw) else { return message }
        var body = text
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            let front = text[text.index(text.startIndex, offsetBy: 3)..<end.lowerBound]
            for line in front.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'[]"))
                value = value.replacingOccurrences(of: "\", \"", with: ", ").replacingOccurrences(of: "\"", with: "")
                switch key {
                case "from": message.from = value
                case "to": message.to = value
                default: break
                }
            }
            body = String(text[end.upperBound...])
            if let nl = body.firstIndex(of: "\n") { body = String(body[body.index(after: nl)...]) }
        }
        for marker in ["\n## Historial citado", "\n## Quoted history"] {
            if let range = body.range(of: marker) {
                var quoted = String(body[range.upperBound...])
                if let nl = quoted.firstIndex(of: "\n") { quoted = String(quoted[quoted.index(after: nl)...]) }
                message.quoted = quoted.trimmingCharacters(in: .whitespacesAndNewlines)
                body = String(body[..<range.lowerBound])
                break
            }
        }
        message.body = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return message
    }
}

/// A thread of emails in the order they were SENT: who wrote to whom, what was new, quoted history folded away.
struct ThreadSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let threadKey: String
    var onOpenPage: ((String) -> Void)?

    @ViewState private var thread: EmailThread?
    @ViewState private var messages: [ThreadMessage] = []
    @ViewState private var loaded = false
    @ViewState private var wikiPage: String?
    @ViewState private var export: ExportRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            if !loaded {
                BrandLoader(size: 24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                EmptyStateView(symbol: "envelope", title: L("thread.empty"), message: "")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            MessageCard(content: .init(message), startExpanded: index == messages.count - 1)
                        }
                    }
                    .padding(Brand.spacing.content)
                }
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack(spacing: 8) {
                Button {
                    dismiss()
                    // Let this sheet close before the email sheet opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        state.requestEmail(threadKey: threadKey, projectSlug: thread?.projectSlug)
                    }
                } label: {
                    Label(L("thread.addNext"), systemImage: "plus")
                }
                .buttonStyle(.brandSecondary)
                Spacer(minLength: 8)
                Button(L("common.close")) { dismiss() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .font(Brand.body)
        .background(Brand.color.surface)
        .frame(minWidth: 560, idealWidth: 680, maxWidth: .infinity, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        .task(id: state.vaultRevision) { await load() }
        .sheet(item: $export) { ExportSheet(request: $0) }
    }

    /// Title and facts; "Resumen del hilo" · "Exportar" on the right when they fit, else below the title.
    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope")
                .font(Brand.font(16))
                .foregroundStyle(Brand.color.accent)
                .frame(width: 36, height: 36)
                .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    titleBlock
                    Spacer(minLength: 8)
                    headerButtons
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleBlock
                    headerButtons
                }
            }
        }
        .padding(Brand.spacing.content)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(thread?.subject ?? threadKey)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let thread {
                Text(facts(thread)).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
                if !thread.participants.isEmpty {
                    Text(thread.participants.map(\.display).joined(separator: ", "))
                        .font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(2)
                }
            }
        }
    }

    private var headerButtons: some View {
        HStack(spacing: 8) {
            if let wikiPage, let onOpenPage {
                Button {
                    dismiss()
                    onOpenPage(wikiPage)
                } label: {
                    Label(L("thread.openSummary"), systemImage: "doc.text")
                }
                .buttonStyle(.brandSecondary)
            }
            Button {
                if let wikiPage {
                    export = ExportRequest(target: .page(path: wikiPage, title: thread?.subject ?? threadKey))
                } else if let last = messages.last?.source {
                    export = ExportRequest(target: .source(last))
                }
            } label: {
                Label(L("export.button"), systemImage: "square.and.arrow.up")
            }
            .buttonStyle(.brandSecondary)
            .disabled(wikiPage == nil && messages.isEmpty)
        }
        .fixedSize()   // two short, fixed labels
    }

    private func facts(_ thread: EmailThread) -> String {
        var parts = [L("email.messages", thread.messageCount)]
        if let first = thread.firstDate, let last = thread.lastDate {
            parts.append(Calendar.current.isDate(first, inSameDayAs: last) ? Fmt.day(first) : "\(Fmt.day(first)) – \(Fmt.day(last))")
        }
        parts.append(state.projectName(thread.projectSlug))
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard state.engineStarted else { return }
        let engine = state.engine
        thread = engine.emailThreads(projectSlug: nil).first { $0.key == threadKey }
        let sources = engine.emails(inThread: threadKey)
        let vault = engine.vault
        let slug = thread?.projectSlug
        let key = threadKey
        let (loadedMessages, page) = await Task.detached { () -> ([ThreadMessage], String?) in
            let list = sources.map { ThreadMessage.load($0, vault: vault) }.sorted { $0.date < $1.date }
            var page: String?
            if let slug {
                let path = "projects/\(slug)/wiki/emails/\(key).md"
                if FileManager.default.fileExists(atPath: vault.url(for: path).path) { page = path }
            }
            return (list, page)
        }.value
        messages = loadedMessages
        wikiPage = page
        loaded = true
    }
}

/// What a `MessageCard` shows: a stored email of the vault (thread sheet) or a fetched one (Correo's "Hilo · N").
struct MessageCardContent {
    var from: String          // "Ana García <ana@acme.com>"
    var to: String            // comma-separated, same format
    var date: Date
    var dateHelp: String?
    var body: String
    var quoted: String?

    init(_ message: ThreadMessage) {
        from = message.from
        to = message.to
        date = message.date
        dateHelp = L("thread.sentAdded", Fmt.dayTime(message.date), Fmt.dayTime(message.source.createdAt))
        body = message.body
        quoted = message.quoted
    }

    init(_ message: MailMessageFull) {
        let split = MailImport.splitBody(message.bodyText)
        from = AddEmailSheet.format(message.summary.from)
        to = (message.summary.to + message.cc).map(AddEmailSheet.format).joined(separator: ", ")
        date = message.summary.date
        dateHelp = nil
        body = split.body
        quoted = split.quoted
    }
}

/// One email of a thread: sender (name only), "Para: …", one timestamp (when it was sent; when it was added is in
/// the tooltip), the new text, and the quoted history folded.
struct MessageCard: View {
    let content: MessageCardContent
    let startExpanded: Bool

    @ViewState private var expanded: Bool?
    @ViewState private var showQuoted = false

    private var message: MessageCardContent { content }

    private var sender: String {
        guard !message.from.isEmpty else { return L("thread.unknownSender") }
        let address = AddEmailSheet.address(message.from)
        return address.name ?? address.email ?? message.from
    }

    /// "Laura Méndez, Ana García" (names only; the full addresses are in the tooltip).
    private var recipients: String {
        message.to.split(separator: ",").map { part in
            let address = AddEmailSheet.address(String(part))
            return address.name ?? address.email ?? String(part)
        }.joined(separator: ", ")
    }

    var body: some View {
        let isExpanded = expanded ?? startExpanded
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(Brand.motion.animation(fast: true)) { expanded = !isExpanded }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(Brand.font(10, .semibold))
                        .foregroundStyle(Brand.color.text2)
                        .frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sender)
                            .font(Brand.font(13, .semibold))
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(1)
                            .help(message.from)
                        if !message.to.isEmpty {
                            Text(L("mail.to", recipients))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .help(message.to)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Text(Fmt.dayTime(message.date))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .help(message.dateHelp ?? Fmt.dayTime(message.date))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                Text(message.body.isEmpty ? L("thread.emptyBody") : message.body)
                    .foregroundStyle(Brand.color.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 20)
                if let quoted = message.quoted, !quoted.isEmpty {
                    DisclosureGroup(isExpanded: $showQuoted) {
                        Text(quoted)
                            .foregroundStyle(Brand.color.text2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    } label: {
                        Text(L("mail.quoted")).font(Brand.callout).foregroundStyle(Brand.color.text2)
                    }
                    .padding(.leading, 20)
                }
            } else if !message.body.isEmpty {
                Text(message.body.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .foregroundStyle(Brand.color.text2)
                    .padding(.leading, 20)
            }
        }
        .font(Brand.body)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.card, in: shape)
        .overlay(shape.strokeBorder(Brand.color.line, lineWidth: 1))
    }
}

/// "Tus correos": the owner's addresses, so emails they sent are marked as theirs (people/README.md).
struct OwnerEmailsField: View {
    @Environment(AppState.self) private var state
    var showsHint = true
    @ViewState private var text = ""
    @ViewState private var loaded: String?
    @ViewState private var vault: VaultStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("owner.emails"), text: $text, prompt: Text(L("owner.emailsPlaceholder")))
                .onSubmit(save)
            if showsHint {
                Text(L("owner.emailsHint")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.engineStarted) { load() }
        .onDisappear(perform: save)
    }

    private func load() {
        guard vault == nil, state.engineStarted else { return }
        let current = state.engine.vault
        vault = current
        let stored = current.ownerEmails().joined(separator: ", ")
        text = stored
        loaded = stored
    }

    private func save() {
        guard let vault, text != loaded else { return }
        let emails = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
        do {
            try vault.setOwnerEmails(emails)
            loaded = text
        } catch {}
    }
}
