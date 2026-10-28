import ArgumentParser
import BrainCore
import Foundation
import PDFKit

// v0.7 attach — `sb attachments selftest` (CONTRACT §17.1, §17.8): triage rules, provider parsers, the demo files,
// saving forward (Claude simulated) and backwards (confirmed), duplicates, > 25 MB, Descartados (rescue, delete,
// 30-day expiry), text extraction (docx/xlsx/pptx) and attachments travelling with their thread. No Claude, no network.

struct AttachmentsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "attachments", abstract: "Email attachments (v0.7).",
                                                    subcommands: [AttachmentsSelfTestCmd.self])
}

struct AttachmentsSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of email attachments.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-attachments-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("attach-triage") { testAttachTriage(t) }
        t.group("attach-parsers") { testAttachParsers(t) }
        await t.groupAsync("attach-demo") { await testAttachDemo(t) }
        t.group("attach-text") { testAttachText(t, root: root.appendingPathComponent("text")) }
        await t.groupAsync("attach-engine") { await testAttachEngine(t, root: root.appendingPathComponent("engine")) }
        t.group("attach-template") { testAttachTemplate(t, root: root.appendingPathComponent("template")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

// MARK: - Triage

@MainActor private func testAttachTriage(_ t: Tester) {
    typealias T = AttachmentTriage
    let ctx = T.Context(inlineContentIds: ["image001.png@01db"])
    let logo = AttachmentInfo(id: "1", name: "image001.png", mimeType: "image/png", size: 4_000, isInline: true, contentId: "<IMAGE001.png@01DB>")
    t.eq(T.classify(logo, context: ctx), .discard(.inlineImage), "inline logo referenced by the body → discard")
    t.eq(T.classify(logo), .discard(.smallImage), "inline logo, body unknown (Graph) → the size/name rules discard it")
    let pasted = AttachmentInfo(id: "9", name: "captura.png", mimeType: "image/png", size: 70_000, isInline: true)
    t.eq(T.classify(pasted), .ask, "inline 70 KB screenshot, reference unknown (Graph) → ask, not discarded")
    t.eq(T.classify(pasted, context: ctx), .ask, "inline without content id → never 'referenced'")
    var bigInline = logo
    bigInline.size = 60_000
    bigInline.name = "foto-planta.jpg"
    bigInline.mimeType = "image/jpeg"
    t.eq(T.classify(bigInline, context: T.Context(inlineContentIds: ["otro@x"])), .ask, "inline but not shown by the body, 60 KB photo → ask")
    t.eq(T.classify(bigInline, context: ctx), .discard(.inlineImage), "inline, referenced, < 100 KB → discard")
    let signature = AttachmentInfo(id: "2", name: "Signature_Ana.png", mimeType: "image/png", size: 45_000)
    t.eq(T.classify(signature), .discard(.junkName), "signature*.png → junk name")
    t.eq(T.classify(AttachmentInfo(id: "3", name: "firma.jpg", mimeType: "image/jpeg", size: 30_000)), .discard(.junkName), "firma* → junk name")
    t.eq(T.classify(AttachmentInfo(id: "4", name: "image003.jpg", mimeType: "image/jpeg", size: 30_000)), .discard(.junkName), "image003.jpg → junk name")
    t.eq(T.classify(AttachmentInfo(id: "5", name: "icono.png", mimeType: "image/png", size: 9_000)), .discard(.smallImage), "image < 20 KB → small")
    let photo = AttachmentInfo(id: "6", name: "pizarron.jpg", mimeType: "image/jpeg", size: 240_000)
    t.eq(T.classify(photo), .ask, "photo ≥ 20 KB not inline → ask (Claude/user)")
    let pdf = AttachmentInfo(id: "7", name: "Contrato.PDF", mimeType: "application/pdf", size: 180_000)
    t.eq(T.classify(pdf), .keep, "PDF → keep")
    t.eq(T.classify(AttachmentInfo(id: "7b", name: "logo-propuesta.pdf", mimeType: "application/pdf", size: 1_000)), .keep,
         "junk names only apply to images (logo-propuesta.pdf kept)")
    t.eq(T.classify(pdf, context: T.Context(sha256: "abc", savedHashes: ["abc"])), .discard(.duplicate), "same SHA-256 as a saved file → duplicate")
    t.eq(T.classify(AttachmentInfo(id: "8", name: "video.zip", mimeType: "application/zip", size: 30 * 1024 * 1024)), .tooBig, "> 25 MB → tooBig")
    t.eq(T.classify(AttachmentInfo(id: "9", name: "invite.ics", mimeType: "text/calendar", size: 2_000)), .discard(.junkType), ".ics → junk type")
    t.eq(T.classify(AttachmentInfo(id: "10", name: "Ana.vcf", mimeType: "text/vcard", size: 900)), .discard(.junkType), ".vcf → junk type")
    t.eq(T.classify(AttachmentInfo(id: "11", name: "winmail.dat", mimeType: "application/ms-tnef", size: 90_000)), .discard(.junkType), "winmail.dat → junk type")
    t.eq(T.classify(AttachmentInfo(id: "12", name: "smime.p7s", mimeType: "application/pkcs7-signature", size: 5_000)), .discard(.junkType), "smime.p7s → junk type")
    for name in ["a.docx", "b.xlsx", "c.pptx", "d.key", "e.pages", "f.numbers", "g.csv", "h.txt", "i.md", "j.rtf", "k.zip", "l.doc"] {
        t.eq(T.classify(AttachmentInfo(id: name, name: name, mimeType: "application/octet-stream", size: 50_000)), .keep, "\(name) → keep")
    }
    t.eq(T.classify(AttachmentInfo(id: "13", name: "datos.bin", mimeType: "application/octet-stream", size: 50_000)), .ask, "unknown type → ask")
    t.check(AttachmentDecision.keep.preselected && AttachmentDecision.ask.preselected, "keep/ask preselected")
    t.check(!AttachmentDecision.discard(.smallImage).preselected && !AttachmentDecision.tooBig.preselected, "discard/tooBig not preselected")
    t.eq(T.contentIds(inHTML: #"<img src="cid:Image001.PNG@01DB"><img src='cid:logo%40x'> cid:image001.png@01db"#),
         ["image001.png@01db", "logo@x"], "cid: references of the HTML")
    t.eq(T.sha256(Data("hola".utf8)).count, 64, "sha256 hex")
    let verdicts = BrainEngine.parseAttachmentTriage("""
        Revisé los dos.
        ```json
        [{"name": "pizarron.jpg", "keep": true, "reason": "Foto del pizarrón"},
         {"name": "banner.png", "keep": false, "reason": "Banner"}]
        ```
        """)
    t.eq(verdicts?.map(\.keep), [true, false], "Claude's JSON parsed")
    t.eq(verdicts?.last?.reason, "Banner", "reason kept")
    t.check(BrainEngine.parseAttachmentTriage("No sé [sin json]") == nil, "no JSON → nil (kept)")
}

// MARK: - Parsers

@MainActor private func testAttachParsers(_ t: Tester) {
    let graph = """
        {"value": [
          {"@odata.type": "#microsoft.graph.fileAttachment", "id": "AAA1", "name": "Contrato.pdf", "contentType": "application/pdf", "size": 182000, "isInline": false},
          {"@odata.type": "#microsoft.graph.fileAttachment", "id": "AAA2", "name": "image001.png", "contentType": "image/png", "size": 4100, "isInline": true, "contentId": "<image001.png@01DB>"},
          {"@odata.type": "#microsoft.graph.itemAttachment", "id": "AAA3", "name": "RE: Propuesta", "contentType": null, "size": 52000, "isInline": false}
        ]}
        """
    do {
        let list = try GraphParser.attachments(Data(graph.utf8))
        t.eq(list.map(\.name), ["Contrato.pdf", "image001.png", "RE: Propuesta.eml"], "Graph attachments listed (item named .eml)")
        t.eq(list.map(\.isDownloadable), [true, true, false], "only fileAttachment is downloadable")
        t.eq(list[1].contentId, "image001.png@01db", "Graph contentId normalized")
        t.check(list[1].isInline && list[0].size == 182_000, "Graph inline flag and size")
    } catch {
        t.check(false, "Graph parse: \(error)")
    }
    let url = MicrosoftGraphProvider.attachmentURL(messageId: "AB/C=", id: "X1").absoluteString
    t.check(url.hasSuffix("/me/messages/AB%2FC=/attachments/X1/$value"), "Graph download URL: \(url)")
    t.check(MicrosoftGraphProvider.attachmentsURL(messageId: "M1").absoluteString.removingPercentEncoding?.contains("select=id,name") == true, "Graph list selects only metadata")

    let gmail = """
        {"id": "m1", "threadId": "t1", "payload": {"mimeType": "multipart/mixed", "parts": [
          {"partId": "0", "mimeType": "multipart/related", "parts": [
            {"partId": "0.0", "mimeType": "text/html", "body": {"size": 40, "data": "PGltZyBzcmM9ImNpZDpsb2dvQHgiPg"}},
            {"partId": "0.1", "mimeType": "image/png", "filename": "logo.png", "headers": [{"name": "Content-Disposition", "value": "inline; filename=logo.png"}, {"name": "Content-ID", "value": "<logo@x>"}], "body": {"size": 3000, "attachmentId": "ANGj1"}}
          ]},
          {"partId": "1", "mimeType": "application/pdf", "filename": "Contrato.pdf", "headers": [{"name": "Content-Disposition", "value": "attachment; filename=Contrato.pdf"}], "body": {"size": 180000, "attachmentId": "ANGj2"}},
          {"partId": "2", "mimeType": "text/plain", "filename": "nota.txt", "body": {"size": 5, "data": "aG9sYQ"}}
        ]}}
        """
    do {
        let list = try GmailParser.attachments(Data(gmail.utf8))
        t.eq(list.map(\.id), ["0.1", "1", "2"], "Gmail attachment ids are part ids")
        t.eq(list.map(\.isInline), [true, false, false], "Gmail inline from Content-Disposition")
        t.eq(list.first?.contentId, "logo@x", "Gmail Content-ID")
        t.eq(list.map(\.size), [3000, 180000, 5], "Gmail sizes")
    } catch {
        t.check(false, "Gmail parse: \(error)")
    }
}

// MARK: - Demo

@MainActor private func testAttachDemo(_ t: Tester) async {
    let demo = DemoProvider(account: DemoProvider.demoAccount(.microsoft), language: "es")
    do {
        let list = try await demo.listAttachments(messageId: "demo-m11")
        t.eq(list.count, 3, "contract email has 3 attachments")
        let full = try await demo.fetchMessage(id: "demo-m11")
        let ctx = AttachmentTriage.Context(inlineContentIds: full.inlineContentIds.map(Set.init))
        t.eq(list.map { AttachmentTriage.classify($0, context: ctx) }, [.keep, .discard(.inlineImage), .ask],
             "demo triage: contract keep, logo discard, whiteboard ask")
        let logo = try await demo.downloadAttachment(messageId: "demo-m11", id: "a2")
        t.check(logo.count > 1_000 && logo.count < 20_000, "logo PNG ~4 KB (\(logo.count) B)")
        t.check(logo.starts(with: [0x89, 0x50, 0x4E, 0x47]), "logo is a PNG")
        let photo = try await demo.downloadAttachment(messageId: "demo-m11", id: "a3")
        t.check(photo.count >= 20_000 && photo.count < 25 * 1024 * 1024, "photo ≥ 20 KB (\(photo.count) B)")
        let pdf = try await demo.downloadAttachment(messageId: "demo-m11", id: "a1")
        let text = PDFDocument(data: pdf)?.string ?? ""
        t.check(text.contains("Puebla") && text.contains("40 cajas"), "contract PDF has text: \(text.prefix(60))")
        t.eq(list.first(where: { $0.id == "a1" })?.size, pdf.count, "listed size = downloaded size")
        t.eq(try await demo.listAttachments(messageId: "demo-m07").count, 0, "a message without attachments")
        let g = DemoProvider(account: DemoProvider.demoAccount(.google), language: "en")
        t.eq(try await g.listAttachments(messageId: "demo-g3").map(\.name), ["oaxaca-market.jpg", "invite.ics"], "Google demo attachments (en)")
    } catch {
        t.check(false, "demo attachments: \(error)")
    }
}

// MARK: - Text extraction

private func runTool(_ tool: String, _ args: [String], cwd: URL? = nil) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}

/// A real .docx (textutil), .xlsx and .pptx (zipped OOXML) for the extraction tests.
private func makeOffice(_ dir: URL) -> (docx: URL, xlsx: URL, pptx: URL) {
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    let txt = dir.appendingPathComponent("minuta.txt")
    try? "Minuta de la visita a la planta.\nAcordamos dos entregas por semana.".write(to: txt, atomically: true, encoding: .utf8)
    let docx = dir.appendingPathComponent("minuta.docx")
    _ = runTool("/usr/bin/textutil", ["-convert", "docx", "-output", docx.path, txt.path])

    func zip(_ name: String, _ files: [String: String]) -> URL {
        let src = dir.appendingPathComponent(name + "-src")
        try? fm.removeItem(at: src)
        for (path, content) in files {
            let url = src.appendingPathComponent(path)
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
        let out = dir.appendingPathComponent(name)
        try? fm.removeItem(at: out)
        _ = runTool("/usr/bin/zip", ["-q", "-r", "-X", out.path, "."], cwd: src)
        return out
    }
    let xlsx = zip("presupuesto.xlsx", [
        "xl/workbook.xml": #"<workbook xmlns:r="r"><sheets><sheet name="Resumen &amp; total" sheetId="1" r:id="rId1"/><sheet name="Detalle" sheetId="2" r:id="rId2"/></sheets></workbook>"#,
        "xl/_rels/workbook.xml.rels": #"<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/></Relationships>"#,
        "xl/sharedStrings.xml": #"<sst><si><t>Área</t></si><si><t>Monto</t></si><si><r><t>Tecno</t></r><r><t>logía, TI</t></r></si></sst>"#,
        "xl/worksheets/sheet1.xml": #"<worksheet><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="C2"><v>1296000</v></c></row></sheetData></worksheet>"#,
        "xl/worksheets/sheet2.xml": #"<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Eventos</t></is></c><c r="B1" t="b"><v>1</v></c></row></sheetData></worksheet>"#,
    ])
    let pptx = zip("kickoff.pptx", [
        "ppt/slides/slide1.xml": #"<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Kickoff</a:t></a:r><a:r><a:t> rediseño</a:t></a:r></a:p><a:p><a:r><a:t>Objetivo: menos de un minuto</a:t></a:r></a:p></p:sld>"#,
        "ppt/slides/slide10.xml": #"<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Gracias</a:t></a:r></a:p></p:sld>"#,
        "ppt/slides/slide2.xml": #"<p:sld xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Calendario</a:t></a:r></a:p></p:sld>"#,
        "ppt/notesSlides/notesSlide1.xml": #"<p:notes xmlns:a="a" xmlns:p="p"><a:p><a:r><a:t>Mencionar el presupuesto</a:t></a:r></a:p><a:p><a:r><a:t>1</a:t></a:r></a:p></p:notes>"#,
    ])
    return (docx, xlsx, pptx)
}

@MainActor private func testAttachText(_ t: Tester, root: URL) {
    let files = makeOffice(root)
    let doc = DocumentText.extract(files.docx) ?? ""
    t.check(doc.contains("dos entregas por semana"), "docx via textutil: \(doc.prefix(50))")
    let xls = DocumentText.extract(files.xlsx) ?? ""
    t.check(xls.contains("## Resumen & total\n\nÁrea,Monto\n\"Tecnología, TI\",,1296000"), "xlsx → CSV per sheet: \(xls)")
    t.check(xls.contains("## Detalle\n\nEventos,TRUE"), "second sheet, inline string + boolean")
    let ppt = DocumentText.extract(files.pptx) ?? ""
    t.check(ppt.contains("## 1\n\nKickoff rediseño\nObjetivo: menos de un minuto"), "pptx slide text: \(ppt)")
    t.check(ppt.contains("> Mencionar el presupuesto") && !ppt.contains("> 1"), "pptx speaker notes, without the slide number")
    let order = ["## 1", "## 2", "## 3"].compactMap { ppt.range(of: $0)?.lowerBound }
    t.check(order.count == 3 && order == order.sorted() && ppt.contains("## 3\n\nGracias"), "slides in numeric order (slide10 last)")
    t.check(DocumentText.needsSidecar("a.DOCX") && !DocumentText.needsSidecar("a.pdf") && !DocumentText.needsSidecar("a.csv"), "needsSidecar")
    t.check(DocumentText.isSidecar("a.docx.txt") && !DocumentText.isSidecar("notas.txt"), "isSidecar")
    let side = DocumentText.writeSidecar(for: files.xlsx)
    t.eq(side?.lastPathComponent, "presupuesto.xlsx.txt", "sidecar next to the original")
    t.check(FileManager.default.fileExists(atPath: files.xlsx.path), "original kept")
    t.check(DocumentText.extract(root.appendingPathComponent("nope.pptx")) == nil, "missing file → nil")
}

// MARK: - Engine

/// A mailbox of two messages of one conversation, with the same contract in both, a docx, a 30 MB zip, a logo and a photo.
private final class FakeAttachProvider: MailCalendarProvider, @unchecked Sendable {
    let account: ConnectedAccount
    let messages: [MailMessageFull]
    var files: [String: [(AttachmentInfo, Data)]]
    var downloads: [String] = []
    var failDownloads = false
    init(account: ConnectedAccount, messages: [MailMessageFull], files: [String: [(AttachmentInfo, Data)]]) {
        self.account = account; self.messages = messages; self.files = files
    }
    func profile() async throws -> ConnectedAccount { account }
    func listMessages(since: Date, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) { (messages.map(\.summary), nil) }
    func searchMessages(_ query: String, pageToken: String?) async throws -> (messages: [MailMessageSummary], next: String?) { ([], nil) }
    var extra: [MailMessageFull] = []
    func fetchMessage(id: String) async throws -> MailMessageFull { (messages + extra).first { $0.summary.id == id }! }
    func fetchThread(id: String) async throws -> [MailMessageFull] { messages.filter { $0.summary.threadId == id } }
    func events(from: Date, to: Date) async throws -> [CalendarEvent] { [] }
    func listAttachments(messageId: String) async throws -> [AttachmentInfo] { (files[messageId] ?? []).map(\.0) }
    func downloadAttachment(messageId: String, id: String) async throws -> Data {
        downloads.append("\(messageId)/\(id)")
        if failDownloads { throw AccountError.network("offline") }
        guard let d = files[messageId]?.first(where: { $0.0.id == id })?.1 else { throw AttachmentError.notDownloadable }
        return d
    }
}

@MainActor private func testAttachEngine(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: AttachNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let account = DemoProvider.demoAccount(.microsoft)
    let demo = DemoProvider(account: account, language: "es")
    do {
        let acme = try engine.projects.create(name: "Acme", description: "Logística", emoji: "🚚")

        // Forward, demo contract email: PDF kept, inline logo discarded, the whiteboard photo goes to (simulated) Claude.
        let m11 = try await demo.fetchMessage(id: "demo-m11")
        let added = try engine.addMailMessages([m11], account: account, threadKey: nil, projectSlug: acme.slug)
        guard let email = added.first, let key = email.threadKey else { t.check(false, "email added"); return }
        nonisolated(unsafe) var asked: [AttachmentTriageCandidate] = []
        let keepAll: AttachmentClaudeTriage = { raw, candidates, folder in
            asked = candidates
            return candidates.map { AttachmentTriageVerdict(name: $0.name, keep: true, reason: "Foto del pizarrón") }
        }
        let r1 = try await engine.saveAttachments(for: m11, account: account, mode: .automatic, provider: demo, claudeTriage: keepAll)
        t.eq(asked.map(\.name), ["pizarron-visita-almacen.jpg"], "only the ambiguous photo goes to Claude")
        t.check(asked.allSatisfy { !$0.path.hasPrefix(engine.vault.root.path) }, "Claude reads staged files outside the vault")
        t.eq(r1.saved.map(\.name), ["Contrato-Acme-Logistics-2026.pdf", "pizarron-visita-almacen.jpg"], "contract + photo saved")
        t.eq(r1.discarded.map(\.reason), [.inlineImage], "inline logo discarded")
        let folder = "projects/\(acme.slug)/raw/emails/\(key)"
        let msgDir = ((email.rawPath ?? "") as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        let contractPath = "\(folder)/attachments/\(msgDir)/contrato-acme-logistics-2026.pdf"
        t.eq(r1.saved.first?.file, contractPath, "stored at <thread>/attachments/<YYYY-MM-DD-HHmm>-<from>/<name>")
        t.check(fm.fileExists(atPath: engine.vault.url(for: contractPath).path), "file on disk")
        let info = engine.vault.threadInfo(key: key)
        t.eq(info?.attachments.count, 2, "_thread.json lists the saved attachments")
        t.eq(info?.messages.first?.attachments.count, 2, "per message in ThreadInfo")
        t.eq(info?.attachments.first?.sha256.count, 64, "sha256 recorded")
        let children = r1.sourceIds.compactMap { engine.source($0) }
        t.eq(children.map(\.kind), [.document, .image], "sources: document + image")
        t.check(children.allSatisfy { $0.parentSourceId == email.id && $0.threadKey == key && $0.projectSlug == acme.slug }, "parentSourceId + threadKey + project")
        t.check(children.allSatisfy { $0.eventDate == email.eventDate }, "dated by the email")
        t.check(children.allSatisfy { c in engine.jobs.contains { $0.kind == .ingest && $0.sourceId == c.id } }, "attachments queued for ingest")
        t.eq(children.map(\.title), ["Contrato-Acme-Logistics-2026.pdf", "pizarron-visita-almacen.jpg"], "titled by the file's name")
        t.eq(engine.discardedStore.list().count, 1, "Descartados has the logo")
        t.eq(engine.discardedStore.list().first?.messageSourceId, email.id, "discarded item knows its email")

        // Reader states, then again: nothing new.
        let list = try await demo.listAttachments(messageId: "demo-m11")
        let states = engine.attachmentStates(messageSourceId: email.id, attachments: list, inlineContentIds: m11.inlineContentIds)
        if case .saved = states["a1"] { t.check(true, "state: saved") } else { t.check(false, "state a1: \(String(describing: states["a1"]))") }
        if case .discarded(let d) = states["a2"] { t.eq(d.reason, .inlineImage, "state: discarded (reason)") } else { t.check(false, "state a2") }
        let r2 = try await engine.saveAttachments(for: m11, account: account, mode: .automatic, provider: demo, claudeTriage: keepAll)
        t.check(r2.saved.isEmpty && r2.discarded.isEmpty && r2.skipped.count == 3, "second run: everything skipped")

        // A fake conversation: the same contract again (duplicate), a docx, a 30 MB zip, an ambiguous photo Claude drops.
        let contract = try Data(contentsOf: engine.vault.url(for: contractPath))
        let office = makeOffice(root.appendingPathComponent("office"))
        let docx = try Data(contentsOf: office.docx)
        let photo = try await DemoProvider(account: DemoProvider.demoAccount(.google)).downloadAttachment(messageId: "demo-g3", id: "a1")   // other bytes than the saved one
        let me = EmailAddress(name: "Ana García", email: "ana@contoso.com")
        let sofia = EmailAddress(name: "Sofía Herrera", email: "sofia@acme.com")
        func msg(_ id: String, _ minutes: Double, body: String) -> MailMessageFull {
            MailMessageFull(summary: MailMessageSummary(id: id, threadId: "conv-1", from: sofia, to: [me], subject: "Firma del contrato",
                                                        snippet: body, date: Date().addingTimeInterval(-minutes * 60), hasAttachments: true),
                            bodyText: body)
        }
        let t1 = msg("t1", 30, body: "Te reenvío el contrato y la minuta.")
        let t2 = msg("t2", 10, body: "Y el video de la visita.")
        let fake = FakeAttachProvider(account: account, messages: [t1, t2], files: [
            "t1": [(AttachmentInfo(id: "c", name: "Contrato firmado.pdf", mimeType: "application/pdf", size: contract.count), contract),
                   (AttachmentInfo(id: "d", name: "Minuta visita.docx", mimeType: "application/vnd.openxmlformats-officedocument.wordprocessingml.document", size: docx.count), docx)],
            "t2": [(AttachmentInfo(id: "v", name: "visita.zip", mimeType: "application/zip", size: 30 * 1024 * 1024), Data("zip".utf8)),
                   (AttachmentInfo(id: "p", name: "IMG_2041.jpg", mimeType: "image/jpeg", size: photo.count), photo)],
        ])
        _ = try engine.addMailMessages([t1, t2], account: account, threadKey: nil, projectSlug: acme.slug)
        let r3 = try await engine.saveAttachments(for: t1, account: account, mode: .automatic, provider: fake, claudeTriage: keepAll)
        t.eq(r3.discarded.map(\.reason), [.duplicate], "same contract bytes in the project → duplicate")
        t.eq(r3.saved.map(\.name), ["Minuta visita.docx"], "docx saved")
        if let docxFile = r3.saved.first?.file {
            let sidecar = engine.vault.url(for: docxFile + ".txt")
            let text = (try? String(contentsOf: sidecar, encoding: .utf8)) ?? ""
            t.check(text.contains("dos entregas por semana"), "docx text next to it (<name>.txt)")
            t.check(docxFile.hasSuffix("/minuta-visita.docx"), "file name slugged: \(docxFile)")
        }
        let dropAll: AttachmentClaudeTriage = { _, candidates, _ in
            candidates.map { AttachmentTriageVerdict(name: $0.name, keep: false, reason: "Foto genérica") }
        }
        let r4 = try await engine.saveAttachments(for: t2, account: account, mode: .automatic, provider: fake, claudeTriage: dropAll)
        t.eq(r4.tooBig.map(\.name), ["visita.zip"], "> 25 MB listed as too big")
        t.check(!fake.downloads.contains("t2/v"), "> 25 MB never downloaded by itself")
        t.eq(r4.discarded.map(\.reason), [.claude("Foto genérica")], "Claude's no → Descartados with its reason")
        let states2 = engine.attachmentStates(messageSourceId: engine.emailSource(externalId: "microsoft:t2")?.id,
                                              attachments: try await fake.listAttachments(messageId: "t2"))
        t.eq(states2["v"], .tooBig, "state: too big")

        // Backwards: "Guardar de todos modos" for the zip.
        let r5 = try await engine.saveAttachments(for: t2, account: account, mode: .confirmed(["v"]), provider: fake)
        t.eq(r5.saved.map(\.name), ["visita.zip"], "confirmed: the big one saved on request")
        // Backwards with an unticked document: not downloaded, it stays in the mailbox ("No guardado").
        let t3 = msg("t3", 5, body: "Otra versión.")
        fake.files["t3"] = [(AttachmentInfo(id: "x", name: "propuesta-v3.pdf", mimeType: "application/pdf", size: 3), Data("pdf".utf8))]
        _ = try engine.addMailMessages([t3], account: account, threadKey: nil, projectSlug: acme.slug)
        let r6 = try await engine.saveAttachments(for: t3, account: account, mode: .confirmed([]), provider: fake)
        t.eq(r6.discarded.count, 0, "unticked → not discarded")
        t.eq(r6.skipped.map(\.name), ["propuesta-v3.pdf"], "unticked → skipped")
        t.check(!fake.downloads.contains("t3/x"), "unticked → never downloaded")
        let states3 = engine.attachmentStates(messageSourceId: engine.emailSource(externalId: "microsoft:t3")?.id,
                                              attachments: try await fake.listAttachments(messageId: "t3"))
        if case .notSaved = states3["x"] { t.check(true, "unticked → No guardado") } else { t.check(false, "unticked state: \(String(describing: states3["x"]))") }
        // The email's own checklist (reviewed): the unticked one is decided → Descartados as the user's choice.
        let r6b = try await engine.saveAttachments(for: t3, account: account, mode: .reviewed([]), provider: fake)
        t.eq(r6b.discarded.map(\.reason), [.user], "checklist: unticked → Descartados (user)")

        // Two attachments with the same name: Claude's verdict and the saved state are per file.
        let t5 = msg("t5", 3, body: "Fotos de la pizarra y el banner.")
        fake.extra.append(t5)
        var photo2 = photo
        photo2.append(contentsOf: [0, 1, 2])
        fake.files["t5"] = [(AttachmentInfo(id: "i1", name: "image.png", mimeType: "image/png", size: photo.count), photo),
                            (AttachmentInfo(id: "i2", name: "image.png", mimeType: "image/png", size: photo2.count), photo2)]
        _ = try engine.addMailMessages([t5], account: account, threadKey: nil, projectSlug: acme.slug)
        var seenNames: [String] = []
        let keepFirst: AttachmentClaudeTriage = { _, candidates, _ in
            candidates.enumerated().map { AttachmentTriageVerdict(name: $0.element.name, keep: $0.offset == 0, reason: "Banner") }
        }
        let r8 = try await engine.saveAttachments(for: t5, account: account, mode: .automatic, provider: fake, claudeTriage: { raw, c, f in
            await MainActor.run { seenNames = c.map(\.name) }
            return await keepFirst(raw, c, f)
        })
        t.eq(seenNames, ["image.png", "image (2).png"], "same-named candidates get names of their own")
        t.eq(r8.saved.count, 1, "one image.png kept")
        t.eq(r8.discarded.map(\.reason), [.claude("Banner")], "the other discarded with its own verdict")
        let states5 = engine.attachmentStates(messageSourceId: engine.emailSource(externalId: "microsoft:t5")?.id,
                                              attachments: try await fake.listAttachments(messageId: "t5"))
        if case .saved = states5["i1"] { t.check(true, "first image.png: Guardado") } else { t.check(false, "i1 state") }
        if case .discarded = states5["i2"] { t.check(true, "second image.png: Descartado, not Guardado") } else { t.check(false, "i2 state: \(String(describing: states5["i2"]))") }

        // Ticking a discarded one backwards: its bytes come from Descartados (no download, works offline); it leaves
        // Descartados only once saved. Without its bytes and offline, it stays there.
        fake.failDownloads = true
        let downloadsBefore = fake.downloads.count
        guard let bannerItem = engine.discardedStore.list().first(where: { $0.attachmentId == "i2" }) else { t.check(false, "banner discarded"); return }
        let r9 = try await engine.saveAttachments(for: t5, account: account, mode: .confirmed(["i2"]), provider: fake)
        t.eq(r9.saved.map(\.name), ["image.png"], "ticked discarded one saved offline from Descartados")
        t.eq(fake.downloads.count, downloadsBefore, "no download for it")
        t.check(engine.discardedStore.item(id: bannerItem.id) == nil, "it left Descartados after saving")
        let t6 = msg("t6", 2, body: "Otra foto.")
        fake.extra.append(t6)
        fake.failDownloads = false
        fake.files["t6"] = [(AttachmentInfo(id: "q", name: "IMG_3000.jpg", mimeType: "image/jpeg", size: photo2.count), photo2 + Data([9]))]
        _ = try engine.addMailMessages([t6], account: account, threadKey: nil, projectSlug: acme.slug)
        _ = try await engine.saveAttachments(for: t6, account: account, mode: .automatic, provider: fake, claudeTriage: dropAll)
        if let qItem = engine.discardedStore.list().first(where: { $0.attachmentId == "q" }) {
            try? fm.removeItem(at: engine.discardedStore.fileURL(of: qItem))
            fake.failDownloads = true
            let r10 = try await engine.saveAttachments(for: t6, account: account, mode: .confirmed(["q"]), provider: fake)
            t.eq(r10.failed, ["IMG_3000.jpg"], "offline, no local bytes → failed")
            t.check(engine.discardedStore.item(id: qItem.id) != nil, "a failed download leaves it in Descartados")
            fake.failDownloads = false
            engine.deleteDiscarded(id: qItem.id)
        } else {
            t.check(false, "t6 photo discarded")
        }

        // Descartados: rescue (back into its thread, as if saved), delete, 30-day expiry.
        let store = engine.discardedStore
        let before = store.list().count
        guard let photoItem = store.list().first(where: { $0.reason == .claude("Foto genérica") }) else { t.check(false, "photo discarded"); return }
        let rescued = try await engine.rescueDiscarded(id: photoItem.id)
        t.eq(rescued?.kind, .image, "rescued as an image source")
        t.check(rescued?.rawPath?.contains("/attachments/") == true && rescued?.parentSourceId != nil, "rescued back into its thread")
        t.eq(store.list().count, before - 1, "rescued item left Descartados")
        if let r = rescued, let k = r.threadKey {
            t.check(engine.vault.threadInfo(key: k)?.attachments.contains { $0.sourceId == r.id } == true, "rescue recorded in _thread.json")
        }
        // A rescue that can't write the file leaves the item in Descartados (try again later).
        if let contractItem = store.list().first(where: { $0.reason == .duplicate }), let parent = contractItem.messageSourceId.flatMap(engine.source),
           let raw = parent.rawPath {
            let attachDir = engine.vault.url(for: (raw as NSString).deletingLastPathComponent + "/attachments/"
                                             + ((raw as NSString).lastPathComponent as NSString).deletingPathExtension)
            try? fm.createDirectory(at: attachDir, withIntermediateDirectories: true)
            try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: attachDir.path)
            do {
                _ = try await engine.rescueDiscarded(id: contractItem.id)
                t.check(false, "rescue into a read-only folder must fail")
            } catch {
                t.check(store.item(id: contractItem.id) != nil && fm.fileExists(atPath: store.fileURL(of: contractItem).path),
                        "failed rescue: still in Descartados with its file")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: attachDir.path)
        } else {
            t.check(false, "duplicate contract discarded")
        }
        if let userItem = store.list().first {
            engine.deleteDiscarded(id: userItem.id)
            t.check(store.item(id: userItem.id) == nil && !fm.fileExists(atPath: store.folder(of: userItem.id).path), "Eliminar ya")
        }
        let remaining = store.list().count
        t.eq(store.expire(now: Date().addingTimeInterval(29 * 86_400)), 0, "nothing expires before 30 days")
        t.eq(store.expire(now: Date().addingTimeInterval(31 * 86_400)), remaining, "everything expires after 30 days")
        t.eq(store.list().count, 0, "Descartados empty")

        // File names: at most 200 bytes of UTF-8 (APFS: 255), the extension kept.
        let cjk = String(repeating: "合同", count: 60) + ".jpg"
        let safe = DiscardedStore.safeName(cjk)
        t.check(safe.utf8.count <= 200 && safe.hasSuffix(".jpg") && safe.hasPrefix("合同"), "long CJK name cut by bytes: \(safe.utf8.count) B")
        t.check(DiscardedStore.safeName("a." + String(repeating: "x", count: 300)).utf8.count <= 200, "a huge 'extension' is cut too")
        let cjkItem = try store.add(DiscardedItem(name: cjk, size: 3, reason: .user), data: Data("abc".utf8))
        t.check(fm.fileExists(atPath: store.fileURL(of: cjkItem).path), "long CJK name stored in Descartados")
        store.delete(id: cjkItem.id)

        // Staging folders left by a quit while Claude was looking are swept (older than an hour).
        let staging = engine.paths.root.appendingPathComponent(BrainEngine.attachmentStagingFolder)
        let old = staging.appendingPathComponent("old"), fresh = staging.appendingPathComponent("fresh")
        try fm.createDirectory(at: old, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-7_200)], ofItemAtPath: old.path)
        BrainEngine.sweepAttachmentStaging(dataRoot: engine.paths.root)
        t.check(!fm.fileExists(atPath: old.path) && fm.fileExists(atPath: fresh.path), "stale staging swept, fresh kept")

        // Sin asignar: attachments wait with their thread (no classify of their own) and move with it.
        let m06 = try await demo.fetchMessage(id: "demo-m06")
        let inbox = try engine.addMailMessages([m06], account: account, threadKey: nil, projectSlug: nil, routeIfUnassigned: false)
        guard let inboxEmail = inbox.first, let inboxKey = inboxEmail.threadKey else { t.check(false, "inbox email"); return }
        let r7 = try await engine.saveAttachments(for: m06, account: account, mode: .automatic, provider: demo, claudeTriage: keepAll)
        t.eq(r7.saved.map(\.name), ["presupuesto-2027-v1.csv"], "inbox: csv saved")
        guard let csvSrc = r7.sourceIds.first.flatMap(engine.source) else { t.check(false, "csv source"); return }
        t.check(csvSrc.rawPath?.hasPrefix("_inbox/emails/\(inboxKey)/attachments/") == true, "inbox attachment under _inbox/emails/<thread>/attachments")
        t.eq(csvSrc.status, .needsProject, "waits for its thread")
        t.check(!engine.jobs.contains { $0.sourceId == csvSrc.id }, "no classify job of its own")
        try engine.assign(sourceId: csvSrc.id, to: acme.slug)   // assigning the attachment assigns the thread
        let moved = engine.source(csvSrc.id)
        t.check(moved?.rawPath?.hasPrefix("projects/\(acme.slug)/raw/emails/\(inboxKey)/attachments/") == true, "moved with the thread: \(moved?.rawPath ?? "-")")
        t.check(moved.flatMap { $0.rawPath }.map { fm.fileExists(atPath: engine.vault.url(for: $0).path) } == true, "file moved")
        t.eq(moved?.projectSlug, acme.slug, "project set")
        t.check(engine.jobs.contains { $0.kind == .ingest && $0.sourceId == csvSrc.id }, "queued for ingest after the move")
        t.eq(engine.vault.threadInfo(key: inboxKey)?.attachments.first?.file, moved?.rawPath, "_thread.json path follows the move")
        let emailJob = engine.jobs.firstIndex { $0.sourceId == inboxEmail.id && $0.kind == .ingest }
        let attJob = engine.jobs.firstIndex { $0.sourceId == csvSrc.id && $0.kind == .ingest }
        t.check(emailJob != nil && attJob != nil, "both queued")

        // Undo of an email takes its unlearned attachments with it.
        try engine.delete(sourceId: inboxEmail.id)
        t.check(engine.source(csvSrc.id) == nil, "attachment source deleted with its email")
        t.check(engine.vault.threadInfo(key: inboxKey)?.attachments.isEmpty ?? true, "_thread.json entry gone")
    } catch {
        t.check(false, "engine: \(error)")
    }
}

// MARK: - Vault command

@MainActor private func testAttachTemplate(_ t: Tester, root: URL) {
    let vault = VaultStore(root: root)
    do { _ = try vault.migrateIfNeeded() } catch { t.check(false, "install template: \(error)"); return }
    let triage = (try? vault.read(".claude/commands/triage-attachments.md")) ?? ""
    t.check(triage.contains("$ARGUMENTS") && triage.contains("\"keep\"") && triage.contains("Read-only"), "triage-attachments.md: JSON, read-only")
    t.check(!triage.contains("placeholder"), "triage-attachments.md filled in")
    let ingest = (try? vault.read(".claude/commands/ingest.md")) ?? ""
    t.check(ingest.contains("/attachments/") && ingest.contains("## Adjuntos") && ingest.contains("<file>.txt"), "ingest.md knows attachments")
}

private final class AttachNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
