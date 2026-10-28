import AppKit
import BrainCore
import SwiftUI

/// Development only (`SB_SNAPSHOT_DIR`, CONTRACT §14.6): "rules-empty", "rules", "rule-editor", "meetings-rule",
/// "meetings-rule-offer" and "email-routed". The sample rules are written when their shot renders, so earlier shots stay as they were.
@MainActor
enum RulesSnapshots {
    static func shots(state: AppState) async -> [(String, CGSize, AnyView)] {
        let emptyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sb-rules-empty-\(ProcessInfo.processInfo.processIdentifier).json")
        try? FileManager.default.removeItem(at: emptyURL)
        let empty = RoutingStore(fileURL: emptyURL)
        let sheet = CGSize(width: 600, height: 560)
        var draft = RoutingRule(conditions: [RuleCondition(field: .senderDomain, op: .is, value: "contoso.com")],
                                projectSlug: state.projects.first?.slug)
        draft.name = ""
        return [
            ("rules-empty", sheet, AnyView(RulesSheet(store: empty))),
            ("rules", sheet, AnyView(SnapshotSetup { addSampleRules(state) } content: { RulesSheet() })),
            ("rule-editor", CGSize(width: 620, height: 600), AnyView(SnapshotSetup { addSampleRules(state) } content: {
                RuleEditorSheet(store: state.engine.routing, item: RuleEditorItem(rule: draft, isNew: true), testOnAppear: true)
            })),
            // A rule-routed meeting selected, so the detail shows the chip with "Por la regla «…»".
            ("meetings-rule", CGSize(width: 1000, height: 640),
             AnyView(SnapshotSetup { addSampleRules(state); selectRuleRoutedMeeting(state) } content: { MeetingsView(initialSegment: .week) })),
            ("meetings-rule-offer", CGSize(width: 1000, height: 640),
             AnyView(SnapshotSetup { offerOnSomeMeeting(state) } content: { MeetingsView() })),
            // "Agregar correo" from Sin asignar with a pasted mail a rule covers: the picker names the rule's project.
            ("email-routed", CGSize(width: 820, height: 640),
             AnyView(AddEmailSheet(request: EmailRequest(threadKey: nil, projectSlug: nil), initialText: routedEmailSample(state)))),
        ] + settingsShots(state: state)
    }

    // MARK: v0.5 settings — Ajustes per tab (ideal 820×600 and min 760×520), onboarding steps, sheets.
    static func settingsShots(state: AppState) -> [(String, CGSize, AnyView)] {
        var shots: [(String, CGSize, AnyView)] = []
        var draft = RoutingRule(conditions: [RuleCondition(field: .senderDomain, op: .is, value: "contoso.com")],
                                projectSlug: state.projects.first?.slug)
        draft.name = ""
        /// Light, then "-dark" through the real app appearance (NSApp.appearance, like the window shots): AppKit
        /// controls (the tab strip, pickers, switches) ignore a SwiftUI-only colorScheme.
        func both(_ name: String, _ size: CGSize, _ make: @escaping () -> AnyView) {
            shots.append((name, size, make()))
            shots.append((name + "-dark", size, AnyView(AppearanceShot(dark: true, content: make))))
        }
        for tab in SettingsTab.allCases {
            // A deep-link request left in the defaults (another run, a click in the app) would win over `initialTab`.
            let view = {
                AnyView(SnapshotSetup {
                    UserDefaults.standard.removeObject(forKey: SettingsTab.requestKey)
                    if tab == .rules { addSampleRules(state) }
                } content: { SettingsView(initialTab: tab) })
            }
            both("settings-\(tab.rawValue)", CGSize(width: 820, height: 600), view)
            shots.append(("settings-\(tab.rawValue)-min", CGSize(width: 760, height: 520), view()))
        }
        // The five steps (§16.11); "onboarding-accounts" itself is DebugSnapshots' (with the Return press after it).
        for step in OnboardingStep.allCases {
            let name = step == .accounts ? "onboarding-accounts-full" : "onboarding-\(step)"
            both(name, CGSize(width: 920, height: 620)) { AnyView(OnboardingView(initialStep: step)) }
            shots.append((name + "-1100", CGSize(width: 1100, height: 720), AnyView(OnboardingView(initialStep: step))))
        }
        both("record-intro", CGSize(width: 560, height: 520)) { AnyView(RecordingIntroSheet(request: nil)) }
        if let template = state.templates.first {
            both("templates-editor", CGSize(width: 780, height: 520)) { AnyView(TemplateEditor(original: template) { _ in }) }
            shots.append(("templates-editor-narrow", CGSize(width: 640, height: 520), AnyView(TemplateEditor(original: template) { _ in })))
        }
        both("templates-make", CGSize(width: 520, height: 440)) { AnyView(MakeTemplateSheet { _ in }) }
        both("claude-reconnect", CGSize(width: 640, height: 520)) { AnyView(ReconnectClaudeSheet()) }
        // Dark twins of the rules and connect sheets (their light shots are rendered above / by DebugSnapshots).
        let dark: [(String, CGSize, () -> AnyView)] = [
            ("rules-dark", CGSize(width: 600, height: 560), { AnyView(SnapshotSetup { addSampleRules(state) } content: { RulesSheet() }) }),
            ("rule-editor-dark", CGSize(width: 620, height: 600), {
                AnyView(SnapshotSetup { addSampleRules(state) } content: {
                    RuleEditorSheet(store: state.engine.routing, item: RuleEditorItem(rule: draft, isNew: true), testOnAppear: true)
                })
            }),
            ("trust-dark", CGSize(width: 460, height: 470),
             { AnyView(TrustSheet(connector: AccountConnector(preview: ConnectFlow(provider: .microsoft, phase: .trust)))) }),
            ("blocked-dark", CGSize(width: 460, height: 520), { AnyView(AccountBlockedView(
                provider: .microsoft, reason: .consent, context: .meetings, onUseMacCalendar: {}, onClose: {})) }),
            ("blocked-notregistered-dark", CGSize(width: 460, height: 520), { AnyView(AccountBlockedView(
                provider: .google, reason: .notRegistered, context: .mail, onUseMacCalendar: {}, onClose: {})) }),
            ("orghelp-dark", CGSize(width: 620, height: 520), { AnyView(OrgAccessHelpSheet(provider: .microsoft)) }),
            ("github-trust-dark", CGSize(width: 460, height: 470), { AnyView(GitHubConnectSheet()) }),
            ("github-code-dark", CGSize(width: 460, height: 400), { AnyView(GitHubConnectSheet(preview: .code(GitHubDeviceCode(
                deviceCode: "demo", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: Date().addingTimeInterval(900), interval: 5)))) }),
            ("github-org-dark", CGSize(width: 560, height: 520), { AnyView(GitHubOrgHelpSheet()) }),
        ]
        for (name, size, make) in dark {
            shots.append((name, size, AnyView(AppearanceShot(dark: true, content: make))))
        }
        shots.append(("rules-sheet-narrow", CGSize(width: 560, height: 420),
                      AnyView(SnapshotSetup { addSampleRules(state) } content: { RulesSheet() })))
        // Every light shot puts the app's appearance back (a filtered run may render it right after a dark one).
        return shots.map { name, size, view in
            name.hasSuffix("-dark") ? (name, size, view) : (name, size, AnyView(AppearanceShot(dark: false) { view }))
        }
    }

    /// Selects (through the same hand-off as Inicio / ⌘K) an upcoming meeting a sample rule routes, so the detail shows
    /// the project chip with its rule subtitle. Falls back to the demo's "Presupuesto 2027" (organized by Carlos).
    static func selectRuleRoutedMeeting(_ state: AppState) {
        let model = MeetingsModel.shared
        let now = Date()
        let routed = (model.events(in: .today, now: now) + model.events(in: .upcoming, now: now))
            .first { model.resolution(for: $0, state: state).rule != nil && model.hero(now: now)?.event.id != $0.id }
        state.pendingEventId = routed?.id ?? "demo-e5"
    }

    /// A few realistic rules over the demo accounts (idempotent: equivalent rules aren't added twice).
    static func addSampleRules(_ state: AppState) {
        let routing = state.engine.routing
        let p = state.projects.map(\.slug)
        guard !p.isEmpty else { return }
        func slug(_ i: Int) -> String { p[min(i, p.count - 1)] }
        let samples: [RoutingRule] = [
            RoutingRule(conditions: [RuleCondition(field: .organizerEmail, op: .is, value: "carlos.ruiz@contoso.com")],
                        projectSlug: slug(2), hits: 4, lastHitAt: Date()),
            RoutingRule(conditions: [RuleCondition(field: .senderDomain, op: .is, value: "acmelogistics.com")],
                        projectSlug: slug(0), autoAddMail: true, hits: 12, lastHitAt: Date()),
            RoutingRule(name: state.config.uiLanguage == "en" ? "Nubia bank alliance" : "Alianza con Banco Nubia",
                        conditions: [RuleCondition(field: .subject, op: .contains, value: "Nubia")], projectSlug: slug(0), hits: 1),
            RoutingRule(enabled: false, conditions: [RuleCondition(field: .senderEmail, op: .contains, value: "newsletter")],
                        projectSlug: nil),
        ]
        for rule in samples where !routing.hasEquivalentRule(rule) {
            try? routing.add(rule)
        }
    }

    /// A pasted mail from @acmelogistics.com (the demo vault's sender-domain rule).
    static func routedEmailSample(_ state: AppState) -> String {
        if state.config.uiLanguage == "en" {
            return """
            From: Sofía Herrera <sofia.herrera@acmelogistics.com>
            To: Ana García <ana@contoso.com>
            Date: Mon, 19 Oct 2026 10:15:00 -0600
            Subject: Delivery windows in Puebla

            Hi Ana, we can move the Puebla deliveries to Tuesday and Thursday mornings starting next week.
            Let me know if that works for the Atlas launch.

            Sofía
            """
        }
        return """
        De: Sofía Herrera <sofia.herrera@acmelogistics.com>
        Para: Ana García <ana@contoso.com>
        Fecha: Mon, 19 Oct 2026 10:15:00 -0600
        Asunto: Horarios de entrega en Puebla

        Hola Ana, podemos mover las entregas de Puebla a martes y jueves por la mañana desde la próxima semana.
        Dime si te funciona para el lanzamiento de Atlas.

        Sofía
        """
    }

    /// The §14.3 line: a meeting put in a project by hand from the hero (Hoy), else from a card of Próximas. An earlier
    /// run's pick is forgotten first, and the project differs from the current one, so the offer always has a reason.
    static func offerOnSomeMeeting(_ state: AppState) {
        addSampleRules(state)
        let model = MeetingsModel.shared
        let now = Date()
        func offerable(_ e: CalendarEvent) -> Bool {
            model.resolution(for: e, state: state).rule == nil && e.organizer != nil
                && !model.myEmails.contains(e.organizer?.email ?? "")
        }
        func offer(_ e: CalendarEvent, at placement: MeetingChipPlacement) {
            model.setProject(nil, for: e, state: state)
            let current = model.resolution(for: e, state: state).recordingProject
            guard let slug = state.projects.map(\.slug).last(where: { $0 != current }) else { return }
            model.setProject(.project(slug), for: e, state: state, offerAt: placement)
        }
        if let hero = model.hero(now: now)?.event, offerable(hero) {
            offer(hero, at: .hero)
        } else if let event = (model.events(in: .today, now: now) + model.events(in: .upcoming, now: now)).first(where: offerable) {
            offer(event, at: .card)
        }
    }
}

/// Renders `content` under the real app appearance (NSApp.appearance, as `AppState.applyAppearance` does), set just
/// before it appears. A light shot puts back the appearance the app had before the first dark one.
private struct AppearanceShot: View {
    let dark: Bool
    let content: () -> AnyView
    @ViewState private var ready = false
    @MainActor private static var original: NSAppearance?? = nil

    var body: some View {
        Group {
            if ready { content() } else { Color.clear }
        }
        // The offscreen window keeps its own appearance otherwise (the AppKit tab strip stays light).
        .background(WindowAppearance(appearance: dark ? NSAppearance(named: .darkAqua) : nil))
        .onAppear {
            if Self.original == nil { Self.original = .some(NSApp.appearance) }
            NSApp.appearance = dark ? NSAppearance(named: .darkAqua) : (Self.original ?? nil)
            // Built only after the window took the appearance (AppKit chrome is styled when it's created).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { ready = true }
        }
        // Whatever renders next (another harness's shot) gets the app's own appearance back.
        .onDisappear { if dark, let original = Self.original { NSApp.appearance = original } }
    }
}

/// Sets the hosting window's appearance (nil = follow the app).
private struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { view.window?.appearance = appearance }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { view.window?.appearance = appearance }
    }
}

/// Runs `setup` when the shot is about to render, then shows `content`.
private struct SnapshotSetup<Content: View>: View {
    let setup: () -> Void
    @ViewBuilder let content: () -> Content
    @ViewState private var ready = false

    var body: some View {
        Group {
            if ready { content() } else { Color.clear }
        }
        .onAppear {
            setup()
            ready = true
        }
    }
}
