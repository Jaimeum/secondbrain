import AppKit
import BrainCore
import SwiftUI

/// "Agregar correo": paste an email (reads the clipboard if it looks like one), check what was understood,
/// pick its thread (suggested automatically), its project and format, and save.
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
    @ViewState private var templateId: String?
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(fixedThread.map { L("email.nextTitle", $0.subject) } ?? L("email.title"))
                    .font(.title2.weight(.semibold)).lineLimit(1)
                Spacer()
                Button {
                    if let s = NSPasteboard.general.string(forType: .string) { text = s; fromClipboard = true }
                } label: {
                    Label(L("email.pasteAgain"), systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
            }
            .padding([.horizontal, .top], 22)
            .padding(.bottom, 12)

            HStack(alignment: .top, spacing: 18) {
                pasteArea.frame(minWidth: 320)
                ScrollView {
                    details.padding(.trailing, 4)
                }
                .frame(width: 360)
            }
            .padding(.horizontal, 22)

            Divider().padding(.top, 14)
            if saved {
                // Saved: the rule offer stays here ~10 s (non-modal); the sheet closes when it goes away.
                HStack(spacing: 12) {
                    RuleOfferBar(offer: ruleOffer)
                    Button(L("rules.offer.done")) { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(16)
            } else {
                HStack {
                    if let error {
                        Text(error).foregroundStyle(.red).font(.callout).lineLimit(3)
                    }
                    Spacer()
                    Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("email.save"), action: save)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(parsed == nil || matching || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .padding(16)
            }
        }
        .onChange(of: ruleOffer.current == nil) { _, gone in if gone && saved { dismiss() } }
        .frame(width: 820, height: 640)
        .onAppear(perform: start)
        .onChange(of: text) { scheduleParse() }
        .onChange(of: subject) { refreshMatches() }
        .onChange(of: from) { refreshMatches() }
    }

    // MARK: Left: the pasted text

    private var pasteArea: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(fromClipboard ? L("email.fromClipboard") : L("email.pasteHint"))
                .font(.callout).foregroundStyle(.secondary)
            ZStack(alignment: .topLeading) {
                TextEditor(text: $text)
                    .font(.system(.callout, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                if text.isEmpty {
                    Text(L("email.placeholder"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .padding(14)
                        .allowsHitTesting(false)
                }
            }
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    // MARK: Right: what was understood

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            if all.count > 1 {
                Label(L("email.several", all.count), systemImage: "square.stack")
                    .font(.callout)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if parsed == nil {
                VStack(spacing: 10) {
                    Image(systemName: "envelope.open").font(.system(size: 34, weight: .light)).foregroundStyle(.tertiary)
                    Text(L("email.waiting")).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 60)
            } else {
                understood
                threadBox
                VStack(alignment: .leading, spacing: 10) {
                    projectPicker
                    TemplatePicker(scope: .email, selection: $templateId, projectSlug: chosenThread?.projectSlug ?? projectSlug)
                }
            }
        }
    }

    private var understood: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L("email.understood"), systemImage: "envelope.fill").font(.headline)
                Spacer()
                if isMine {
                    Chip(text: L("email.isMine"), tint: .accentColor, symbol: "person.fill")
                        .help(L("email.isMineHelp"))
                }
            }
            field(L("email.subject"), text: $subject)
            field(L("email.from"), text: $from)
            field(L("email.to"), text: $to)
            HStack {
                Text(L("email.date")).frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
                DatePicker("", selection: Binding(get: { date }, set: { date = $0; hasDate = true }),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .fixedSize()
                Spacer()
            }
            if !hasDate {
                Label(L("email.noDate"), systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("email.dateHint", Fmt.relativeDay(date))).font(.caption).foregroundStyle(.secondary)
            }
            if ownerEmails.isEmpty {
                Text(L("email.noOwnerEmails")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        HStack {
            Text(label).frame(width: 64, alignment: .leading).foregroundStyle(.secondary)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    @ViewBuilder private var threadBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(L("email.thread"), systemImage: "bubble.left.and.bubble.right").font(.headline)
            if let fixedThread {
                threadSummary(fixedThread, reason: nil)
            } else {
                if let best = matches.first, best.score >= 0.5 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(best.score >= 0.8 ? L("email.looksLike", best.thread.subject) : L("email.mightBe", best.thread.subject))
                            .font(.callout.weight(.medium))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(threadFacts(best.thread) + " · " + best.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("", selection: Binding(get: { choice }, set: { choice = $0; userPickedThread = true })) {
                    if let best = matches.first, best.score >= 0.5 {
                        Text(L("email.addToThread")).tag(ThreadChoice.existing(best.thread.key))
                    }
                    Text(L("email.newThread")).tag(ThreadChoice.new)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                Menu(otherThreadTitle) {
                    ForEach(allThreads.sorted { ($0.lastDate ?? .distantPast) > ($1.lastDate ?? .distantPast) }) { thread in
                        Button("\(thread.subject) — \(state.projectName(thread.projectSlug))") {
                            choice = .existing(thread.key)
                            userPickedThread = true
                        }
                    }
                }
                .disabled(allThreads.isEmpty)
                .fixedSize()
                if let thread = chosenThread, thread.key != matches.first?.thread.key || (matches.first?.score ?? 0) < 0.5 {
                    threadSummary(thread, reason: nil)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private var otherThreadTitle: String {
        if case .existing(let key) = choice, key != matches.first?.thread.key, let t = allThreads.first(where: { $0.key == key }) {
            return L("email.otherThreadChosen", t.subject)
        }
        return L("email.otherThread")
    }

    private func threadSummary(_ thread: EmailThread, reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("«\(thread.subject)»").font(.callout.weight(.medium))
            Text(threadFacts(thread)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// "3 correos · último 24 oct · 📁 Proyecto".
    private func threadFacts(_ thread: EmailThread) -> String {
        var parts = [thread.messageCount == 1 ? L("email.oneMessage") : L("email.messages", thread.messageCount)]
        if let last = thread.lastDate { parts.append(L("email.last", Fmt.day(last))) }
        parts.append(state.projectName(thread.projectSlug))
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var projectPicker: some View {
        if let thread = chosenThread {
            LabeledContent(L("menu.project")) {
                Text(state.projectName(thread.projectSlug)).foregroundStyle(.secondary)
            }
            .help(L("email.projectLocked"))
        } else {
            Picker(L("menu.project"), selection: Binding(get: { projectSlug }, set: {
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
            if let rule = routedRule {
                Text(L("rules.mail.byRule", RoutingStore.displayName(for: rule, projects: state.projects, language: Localizer.language)))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if routedByDefault {
                Text(L("rules.mail.byDefault")).font(.caption).foregroundStyle(.secondary)
            }
        }
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
        guard var email = edited() else { return }
        if email.date == nil { email.date = date }
        do {
            let thread = chosenThread
            let project = thread == nil ? projectSlug : nil
            // The picker already shows the §14.2 result: a new thread goes exactly there (an explicit Sin asignar is not
            // routed again); an existing thread follows the engine's precedence.
            let route = thread != nil
            var added: [SourceRecord]
            if all.count > 1 {
                // The whole conversation, oldest first; the newest one carries the user's corrections.
                var list = all
                list[list.count - 1] = email
                added = try state.engine.addEmails(list, threadKey: thread?.key, projectSlug: project, routeIfUnassigned: route)
                if added.isEmpty { throw EngineError.duplicateEmail(email.subject ?? "") }
            } else {
                added = [try state.engine.addEmail(email, threadKey: thread?.key, projectSlug: project, routeIfUnassigned: route)]
            }
            if let templateId {
                for source in added { state.engine.setTemplate(sourceId: source.id, templateId: templateId) }
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
            Divider()
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                EmptyStateView(symbol: "envelope", title: L("thread.empty"), message: "")
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                            MessageCard(message: message, number: index + 1, startExpanded: index == messages.count - 1)
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack {
                Button {
                    dismiss()
                    // Let this sheet close before the email sheet opens.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        state.requestEmail(threadKey: threadKey, projectSlug: thread?.projectSlug)
                    }
                } label: {
                    Label(L("thread.addNext"), systemImage: "plus.circle")
                }
                Spacer()
                Button(L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
        .frame(width: 720, height: 640)
        .task(id: state.vaultRevision) { await load() }
        .sheet(item: $export) { ExportSheet(request: $0) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "envelope.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.accentColor)
                .frame(width: 36, height: 36)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 3) {
                Text(thread?.subject ?? threadKey).font(.title3.weight(.semibold)).lineLimit(2)
                if let thread {
                    Text(facts(thread)).font(.caption).foregroundStyle(.secondary)
                    if !thread.participants.isEmpty {
                        Text(thread.participants.map(\.display).joined(separator: ", "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            Spacer()
            if let wikiPage, let onOpenPage {
                Button {
                    dismiss()
                    onOpenPage(wikiPage)
                } label: {
                    Label(L("thread.openSummary"), systemImage: "doc.text")
                }
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
            .disabled(wikiPage == nil && messages.isEmpty)
        }
        .padding(20)
    }

    private func facts(_ thread: EmailThread) -> String {
        var parts = [thread.messageCount == 1 ? L("email.oneMessage") : L("email.messages", thread.messageCount)]
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

private struct MessageCard: View {
    let message: ThreadMessage
    let number: Int
    let startExpanded: Bool

    @ViewState private var expanded: Bool?
    @ViewState private var showQuoted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                expanded = !(expanded ?? startExpanded)
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: (expanded ?? startExpanded) ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(message.from.isEmpty ? L("thread.unknownSender") : message.from).font(.body.weight(.semibold))
                            if !message.to.isEmpty {
                                Text("→ \(message.to)").foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        Text(L("thread.sentAdded", Fmt.dayTime(message.date), Fmt.dayTime(message.source.createdAt)))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("#\(number)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded ?? startExpanded {
                Text(message.body.isEmpty ? L("thread.emptyBody") : message.body)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
                if let quoted = message.quoted, !quoted.isEmpty {
                    DisclosureGroup(isExpanded: $showQuoted) {
                        Text(quoted)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    } label: {
                        Text(L("thread.quoted")).font(.callout).foregroundStyle(.secondary)
                    }
                    .padding(.leading, 20)
                }
            } else if !message.body.isEmpty {
                Text(message.body.replacingOccurrences(of: "\n", with: " "))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 20)
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
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
                Text(L("owner.emailsHint")).font(.caption).foregroundStyle(.secondary)
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
