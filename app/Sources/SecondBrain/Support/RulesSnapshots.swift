import BrainCore
import SwiftUI

/// Development only (`SB_SNAPSHOT_DIR`, CONTRACT §14.6): "rules-empty", "rules", "rule-editor", "meetings-rule" and
/// "meetings-rule-offer". The sample rules are written when their shot renders, so earlier shots stay as they were.
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
            ("meetings-rule", CGSize(width: 1000, height: 640),
             AnyView(SnapshotSetup { addSampleRules(state) } content: { MeetingsView(initialSegment: .week) })),
            ("meetings-rule-offer", CGSize(width: 1000, height: 640),
             AnyView(SnapshotSetup { offerOnSomeMeeting(state) } content: { MeetingsView(initialSegment: .week) })),
        ]
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

    /// The §14.3 line: a meeting of the week put in a project by hand, as if from its card.
    static func offerOnSomeMeeting(_ state: AppState) {
        addSampleRules(state)
        let model = MeetingsModel.shared
        let candidates = model.events(in: .week, now: Date()).filter { e in
            let r = model.resolution(for: e, state: state)
            return !r.isConfirmed && e.organizer != nil && !model.myEmails.contains(e.organizer?.email ?? "")
        }
        guard let event = candidates.first, let slug = state.projects.last?.slug else { return }
        model.setProject(.project(slug), for: event, state: state, offerAt: .card)
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
