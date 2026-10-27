import BrainCore
import Foundation

/// v0.4 routing for meetings and the rules screen (CONTRACT §14.2–§14.4): meeting precedence (manual > rule > default >
/// suggestion), the rule offered after a manual meeting choice, rule names, the editor's checks and "Probar", and the
/// global auto-check switch.
@MainActor func testRoutingMeetings(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    func a(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }
    let owner = "jaime@dive.ai"
    let now = Date()
    func event(_ id: String, title: String = "Sync", organizer: String?, attendees: [String]) -> CalendarEvent {
        CalendarEvent(id: id, accountId: "demo", title: title, start: now, end: now.addingTimeInterval(1800),
                      organizer: organizer.map { a($0) }, attendees: attendees.map { a($0) })
    }
    let projects = [Project(slug: "acme", name: "Acme", description: "", emoji: "🚀"),
                    Project(slug: "nubia", name: "Alianza", description: "", emoji: "🤝")]
    let exists: (String) -> Bool = { slug in projects.contains { $0.slug == slug } }
    let ruleAcme = RoutingRule(.organizerEmail, .is, "ana@acme.com", projectSlug: "acme")
    let suggestion = MeetingSuggestion(projectSlug: "nubia", reason: .title)
    func resolve(_ choice: MeetingProjectChoice?, _ rule: RoutingRule?, _ def: String?, _ sug: MeetingSuggestion? = suggestion)
        -> MeetingProjectResolution {
        MeetingProjectResolution.resolve(choice: choice, rule: rule.map { RoutingDecision(rule: $0, projectSlug: $0.projectSlug) },
                                         defaultProject: def, projectExists: exists, suggestion: { sug })
    }

    // --- Precedence: manual link > rule > default > suggestion.
    var r = resolve(.project("nubia"), ruleAcme, "acme")
    t.check(r.projectSlug == "nubia" && r.origin == .manual && r.isConfirmed, "manual choice beats the rule")
    r = resolve(.noProject, ruleAcme, "acme")
    t.check(r.projectSlug == nil && r.origin == .manualNone && r.isConfirmed && r.recordingProject == nil, "manual «Sin proyecto» beats the rule")
    r = resolve(.project("gone"), ruleAcme, "nubia")
    t.check(r.projectSlug == "acme" && r.rule == ruleAcme, "manual choice of a deleted project → the rule decides")
    r = resolve(nil, ruleAcme, "nubia")
    t.check(r.projectSlug == "acme" && r.rule == ruleAcme && r.isConfirmed && r.recordingProject == "acme", "rule beats default")
    let unassignRule = RoutingRule(.title, .contains, "newsletter", projectSlug: nil)
    r = resolve(nil, unassignRule, "nubia")
    t.check(r.projectSlug == nil && r.rule == unassignRule && r.isConfirmed, "rule without project = explicit Sin asignar, beats default")
    let goneRule = RoutingRule(.title, .contains, "x", projectSlug: "gone")
    r = resolve(nil, goneRule, "nubia")
    t.check(r.projectSlug == "nubia" && r.origin == .defaultProject, "rule to a deleted project is skipped → default")
    r = resolve(nil, nil, "nubia")
    t.check(r.projectSlug == "nubia" && r.origin == .defaultProject && r.recordingProject == "nubia", "default beats suggestion")
    r = resolve(nil, nil, "gone")
    t.check(r.origin == .suggestion(suggestion) && !r.isConfirmed && r.recordingProject == nil, "deleted default → suggestion (asked, not recorded)")
    r = resolve(nil, nil, nil, MeetingSuggestion(projectSlug: "gone", reason: .title))
    t.check(r.origin == .none && r.projectSlug == nil, "suggestion of a deleted project → nothing")
    r = resolve(nil, nil, nil, nil)
    t.check(r.origin == .none, "nothing known")

    // --- With a real store: the rule matches through RoutingSubject.meeting; disabled rules don't.
    let store = RoutingStore(fileURL: root.appendingPathComponent("routing.json"))
    try? store.add(ruleAcme)
    let byAna = event("e1", organizer: "ana@acme.com", attendees: [owner, "ana@acme.com"])
    let decision = store.match(.meeting(byAna, ownerEmails: [owner]))
    t.check(decision?.rule.id == ruleAcme.id, "store matches the meeting's organizer")
    r = MeetingProjectResolution.resolve(choice: nil, rule: decision, defaultProject: nil, projectExists: exists, suggestion: { nil })
    t.check(r.projectSlug == "acme", "store decision → resolution")
    var off = ruleAcme
    off.enabled = false
    try? store.update(off)
    t.check(store.match(.meeting(byAna, ownerEmails: [owner])) == nil, "disabled rule doesn't decide a meeting")
    t.eq(store.rule(id: ruleAcme.id)?.hits ?? -1, 0, "match() counted no hit")
    try? store.update(ruleAcme)
    _ = store.route(.meeting(byAna, ownerEmails: [owner]))
    t.eq(store.rule(id: ruleAcme.id)?.hits ?? -1, 1, "route() at recording time counts one hit")
    store.flush()

    // --- §14.3 offer after a manual meeting choice.
    let offer = RuleOffer.forMeeting(byAna, projectSlug: "nubia", previous: resolve(nil, nil, nil), ownerEmails: [owner],
                                     existing: [], language: "es", projectName: "🤝 Alianza")
    t.check(offer?.conditions == [RuleCondition(field: .organizerEmail, op: .is, value: "ana@acme.com")] && offer?.projectSlug == "nubia",
            "offer: organizer is ana@acme.com")
    t.eq(offer?.name ?? "", "Organiza ana@acme.com → 🤝 Alianza", "offer name in Spanish")
    let mine = event("e2", organizer: owner, attendees: [owner, "luis@banco.mx"])
    let byDomain = RuleOffer.forMeeting(mine, projectSlug: "nubia", previous: nil, ownerEmails: [owner], existing: [], language: "en",
                                        projectName: "🤝 Alianza")
    t.check(byDomain?.conditions.first == RuleCondition(field: .attendeeDomain, op: .is, value: "banco.mx"), "offer: owner organizes → attendee domain")
    t.eq(byDomain?.name ?? "", "With @banco.mx → 🤝 Alianza", "offer name in English")
    let gmail = event("e3", organizer: owner, attendees: [owner, "pablo@gmail.com"])
    t.check(RuleOffer.forMeeting(gmail, projectSlug: "acme", previous: nil, ownerEmails: [owner], existing: [], language: "es")?
        .conditions.first == RuleCondition(field: .attendeeEmail, op: .is, value: "pablo@gmail.com"), "offer: public domain → the address")
    let alone = event("e4", organizer: owner, attendees: [owner])
    t.check(RuleOffer.forMeeting(alone, projectSlug: "acme", previous: nil, ownerEmails: [owner], existing: [], language: "es") == nil,
            "offer: only the owner → nothing")
    t.check(RuleOffer.forMeeting(byAna, projectSlug: nil, previous: nil, ownerEmails: [owner], existing: [], language: "es") == nil,
            "offer: «Sin proyecto» → nothing")
    t.check(RuleOffer.forMeeting(byAna, projectSlug: "nubia", previous: resolve(nil, ruleAcme, nil), ownerEmails: [owner],
                                 existing: [], language: "es") == nil, "offer: correcting a rule's choice → nothing")
    let equivalent = RoutingRule(.organizerEmail, .is, " ANA@acme.com ", projectSlug: "acme")
    t.check(RuleOffer.forMeeting(byAna, projectSlug: "nubia", previous: nil, ownerEmails: [owner], existing: [equivalent],
                                 language: "es") == nil, "offer: an equivalent rule exists → nothing")
    t.check(store.hasEquivalentRule(offer!) == true, "store sees the stored rule as equivalent to the offer")

    // --- Names.
    t.eq(RoutingStore.conditionSummary(ruleAcme, language: "es"), "Organiza ana@acme.com", "summary: es")
    t.eq(RoutingStore.conditionSummary(ruleAcme, language: "en"), "Organized by ana@acme.com", "summary: en")
    let two = RoutingRule(conditions: [RuleCondition(field: .subject, op: .contains, value: "Nubia"),
                                       RuleCondition(field: .senderDomain, op: .is, value: "acme.com")], projectSlug: "nubia")
    t.eq(RoutingStore.conditionSummary(two, language: "es"), "El asunto contiene «Nubia» y de @acme.com", "summary: two conditions")
    t.eq(RoutingStore.conditionSummary(RoutingRule(name: " Bancos ", conditions: two.conditions, projectSlug: nil), language: "es"),
         "Bancos", "summary: the rule's own name")
    t.eq(RoutingStore.displayName(for: two, projects: projects, language: "es"), "El asunto contiene «Nubia» y de @acme.com → 🤝 Alianza",
         "displayName generated with the project")
    t.eq(RoutingStore.displayName(for: unassignRule, projects: projects, language: "en"), "The title contains «newsletter» → Unassigned",
         "displayName: no project")
    t.eq(RoutingStore.displayName(for: goneRule, projects: projects, language: "es"), "El título contiene «x» → gone",
         "displayName: deleted project shows its slug")

    // --- Editor checks.
    t.check(RuleValidation.issue(RuleCondition(field: .subject, op: .contains, value: "  ")) == .empty, "editor: empty value")
    t.check(RuleValidation.issue(RuleCondition(field: .senderDomain, op: .is, value: "acme .com")) == .hasSpaces, "editor: domain with spaces")
    t.check(RuleValidation.issue(RuleCondition(field: .senderEmail, op: .is, value: " ana@acme.com ")) == nil, "editor: trimmed address ok")
    t.check(RuleValidation.issue(RuleCondition(field: .subject, op: .contains, value: "propuesta Q4")) == nil, "editor: text with spaces ok")
    t.check(!RuleValidation.isValid([]), "editor: no conditions is invalid")
    t.check(!RuleValidation.isValid([RuleCondition(field: .subject, op: .contains, value: "a"),
                                     RuleCondition(field: .title, op: .is, value: "")]), "editor: one empty condition is invalid")
    let cleaned = RuleValidation.cleaned(RoutingRule(name: "  Acme ", conditions: [RuleCondition(field: .senderDomain, op: .is, value: " acme.com\n")],
                                                     projectSlug: "acme"))
    t.check(cleaned.name == "Acme" && cleaned.conditions.first?.value == "acme.com", "editor: cleaned trims name and values")

    // --- "Probar": newest 50 mails, the week's events; tested even when off.
    var mails: [MailMessageSummary] = []
    for i in 0..<60 {
        let from = i % 2 == 0 ? "ana@acme.com" : "x@other.org"
        mails.append(MailMessageSummary(id: "m\(i)", threadId: "t\(i)", from: a(from), to: [a(owner)], subject: "Hola \(i)", snippet: "",
                                        date: now.addingTimeInterval(Double(-i) * 3600)))
    }
    var domainRule = RoutingRule(.senderDomain, .is, "acme.com", projectSlug: "acme")
    domainRule.enabled = false
    let events = [byAna, mine, event("e5", organizer: "bob@acme.com", attendees: [owner])]
    let result = RuleTester.run(domainRule, mails: mails, events: events, ownerEmails: [owner])
    t.eq(result.checkedMails, 50, "Probar looks at the newest 50 mails")
    t.eq(result.mails.count, 25, "Probar: half of them are from acme.com")
    t.check(result.mails.allSatisfy { Int($0.id.dropFirst())! < 50 }, "Probar: only the newest ones")
    t.eq(result.events.map(\.id), ["e1", "e5"], "Probar: meetings organized from acme.com")
    t.eq(result.checkedEvents, 3, "Probar: counts the events looked at")

    // --- Global auto-check switch (§14.5): default on, tolerant decode, persisted.
    let legacy = #"{"rules":[],"mailSyncCursors":{}}"#.data(using: .utf8)!
    t.check((try? JSONDecoder.sb.decode(RoutingSettings.self, from: legacy))?.autoImportEnabled == true, "autoImportEnabled defaults to on")
    try? store.setAutoImportEnabled(false)
    let reread = RoutingStore(fileURL: root.appendingPathComponent("routing.json"))
    t.check(reread.settings.autoImportEnabled == false && reread.rules.count == 1, "autoImportEnabled persists with the rules")
}
