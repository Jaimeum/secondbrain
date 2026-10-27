import ArgumentParser
import BrainCore
import Foundation

/// Focused checks of the v0.2 engine pieces that need no Claude and no audio: email parsing, thread matching, tasks,
/// dates/timeline, export assembly and vault migration. `sb selftest --dir <tmp> [--v01 <copy of a v0.1 setup>]`.
/// Run it under several `TZ=` values: every date check is time-zone independent.
struct SelfTest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Run the engine self-tests.",
                                                    shouldDisplay: false)
    @Option(help: "Scratch folder (created/emptied)") var dir: String
    @Option(help: "A v0.1 setup folder (config.json, vault, data) to test migration and export against (copied, not modified)")
    var v01: String?
    @Option(help: "Only groups whose name contains this") var filter: String?

    @MainActor func run() async throws {
        let t = Tester(filter: filter)
        let root = URL(fileURLWithPath: (dir as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        print("TZ: \(TimeZone.current.identifier) (\(SBDate.iso(Date())))")

        t.group("dates") { testDates(t) }
        t.group("email-parse") { testEmailParsing(t) }
        t.group("tasks-parse") { testTaskParsing(t) }
        t.group("integration-fixes") { testIntegrationFixes(t) }
        await t.groupAsync("v03-models") { await testV3Models(t, root: root.appendingPathComponent("v03")) }
        await t.groupAsync("accounts") { await testAccounts(t, root: root.appendingPathComponent("accounts")) }   // MARK: v0.3 accounts
        await t.groupAsync("v03-meetings") { await testMeetings(t, root: root.appendingPathComponent("meetings")) }
        await t.groupAsync("engine") { await testEngine(t, root: root.appendingPathComponent("engine")) }
        await t.groupAsync("graph") { await testGraph(t, root: root.appendingPathComponent("graph")) }  // MARK: v0.3 graph
        await t.groupAsync("mail") { await testMail(t, root: root.appendingPathComponent("mail")) }   // MARK: v0.3 mail
        await t.groupAsync("github") { await testGitHub(t, root: root.appendingPathComponent("github")) }   // MARK: v0.4 github
        await t.groupAsync("routing") { await testRouting(t, root: root.appendingPathComponent("routing")) }   // MARK: v0.4 routing
        await t.groupAsync("routing-mail") { await testRoutingMail(t, root: root.appendingPathComponent("routing-mail")) }   // MARK: v0.4 routing mail
        await t.groupAsync("routing-meetings") { await testRoutingMeetings(t, root: root.appendingPathComponent("routing-meetings")) }   // MARK: v0.4 rules UI
        await t.groupAsync("routing-review") { await testRoutingReview(t, root: root.appendingPathComponent("routing-review")) }   // MARK: v0.4 review fixes
        if let v01 {
            await t.groupAsync("migration") { await testMigration(t, source: URL(fileURLWithPath: v01), root: root.appendingPathComponent("v01")) }
        }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

@MainActor final class Tester {
    var passed = 0
    var failures: [String] = []
    var current = ""
    let filter: String?
    init(filter: String?) { self.filter = filter }

    func group(_ name: String, _ body: () -> Void) {
        guard filter.map({ name.contains($0) }) ?? true else { return }
        current = name
        print("· \(name)")
        body()
    }

    func groupAsync(_ name: String, _ body: () async -> Void) async {
        guard filter.map({ name.contains($0) }) ?? true else { return }
        current = name
        print("· \(name)")
        await body()
    }

    func check(_ cond: Bool, _ what: @autoclosure () -> String) {
        if cond { passed += 1 } else { failures.append("[\(current)] \(what())") }
    }

    func eq<T: Equatable>(_ a: T, _ b: T, _ what: String) {
        check(a == b, "\(what): got \(a), expected \(b)")
    }
}

// MARK: - Helpers

private func local(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0, _ s: Int = 0, tz: TimeZone = .current) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = tz
    return cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
}

private func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Date { local(y, mo, d, h, mi, tz: TimeZone(identifier: "UTC")!) }

private let owner = ["jaime@dive.ai"]

// MARK: - Integration fixes (found in the v0.2 E2E)

@MainActor private func testIntegrationFixes(_ t: Tester) {
    // "para mí" is the FIRST address the owner listed, not the alphabetically first one.
    let gmail = "Presupuesto\n\nLaura <laura@cliente.mx>\nmié, 21 oct 2026, 16:40\npara mí, Diego\n\nHola Jaime"
    let e = EmailParser.parse(gmail, ownerEmails: ["jaime@dive.ai", "jaime.ruiz@xfiles.mx"], ownerName: "Jaime")
    t.eq(e.to.first?.email ?? "nil", "jaime@dive.ai", "para mí → primary owner address")
    // A received forward: Gmail's subject line ("Fwd: …") wins over the Subject: of the forwarded message.
    let fwd = """
    Fwd: RE: Presupuesto caso Roswell

    Diego <diego@xfiles.mx>
    vie, 23 oct 2026, 8:05
    para mí

    Te reenvío lo de Walter.

    ---------- Forwarded message ---------
    De: Walter Skinner <w.skinner@cliente.mx>
    Date: jue, 22 oct 2026 a las 9:15
    Subject: RE: Presupuesto caso Roswell
    To: Jaime <jaime@dive.ai>

    Hi Jaime
    """
    let f = EmailParser.parse(fwd, ownerEmails: owner)
    t.eq(f.subject ?? "nil", "Fwd: RE: Presupuesto caso Roswell", "forward keeps its own subject")
    t.eq(f.from?.email ?? "nil", "diego@xfiles.mx", "forward is from the forwarder")
    t.check(f.quotedHistory?.contains("Walter") == true, "forwarded message kept as quoted history")
}

// MARK: - Dates

@MainActor private func testDates(_ t: Tester) {
    let now = local(2026, 10, 29, 12, 0)
    let cases: [(String, Date)] = [
        ("lun, 26 oct 2026, 10:15", local(2026, 10, 26, 10, 15)),
        ("lun, 26 oct 2026, 10:15 (hace 3 días)", local(2026, 10, 26, 10, 15)),
        ("Monday, October 26, 2026 at 10:15 AM", local(2026, 10, 26, 10, 15)),
        ("Monday, October 26, 2026 10:15 PM", local(2026, 10, 26, 22, 15)),
        ("Mon, Oct 26, 2026, 3:42 PM", local(2026, 10, 26, 15, 42)),
        ("26/10/2026 10:15", local(2026, 10, 26, 10, 15)),
        ("10/26/2026 10:15 AM", local(2026, 10, 26, 10, 15)),
        ("26.10.2026 10:15", local(2026, 10, 26, 10, 15)),
        ("Mon, 26 Oct 2026 10:15:00 -0600", utc(2026, 10, 26, 16, 15)),
        ("Mon, 26 Oct 2026 10:15:00 -0600 (CST)", utc(2026, 10, 26, 16, 15)),
        ("Mon, 26 Oct 2026 16:15:00 +0000", utc(2026, 10, 26, 16, 15)),
        ("2026-10-26T10:15:00-06:00", utc(2026, 10, 26, 16, 15)),
        ("2026-10-26T16:15:00Z", utc(2026, 10, 26, 16, 15)),
        ("lunes, 26 de octubre de 2026 10:15 p. m.", local(2026, 10, 26, 22, 15)),
        ("lunes, 26 de octubre de 2026, 10:15 a. m.", local(2026, 10, 26, 10, 15)),
        ("26 de octubre de 2026, 10:15:00 CST", utc(2026, 10, 26, 16, 15)),
        ("October 26, 2026 at 10:15:00 AM EDT", utc(2026, 10, 26, 14, 15)),
        ("Mon, Oct 26, 2026 at 10:15 AM GMT-6", utc(2026, 10, 26, 16, 15)),
        ("mar, 27 oct 2026, 9:05", local(2026, 10, 27, 9, 5)),
        ("mié, 28 oct 2026, 18:00", local(2026, 10, 28, 18, 0)),
        ("Tue, Oct 27, 10:05 AM (2 days ago)", local(2026, 10, 27, 10, 5)),
        ("27 oct, 10:05", local(2026, 10, 27, 10, 5)),
        ("Oct 26, 2026, 12:30 AM", local(2026, 10, 26, 0, 30)),
        ("Oct 26, 2026, 12:30 PM", local(2026, 10, 26, 12, 30)),
        ("10:15 (hace 5 minutos)", local(2026, 10, 29, 10, 15)),
        ("ayer 18:30", local(2026, 10, 28, 18, 30)),
    ]
    for (text, expected) in cases {
        let got = EmailParser.parseDate(text, now: now)
        t.check(got == expected, "parseDate(\(text)) = \(got.map { SBDate.iso($0) } ?? "nil"), expected \(SBDate.iso(expected))")
    }
    // Year missing and the date would be in the future → last year.
    let jan = local(2027, 1, 2, 9, 0)
    t.eq(EmailParser.parseDate("Thu, Dec 31, 11:00 PM", now: jan), local(2026, 12, 31, 23, 0), "missing year rolls back")
    t.check(EmailParser.parseDate("hola qué tal", now: now) == nil, "non-date → nil")
    t.check(EmailParser.parseDate("32/13/2026", now: now) == nil, "invalid → nil")

    // ISO round trips keep the instant and carry the local offset.
    for d in [Date(timeIntervalSince1970: 1_793_000_000), local(2026, 3, 29, 2, 30), local(2026, 11, 1, 1, 30)] {
        let iso = SBDate.iso(d)
        t.check(SBDate.parseISO(iso)?.date == d, "ISO round trip \(iso)")
        t.check(iso.hasSuffix("Z") || iso.range(of: #"[+-]\d{2}:\d{2}$"#, options: .regularExpression) != nil, "ISO has offset: \(iso)")
    }
    t.eq(SBDate.parseISO("2026-10-26")?.hasTime, false, "date-only ISO")
    t.eq(SBDate.parseISO("2026-10-26")?.date, local(2026, 10, 26), "date-only is local midnight")
    t.eq(SBDate.parseISO("\"2026-10-26T15:30:00-06:00\"")?.date, utc(2026, 10, 26, 21, 30), "quoted ISO (Claude's event_date)")
    t.eq(SBDate.human(local(2026, 10, 26, 15, 30), language: "es"), "26 oct 2026, 15:30", "human es")
    t.check(SBDate.human(local(2026, 10, 26, 15, 30), language: "en").contains("Oct 26, 2026"), "human en")
}

// MARK: - Email parsing

@MainActor private func testEmailParsing(_ t: Tester) {
    let now = local(2026, 10, 29, 12, 0)
    func p(_ s: String) -> ParsedEmail { EmailParser.parse(s, ownerEmails: owner, ownerName: "Jaime Ruiz", now: now) }

    // 1. Gmail (es), one message.
    var e = p("""
    Contrato proveedor Acme
    Recibidos

    Ana García <ana@acme.com>
    lun, 26 oct 2026, 10:15 (hace 3 días)
    para mí, Luis

    Hola Jaime,

    Te mando el contrato revisado. ¿Lo puedes firmar antes del viernes?

    Saludos,
    Ana
    """)
    t.eq(e.subject, "Contrato proveedor Acme", "gmail-es subject")
    t.eq(e.from?.email, "ana@acme.com", "gmail-es from email")
    t.eq(e.from?.name, "Ana García", "gmail-es from name")
    t.eq(e.date, local(2026, 10, 26, 10, 15), "gmail-es date")
    t.eq(e.to.map(\.display), ["Jaime Ruiz", "Luis"], "gmail-es to (para mí → owner)")
    t.eq(e.to.first?.email, "jaime@dive.ai", "gmail-es 'mí' gets the owner's address")
    t.check(e.body.hasPrefix("Hola Jaime,") && e.body.hasSuffix("Ana"), "gmail-es body: \(e.body)")
    t.check(e.quotedHistory == nil, "gmail-es no quote")
    t.check(!e.isFromOwner, "gmail-es not from owner")

    // 2. Gmail (en) reply with ">" quote and "On … wrote:".
    e = p("""
    Re: Q4 budget review
    Inbox

    Luis Pérez <luis.perez@acme.com>
    Mon, Oct 26, 2026, 3:42 PM (2 days ago)
    to me

    Sounds good, let's go with option B.

    On Mon, Oct 26, 2026 at 10:15 AM Jaime Ruiz <jaime@dive.ai> wrote:
    > Hi Luis,
    > Which option do you prefer for the Q4 budget?
    >
    > Thanks
    """)
    t.eq(e.subject, "Re: Q4 budget review", "gmail-en subject")
    t.eq(e.date, local(2026, 10, 26, 15, 42), "gmail-en date")
    t.eq(e.body, "Sounds good, let's go with option B.", "gmail-en body")
    t.check(e.quotedHistory?.hasPrefix("On Mon, Oct 26, 2026") == true, "gmail-en quote start")
    t.check(e.quotedHistory?.contains("Which option") == true, "gmail-en quote content")

    // 3. Gmail quote header wrapped over two lines (es).
    e = p("""
    Perfecto, nos vemos el jueves.

    El lun, 26 oct 2026 a las 10:15, Ana García (<
    ana@acme.com>) escribió:

    > Hola, ¿podemos vernos el jueves?
    """)
    t.eq(e.body, "Perfecto, nos vemos el jueves.", "wrapped escribió body")
    t.check(e.quotedHistory?.hasPrefix("El lun, 26 oct") == true, "wrapped escribió quote")
    t.check(e.from == nil && e.date == nil, "header-less paste has no from/date")

    // 4. Outlook (en) reply chain.
    e = p("""
    From: Ana García <ana@acme.com>
    Sent: Monday, October 26, 2026 10:15 AM
    To: Jaime Ruiz <jaime@dive.ai>; Luis Pérez <luis.perez@acme.com>
    Cc: Marta López <marta@acme.com>
    Subject: RE: Contrato proveedor Acme

    Jaime, adjunto la versión final.

    Ana

    ________________________________
    From: Jaime Ruiz <jaime@dive.ai>
    Sent: Friday, October 23, 2026 6:02 PM
    To: Ana García <ana@acme.com>
    Subject: Contrato proveedor Acme

    Ana, ¿me mandas la versión final?
    """)
    t.eq(e.subject, "RE: Contrato proveedor Acme", "outlook-en subject")
    t.eq(e.date, local(2026, 10, 26, 10, 15), "outlook-en date")
    t.eq(e.to.compactMap(\.email), ["jaime@dive.ai", "luis.perez@acme.com"], "outlook-en to")
    t.eq(e.cc.compactMap(\.email), ["marta@acme.com"], "outlook-en cc")
    t.eq(e.body, "Jaime, adjunto la versión final.\n\nAna", "outlook-en body")
    t.check(e.quotedHistory?.hasPrefix("______") == true, "outlook-en quote at separator")
    t.eq(EmailParser.normalizeSubject(e.subject ?? ""), "Contrato proveedor Acme", "outlook-en normalized subject")

    // 5. Outlook (es) forward, no separator line.
    e = p("""
    De: Ana García <ana@acme.com>
    Enviado el: lunes, 26 de octubre de 2026 10:15
    Para: Jaime Ruiz <jaime@dive.ai>
    CC: 'Luis Pérez' <luis.perez@acme.com>
    Asunto: RV: Propuesta de calendario

    Te reenvío lo de Luis.

    De: Luis Pérez <luis.perez@acme.com>
    Enviado el: viernes, 23 de octubre de 2026 17:30
    Para: Ana García <ana@acme.com>
    Asunto: Propuesta de calendario

    Propongo entregar el 15 de noviembre.
    """)
    t.eq(e.subject, "RV: Propuesta de calendario", "outlook-es subject")
    t.eq(e.date, local(2026, 10, 26, 10, 15), "outlook-es date")
    t.eq(e.cc.first?.name, "Luis Pérez", "outlook-es cc quoted name")
    t.eq(e.body, "Te reenvío lo de Luis.", "outlook-es body")
    t.check(e.quotedHistory?.hasPrefix("De: Luis Pérez") == true, "outlook-es quote")
    t.eq(EmailParser.normalizeSubject("RV: Propuesta de calendario"), "Propuesta de calendario", "RV prefix")

    // 6. Apple Mail (es) with zone name and ">" quote.
    e = p("""
    De: Ana García <ana@acme.com>
    Asunto: Re: Minuta de la junta
    Fecha: 26 de octubre de 2026, 10:15:00 CST
    Para: Jaime Ruiz <jaime@dive.ai>

    Perfecto, quedo atenta.

    > El 25 oct 2026, a las 18:00, Jaime Ruiz <jaime@dive.ai> escribió:
    >
    > Ana, te comparto la minuta.
    """)
    t.eq(e.date, utc(2026, 10, 26, 16, 15), "apple-es date with CST")
    t.eq(e.body, "Perfecto, quedo atenta.", "apple-es body")
    t.check(e.quotedHistory?.contains("te comparto la minuta") == true, "apple-es quote")

    // 7. Apple Mail (en).
    e = p("""
    From: Ana García <ana@acme.com>
    Subject: Re: Launch plan
    Date: October 26, 2026 at 10:15:00 AM EDT
    To: Jaime Ruiz <jaime@dive.ai>

    Works for me.

    > On Oct 25, 2026, at 6:00 PM, Jaime Ruiz <jaime@dive.ai> wrote:
    > Shall we launch on Nov 15?
    """)
    t.eq(e.date, utc(2026, 10, 26, 14, 15), "apple-en date with EDT")
    t.eq(e.body, "Works for me.", "apple-en body")

    // 8. Gmail forward pasted without the forwarder's headers.
    e = p("""
    ---------- Forwarded message ---------
    From: Ana García <ana@acme.com>
    Date: Mon, Oct 26, 2026 at 10:15 AM
    Subject: Contrato proveedor Acme
    To: Jaime Ruiz <jaime@dive.ai>


    Hola Jaime, te mando el contrato.
    """)
    t.eq(e.from?.email, "ana@acme.com", "bare forward: original sender")
    t.eq(e.date, local(2026, 10, 26, 10, 15), "bare forward: original date")
    t.eq(e.body, "Hola Jaime, te mando el contrato.", "bare forward: body")

    // 9. Gmail (es) forward with the forwarder's block; "mar" = martes, not marzo.
    e = p("""
    Fwd: Contrato proveedor Acme
    Recibidos

    Luis Pérez <luis.perez@acme.com>
    mar, 27 oct 2026, 9:05
    para mí

    FYI, mira esto.

    ---------- Mensaje reenviado ---------
    De: Ana García <ana@acme.com>
    Date: lun, 26 oct 2026 a las 10:15
    Subject: Contrato proveedor Acme
    To: Luis Pérez <luis.perez@acme.com>

    Hola Luis, te mando el contrato.
    """)
    t.eq(e.from?.email, "luis.perez@acme.com", "gmail fwd: forwarder")
    t.eq(e.date, local(2026, 10, 27, 9, 5), "gmail fwd: date (mar = martes)")
    t.eq(e.body, "FYI, mira esto.", "gmail fwd: note")
    t.check(e.quotedHistory?.hasPrefix("---------- Mensaje reenviado") == true, "gmail fwd: forwarded part quoted")
    t.eq(EmailParser.normalizeSubject(e.subject ?? ""), "Contrato proveedor Acme", "Fwd prefix")

    // 10. Gmail conversation copy: three messages.
    let conversation = """
    Contrato proveedor Acme
    Recibidos

    Ana García <ana@acme.com>
    vie, 23 oct 2026, 18:02
    para mí

    Jaime, ¿revisaste el contrato?

    Jaime Ruiz <jaime@dive.ai>
    lun, 26 oct 2026, 9:00
    para Ana

    Sí, lo firmo hoy.

    Ana García <ana@acme.com>
    lun, 26 oct 2026, 10:15
    para mí

    ¡Gracias!
    """
    let all = EmailParser.parseAll(conversation, ownerEmails: owner, now: now)
    t.eq(all.count, 3, "conversation: 3 messages")
    t.eq(all.map(\.body), ["Jaime, ¿revisaste el contrato?", "Sí, lo firmo hoy.", "¡Gracias!"], "conversation bodies in order")
    t.eq(all.map(\.isFromOwner), [false, true, false], "conversation: owner's message")
    t.check(all.allSatisfy { $0.subject == "Contrato proveedor Acme" }, "conversation: shared subject")
    e = p(conversation)
    t.eq(e.body, "¡Gracias!", "conversation: parse() → newest")
    t.check(e.quotedHistory?.contains("Sí, lo firmo hoy.") == true, "conversation: earlier messages kept as history")

    // 11. RFC 2822 headers, quoted display name with comma, [tags] and stacked prefixes.
    e = p("""
    Date: Mon, 26 Oct 2026 10:15:00 -0600
    From: "García, Ana" <ana@acme.com>
    To: jaime@dive.ai
    Subject: [EXTERNAL] RE: FW: Contrato

    Va el contrato.
    """)
    t.eq(e.from?.name, "García, Ana", "rfc quoted name")
    t.eq(e.to.first?.email, "jaime@dive.ai", "rfc bare address")
    t.eq(e.date, utc(2026, 10, 26, 16, 15), "rfc date")
    t.eq(EmailParser.normalizeSubject(e.subject ?? ""), "Contrato", "tags + stacked prefixes")

    // 12. Outlook [mailto:], recipients without addresses; from the owner.
    e = p("""
    From: Jaime Ruiz [mailto:Jaime@Dive.ai]
    Sent: Monday, October 26, 2026 10:15 AM
    To: Ana García; Luis Pérez
    Subject: Contrato

    Listo.
    """)
    t.eq(e.from?.email, "jaime@dive.ai", "mailto lowercased")
    t.check(e.isFromOwner, "from the owner")
    t.eq(e.to.map(\.display), ["Ana García", "Luis Pérez"], "names-only recipients")

    // 13. Gmail "en" today: only a time.
    e = p("""
    Ana García <ana@acme.com>
    10:15 (hace 5 minutos)
    para mí

    ¿Lo viste?
    """)
    t.eq(e.date, local(2026, 10, 29, 10, 15), "gmail today time only")

    // 14. Prose that looks like a quote header is not cut; Gmail sender + date on one tab-separated line.
    e = p("""
    Ana García <ana@acme.com>\tlun, 26 oct 2026, 10:15 (hace 3 días)\t
    para mí

    Hola. El viernes Luis me escribió:
    "mándame el contrato". Se lo mandé.
    """)
    t.eq(e.date, local(2026, 10, 26, 10, 15), "gmail one-line sender+date")
    t.check(e.body.contains("Se lo mandé.") && e.quotedHistory == nil, "prose 'me escribió:' kept in the body")

    // 15. Outlook (es, new) "Enviado:" with a. m., Para with several names; signature + disclaimer stay in the body.
    e = p("""
    De: Luis Pérez <luis.perez@acme.com>
    Enviado: martes, 27 de octubre de 2026 09:05 a. m.
    Para: Jaime Ruiz <jaime@dive.ai>; Ana García <ana@acme.com>
    Asunto: Calendario

    Confirmo el 15 de noviembre.

    Luis Pérez | Director
    """)
    t.eq(e.date, local(2026, 10, 27, 9, 5), "outlook-es new: date with a. m.")
    t.eq(e.to.count, 2, "outlook-es new: recipients")
    t.check(e.body.hasSuffix("Luis Pérez | Director"), "signature kept")

    // 16. Subjects.
    t.eq(EmailParser.normalizeSubject("Re: RE: Fwd: AW: WG: TR: Rv: Hola  mundo"), "Hola mundo", "many prefixes")
    t.eq(EmailParser.subjectKey("RE: Revisión del Contrato"), "revision del contrato", "subject key")
    t.eq(EmailParser.parseAddresses("Ana <a@x.com>, \"Pérez, Luis\" <l@y.com>; bob@z.com").compactMap(\.email),
         ["a@x.com", "l@y.com", "bob@z.com"], "address list")
    t.eq(EmailParser.parseAddresses("García, Ana <ana@x.com>").count, 1, "unquoted comma name glued")
}

// MARK: - Tasks

private let tasksFixture = """
---
type: tasks
title: "Acme — pendientes"
project: acme
---

# Acme — pendientes

## Abiertas

### Yo — [[jaime-ruiz|Jaime Ruiz]]
- [ ] Preparar la demo — [[jaime-ruiz|Jaime]] · 📅 2026-10-30 · ([[2026-10-26-1530-kickoff]] 00:15:20)
- [ ] Mandar el contrato firmado — [[jaime-ruiz|Jaime]] · 📅 2026-10-28 (antes 2026-10-25) · ([[2026-10-21-1015-ana-garcia]]; [[2026-10-23-0900-ana-garcia]])

### [[ana-garcia|Ana García]]
- [ ] Enviar propuesta revisada a Acme — [[ana-garcia|Ana]] · 📅 2026-11-03 · ([[2026-10-26-1530-kickoff]] 00:14:05)

### Diego
- [ ] Entregar la versión en inglés del informe — [[diego|Diego]] · 📅 2026-10-30 · («viernes 30 de octubre», dicho en la reunión) ([[2026-10-26-1230-reunion-12-30]] 00:00:46; 00:00:51)
- [ ] Revisar fotos — Diego · ([[2026-10-26-1230-reunion-12-30]] 00:01:00)

## Sin dueño
- [ ] Pedir el logo en alta resolución · ([[2026-10-26-1530-kickoff]] 00:25:00)

## Hechas
- [x] Reservar sala para demo — [[jaime-ruiz|Jaime]] · 📅 2026-10-28 · ✅ 2026-10-27 · ([[2026-10-26-1530-kickoff]] 00:20:10; [[2026-10-27-nota-sala]])
"""

@MainActor private func testTaskParsing(_ t: Tester) {
    let owner = TaskParser.OwnerInfo(slugs: ["jaime-ruiz"], names: ["jaime ruiz", "jaime"])
    let items = TaskParser.parse(tasksFixture, path: "projects/acme/wiki/tasks.md", projectSlug: "acme", owner: owner)
    t.eq(items.count, 7, "task count")
    guard items.count == 7 else { return }
    t.eq(items[0].text, "Preparar la demo", "text")
    t.check(items[0].isMine, "owner group → mine")
    t.eq(items[0].ownerSlug, "jaime-ruiz", "owner slug")
    t.eq(items[0].due, local(2026, 10, 30), "due")
    t.eq(items[0].sourceKeys, ["2026-10-26-1530-kickoff"], "citation keys")
    t.eq(items[1].due, local(2026, 10, 28), "current due, not the (antes …) one")
    t.eq(items[1].sourceKeys, ["2026-10-21-1015-ana-garcia", "2026-10-23-0900-ana-garcia"], "two citations")
    t.check(!items[2].isMine && items[2].ownerSlug == "ana-garcia" && items[2].ownerName == "Ana", "other's task")
    t.eq(items[3].text, "Entregar la versión en inglés del informe", "note before citation stripped")
    t.eq(items[3].sourceKeys, ["2026-10-26-1230-reunion-12-30"], "citation after a note")
    t.eq(items[4].ownerName, "Diego", "plain-text owner")
    t.check(items[5].ownerName == nil && items[5].ownerSlug == nil && !items[5].isMine, "unowned")
    t.eq(items[5].text, "Pedir el logo en alta resolución", "unowned text")
    t.check(items[6].done && items[6].doneDate == local(2026, 10, 27) && items[6].isMine, "done task")
    t.eq(Set(items.map(\.id)).count, 7, "ids unique")
    t.check(items.allSatisfy { $0.id.hasPrefix("projects/acme/wiki/tasks.md#") }, "id format")

    // Owner not known yet: "### Yo" and "— Yo".
    let unknown = TaskParser.parse("## Abiertas\n### Yo\n- [ ] Llamar a Ana — Yo · 📅 2026-11-01 · ([[k]] 00:01:00)\n",
                                   path: "p", projectSlug: "x", owner: .init())
    t.check(unknown.first?.isMine == true, "'Yo' group without a person page → mine")

    // Toggling keeps the line format.
    let line = "- [ ] Enviar propuesta revisada a Acme — [[ana-garcia|Ana]] · 📅 2026-11-03 · ([[2026-10-26-1530-kickoff]] 00:14:05)"
    let done = TaskParser.toggled(line, done: true, on: local(2026, 10, 29, 9, 0))
    t.eq(done, "- [x] Enviar propuesta revisada a Acme — [[ana-garcia|Ana]] · 📅 2026-11-03 · ✅ 2026-10-29 · ([[2026-10-26-1530-kickoff]] 00:14:05)",
         "toggle done")
    t.eq(TaskParser.toggled(done, done: false), line, "toggle back")
    let parsedDone = TaskParser.parseLine(done, projectSlug: "acme")
    t.check(parsedDone?.done == true && parsedDone?.doneDate == local(2026, 10, 29) && parsedDone?.due == local(2026, 11, 3), "reparse toggled")
}

// MARK: - Engine (temp vault)

private final class NoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}

@MainActor private func makeTestEngine(_ root: URL) -> BrainEngine {
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: NoTranscriber())
    engine.autoProcess = false
    engine.start()
    return engine
}

@MainActor private func testEngine(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    let engine = makeTestEngine(root)
    do {
        try engine.vault.setOwnerName("Jaime Ruiz")
        try engine.vault.setOwnerEmails(["Jaime@Dive.ai", "jaime.ruiz@empresa.com"])
        t.eq(engine.vault.ownerEmails(), ["jaime@dive.ai", "jaime.ruiz@empresa.com"], "owner emails round trip")
        t.eq(engine.vault.ownerName(), "Jaime Ruiz", "owner name kept")
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🏢")
        t.check(fm.fileExists(atPath: engine.vault.url(for: "projects/acme/wiki/timeline.md").path)
                || !fm.fileExists(atPath: (VaultStore.templateURL?.appendingPathComponent("project/wiki/timeline.md").path) ?? "/none"),
                "new project gets timeline.md")

        // --- Raw dates: event vs added, with offsets.
        let event = local(2026, 10, 20, 9, 30)
        try engine.addNote(title: "Minuta vieja", body: "Se habló del lanzamiento.", projectSlug: acme.slug, eventDate: event)
        guard let note = engine.sources.first(where: { $0.title == "Minuta vieja" }), let notePath = note.rawPath else {
            t.check(false, "note created"); return
        }
        let noteText = try engine.vault.read(notePath)
        t.eq(note.eventDate, event, "note eventDate")
        t.check(notePath.contains("2026-10-20-minuta-vieja"), "raw file named by event date: \(notePath)")
        t.check(noteText.contains("date: \(SBDate.iso(event))"), "raw date: is the event, with offset")
        t.check(noteText.range(of: #"\nadded: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}([+-]\d{2}:\d{2}|Z)\n"#, options: .regularExpression) != nil,
                "raw added: with offset")
        t.check(note.createdAt.timeIntervalSinceNow > -60, "createdAt = now")

        // setEventDate on a source not learned yet: raw updated, no extra ingest.
        let corrected = local(2026, 10, 19, 17, 0)
        try engine.setEventDate(sourceId: note.id, date: corrected)
        t.check(try engine.vault.read(notePath).contains("date: \(SBDate.iso(corrected))"), "setEventDate rewrites raw date:")
        t.eq(engine.source(note.id)?.eventDate, corrected, "setEventDate updates the record")
        t.eq(engine.jobs.filter { $0.sourceId == note.id && $0.kind == .ingest }.count, 1, "no duplicate ingest")

        // Learned already → re-ingest queued.
        let srcFile = engine.paths.sources.appendingPathComponent("\(note.id).json")
        var learned = engine.source(note.id)!
        learned.status = .done
        learned.historyId = "fake"
        try JSONEncoder.sb.encode(learned).write(to: srcFile)
        for job in engine.jobs where job.sourceId == note.id { try? fm.removeItem(at: engine.paths.jobs.appendingPathComponent("\(job.id).json")) }
        await engine.refreshFromDisk()
        try engine.setEventDate(sourceId: note.id, date: event)
        t.check(engine.jobs.contains { $0.sourceId == note.id && $0.kind == .ingest && $0.status == .queued }, "learned source → re-ingest queued")

        // --- Emails.
        let first = EmailParser.parse("""
        From: Ana García <ana@acme.com>
        Sent: Wednesday, October 21, 2026 10:15 AM
        To: Jaime Ruiz <jaime@dive.ai>
        Subject: Contrato proveedor Acme

        Hola Jaime, te mando el contrato para que lo firmes antes del viernes 23.
        """, ownerEmails: engine.vault.ownerEmails())
        let e1 = try engine.addEmail(first, threadKey: nil, projectSlug: acme.slug)
        t.eq(e1.kind, .email, "email kind")
        t.eq(e1.threadKey, "contrato-proveedor-acme", "thread key from subject")
        t.eq(e1.eventDate, local(2026, 10, 21, 10, 15), "email eventDate = sent")
        t.check(e1.rawPath == "projects/acme/raw/emails/contrato-proveedor-acme/2026-10-21-1015-ana-garcia.md", "email raw path: \(e1.rawPath ?? "")")
        let e1Text = try engine.vault.read(e1.rawPath!)
        t.check(e1Text.contains("type: email") && e1Text.contains("thread: contrato-proveedor-acme")
                && e1Text.contains("from: \"Ana García <ana@acme.com>\"") && e1Text.contains("date: \(SBDate.iso(local(2026, 10, 21, 10, 15)))")
                && e1Text.contains("\nadded: ") && e1Text.contains("project: acme"), "email raw frontmatter")
        t.check(fm.fileExists(atPath: engine.vault.url(for: "projects/acme/raw/emails/contrato-proveedor-acme/_thread.json").path), "_thread.json")
        t.check(engine.jobs.contains { $0.sourceId == e1.id && $0.kind == .ingest }, "email in a project → ingest queued")

        let reply = EmailParser.parse("""
        From: Jaime Ruiz <jaime@dive.ai>
        Sent: Thursday, October 22, 2026 9:30 AM
        To: Ana García <ana@acme.com>
        Subject: RE: Contrato proveedor Acme

        Ana, lo firmo mañana.

        From: Ana García <ana@acme.com>
        Sent: Wednesday, October 21, 2026 10:15 AM
        To: Jaime Ruiz <jaime@dive.ai>
        Subject: Contrato proveedor Acme

        Hola Jaime, te mando el contrato para que lo firmes antes del viernes 23.
        """, ownerEmails: engine.vault.ownerEmails())
        t.check(reply.isFromOwner, "reply from the owner")
        let matches = engine.matchThreads(for: reply)
        t.eq(matches.first?.thread.key, "contrato-proveedor-acme", "reply matches the thread")
        t.check((matches.first?.score ?? 0) >= 0.9, "reply match is strong: \(matches.first?.score ?? 0) \(matches.first?.reason ?? "")")
        let e2 = try engine.addEmail(reply, threadKey: matches.first?.thread.key, projectSlug: nil)
        t.eq(e2.projectSlug, "acme", "reply goes to the thread's project")

        // Quoted history alone (different subject) is a strong match.
        let quoting = EmailParser.parse("""
        From: Marta López <marta@acme.com>
        Date: Fri, 23 Oct 2026 08:00:00 -0600
        To: Jaime Ruiz <jaime@dive.ai>
        Subject: Pregunta rápida

        ¿Ya quedó firmado?

        > Hola Jaime, te mando el contrato para que lo firmes antes del viernes 23.
        """)
        t.eq(engine.matchThreads(for: quoting).first.map { ($0.thread.key, $0.score >= 0.9) }.map { "\($0.0) \($0.1)" },
             "contrato-proveedor-acme true", "quoted body → strong match")

        // Similar subject + shared participants → suggestion; unrelated → nothing.
        let similar = EmailParser.parse("From: Ana García <ana@acme.com>\nDate: 24/10/2026 12:00\nSubject: Contrato proveedor Acme - firmas\n\nOtra cosa.")
        let sim = engine.matchThreads(for: similar).first
        t.check(sim?.thread.key == "contrato-proveedor-acme" && (sim?.score ?? 0) >= 0.5 && (sim?.score ?? 1) < 0.8,
                "similar subject + people → medium: \(sim?.score ?? -1)")
        let unrelated = EmailParser.parse("From: Pedro <p@otro.com>\nDate: 24/10/2026 12:00\nSubject: Fiesta\n\nNos vemos.")
        t.check(engine.matchThreads(for: unrelated).isEmpty, "unrelated → no match")

        // [R] A generic subject ("Re: Hola") never matches strongly: different people → nothing, same people → weak.
        let hola = EmailParser.parse("From: Pedro <p@otro.com>\nDate: 20/10/2026 12:00\nSubject: Hola #2\n\nTe escribo por lo de la fiesta <del sábado> & *más*\n1. primero\n# no es título")
        let holaSrc = try engine.addEmail(hola, threadKey: nil, projectSlug: acme.slug)
        let holaKey = holaSrc.threadKey ?? ""
        let otherHola = EmailParser.parse("From: Luisa <luisa@x.com>\nDate: 22/10/2026 12:00\nSubject: Re: Hola #2\n\nHola, ¿cómo vas con el reporte?")
        t.check(!engine.matchThreads(for: otherHola).contains { $0.thread.key == holaKey }, "generic subject, other people → no match")
        let pedroAgain = EmailParser.parse("From: Pedro <p@otro.com>\nDate: 23/10/2026 12:00\nSubject: RE: Hola #2\n\nOtra cosa distinta.")
        let weak = engine.matchThreads(for: pedroAgain).first { $0.thread.key == holaKey }
        t.check(weak != nil && (weak?.score ?? 1) < 0.8, "generic subject, same person → weak suggestion: \(weak?.score ?? -1) \(weak?.reason ?? "")")
        // [R] Pasted text is exported literally: `<…>`, `*`, `1.`, `#` are text, and its line breaks are kept.
        var withEmails = ExportOptions()
        withEmails.includeTranscript = true
        if let doc = try? await engine.exportDocument(sourceId: holaSrc.id, options: withEmails) {
            let plain = Exporter.plainText(markdown: doc.markdown, options: withEmails)
            t.check(plain.contains("fiesta <del sábado> & *más*\n1. primero\n# no es título"), "email body exported literally: \(plain.suffix(160))")
            t.check(plain.contains("Hola #2"), "subject with # read back from the raw")
        } else {
            t.check(false, "export of a pasted email")
        }
        try engine.delete(sourceId: holaSrc.id)
        t.check(!engine.emailThreads(projectSlug: nil).contains { $0.key == holaKey }, "deleting the only email removes its thread")

        // Exact duplicate refused.
        do {
            _ = try engine.addEmail(first, threadKey: "contrato-proveedor-acme", projectSlug: nil)
            t.check(false, "duplicate refused")
        } catch EngineError.duplicateEmail {
            t.check(true, "duplicate refused")
        }

        // An OLDER email pasted late: the stored reply quotes it → strong match; sorted by sent date in the thread.
        let older = EmailParser.parse("""
        From: Ana García <ana@acme.com>
        Sent: Monday, October 19, 2026 8:00 AM
        To: Jaime Ruiz <jaime@dive.ai>
        Subject: Borrador

        Te adelanto el borrador del contrato con el proveedor, el definitivo llega esta semana.
        """)
        let threads = engine.emailThreads(projectSlug: "acme")
        t.eq(threads.first?.messageCount, 2, "thread message count")
        let e0 = try engine.addEmail(older, threadKey: "contrato-proveedor-acme", projectSlug: nil)
        t.eq(engine.emails(inThread: "contrato-proveedor-acme").map(\.id), [e0.id, e1.id, e2.id], "thread emails by sent date, not paste order")
        t.eq(engine.emailThreads(projectSlug: "acme").first?.firstDate, local(2026, 10, 19, 8, 0), "thread first date")

        // Inbox thread, then assign: the whole thread moves.
        let inbox1 = try engine.addEmail(EmailParser.parse("From: Pedro <p@otro.com>\nDate: 24/10/2026 12:00\nSubject: Fiesta\n\nNos vemos."),
                                         threadKey: nil, projectSlug: nil)
        t.check(inbox1.rawPath?.hasPrefix("_inbox/emails/fiesta/") == true, "no project → inbox: \(inbox1.rawPath ?? "")")
        t.check(engine.jobs.contains { $0.sourceId == inbox1.id && $0.kind == .classify }, "inbox email → classify")
        let inbox2 = try engine.addEmail(EmailParser.parse("From: Jaime Ruiz <jaime@dive.ai>\nDate: 24/10/2026 13:00\nSubject: Re: Fiesta\n\n¡Ahí estaré!"),
                                         threadKey: "fiesta", projectSlug: nil)
        try engine.assign(sourceId: inbox1.id, to: acme.slug)
        let moved = engine.emails(inThread: "fiesta")
        t.check(moved.count == 2 && moved.allSatisfy { $0.projectSlug == "acme" && $0.rawPath?.hasPrefix("projects/acme/raw/emails/fiesta/") == true },
                "assign moves the whole thread")
        t.check(!fm.fileExists(atPath: engine.vault.url(for: "_inbox/emails/fiesta").path), "inbox folder gone")
        t.check(try engine.vault.read(moved[1].rawPath!).contains("project: acme"), "moved raw project: updated")
        t.eq(engine.jobs.filter { [inbox1.id, inbox2.id].contains($0.sourceId ?? "") && $0.kind == .ingest }.count, 2, "both queued for ingest")
        t.check(!engine.jobs.contains { [inbox1.id, inbox2.id].contains($0.sourceId ?? "") && $0.kind == .classify }, "classify jobs dropped")

        // Delete a never-learned email: raw and thread entry go.
        try engine.delete(sourceId: inbox2.id)
        t.eq(engine.emailThreads(projectSlug: "acme").first { $0.key == "fiesta" }?.messageCount, 1, "delete updates _thread.json")

        // --- Templates (only if the bundled template ships them).
        let templates = engine.templates(scope: .meeting)
        if templates.contains(where: { $0.id == "estandar" }) {
            t.check(!templates.contains { $0.scope == .email }, "meeting scope excludes email templates")
            var std = templates.first { $0.id == "estandar" }!
            std.body += "\n## Extra\n<!-- algo -->\n"
            let copy = try engine.saveTemplate(std)
            t.eq(copy.id, "estandar-mio", "editing a builtin makes a user copy")
            t.check(!copy.isBuiltIn && engine.templates(scope: nil).contains { $0.id == "estandar" && $0.isBuiltIn }, "builtin untouched")
            do { try engine.deleteTemplate(id: "estandar"); t.check(false, "builtin can't be deleted") } catch { t.check(true, "builtin can't be deleted") }
            try engine.setDefaultTemplate(projectSlug: acme.slug, templateId: "estandar-mio")
            t.eq(engine.projects.get(acme.slug)?.defaultTemplate, "estandar-mio", "project default template")
            try engine.deleteTemplate(id: "estandar-mio")
            t.eq(engine.projects.get(acme.slug)?.defaultTemplate, nil, "deleted template cleared from project")
        } else {
            print("  (bundled template has no templates yet: template checks skipped)")
        }
        let custom = try engine.saveTemplate(TemplateInfo(id: "", name: "Mi formato", description: "d", scope: .any, isBuiltIn: false, body: "## A\n"))
        t.eq(custom.id, "mi-formato", "new template id from name")
        engine.reformat(sourceId: e1.id, templateId: custom.id)
        t.check(engine.jobs.contains { $0.kind == .reformat && $0.payload["templateId"] == "mi-formato" }, "reformat job queued")
        engine.makeTemplate(fromDescription: "Solo acuerdos y fechas", name: "Acuerdos rápidos")
        t.check(engine.jobs.contains { $0.kind == .makeTemplate && $0.payload["id"] == "acuerdos-rapidos" }, "make-template job queued")

        // --- Tasks against the vault.
        let e1Key = ((e1.rawPath! as NSString).lastPathComponent as NSString).deletingPathExtension
        try """
        ---
        type: person
        title: "Jaime Ruiz"
        owner: true
        ---
        # Jaime Ruiz
        """.write(to: engine.vault.url(for: "people/jaime-ruiz.md"), atomically: true, encoding: .utf8)
        let tasksText = tasksFixture.replacingOccurrences(of: "2026-10-21-1015-ana-garcia", with: e1Key)
        try tasksText.write(to: engine.vault.url(for: "projects/acme/wiki/tasks.md"), atomically: true, encoding: .utf8)
        let all = await engine.tasks(projectSlug: nil)
        t.eq(all.count, 7, "tasks(nil) reads every project")
        t.eq(all.filter(\.isMine).count, 3, "mine via owner: true page")
        let forEmail = await engine.tasks(forSourceId: e2.id)
        t.eq(forEmail.map(\.text), ["Mandar el contrato firmado"], "tasks(forSourceId:) via the thread's messages")

        let ana = all.first { $0.ownerSlug == "ana-garcia" }!
        try engine.setTask(ana, done: true)
        let afterDone = await engine.tasks(projectSlug: "acme")
        t.check(afterDone.first { $0.text == ana.text }?.done == true, "setTask done")
        let manual = engine.history.entries().first
        t.check(manual?.kind == .manualEdit && manual?.title.hasPrefix("Marcaste como hecho:") == true, "history .manualEdit entry")
        try engine.undo(historyId: manual!.id)
        t.check(try engine.vault.read("projects/acme/wiki/tasks.md") == tasksText, "undo restores tasks.md exactly")

        // Claude rewrote the line (new citation) → found by normalized text.
        try tasksText.replacingOccurrences(of: "· 📅 2026-11-03 · ([[2026-10-26-1530-kickoff]] 00:14:05)",
                                           with: "· 📅 2026-11-04 (antes 2026-11-03) · ([[2026-10-26-1530-kickoff]] 00:14:05; [[otra]])")
            .write(to: engine.vault.url(for: "projects/acme/wiki/tasks.md"), atomically: true, encoding: .utf8)
        try engine.setTask(ana, done: true)
        t.check(try engine.vault.read("projects/acme/wiki/tasks.md").contains("- [x] Enviar propuesta revisada a Acme"), "stale task found by text")
        // Gone → clear error.
        var ghost = ana
        ghost.text = "Algo que ya no existe"
        ghost.id = "x"
        ghost.line = "- [ ] Algo que ya no existe"
        do { try engine.setTask(ghost, done: true); t.check(false, "missing task → error") } catch EngineError.taskNotFound { t.check(true, "missing task → error") }
        // Busy while Claude edits that project (a running job of another process, on disk).
        var running = Job(kind: .ingest, sourceId: "other", projectSlug: "acme")
        running.status = .running
        let runningURL = engine.paths.jobs.appendingPathComponent("\(running.id).json")
        try JSONEncoder.sb.encode(running).write(to: runningURL)
        do { try engine.setTask(ana, done: false); t.check(false, "busy while ingesting") } catch EngineError.busy { t.check(true, "busy while ingesting") }
        try fm.removeItem(at: runningURL)

        let checklist = engine.exportTasks(all, title: "Pendientes")
        t.check(checklist.contains("## Míos") && checklist.contains("## De los demás") && checklist.contains("## Sin dueño")
                && checklist.contains("- [x] Reservar sala para demo · para el 28 oct 2026 · hecho el 27 oct 2026"), "exportTasks checklist:\n\(checklist)")

        // --- Timeline: a late, old source lands in its place.
        try """
        ---
        type: decision
        title: "Firmar con Acme"
        date: 2026-10-22
        status: accepted
        ---
        # Firmar con Acme
        """.write(to: engine.vault.url(for: "projects/acme/wiki/decisions/2026-10-22-firmar-con-acme.md"), atomically: true, encoding: .utf8)
        try engine.addNote(title: "Llamada de arranque", body: "Primera llamada.", projectSlug: acme.slug, eventDate: local(2026, 9, 30, 16, 0))
        let lateKey = ((engine.sources.first { $0.title == "Llamada de arranque" }!.rawPath! as NSString).lastPathComponent as NSString).deletingPathExtension
        try """
        ---
        type: timeline
        ---
        # Acme — línea de tiempo

        ## Septiembre 2026
        - 2026-09-30 16:00 · 📝 [[\(lateKey)|Llamada de arranque]] — primera llamada · agregada 2026-10-29
        - 2026-10-22 · ⚖️ [[2026-10-22-firmar-con-acme|Firmar con Acme]] — acordado por correo
        - 2026-10-21 10:15 · ✉️ [[contrato-proveedor-acme|Contrato proveedor]] — Ana envía el contrato

        ## Noviembre 2026
        - 2026-11-15 · 🚩 Lanzamiento de Acme (planeado) — [[2026-10-22-firmar-con-acme]]
        - 2026-11-20 · 📅 Entrega final al cliente
        """.write(to: engine.vault.url(for: "projects/acme/wiki/timeline.md"), atomically: true, encoding: .utf8)
        let timeline = await engine.timeline(projectSlug: "acme")
        let dates = timeline.map(\.date)
        t.check(dates == dates.sorted(), "timeline ascending")
        t.eq(timeline.first?.title, "Llamada de arranque", "late old source first (by event date, not added)")
        t.eq(timeline.filter { $0.title.contains("Llamada de arranque") }.count, 1, "timeline.md line for a known source not duplicated")
        let decision = timeline.first { $0.kind == .decision }
        t.check(decision?.title == "Firmar con Acme" && decision?.hasTime == false && decision?.date == local(2026, 10, 22), "decision entry")
        let milestone = timeline.first { $0.kind == .milestone }
        t.check(milestone?.title.hasPrefix("Lanzamiento de Acme") == true && milestone?.pagePath?.hasSuffix("2026-10-22-firmar-con-acme.md") == true,
                "milestone from timeline.md: \(milestone.map { "\($0.title) \($0.pagePath ?? "")" } ?? "nil")")
        t.check(timeline.contains { $0.kind == .task && $0.title.hasPrefix("Entrega final") }, "📅 line as deadline")
        t.eq(timeline.filter { $0.kind == .decision }.count, 1, "⚖️ line (VS16 emoji) for a known decision not duplicated")
        t.check(!timeline.contains { $0.title.contains("Contrato proveedor") && $0.sourceId == nil }, "✉️ line for a known thread not duplicated")
        t.check(!timeline.contains { $0.title.unicodeScalars.first.map { $0.properties.isEmojiPresentation } ?? false }, "no emoji left in titles")
        t.check(timeline.contains { $0.kind == .task && $0.title.hasPrefix("Preparar la demo") && $0.date == local(2026, 10, 30) }, "task due in timeline")
        let emailEntries = timeline.filter { $0.kind == .email }
        t.eq(emailEntries.map(\.sourceId), [e0.id, e1.id, e2.id, inbox1.id], "emails by sent date")
        t.check(emailEntries.first?.title.contains("Ana García") == true, "email entry names the sender")
        t.check(timeline.first { $0.sourceId == note.id }?.addedAt != nil, "source entries carry addedAt")

        // --- Export assembly (thread).
        var options = ExportOptions()
        options.includeTranscript = true
        let doc = try await engine.exportDocument(sourceId: e2.id, options: options)
        t.eq(doc.title, "Contrato proveedor Acme", "thread export title")
        t.check(doc.markdown.contains("**Hilo de correo:** 3 correos, del 19 oct 2026, 08:00 al 22 oct 2026, 09:30"), "thread export dates:\n\(doc.markdown)")
        t.check(doc.markdown.contains("## Correos del hilo") && doc.markdown.contains("### 19 oct 2026, 08:00 · Ana García → Jaime Ruiz"),
                "thread export emails")
        let order = ["### 19 oct", "### 21 oct", "### 22 oct"].map { doc.markdown.range(of: $0)?.lowerBound }
        t.check(order.allSatisfy { $0 != nil } && order.compactMap { $0 } == order.compactMap { $0 }.sorted(), "emails chronological")
        t.check(doc.markdown.contains("## Pendientes (estado actual)") && doc.markdown.contains("Mandar el contrato firmado"), "thread export tasks")
        t.check(!doc.markdown.contains("Historial citado"), "quoted history left out")
    } catch {
        t.check(false, "engine test threw: \(error)")
    }
}

// MARK: - Migration (copy of a v0.1 setup)

@MainActor private func testMigration(_ t: Tester, source: URL, root: URL) async {
    let fm = FileManager.default
    do {
        try? fm.removeItem(at: root)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        for item in ["vault", "data"] {
            let from = source.appendingPathComponent(item), to = root.appendingPathComponent(item)
            if item == "data" {
                try fm.createDirectory(at: to, withIntermediateDirectories: true)
                for sub in ["sources", "sessions"] where fm.fileExists(atPath: from.appendingPathComponent(sub).path) {
                    try fm.copyItem(at: from.appendingPathComponent(sub), to: to.appendingPathComponent(sub))
                }
            } else {
                try fm.copyItem(at: from, to: to)
            }
        }
        let vaultURL = root.appendingPathComponent("vault")
        let vault = VaultStore(root: vaultURL)
        t.check(!fm.fileExists(atPath: vault.url(for: ".secondbrain/template-version").path), "fixture is v0.1")
        func wikiHashes() -> [String: Data] {
            var out: [String: Data] = [:]
            for p in vault.allMarkdownPaths() where p.contains("/wiki/") || p.hasPrefix("people/") || p == "index.md" || p == "log.md" {
                out[p] = try? Data(contentsOf: vault.url(for: p))
            }
            return out
        }
        let before = wikiHashes()
        let result = try vault.migrateIfNeeded()
        t.eq(result.fromVersion, 1, "from v1")
        t.eq(result.toVersion, VaultStore.bundledTemplateVersion, "to bundled version")
        t.check(result.replacedClaudeMd, "unedited v0.1 CLAUDE.md replaced")
        t.check(result.pendingManual == nil, "no pending manual")
        let bundled = VaultStore.templateURL!.appendingPathComponent("vault")
        t.eq(try Data(contentsOf: vault.url(for: "CLAUDE.md")), try Data(contentsOf: bundled.appendingPathComponent("CLAUDE.md")), "CLAUDE.md is the new one")
        for cmd in (try fm.contentsOfDirectory(atPath: bundled.appendingPathComponent(".claude/commands").path)) {
            t.eq(try Data(contentsOf: vault.url(for: ".claude/commands/\(cmd)")),
                 try Data(contentsOf: bundled.appendingPathComponent(".claude/commands/\(cmd)")), "command \(cmd) current")
        }
        t.check(fm.fileExists(atPath: vault.url(for: "projects/x-files/wiki/timeline.md").path), "project gets timeline.md")
        if let tl = try? vault.read("projects/x-files/wiki/timeline.md") {
            t.check(!tl.contains("{{"), "timeline placeholders filled")
            t.check(tl.contains("X-Files"), "timeline has the project name")
        }
        t.check(isDir(vault.url(for: "projects/x-files/raw/emails")) && isDir(vault.url(for: "_inbox/emails")), "email folders")
        let after = wikiHashes()
        let changed = before.keys.filter { before[$0] != after[$0] }
        t.check(changed.isEmpty, "existing wiki pages untouched: \(changed)")
        t.eq(try String(contentsOf: vault.url(for: ".secondbrain/template-version"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
             "\(VaultStore.bundledTemplateVersion)", "version file")
        let again = try vault.migrateIfNeeded()
        t.check(again.copied.isEmpty && again.updatedCommands.isEmpty && !again.replacedClaudeMd && again.fromVersion == again.toVersion,
                "second run is a no-op")
        // [R] A built-in template edited by hand (still `builtin: true`) survives the next launch; an untouched one is refreshed.
        let handEdited = try vault.read("templates/ejecutivo.md") + "\n## Mi sección\n<!-- algo mío -->\n"
        try handEdited.write(to: vault.url(for: "templates/ejecutivo.md"), atomically: true, encoding: .utf8)
        try "---\nbuiltin: true\n---\nviejo\n".write(to: vault.url(for: "templates/standup.md"), atomically: true, encoding: .utf8)
        let installedPath = vault.url(for: VaultStore.installedTemplatesFile)
        var installed = try JSONDecoder().decode([String: String].self, from: Data(contentsOf: installedPath))
        installed["templates/standup.md"] = VaultStore.sha256(vault.url(for: "templates/standup.md"))   // as if an older app shipped it
        try JSONEncoder().encode(installed).write(to: installedPath)
        _ = try vault.migrateIfNeeded()
        t.eq(try vault.read("templates/ejecutivo.md"), handEdited, "hand-edited built-in template kept")
        t.eq(try Data(contentsOf: vault.url(for: "templates/standup.md")), try Data(contentsOf: bundled.appendingPathComponent("templates/standup.md")),
             "untouched older built-in template refreshed")

        // A user-edited CLAUDE.md is kept; the new manual goes next to it.
        let edited = root.appendingPathComponent("edited")
        try fm.copyItem(at: source.appendingPathComponent("vault"), to: edited)
        let mine = try String(contentsOf: edited.appendingPathComponent("CLAUDE.md"), encoding: .utf8) + "\n## Mis reglas\n- Siempre en inglés.\n"
        try mine.write(to: edited.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        let r2 = try VaultStore(root: edited).migrateIfNeeded()
        t.eq(r2.pendingManual, "CLAUDE.v\(VaultStore.bundledTemplateVersion).md", "edited CLAUDE.md → pending manual")
        t.eq(try String(contentsOf: edited.appendingPathComponent("CLAUDE.md"), encoding: .utf8), mine, "edited CLAUDE.md kept")
        t.check(fm.fileExists(atPath: edited.appendingPathComponent(r2.pendingManual ?? "-").path), "new manual written")

        // Engine on the migrated setup: records get event dates; notice for the edited one.
        var config = AppConfig.default
        config.vaultPath = edited.path
        config.dataPath = root.appendingPathComponent("data").path
        let engine = BrainEngine(config: config, transcriber: NoTranscriber())
        engine.autoProcess = false
        engine.start()
        t.check(engine.migrationNotice?.contains("CLAUDE.md") == true, "migrationNotice set")
        t.check(engine.sources.allSatisfy { $0.eventDate != nil }, "v0.1 sources get eventDate")
        if let s = engine.source("20261026-123023-9f07"), let raw = s.rawPath {
            let rawDate = Frontmatter_field("date", try engine.vault.read(raw)).flatMap { SBDate.parseISO($0)?.date }
            t.eq(s.eventDate, rawDate, "eventDate from raw date:")

            // Export of a real meeting: speakers resolved, both dates, tasks.
            var options = ExportOptions()
            options.includeTranscript = true
            let doc = try await engine.exportDocument(sourceId: s.id, options: options)
            let expected = "**Reunión:** " + SBDate.human(utc(2026, 10, 26, 18, 30), language: "es")   // 12:30 in Mexico City
            t.check(doc.markdown.contains(expected), "meeting export date line (local zone): \(expected)")
            t.check(doc.markdown.contains("**Agregado al cerebro:**"), "meeting export added line")
            t.check(doc.markdown.contains("Mariana Torres:**") && !doc.markdown.contains("Hablante 1:**"), "speaker names resolved")
            t.check(doc.markdown.contains("**[00:00:"), "timestamps kept")
            t.check(doc.markdown.contains("## Pendientes (estado actual)") && doc.markdown.contains("Preparar el análisis de las muestras"),
                    "meeting export tasks")
            t.check(!doc.markdown.contains("## Fuente"), "raw-link section dropped")
            options.includeTimestamps = false
            options.resolveSpeakerNames = false
            let plain = try await engine.exportDocument(sourceId: s.id, options: options)
            t.check(!plain.markdown.contains("**[00:") && plain.markdown.contains("**Hablante 1:**"), "no timestamps / raw labels")
            let tmp = root.appendingPathComponent("export.md")
            try Exporter.export(markdown: doc.markdown, title: doc.title, format: .markdown, options: options, to: tmp)
            t.check((try? String(contentsOf: tmp, encoding: .utf8))?.contains("Mariana") == true, "Exporter writes the assembled doc")
        } else {
            t.check(false, "fixture source 20261026-123023-9f07 present")
        }
    } catch {
        t.check(false, "migration test threw: \(error)")
    }
}

private func Frontmatter_field(_ key: String, _ text: String) -> String? {
    guard text.hasPrefix("---\n"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 4)..<text.endIndex) else { return nil }
    for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].components(separatedBy: "\n") where line.hasPrefix(key + ":") {
        return line.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
    }
    return nil
}

private func isDir(_ url: URL) -> Bool {
    var d: ObjCBool = false
    return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
}
