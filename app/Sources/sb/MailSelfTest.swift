import BrainCore
import Foundation

/// v0.3 Correo (CONTRACT §12.4/§12.7): `MailMessageFull → ParsedEmail`, known people, and the import path from a
/// connected account (DemoProvider) into a temp vault: sources on disk under raw/emails/<thread>/ with externalId.
@MainActor func testMail(_ t: Tester, root: URL) async {
    let account = DemoProvider.demoAccount(.microsoft)
    let demo = DemoProvider(account: account, language: "es")
    let demoEN = DemoProvider(account: account, language: "en")

    // --- Conversion.
    do {
        let first = try await demo.fetchMessage(id: "demo-m01")
        let reply = try await demo.fetchMessage(id: "demo-m02")
        let e1 = MailImport.parsedEmail(first, account: account, ownerEmails: [], language: "es")
        t.eq(e1.subject, "Propuesta de logística Q4", "subject kept")
        t.eq(e1.from?.email, "sofia.herrera@acmelogistics.com", "from")
        t.eq(e1.cc.compactMap(\.email), ["laura.mendez@contoso.com"], "cc")
        t.eq(e1.date, first.summary.date, "date = sent date")
        t.check(!e1.isFromOwner, "someone else's message is not mine")
        t.check(e1.quotedHistory == nil && e1.body.contains("Te comparto la propuesta"), "first message: no history")
        t.check(e1.raw.hasPrefix("De: Sofía Herrera <sofia.herrera@acmelogistics.com>\nPara: Ana García <ana@contoso.com>\nCC: Laura Méndez"),
                "raw headers De/Para/CC: \(e1.raw.prefix(140))")
        t.check(e1.raw.contains("\nFecha: \(SBDate.iso(first.summary.date))\nAsunto: Propuesta de logística Q4\n\nHola Ana,"),
                "raw headers Fecha/Asunto then body")
        t.check(MailImport.parsedEmail(first, account: account, ownerEmails: ["Sofia.Herrera@acmelogistics.com"]).isFromOwner,
                "owner emails (people/README) count as mine")

        let e2 = MailImport.parsedEmail(reply, account: account, ownerEmails: [])
        t.check(e2.isFromOwner, "sent from the account address → mine")
        t.check(e2.body.hasPrefix("Gracias, Sofía.") && !e2.body.contains("Te comparto"), "reply body without history: \(e2.body.prefix(60))")
        t.check(e2.body.hasSuffix("Ana"), "reply body keeps the signature")
        t.check((e2.quotedHistory ?? "").hasPrefix("El ") && (e2.quotedHistory ?? "").contains("> Te comparto la propuesta"),
                "quoted history split: \((e2.quotedHistory ?? "nil").prefix(60))")
        let other = ConnectedAccount(provider: .google, email: "demo@gmail.com")
        t.check(!MailImport.parsedEmail(reply, account: other, ownerEmails: []).isFromOwner, "another account's address is not mine")

        let en = MailImport.parsedEmail(try await demoEN.fetchMessage(id: "demo-m03"), account: account, ownerEmails: [], language: "en")
        t.check(en.raw.hasPrefix("From: Sofía Herrera") && en.raw.contains("\nCc: Laura Méndez") && en.raw.contains("\nSubject: RE: Q4 logistics proposal"),
                "English raw headers")
        t.check((en.quotedHistory ?? "").hasPrefix("On ") && en.body.hasPrefix("Ana, good news"), "English history split")
    } catch {
        t.check(false, "demo conversion: \(error)")
    }
    let outlook = MailImport.splitBody("""
        Va, lo vemos el jueves.

        -----Original Message-----
        From: Laura <laura@x.com>
        Sent: Monday
        Subject: Hola
        """)
    t.check(outlook.body == "Va, lo vemos el jueves." && outlook.quoted?.hasPrefix("-----Original Message-----") == true, "Outlook history split")
    let plain = MailImport.splitBody("Solo texto.\r\nSegunda línea.\u{00A0}")
    t.check(plain.body == "Solo texto.\nSegunda línea." && plain.quoted == nil, "plain body normalized, no history")
    t.eq(MailImport.externalId(account: account, messageId: "AAMk=="), "microsoft:AAMk==", "externalId format")

    // --- Engine: a temp vault with a project, the demo thread imported end to end.
    let fm = FileManager.default
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: MailNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        try engine.vault.setOwnerEmails(["ana.personal@example.com"])
        let kickoff = try engine.projects.create(name: "Kickoff", description: "Rediseño", emoji: "🚀")
        let thread = try await demo.fetchThread(id: "demo-thread-acme")
        t.eq(thread.count, 3, "demo thread has 3 messages")
        let added = try engine.addMailMessages(thread.reversed(), account: account, threadKey: nil, projectSlug: kickoff.slug)
        t.eq(added.count, 3, "whole conversation added")
        t.eq(added.map { $0.externalId ?? "-" }, ["microsoft:demo-m01", "microsoft:demo-m02", "microsoft:demo-m03"], "oldest first, externalId set")
        let key = added.first?.threadKey ?? "-"
        t.check(added.allSatisfy { $0.threadKey == key && $0.projectSlug == kickoff.slug && $0.status == .queued }, "one thread, queued in the project")
        t.check(engine.jobs.filter { $0.kind == .ingest && added.map(\.id).contains($0.sourceId ?? "") }.count == 3, "ingest jobs queued")
        let folder = "projects/\(kickoff.slug)/raw/emails/\(key)"
        t.check(added.allSatisfy { ($0.rawPath ?? "").hasPrefix(folder + "/") }, "raws under raw/emails/<thread>/: \(added.first?.rawPath ?? "-")")
        for src in added {
            let text = (try? engine.vault.read(src.rawPath ?? "")) ?? ""
            t.check(text.contains("\nexternal_id: \"\(src.externalId ?? "")\"\n"), "raw has external_id (\(src.id))")
        }
        if let replyRaw = added.dropFirst().first?.rawPath, let text = try? engine.vault.read(replyRaw) {
            t.check(text.contains("\n## Historial citado\n") && text.contains("from: \"Ana García <ana@contoso.com>\""), "reply raw: history section + from")
            t.check(VaultStore.emailBody(text).body.hasPrefix("Gracias, Sofía."), "emailBody (public) reads the new text")
        }
        t.check(added.dropFirst().first?.title.hasSuffix("— tú") == true, "own reply titled as mine: \(added.dropFirst().first?.title ?? "-")")
        let metaData = (try? Data(contentsOf: engine.vault.url(for: "\(folder)/_thread.json"))) ?? Data()
        let metaText = String(data: metaData, encoding: .utf8) ?? ""
        t.check(metaText.contains("microsoft:demo-m01") && metaText.contains("microsoft:demo-m03"), "_thread.json remembers externalIds")
        t.eq(engine.emailSource(externalId: "microsoft:demo-m02")?.id, added.dropFirst().first?.id, "emailSource(externalId:)")

        // Dedupe: the same messages again add nothing; addEmail with a known externalId throws.
        let again = try engine.addMailMessages(thread, account: account, threadKey: nil, projectSlug: kickoff.slug)
        t.eq(again.count, 0, "re-adding the conversation adds nothing")
        let e3 = MailImport.parsedEmail(thread[2], account: account, ownerEmails: [])
        do {
            _ = try engine.addEmail(e3, threadKey: nil, projectSlug: nil, externalId: "microsoft:demo-m03")
            t.check(false, "duplicate externalId must throw")
        } catch EngineError.duplicateEmail {
            t.check(true, "duplicate externalId throws")
        }
        // Same message text pasted by hand (no externalId) is still caught by the body/sender/minute check.
        t.check(engine.duplicateOf(e3) != nil, "pasted copy of an imported message is a duplicate")
        // An externalId remembered only in _thread.json (record gone) is still a duplicate.
        var bare = e3
        bare.body = "Otro texto"
        t.check(engine.duplicateOf(bare, externalId: "microsoft:demo-m03") != nil, "externalId matched via sources/_thread.json")
        t.check(engine.duplicateOf(bare, externalId: "microsoft:nope") == nil, "unknown externalId + different body → new")

        // Continue a thread: the first message alone, then the conversation → only the new one, same thread.
        let k1 = try await demo.fetchMessage(id: "demo-m04")
        let single = try engine.addMailMessages([k1], account: account, threadKey: nil, projectSlug: kickoff.slug)
        let rest = try engine.addMailMessages(try await demo.fetchThread(id: "demo-thread-kickoff"), account: account, threadKey: nil,
                                              projectSlug: kickoff.slug)
        t.check(single.count == 1 && rest.count == 1 && rest.first?.externalId == "microsoft:demo-m05", "only the missing message added")
        t.eq(rest.first?.threadKey, single.first?.threadKey, "continues the stored thread")

        // Inbox ("Sin asignar") + undo: delete a not-yet-learned source → raw and _thread.json entry go away; can re-add.
        let budget = try await demo.fetchMessage(id: "demo-m06")
        guard let inbox = try engine.addMailMessages([budget], account: account, threadKey: nil, projectSlug: nil).first else {
            t.check(false, "inbox add"); return
        }
        t.check(inbox.status == .needsProject && (inbox.rawPath ?? "").hasPrefix("_inbox/emails/"), "no project → Sin asignar")
        let inboxRaw = engine.vault.url(for: inbox.rawPath ?? "")
        t.check(fm.fileExists(atPath: inboxRaw.path), "inbox raw on disk")
        try engine.delete(sourceId: inbox.id)
        t.check(!fm.fileExists(atPath: inboxRaw.path) && engine.emailSource(externalId: "microsoft:demo-m06") == nil, "undo removes raw + record")
        let readded = try engine.addMailMessages([budget], account: account, threadKey: nil, projectSlug: kickoff.slug)
        t.eq(readded.count, 1, "after undo the message can be added again")
    } catch {
        t.check(false, "mail import engine: \(error)")
    }

    // --- Known people (people/*.md): by address on aliases / Correo lines, by full name; not by first name alone.
    do {
        try """
        ---
        type: person
        title: "Laura Méndez"
        aliases: ["Laura", "laura.mendez@contoso.com"]
        ---

        # Laura Méndez
        """.write(to: engine.vault.url(for: "people/laura-mendez.md"), atomically: true, encoding: .utf8)
        try """
        # Diego Torres

        - **Correo:** diego.torres@contoso.com
        """.write(to: engine.vault.url(for: "people/diego-torres.md"), atomically: true, encoding: .utf8)
        let known = KnownPeople.scan(engine.vault)
        t.eq(known.pageCount, 2, "two person pages (README excluded)")
        t.check(known.contains(EmailAddress(name: nil, email: "Laura.Mendez@contoso.com")), "known by alias address")
        t.check(known.contains(EmailAddress(name: "Diego Torres", email: "diego@otra.com")), "known by full name")
        t.check(known.contains(EmailAddress(name: nil, email: "diego.torres@contoso.com")), "known by Correo line")
        t.check(known.contains(EmailAddress(name: "laura mendez", email: nil)), "name match ignores accents/case")
        t.check(!known.contains(EmailAddress(name: "Laura", email: "laura@else.com")), "first name alone is not enough")
        t.check(!known.contains(EmailAddress(name: "Carlos Ruiz", email: "carlos.ruiz@contoso.com")), "unknown sender")
    } catch {
        t.check(false, "known people: \(error)")
    }
}

private final class MailNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
