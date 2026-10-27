import BrainCore
import Foundation

/// v0.4 routing rules (CONTRACT §14): the matcher, the store (persistence, hits, corrupt file), the rule suggested after
/// a manual assignment, and the §14.2 precedence on a temp vault (existing thread > rule > default > inbox).
@MainActor func testRouting(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    func a(_ email: String, _ name: String? = nil) -> EmailAddress { EmailAddress(name: name, email: email) }
    func mail(from: String, to: [String] = ["jaime@dive.ai"], subject: String = "", text: String = "", name: String? = nil) -> RoutingSubject {
        RoutingSubject(kind: .mail, sender: a(from, name), recipients: to.map { a($0) }, subject: subject, text: text,
                       ownerEmails: ["jaime@dive.ai"])
    }
    func cond(_ f: RuleField, _ o: RuleOperator, _ v: String) -> RoutingRule { RoutingRule(f, o, v, projectSlug: "p") }
    func m(_ r: RoutingRule, _ s: RoutingSubject) -> Bool { RuleMatcher.matches(r, s) }

    // --- Matcher: folding.
    t.check(m(cond(.subject, .contains, "nandu"), mail(from: "x@y.com", subject: "Reunión Ñandú")), "folding: nandu ⊂ Ñandú")
    t.check(m(cond(.subject, .contains, " Ñandú "), mail(from: "x@y.com", subject: "NANDU semanal")), "folding: value Ñandú, trimmed")
    t.check(m(cond(.senderName, .is, "sofia herrera"), mail(from: "s@x.com", name: "Sofía Herrera")), "folding sender name")
    t.check(!m(cond(.subject, .contains, "nubia"), mail(from: "x@y.com", subject: "Otra cosa")), "subject non-match")
    // Domains: whole domain or dotted suffix, never a bare suffix.
    let domainRule = cond(.senderDomain, .is, "acme.com")
    t.check(m(domainRule, mail(from: "ana@acme.com")), "domain is: exact")
    t.check(m(domainRule, mail(from: "ana@mail.ACME.com")), "domain is: subdomain")
    t.check(!m(domainRule, mail(from: "ana@notacme.com")), "domain is: notacme.com doesn't match")
    t.check(!m(domainRule, mail(from: "ana@acme.com.mx")), "domain is: acme.com.mx doesn't match")
    t.check(m(cond(.senderDomain, .is, "@acme.com"), mail(from: "ana@acme.com")), "domain value with @")
    t.check(m(cond(.senderDomain, .endsWith, "acme.com"), mail(from: "ana@notacme.com")), "domain endsWith is literal")
    t.check(m(cond(.senderDomain, .startsWith, "mail."), mail(from: "ana@mail.acme.com")), "domain startsWith")
    t.check(m(cond(.senderDomain, .contains, "acme"), mail(from: "ana@notacme.com")), "domain contains")
    // Addresses.
    t.check(m(cond(.senderEmail, .is, "Ana@Acme.com"), mail(from: "ana@acme.com")), "senderEmail is (case)")
    t.check(!m(cond(.senderEmail, .is, "ana@acme.com"), mail(from: "anabel@acme.com")), "senderEmail is: exact only")
    t.check(m(cond(.senderEmail, .startsWith, "ana"), mail(from: "anabel@acme.com")), "senderEmail startsWith")
    t.check(m(cond(.senderEmail, .endsWith, "@acme.com"), mail(from: "anabel@acme.com")), "senderEmail endsWith")
    t.check(m(cond(.senderEmail, .is, "acme.com"), mail(from: "ana@sub.acme.com")), "senderEmail is <domain> → domain semantics")
    t.check(!m(cond(.senderEmail, .is, "acme.com"), mail(from: "ana@notacme.com")), "senderEmail is <domain>: notacme.com no")
    // Recipient includes the owner (an alias is a valid rule); attendee* skip the owner.
    let alias = mail(from: "x@y.com", to: ["jaime+acme@dive.ai"])
    t.check(m(cond(.recipient, .is, "jaime+acme@dive.ai"), alias), "recipient: the owner's alias")
    t.check(m(cond(.recipient, .is, "dive.ai"), mail(from: "x@y.com")), "recipient is <domain>")
    t.check(m(cond(.recipient, .contains, "+acme"), alias), "recipient contains")
    t.check(!m(cond(.attendeeEmail, .is, "jaime@dive.ai"), mail(from: "x@y.com")), "attendeeEmail never the owner")
    t.check(!m(cond(.attendeeDomain, .is, "dive.ai"), mail(from: "x@y.com")), "attendeeDomain never the owner's")
    t.check(m(cond(.attendeeDomain, .is, "dive.ai"), mail(from: "x@y.com", to: ["jaime@dive.ai", "bob@dive.ai"])), "attendeeDomain: another person")
    t.check(m(cond(.attendeeEmail, .is, "bob@corp.io"), mail(from: "x@y.com", to: ["jaime@dive.ai", "bob@corp.io"])), "attendeeEmail: any attendee")
    // anyText = subject + text.
    t.check(m(cond(.anyText, .contains, "factura"), mail(from: "x@y.com", subject: "Hola", text: "Te mando la Factura 12")), "anyText in text")
    t.check(m(cond(.anyText, .contains, "hola"), mail(from: "x@y.com", subject: "Hola", text: "")), "anyText in subject")
    // Meetings: organizer = sender, title = subject.
    let ev = CalendarEvent(id: "e1", accountId: "local:calendar", title: "Sync Nubia", start: Date(), end: Date().addingTimeInterval(1800),
                           organizer: a("ana@acme.com"), attendees: [a("jaime@dive.ai"), a("lu@alianza.org")], notes: "Agenda: presupuesto")
    let meeting = RoutingSubject.meeting(ev, ownerEmails: ["jaime@dive.ai"])
    t.check(meeting.kind == .meeting && meeting.subject == "Sync Nubia" && meeting.text == "Agenda: presupuesto", "meeting builder")
    t.check(m(cond(.organizerEmail, .is, "ana@acme.com"), meeting), "organizerEmail")
    t.check(m(cond(.title, .contains, "nubia"), meeting), "title")
    t.check(m(cond(.attendeeDomain, .is, "alianza.org"), meeting), "meeting attendeeDomain")
    t.check(m(cond(.anyText, .contains, "presupuesto"), meeting), "anyText in notes")
    // AND, empty values, no conditions.
    let both = RoutingRule(conditions: [.init(field: .senderDomain, op: .is, value: "acme.com"), .init(field: .subject, op: .contains, value: "factura")],
                           projectSlug: "p")
    t.check(m(both, mail(from: "a@acme.com", subject: "Factura octubre")), "AND: both hold")
    t.check(!m(both, mail(from: "a@acme.com", subject: "Hola")), "AND: one fails")
    t.check(!m(both, mail(from: "a@otro.com", subject: "Factura")), "AND: the other fails")
    t.check(!m(cond(.subject, .contains, "  "), mail(from: "x@y.com", subject: "Hola")), "empty value never matches")
    t.check(!m(RoutingRule(conditions: [], projectSlug: "p"), mail(from: "x@y.com")), "no conditions never matches")
    t.check(!m(cond(.senderDomain, .is, "acme.com"), RoutingSubject(kind: .mail, sender: nil, recipients: [], subject: "", text: "")),
            "no sender never matches a sender rule")
    // Builders.
    let parsed = ParsedEmail(subject: "Hola", from: a("me@dive.ai"), to: [a("x@corp.io")], cc: [a("y@corp.io")], date: nil, body: "cuerpo",
                             quotedHistory: "viejo", raw: "", isFromOwner: true)
    let ps = RoutingSubject.mail(parsed, ownerEmails: ["jaime@dive.ai"])
    t.check(ps.recipients.count == 2 && ps.text == "cuerpo" && ps.ownerEmails.contains("me@dive.ai"), "ParsedEmail builder: to+cc, body, owner sender")
    let summary = MailMessageSummary(id: "m", threadId: "t", from: a("s@acme.com"), to: [a("jaime@dive.ai")], subject: "Asunto", snippet: "snip",
                                     date: Date())
    let ss = RoutingSubject.mail(summary)
    t.check(ss.kind == .mail && ss.text == "snip" && ss.subject == "Asunto" && ss.sender?.email == "s@acme.com", "summary builder")

    // --- Order, disabled rules, explicit inbox rule.
    var nubia = RoutingRule(.subject, .contains, "Nubia", projectSlug: "alianza")
    let acme = RoutingRule(.senderDomain, .is, "acme.com", projectSlug: "acme")
    let news = RoutingRule(.senderDomain, .is, "news.io", projectSlug: nil)
    let both2 = mail(from: "ana@acme.com", subject: "Nubia kickoff")
    t.eq(RuleMatcher.firstMatch([nubia, acme], both2)?.projectSlug, "alianza", "first rule wins")
    t.eq(RuleMatcher.firstMatch([acme, nubia], both2)?.projectSlug, "acme", "order = priority")
    nubia.enabled = false
    t.eq(RuleMatcher.firstMatch([nubia, acme], both2)?.projectSlug, "acme", "disabled rule skipped")
    t.check(RuleMatcher.matches(nubia, both2), "matches() ignores enabled (Probar)")

    // --- Store: persistence round-trip.
    let file = RoutingStore.fileURL(vaultRoot: root.appendingPathComponent("vault"))
    t.check(file.path.hasSuffix("vault/.secondbrain/routing.json"), "file in the vault")
    let store = RoutingStore(fileURL: file)
    t.check(store.settings == RoutingSettings(), "missing file → empty settings")
    do {
        nubia.enabled = true
        try store.add(nubia)
        try store.add(acme)
        try store.add(news)
        try store.setDefaultProject("general")
        try store.setMailSyncCursor(Date(timeIntervalSince1970: 1_800_000_000), for: "microsoft:a@x.com")
        t.check(fm.fileExists(atPath: file.path), "written")
        let again = RoutingStore(fileURL: file)
        t.eq(again.settings.rules.map(\.id), [nubia.id, acme.id, news.id], "round-trip: rules in order")
        t.eq(again.settings.rules.map(\.projectSlug), ["alianza", "acme", nil], "round-trip: projects (nil kept)")
        t.eq(again.settings.defaultProjectSlug, "general", "round-trip: default")
        t.eq(again.settings.mailSyncCursors["microsoft:a@x.com"], Date(timeIntervalSince1970: 1_800_000_000), "round-trip: cursor")
        t.eq(again.settings.rules[0].conditions, nubia.conditions, "round-trip: conditions")

        // route: hit recorded, written at most once per second (flush writes the pending one).
        let d = store.route(mail(from: "ana@acme.com", subject: "Hola"))
        t.eq(d?.projectSlug, "acme", "route → acme")
        t.eq(d?.rule.hits, 1, "decision carries the counted rule")
        _ = store.route(mail(from: "bob@acme.com", subject: "Otra"))
        t.eq(store.rule(id: acme.id)?.hits, 2, "hits in memory")
        t.check(store.rule(id: acme.id)?.lastHitAt != nil, "lastHitAt set")
        t.eq(RoutingStore(fileURL: file).rule(id: acme.id)?.hits ?? -1, 0, "throttled: not on disk within the second")
        store.flush()
        t.eq(RoutingStore(fileURL: file).rule(id: acme.id)?.hits ?? -1, 2, "flush writes the hits")
        t.check(store.match(mail(from: "ana@acme.com")) != nil && store.rule(id: acme.id)?.hits == 2, "match() doesn't count")
        // resolvedProject: rule ?? default; an explicit inbox rule beats the default.
        t.eq(store.resolvedProject(mail(from: "x@nowhere.org"), recordHit: false), "general", "no rule → default")
        t.eq(store.resolvedProject(mail(from: "x@news.io"), recordHit: false), nil, "nil-project rule = explicit inbox (default ignored)")
        t.eq(store.match(mail(from: "x@news.io"))?.rule.id, news.id, "explicit inbox is a decision")

        // Another process edits the file: the next write keeps its rule and our hits.
        let other = RoutingStore(fileURL: file)
        let extra = RoutingRule(.anyText, .contains, "boletín", projectSlug: nil)
        try other.add(extra)
        try await Task.sleep(for: .milliseconds(1100))
        _ = store.route(mail(from: "z@acme.com"))
        store.flush()
        let disk = RoutingStore(fileURL: file)
        t.check(disk.rule(id: extra.id) != nil, "external rule kept by a hit write")
        t.eq(disk.rule(id: acme.id)?.hits, 3, "hits merged")
        t.check(store.rule(id: extra.id) != nil, "memory picks up the external rule")

        // update / move / remove / errors.
        var renamed = acme
        renamed.name = "Acme Corp"
        renamed.hits = 0
        try store.update(renamed)
        t.eq(store.rule(id: acme.id)?.name, "Acme Corp", "update")
        t.eq(store.rule(id: acme.id)?.hits, 3, "update keeps the larger hit count on disk")
        try store.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        t.eq(store.rules.map(\.id), [news.id, nubia.id, acme.id, extra.id], "move to top")
        try store.move(fromOffsets: IndexSet(integer: 0), toOffset: 4)
        t.eq(store.rules.map(\.id), [nubia.id, acme.id, extra.id, news.id], "move to bottom")
        t.eq(RoutingStore(fileURL: file).rules.map(\.id), [nubia.id, acme.id, extra.id, news.id], "move persisted")
        try store.remove(id: extra.id)
        t.check(store.rule(id: extra.id) == nil && RoutingStore(fileURL: file).rule(id: extra.id) == nil, "remove")
        do { try store.update(RoutingRule(.subject, .is, "x", projectSlug: nil)); t.check(false, "update unknown must throw") }
        catch RoutingError.ruleNotFound { t.check(true, "update unknown throws") }
        do { try store.add(RoutingRule(.subject, .is, "  ", projectSlug: nil)); t.check(false, "empty rule must throw") }
        catch RoutingError.emptyRule { t.check(true, "empty rule throws") }
        try store.setDefaultProject(nil)
        t.eq(RoutingStore(fileURL: file).settings.defaultProjectSlug, nil, "default cleared")
        t.check(store.hasEquivalentRule(RoutingRule(.senderDomain, .is, " ACME.com", projectSlug: "x")), "equivalent rule (folded value)")
        t.check(!store.hasEquivalentRule(RoutingRule(.senderDomain, .contains, "acme.com", projectSlug: "x")), "different operator → not equivalent")
    } catch {
        t.check(false, "store: \(error)")
    }

    // Corrupt file: tolerated (empty), copied aside, and a later save works. One unknown rule doesn't lose the rest.
    do {
        let bad = root.appendingPathComponent("bad/.secondbrain/routing.json")
        try fm.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: bad)
        let s = RoutingStore(fileURL: bad)
        t.check(s.rules.isEmpty, "corrupt file → no rules, no crash")
        t.check(fm.fileExists(atPath: bad.deletingLastPathComponent().appendingPathComponent("routing.corrupt.json").path), "corrupt file copied aside")
        try s.add(acme)
        t.eq(RoutingStore(fileURL: bad).rules.map(\.id), [acme.id], "saving after a corrupt file")
        let mixed = """
        {"rules":[{"id":"a","conditions":[{"field":"githubRepo","op":"is","value":"x"}],"projectSlug":"p"},
                  {"id":"b","conditions":[{"field":"subject","op":"contains","value":"hola"}]}],"defaultProjectSlug":"g"}
        """
        try Data(mixed.utf8).write(to: bad)
        s.reload(fileURL: bad)
        t.eq(s.rules.map(\.id), ["b"], "an unknown field drops only that rule")
        t.check(s.rules.first?.enabled == true && s.rules.first?.projectSlug == nil && s.rules.first?.hits == 0, "missing keys → defaults")
        t.eq(s.settings.defaultProjectSlug, "g", "default read")
    } catch {
        t.check(false, "corrupt: \(error)")
    }

    // --- suggestedRule (§14.3).
    func suggest(_ s: RoutingSubject, _ lang: String = "es", name: String? = "🚀 Acme") -> RoutingRule? {
        RoutingStore.suggestedRule(for: s, projectSlug: "acme", language: lang, projectName: name)
    }
    let corp = suggest(mail(from: "Ana@Acme.com"))
    t.eq(corp?.conditions, [RuleCondition(field: .senderDomain, op: .is, value: "acme.com")], "corporate sender → domain")
    t.eq(corp?.name, "De @acme.com → 🚀 Acme", "generated name (es)")
    t.eq(corp?.projectSlug, "acme", "suggested project")
    t.eq(suggest(mail(from: "ana@acme.com"), "en")?.name, "From @acme.com → 🚀 Acme", "generated name (en)")
    t.eq(suggest(mail(from: "ana@acme.com"), name: nil)?.name, "", "no project name → name generated on display")
    for d in ["gmail.com", "outlook.com", "hotmail.com", "hotmail.es", "yahoo.com", "yahoo.com.mx", "icloud.com", "proton.me", "protonmail.com",
              "me.com", "live.com.mx"] {
        t.eq(suggest(mail(from: "pepe@\(d)"))?.conditions, [RuleCondition(field: .senderEmail, op: .is, value: "pepe@\(d)")], "public \(d) → address")
    }
    t.eq(suggest(mail(from: "pepe@gmail.com"))?.name, "De pepe@gmail.com → 🚀 Acme", "address rule name")
    t.check(!RoutingStore.isPublicDomain("mail.acme.com") && !RoutingStore.isPublicDomain("gmail.acme.com") && !RoutingStore.isPublicDomain("acme.com"),
            "corporate domains are not public")
    // Sent by the owner → first other recipient's domain (or address), or nothing.
    let mine = suggest(mail(from: "jaime@dive.ai", to: ["jaime@dive.ai", "laura@cliente.mx"]))
    t.eq(mine?.conditions, [RuleCondition(field: .recipient, op: .is, value: "cliente.mx")], "owner sender → recipient domain")
    t.eq(mine?.name, "Para @cliente.mx → 🚀 Acme", "recipient rule name")
    t.eq(suggest(mail(from: "jaime@dive.ai", to: ["pepe@gmail.com"]))?.conditions, [RuleCondition(field: .recipient, op: .is, value: "pepe@gmail.com")],
         "owner sender → public recipient address")
    t.check(suggest(mail(from: "jaime@dive.ai", to: ["jaime@dive.ai"])) == nil, "owner to owner → nothing")
    t.eq(suggest(RoutingSubject.mail(parsed, ownerEmails: []))?.conditions, [RuleCondition(field: .recipient, op: .is, value: "corp.io")],
         "isFromOwner pasted email → recipient")
    // Meetings.
    t.eq(suggest(meeting)?.conditions, [RuleCondition(field: .organizerEmail, op: .is, value: "ana@acme.com")], "meeting → organizer")
    t.eq(suggest(meeting)?.name, "Reuniones de ana@acme.com → 🚀 Acme", "organizer rule name")
    var ownMeeting = ev
    ownMeeting.organizer = a("jaime@dive.ai")
    t.eq(suggest(.meeting(ownMeeting, ownerEmails: ["jaime@dive.ai"]))?.conditions,
         [RuleCondition(field: .attendeeDomain, op: .is, value: "alianza.org")], "owner organizer → attendee domain")
    ownMeeting.organizer = nil
    ownMeeting.attendees = [a("jaime@dive.ai"), a("lu@gmail.com")]
    t.eq(suggest(.meeting(ownMeeting, ownerEmails: ["jaime@dive.ai"]))?.conditions,
         [RuleCondition(field: .attendeeEmail, op: .is, value: "lu@gmail.com")], "no organizer, public attendee → address")
    ownMeeting.attendees = [a("jaime@dive.ai")]
    t.check(suggest(.meeting(ownMeeting, ownerEmails: ["jaime@dive.ai"])) == nil, "only the owner → nothing")
    // Display names.
    let projects = [Project(slug: "acme", name: "Acme", description: "", emoji: "🚀"), Project(slug: "alianza", name: "Alianza", description: "", emoji: "🤝")]
    t.eq(RoutingStore.displayName(for: acme, projects: projects, language: "es"), "De @acme.com → 🚀 Acme", "displayName generated")
    t.eq(RoutingStore.displayName(for: nubia, projects: projects, language: "es"), "El asunto contiene «Nubia» → 🤝 Alianza", "displayName generic")
    t.eq(RoutingStore.displayName(for: news, projects: projects, language: "en"), "From @news.io → Unassigned", "displayName inbox (en)")
    t.eq(RoutingStore.displayName(for: both, projects: projects, language: "es"), "De @acme.com y el asunto contiene «factura» → p", "AND name, unknown project")
    var named = acme
    named.name = "Clientes Acme"
    t.eq(RoutingStore.displayName(for: named, projects: projects, language: "es"), "Clientes Acme", "a given name wins")

    // --- Precedence on a temp vault (§14.2).
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("engine/vault").path
    config.dataPath = root.appendingPathComponent("engine/data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: RoutingNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        try engine.vault.setOwnerEmails(["jaime@dive.ai"])
        let pAcme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")
        let pAlianza = try engine.projects.create(name: "Alianza", description: "Socio", emoji: "🤝")
        let pGeneral = try engine.projects.create(name: "General", description: "Todo lo demás", emoji: "📦")
        t.check(engine.routing.fileURL == RoutingStore.fileURL(vaultRoot: engine.vault.root), "engine.routing reads the vault's file")
        let ruleAcme = RoutingRule(.senderDomain, .is, "acme.com", projectSlug: pAcme.slug)
        let ruleNews = RoutingRule(.subject, .contains, "boletin", projectSlug: nil)
        try engine.routing.add(ruleAcme)
        try engine.routing.add(ruleNews)
        var minute = 0
        func email(_ from: String, _ subject: String, _ body: String) -> ParsedEmail {
            minute += 1
            return engine.parseEmail("From: \(from)\nTo: Jaime <jaime@dive.ai>\nDate: 24/10/2026 10:\(String(format: "%02d", minute))\nSubject: \(subject)\n\n\(body)")
        }

        // Existing thread in a project > rule.
        let first = try engine.addEmail(email("Laura <laura@otro.com>", "Contrato", "Va el contrato."), threadKey: nil, projectSlug: pAlianza.slug)
        t.eq(first.projectSlug, pAlianza.slug, "explicit project")
        t.check(engine.lastRoutingDecision == nil, "explicit choice: no routing")
        let reply = try engine.addEmail(email("Ana <ana@acme.com>", "Re: Contrato", "Lo reviso."), threadKey: first.threadKey, projectSlug: nil)
        t.eq(reply.projectSlug, pAlianza.slug, "thread in a project beats the rule")
        t.check(engine.lastRoutingDecision == nil, "thread kept: no decision")
        t.eq(engine.routing.rule(id: ruleAcme.id)?.hits, 0, "thread kept: no hit")

        // Rule.
        let ruled = try engine.addEmail(email("Ana <ana@acme.com>", "Kickoff", "Arrancamos."), threadKey: nil, projectSlug: nil)
        t.eq(ruled.projectSlug, pAcme.slug, "rule → project")
        t.check((ruled.rawPath ?? "").hasPrefix("projects/\(pAcme.slug)/raw/emails/"), "routed raw in the project: \(ruled.rawPath ?? "-")")
        t.eq(engine.lastRoutingDecision?.rule.id, ruleAcme.id, "lastRoutingDecision = the rule")
        t.eq(engine.routing.rule(id: ruleAcme.id)?.hits, 1, "hit recorded")
        t.check(engine.jobs.contains { $0.sourceId == ruled.id && $0.kind == .ingest }, "routed email queued for ingest")

        // Default project.
        try engine.routing.setDefaultProject(pGeneral.slug)
        let defaulted = try engine.addEmail(email("Pedro <pedro@random.org>", "Hola qué tal", "Saludos."), threadKey: nil, projectSlug: nil)
        t.eq(defaulted.projectSlug, pGeneral.slug, "no rule → default project")
        t.check(engine.lastRoutingDecision == nil, "default: no rule decision")
        // Explicit inbox rule beats the default.
        let letter = try engine.addEmail(email("News <hola@letters.io>", "Boletín de octubre", "Novedades."), threadKey: nil, projectSlug: nil)
        t.eq(letter.projectSlug, nil, "nil-project rule → inbox even with a default")
        t.eq(engine.lastRoutingDecision?.rule.id, ruleNews.id, "explicit inbox rule reported")
        // A rule to a deleted project falls through to the default.
        try engine.routing.add(RoutingRule(.senderDomain, .is, "ghost.io", projectSlug: "ghost"))
        let ghost = try engine.addEmail(email("G <g@ghost.io>", "Fantasma", "Bu."), threadKey: nil, projectSlug: nil)
        t.eq(ghost.projectSlug, pGeneral.slug, "rule to a missing project → default")

        // Inbox: no default, no rule.
        try engine.routing.setDefaultProject(nil)
        let inbox = try engine.addEmail(email("X <x@nowhere.org>", "Pregunta suelta", "¿Qué tal?"), threadKey: nil, projectSlug: nil)
        t.eq(inbox.projectSlug, nil, "no rule, no default → inbox")
        t.check((inbox.rawPath ?? "").hasPrefix("_inbox/emails/") && inbox.status == .needsProject, "inbox raw + needsProject")
        // routeIfUnassigned: false bypasses rules and default.
        try engine.routing.setDefaultProject(pGeneral.slug)
        let chosen = try engine.addEmail(email("Bob <bob@acme.com>", "Para el inbox", "A propósito."), threadKey: nil, projectSlug: nil,
                                         routeIfUnassigned: false)
        t.eq(chosen.projectSlug, nil, "routeIfUnassigned:false → inbox")
        t.check(engine.lastRoutingDecision == nil, "bypass: no decision")
        // An inbox thread: the default never moves it; a rule does.
        let keep = try engine.addEmail(email("Q <q@zeta.com>", "Zeta inicio", "Hola."), threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        let keepReply = try engine.addEmail(email("Q <q@zeta.com>", "Re: Zeta inicio", "Sigo."), threadKey: keep.threadKey, projectSlug: nil)
        t.eq(keepReply.projectSlug, nil, "inbox thread: the default doesn't move it")
        try engine.routing.add(RoutingRule(.senderDomain, .is, "zeta.com", projectSlug: pAlianza.slug))
        let moved = try engine.addEmail(email("Q <q@zeta.com>", "Re: Zeta inicio", "Y algo más."), threadKey: keep.threadKey, projectSlug: nil)
        t.eq(moved.projectSlug, pAlianza.slug, "inbox thread + rule → moves to the project")
        t.check(engine.emails(inThread: keep.threadKey ?? "-").allSatisfy { $0.projectSlug == pAlianza.slug }, "whole thread moved")
        try engine.routing.setDefaultProject(nil)

        // addEmails routes the batch (first message decides, the rest follow the thread).
        let batch = try engine.addEmails([email("Ana <ana@acme.com>", "Factura", "Uno."), email("Jaime <jaime@dive.ai>", "Re: Factura", "Dos.")],
                                         threadKey: nil, projectSlug: nil)
        t.check(batch.count == 2 && batch.allSatisfy { $0.projectSlug == pAcme.slug }, "addEmails routed")
        t.eq(engine.lastRoutingDecision?.rule.id, ruleAcme.id, "addEmails reports the rule")
        let batchInbox = try engine.addEmails([email("Ana <ana@acme.com>", "Otra factura", "Tres.")], threadKey: nil, projectSlug: nil,
                                              routeIfUnassigned: false)
        t.eq(batchInbox.first?.projectSlug, nil, "addEmails routeIfUnassigned:false")

        // Connected account messages.
        let account = ConnectedAccount(provider: .microsoft, email: "jaime@dive.ai")
        func msg(_ id: String, _ from: String, _ subject: String) -> MailMessageFull {
            MailMessageFull(summary: MailMessageSummary(id: id, threadId: "t-\(id)", from: a(from), to: [a("jaime@dive.ai")], subject: subject,
                                                        snippet: "", date: Date(timeIntervalSince1970: 1_800_000_000 + Double(id.count * 60))),
                            bodyText: "Mensaje \(id)")
        }
        let viaRule = try engine.addMailMessages([msg("r1", "sofia@acme.com", "Entrega")], account: account, threadKey: nil, projectSlug: nil)
        t.eq(viaRule.first?.projectSlug, pAcme.slug, "addMailMessages routes")
        let bypass = try engine.addMailMessages([msg("r22", "sofia@acme.com", "Entrega 2")], account: account, threadKey: nil, projectSlug: nil,
                                                routeIfUnassigned: false)
        t.eq(bypass.first?.projectSlug, nil, "addMailMessages(routeIfUnassigned:false) → inbox")
        let afterBypass = try engine.addMailMessages([msg("r333", "sofia@acme.com", "Entrega 3")], account: account, threadKey: nil, projectSlug: nil,
                                                     routeIfUnassigned: true)
        t.eq(afterBypass.first?.projectSlug, pAcme.slug, "the bypass doesn't stick")

        // Preview: no hit.
        let hits = engine.routing.rule(id: ruleAcme.id)?.hits ?? 0
        let preview = engine.routingPreview(.mail(summary, ownerEmails: ["jaime@dive.ai"]))
        t.eq(preview.projectSlug, pAcme.slug, "routingPreview")
        t.eq(engine.routing.rule(id: ruleAcme.id)?.hits ?? 0, hits, "routingPreview doesn't count")
        engine.routing.flush()
        t.eq(RoutingStore(fileURL: engine.routing.fileURL).rule(id: ruleAcme.id)?.hits, hits, "engine hits persisted")
    } catch {
        t.check(false, "precedence: \(error)")
    }
}

private final class RoutingNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
