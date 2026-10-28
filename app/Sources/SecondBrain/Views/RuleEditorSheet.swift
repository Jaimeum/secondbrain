import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.4): a rule as one sentence built with menus —
// «Cuando [el remitente ▾] [es ▾] [________] (+ y también…) → mandar a [🚀 Acme ▾]» — plus "Probar" against the latest
// mail and this week's meetings.

struct RuleEditorSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let store: RoutingStore
    let isNew: Bool
    /// The messages on screen (Correo), for "Probar". Empty → the cached list or a fresh first page per account.
    var mail: [MailMessageSummary] = []
    /// Snapshots: run "Probar" right away.
    var testOnAppear = false
    /// v0.7 backfill: a new rule was saved (the rules panel then offers "Traer anteriores", §17.6).
    var onCreated: ((RoutingRule) -> Void)?

    @ViewState private var draft: RoutingRule
    @ViewState private var showIssues = false
    @ViewState private var error: String?
    @ViewState private var test: RuleTestResult?
    @ViewState private var testing = false
    @ViewState private var testTask: Task<Void, Never>?
    @FocusState private var focused: Int?

    init(store: RoutingStore, item: RuleEditorItem, mail: [MailMessageSummary] = [], testOnAppear: Bool = false,
         onCreated: ((RoutingRule) -> Void)? = nil) {
        self.onCreated = onCreated
        self.store = store
        self.isNew = item.isNew
        self.mail = mail
        self.testOnAppear = testOnAppear
        _draft = ViewState(initialValue: item.rule)
    }

    private var lang: String { state.config.uiLanguage }
    private var isValid: Bool { RuleValidation.isValid(draft.conditions) }
    private var generatedName: String {
        RoutingStore.generatedName(conditions: RuleValidation.cleaned(draft).conditions,
                                   projectLabel: RoutingStore.projectLabel(draft.projectSlug, projects: state.projects, language: lang),
                                   language: lang)
    }
    private var duplicatesExisting: Bool {
        isValid && store.rules.contains { $0.id != draft.id && $0.hasSameConditions(as: draft) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isNew ? L("rules.editor.newTitle") : L("rules.editor.editTitle"))
                            .font(Brand.title)
                            .foregroundStyle(Brand.color.text)
                        Text(L("rules.editor.subtitle")).foregroundStyle(Brand.color.text2)
                    }
                    sentence
                    options
                    tester
                }
                .padding(Brand.spacing.contentWide)
            }
            .brandScrollEdgeFade(.bottom)
            BrandSheetFooter {
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.danger)
                        .lineLimit(2)
                }
                Spacer()
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
                Button(L("rules.editor.save")) { save() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                    .disabled(showIssues && !isValid)
            }
        }
        .frame(minWidth: 580, idealWidth: 620, minHeight: 440, idealHeight: 520)
        .background(Brand.color.surface)
        .onAppear {
            if draft.conditions.isEmpty { draft.conditions = [RuleCondition(field: .senderEmail, op: .is, value: "")] }
            if testOnAppear { runTest() } else if isNew { focused = 0 }
        }
        .onChange(of: draft.conditions) {
            // A result (or a test still loading) is about conditions that are no longer the ones on screen.
            test = nil
            testTask?.cancel()
            testing = false
        }
        .onDisappear { testTask?.cancel() }
    }

    // MARK: Sentence

    /// Width of the "Cuando" / "y" / "mandar a" column; the value field and hints line up after it.
    private static let labelWidth: CGFloat = 76
    private static let indent: CGFloat = labelWidth + 8

    private var sentence: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(draft.conditions.indices), id: \.self) { i in
                conditionRow(i)
            }
            Button {
                draft.conditions.append(RuleCondition(field: .subject, op: .contains, value: ""))
                focused = draft.conditions.count - 1
            } label: {
                Label(L("rules.editor.and"), systemImage: "plus")
            }
            .buttonStyle(.settingsLink)
            .padding(.leading, Self.indent)
            HStack(spacing: 8) {
                Text(L("rules.editor.sendTo"))
                    .foregroundStyle(Brand.color.text2)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                BrandMenuPicker(title: projectTitle, selection: projectBinding, maxWidth: 240) {
                    ForEach(state.projects) { p in Text("\(p.emoji) \(p.name)").tag(p.slug) }
                    if !state.projects.isEmpty { Divider() }
                    Text(L("rules.unassigned")).tag("")
                    if let slug = draft.projectSlug, state.project(slug) == nil { Text(slug).tag(slug) }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.lineSoft))
    }

    /// What the "mandar a" pull-down shows: the project, "Sin asignar", or a slug that no longer exists.
    private var projectTitle: String {
        guard let slug = draft.projectSlug, !slug.isEmpty else { return L("rules.unassigned") }
        if let p = state.project(slug) { return "\(p.emoji) \(p.name)" }
        return slug
    }

    /// «Cuando [campo ▾] [operador ▾]» on one line, the value on its own full-width line under it (so an address
    /// like carlos.ruiz@contoso.com always fits), then the hint.
    private func conditionRow(_ i: Int) -> some View {
        let c = draft.conditions.indices.contains(i) ? draft.conditions[i] : RuleCondition(field: .subject, op: .contains, value: "")
        let issue = RuleValidation.issue(c)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(i == 0 ? L("rules.editor.when") : L("rules.editor.andAlso"))
                    .foregroundStyle(Brand.color.text2)
                    .frame(width: Self.labelWidth, alignment: .trailing)
                BrandMenuPicker(title: Self.fieldLabel(c.field), selection: fieldBinding(i), maxWidth: 200) {
                    Section(L("rules.editor.section.mail")) {
                        ForEach([RuleField.senderEmail, .senderDomain, .senderName, .recipient, .subject], id: \.self) {
                            Text(Self.fieldLabel($0)).tag($0)
                        }
                    }
                    Section(L("rules.editor.section.meetings")) {
                        ForEach([RuleField.organizerEmail, .attendeeEmail, .attendeeDomain, .title], id: \.self) {
                            Text(Self.fieldLabel($0)).tag($0)
                        }
                    }
                    Section(L("rules.editor.section.both")) {
                        Text(Self.fieldLabel(.anyText)).tag(RuleField.anyText)
                    }
                }
                BrandMenuPicker(title: Self.opLabel(c.op), selection: opBinding(i), maxWidth: 120) {
                    ForEach(RuleOperator.allCases, id: \.self) { Text(Self.opLabel($0)).tag($0) }
                }
                Spacer(minLength: 0)
                if draft.conditions.count > 1 {
                    Button {
                        draft.conditions.remove(at: i)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.brandIcon)
                    .help(L("rules.editor.removeCondition"))
                }
            }
            TextField(Self.placeholder(c.field, c.op), text: valueBinding(i))
                .focused($focused, equals: i)
                .brandField()
                .onSubmit { save() }
                .padding(.leading, Self.indent)
            Group {
                if showIssues, let issue {
                    Text(issue == .empty ? L("rules.editor.issue.empty") : L("rules.editor.issue.spaces"))
                        .foregroundStyle(Brand.color.warning)
                } else {
                    Text(Self.fieldHint(c.field)).foregroundStyle(Brand.color.text2)
                }
            }
            .font(Brand.caption)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.indent)
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("rules.editor.name")).font(Brand.callout).foregroundStyle(Brand.color.text)
                TextField(generatedName, text: $draft.name)
                    .brandField()
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle(L("rules.editor.autoAdd"), isOn: $draft.autoAddMail)
                    .toggleStyle(.brandCheckbox)
                Text(L("rules.editor.autoAddHint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
            if duplicatesExisting {
                Label(L("rules.editor.duplicate"), systemImage: "info.circle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
            }
        }
    }

    // MARK: Probar

    private var tester: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button { runTest() } label: {
                    Label(L("rules.editor.test"), systemImage: "play")
                }
                .buttonStyle(.brandSecondary)
                .disabled(!isValid || testing)
                if testing { BrandLoader(size: 16) }
                if let test {
                    Text(Self.summary(test)).font(Brand.callout).foregroundStyle(Brand.color.text)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !testing {
                    Text(L("rules.editor.testHint")).font(Brand.caption).foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let test, !(test.mails.isEmpty && test.events.isEmpty) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(examples(test), id: \.id) { line in
                        HStack(spacing: 8) {
                            Image(systemName: line.symbol).foregroundStyle(Brand.color.text3).frame(width: 16)
                            Text(line.title).foregroundStyle(Brand.color.text).lineLimit(1)
                            Text(line.detail).foregroundStyle(Brand.color.text2).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                    let more = test.mails.count + test.events.count - 5
                    if more > 0 {
                        Text(L("rules.editor.testMore", more)).font(Brand.caption).foregroundStyle(Brand.color.text2).padding(.leading, 24)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            }
        }
    }

    private struct Example { let id: String; let symbol: String; let title: String; let detail: String }

    private func examples(_ t: RuleTestResult) -> [Example] {
        let mails = t.mails.map { Example(id: "m" + $0.id, symbol: "envelope", title: $0.from.display,
                                          detail: $0.subject.isEmpty ? L("rules.editor.noSubject") : $0.subject) }
        let events = t.events.map { Example(id: "e" + $0.id, symbol: "calendar", title: $0.title, detail: Fmt.dayTime($0.start)) }
        // Both kinds when both matched: up to 3 mails, the rest meetings.
        let m = min(mails.count, events.isEmpty ? 5 : 3)
        return Array((Array(mails.prefix(m)) + events).prefix(5))
    }

    /// "Coincidiría con 7 correos y 2 reuniones".
    static func summary(_ t: RuleTestResult) -> String {
        if t.checkedMails == 0 && t.checkedEvents == 0 { return L("rules.editor.testNothing") }
        if t.mails.isEmpty && t.events.isEmpty { return L("rules.editor.testNone") }
        let mails = t.mails.count == 1 ? L("rules.editor.mails.one") : L("rules.editor.mails.other", t.mails.count)
        let events = t.events.count == 1 ? L("rules.editor.events.one") : L("rules.editor.events.other", t.events.count)
        return L("rules.editor.testResult", mails, events)
    }

    private func runTest() {
        guard isValid else { showIssues = true; return }
        testing = true
        let rule = RuleValidation.cleaned(draft)
        testTask?.cancel()
        testTask = Task {
            let (messages, events, owners) = await RuleTestData.load(state: state, mail: mail)
            // Edited while the mail loaded: this result is about other conditions.
            guard !Task.isCancelled, RuleValidation.cleaned(draft).conditions == rule.conditions else { return }
            test = RuleTester.run(rule, mails: messages, events: events, ownerEmails: owners)
            testing = false
        }
    }

    // MARK: Save

    private func save() {
        showIssues = true
        guard isValid else { return }
        let rule = RuleValidation.cleaned(draft)
        do {
            if isNew || store.rule(id: rule.id) == nil {
                try store.add(rule)
                onCreated?(rule)
            } else {
                try store.update(rule)
            }
            dismiss()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    // MARK: Bindings

    private func fieldBinding(_ i: Int) -> Binding<RuleField> {
        Binding(get: { draft.conditions.indices.contains(i) ? draft.conditions[i].field : .subject },
                set: { f in
                    guard draft.conditions.indices.contains(i) else { return }
                    draft.conditions[i].field = f
                })
    }

    private func opBinding(_ i: Int) -> Binding<RuleOperator> {
        Binding(get: { draft.conditions.indices.contains(i) ? draft.conditions[i].op : .contains },
                set: { o in if draft.conditions.indices.contains(i) { draft.conditions[i].op = o } })
    }

    private func valueBinding(_ i: Int) -> Binding<String> {
        Binding(get: { draft.conditions.indices.contains(i) ? draft.conditions[i].value : "" },
                set: { v in if draft.conditions.indices.contains(i) { draft.conditions[i].value = v } })
    }

    private var projectBinding: Binding<String> {
        Binding(get: { draft.projectSlug ?? "" }, set: { draft.projectSlug = $0.isEmpty ? nil : $0 })
    }

    // MARK: Words

    static func fieldLabel(_ f: RuleField) -> String {
        switch f {
        case .senderEmail: L("rules.field.senderEmail")
        case .senderDomain: L("rules.field.senderDomain")
        case .senderName: L("rules.field.senderName")
        case .recipient: L("rules.field.recipient")
        case .subject: L("rules.field.subject")
        case .attendeeEmail: L("rules.field.attendeeEmail")
        case .attendeeDomain: L("rules.field.attendeeDomain")
        case .organizerEmail: L("rules.field.organizerEmail")
        case .title: L("rules.field.title")
        case .anyText: L("rules.field.anyText")
        }
    }

    /// What the field catches, in plain words (fields work on mail and meetings alike).
    static func fieldHint(_ f: RuleField) -> String {
        switch f {
        case .senderEmail: L("rules.hint.sender")
        case .organizerEmail: L("rules.hint.organizer")
        case .senderDomain: L("rules.hint.senderDomain")
        case .senderName: L("rules.hint.senderName")
        case .recipient: L("rules.hint.recipient")
        case .subject, .title: L("rules.hint.subject")
        case .attendeeEmail, .attendeeDomain: L("rules.hint.attendee")
        case .anyText: L("rules.hint.anyText")
        }
    }

    static func opLabel(_ o: RuleOperator) -> String {
        switch o {
        case .contains: L("rules.op.contains")
        case .is: L("rules.op.is")
        case .startsWith: L("rules.op.startsWith")
        case .endsWith: L("rules.op.endsWith")
        }
    }

    static func placeholder(_ f: RuleField, _ o: RuleOperator) -> String {
        switch f {
        case .senderEmail, .organizerEmail, .attendeeEmail, .recipient:
            o == .is ? L("rules.placeholder.address") : L("rules.placeholder.domain")
        case .senderDomain, .attendeeDomain: L("rules.placeholder.domain")
        case .senderName: L("rules.placeholder.name")
        case .subject, .title, .anyText: L("rules.placeholder.text")
        }
    }
}

/// What "Probar" looks at: the messages on screen, else the cached list (Correo was open), else the first page of each
/// mail account; and this week's meetings (Reuniones' list, else read now).
@MainActor
enum RuleTestData {
    static func load(state: AppState, mail: [MailMessageSummary]) async
        -> (mails: [MailMessageSummary], events: [CalendarEvent], owners: [String]) {
        let accountsStore = state.engine.accounts
        let meetings = MeetingsModel.shared
        let owners = Set(state.engine.vault.ownerEmails().map { $0.lowercased() })
            .union(accountsStore.accounts.map { $0.email.lowercased() })
            .union(meetings.myEmails)
        var messages = mail
        if messages.isEmpty {
            for account in accountsStore.mailAccounts {
                if let cached = MailCache.shared.list(MailCache.key(account: account.id, query: "")) {
                    messages += cached.messages
                } else if let page = try? await accountsStore.provider(for: account)
                    .listMessages(since: Date().addingTimeInterval(-MailModel.window), pageToken: nil) {
                    messages += page.messages
                }
            }
        }
        var events: [CalendarEvent]
        if meetings.loadedOnce {
            events = meetings.events(in: .week, now: Date())
        } else {
            events = []
            let from = Calendar.current.startOfDay(for: Date())
            let to = from.addingTimeInterval(7 * 86_400)
            for account in accountsStore.accounts {
                if let list = try? await accountsStore.provider(for: account).events(from: from, to: to) { events += list }
            }
            events = MeetingAgenda.dedupe(events)
        }
        return (messages, events, owners.sorted())
    }
}
