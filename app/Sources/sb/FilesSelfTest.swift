import AppKit
import ArgumentParser
import BrainCore
import Foundation

/// `sb files …` (CONTRACT §17.2): Archivos from the terminal.
struct FilesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files", abstract: "Every file of the brain (documents, images, email attachments).",
        subcommands: [List.self, FilesSelfTestCmd.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the files of the vault.")
        @Option(help: "Vault folder (default: the configured vault)") var dir: String?
        @Option(help: "Only this project") var project: String?
        @Argument(help: "Words to find (name or summary page)") var words: [String] = []

        @MainActor func run() async throws {
            let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppConfig.load().vaultURL
            let started = Date()
            let snapshot = EntityIndex.shared(vaultRoot: root).refresh()
            let all = FileIndex.shared(vaultRoot: root).refresh(entities: snapshot)
            let shown = FileIndex.filter(all, FileQuery(text: words.joined(separator: " "), project: project))
            print("\(all.count) files indexed in \(Int(Date().timeIntervalSince(started) * 1000)) ms · \(shown.count) shown")
            for e in shown {
                var line = "[\(e.type.rawValue)/\(e.origin.rawValue)] \(e.name) · \(e.size) B · \(e.projectSlug ?? "_inbox")"
                if let subject = e.threadSubject { line += " · ✉️ \(subject)" + (e.sender.map { " · \($0.display)" } ?? "") }
                print(line)
                print("      \(e.path)" + (e.summaryPath.map { " → \($0)" } ?? ""))
            }
        }
    }
}

/// `sb files selftest [--dir <tmp>]`: the index (raw/docs wrappers and plain text documents, raw/assets, email
/// attachments with and without `_thread.json`, `_inbox`), kinds, origins, dates, people, summary pages, filters and
/// sorting, the files a ficha lists, and incremental refresh (a changed summary page, a deleted file).
struct FilesSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of Archivos (FileIndex).")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-files-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("files-kinds") { testFileKinds(t) }
        t.group("files-index") { testFileIndex(t, root: root.appendingPathComponent("vault")) }
        t.group("files-demo") { testDemoFiles(t, root: root.appendingPathComponent("demo")) }
        await t.groupAsync("files-capture") { await testCaptureOrigin(t, root: root.appendingPathComponent("capture")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

private func put(_ root: URL, _ path: String, _ text: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

private func putData(_ root: URL, _ path: String, _ data: Data) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url)
}

@MainActor private func testFileKinds(_ t: Tester) {
    t.eq(FileType.of(extension: "PDF"), .pdf, "pdf")
    t.eq(FileType.of(extension: "docx"), .document, "docx")
    t.eq(FileType.of(extension: "md"), .document, "md")
    t.eq(FileType.of(extension: "xlsx"), .spreadsheet, "xlsx")
    t.eq(FileType.of(extension: "csv"), .spreadsheet, "csv")
    t.eq(FileType.of(extension: "key"), .presentation, "keynote")
    t.eq(FileType.of(extension: "pptx"), .presentation, "pptx")
    t.eq(FileType.of(extension: "HEIC"), .image, "heic")
    t.eq(FileType.of(extension: "zip"), .other, "zip")
    t.eq(FileOrigin.of(via: nil), .upload, "no via = upload")
    t.eq(FileOrigin.of(via: "dump"), .dump, "via dump")
    t.eq(FileOrigin.of(via: "capture"), .capture, "via capture")
    t.eq(FileIndex.stampDate("2026-10-27-1430-ana-garcia").map { DemoVault.fmt($0, "yyyy-MM-dd HH:mm") }, "2026-10-27 14:30", "stamp date")
    t.check(FileIndex.stampDate("contrato") == nil, "no stamp → nil")
}

@MainActor private func testFileIndex(_ t: Tester, root: URL) {
    let vault = VaultStore(root: root)
    _ = try? vault.migrateIfNeeded()
    try? vault.setOwnerName("Jaime Ruiz")
    try? vault.setOwnerEmails(["jaime@dive.ai"])
    put(root, "people/ana-garcia.md", "---\ntype: person\ntitle: \"Ana García\"\naliases: [\"Ana\"]\n---\n\n# Ana García\n")
    put(root, "people/luis-perez.md", "---\ntype: person\ntitle: \"Luis Pérez\"\norg: \"[[acme]]\"\n---\n\n# Luis Pérez\n")
    put(root, "orgs/acme.md", "---\ntype: org\ntitle: \"Acme\"\n---\n\n# Acme\n")
    let p = "projects/atlas"
    for sub in ["raw/docs", "raw/assets", "raw/emails", "wiki/sources", "wiki/emails"] {
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("\(p)/\(sub)"), withIntermediateDirectories: true)
    }

    // raw/docs: a PDF with its wrapper (uploaded), a text document kept as markdown, a web page and a note (no files).
    putData(root, "\(p)/raw/docs/2026-10-01-contrato-acme.pdf", Data(repeating: 1, count: 2048))
    put(root, "\(p)/raw/docs/2026-10-01-contrato-acme.md", """
        ---
        type: document
        source_id: s-contrato
        title: "Contrato Acme"
        project: atlas
        date: 2026-09-30T10:00:00-06:00
        added: 2026-10-01T09:00:00-06:00
        original_file: 2026-10-01-contrato-acme.pdf
        ---

        texto del contrato
        """)
    put(root, "\(p)/raw/docs/2026-10-02-minuta.md", "---\ntype: document\ntitle: \"Minuta de la visita\"\nadded: 2026-10-02T09:00:00-06:00\n---\n\nTexto.\n")
    put(root, "\(p)/raw/docs/2026-10-03-sitio.md", "---\ntype: url\ntitle: \"Sitio\"\nsource_url: https://x.example\n---\n\nweb\n")
    // raw/assets: a photo dropped with "Agregar al proyecto", a captured one, one with no wrapper.
    putData(root, "\(p)/raw/assets/2026-10-04-planta.jpg", Data(repeating: 2, count: 50_000))
    put(root, "\(p)/raw/assets/2026-10-04-planta.md", "---\ntype: image\ntitle: \"Foto de la planta\"\nvia: dump\nadded: 2026-10-04T12:00:00-06:00\noriginal_file: 2026-10-04-planta.jpg\n---\n\n")
    putData(root, "\(p)/raw/assets/pizarron.png", Data(repeating: 3, count: 30_000))
    put(root, "\(p)/raw/assets/pizarron.md", "---\ntype: image\ntitle: \"Pizarrón\"\nvia: capture\nadded: 2026-10-05T12:00:00-06:00\noriginal_file: pizarron.png\n---\n\n")
    putData(root, "\(p)/raw/assets/suelta.gif", Data(repeating: 4, count: 10))

    // A thread without _thread.json (rebuilt from the message files): the attachment folder matches a message file.
    let thread = "\(p)/raw/emails/contrato-acme"
    put(root, "\(thread)/2026-10-06-1015-ana-garcia.md", """
        ---
        type: email
        source_id: s-mail-1
        subject: "Contrato Acme"
        from: "Ana García <ana@acme.com>"
        date: 2026-10-06T10:15:00-06:00
        ---

        Te mando el contrato firmado.
        """)
    putData(root, "\(thread)/attachments/2026-10-06-1015-ana-garcia/Contrato firmado.pdf", Data(repeating: 5, count: 4096))
    putData(root, "\(thread)/attachments/2026-10-06-1015-ana-garcia/Anexo precios.xlsx", Data(repeating: 6, count: 9000))
    // A thread with _thread.json listing its attachment (name, message, source) and a reply from the owner.
    let thread2 = "\(p)/raw/emails/presupuesto"
    put(root, "\(thread2)/2026-10-08-0900-luis-perez.md", "---\ntype: email\nfrom: \"Luis Pérez <luis@acme.com>\"\n---\n\nPresupuesto.\n")
    put(root, "\(thread2)/2026-10-08-1100-jaime-ruiz.md", "---\ntype: email\nfrom: \"Jaime Ruiz <jaime@dive.ai>\"\n---\n\nGracias.\n")
    putData(root, "\(thread2)/attachments/2026-10-08-0900-luis-perez/presupuesto-v2.pptx", Data(repeating: 7, count: 70_000))
    put(root, "\(thread2)/_thread.json", """
        {
          "key": "presupuesto",
          "subject": "Presupuesto 2027",
          "createdAt": "2026-10-08T15:00:00Z",
          "participants": [{"name": "Luis Pérez", "email": "luis@acme.com"}, {"name": "Jaime Ruiz", "email": "jaime@dive.ai"}],
          "messages": [
            {"file": "2026-10-08-0900-luis-perez.md", "date": "2026-10-08T15:00:00Z",
             "from": {"name": "Luis Pérez", "email": "luis@acme.com"}, "sourceId": "s-mail-2",
             "externalId": "microsoft:AAMk1", "webLink": "https://outlook.office.com/mail/id/AAMk1"},
            {"file": "2026-10-08-1100-jaime-ruiz.md", "date": "2026-10-08T17:00:00Z",
             "from": {"name": "Jaime Ruiz", "email": "jaime@dive.ai"}, "isFromOwner": true}
          ],
          "attachments": [
            {"file": "\(thread2)/attachments/2026-10-08-0900-luis-perez/presupuesto-v2.pptx",
             "message": "2026-10-08-0900-luis-perez.md", "name": "Presupuesto v2.pptx",
             "mime": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
             "size": 70000, "sha256": "abc", "sourceId": "s-att-ppt"}
          ]
        }
        """)
    // The inbox: an attachment of a thread with no project.
    putData(root, "_inbox/emails/factura/attachments/2026-10-09-0800-proveedor/factura.pdf", Data(repeating: 8, count: 1000))
    put(root, "_inbox/emails/factura/2026-10-09-0800-proveedor.md", "---\ntype: email\nfrom: \"Proveedor <cobros@nube.example>\"\ndate: 2026-10-09T08:00:00-06:00\n---\n\nFactura.\n")

    // Summary pages: the contract's (by `sources:`), the photo's (by file name), the attachment's (by its source).
    put(root, "\(p)/wiki/sources/2026-10-01-contrato-acme.md", """
        ---
        type: source
        title: "Contrato de servicios con Acme"
        project: atlas
        sources: ["projects/atlas/raw/docs/2026-10-01-contrato-acme.md"]
        people: ["[[luis-perez]]"]
        ---

        # Contrato de servicios con Acme

        > **En breve:** Contrato anual con cláusula de penalización por retraso.

        Firmado con [[luis-perez|Luis]].
        """)
    put(root, "\(p)/wiki/sources/2026-10-04-planta.md", "---\ntype: source\ntitle: \"Visita a la planta\"\n---\n\n# Visita a la planta\n\nLa línea 3 está detenida.\n")
    put(root, "\(p)/wiki/emails/contrato-acme.md", "---\ntype: email-thread\ntitle: \"Contrato Acme\"\n---\n\n# Contrato Acme\n")
    put(root, "\(p)/wiki/topics/penalizaciones.md", "---\ntype: topic\ntitle: \"Penalizaciones\"\n---\n\n# Penalizaciones\n\nVer [[2026-10-01-contrato-acme]].\n")

    let sources: [SourceRecord] = {
        var att = SourceRecord(id: "s-att-ppt", kind: .document, title: "Presupuesto v2", projectSlug: "atlas", status: .done,
                               rawPath: "\(thread2)/attachments/2026-10-08-0900-luis-perez/presupuesto-v2.pptx")
        att.parentSourceId = "s-mail-2"
        return [att]
    }()
    let snapshot = EntityIndex(vaultRoot: root).refresh()
    let index = FileIndex(vaultRoot: root)
    let all = index.refresh(sources: sources, entities: snapshot)
    func entry(_ suffix: String) -> FileEntry? { all.first { $0.path.hasSuffix(suffix) } }

    t.eq(all.count, 9, "files indexed (2 docs, 3 assets, 3 project attachments, 1 inbox attachment)")
    t.check(entry("sitio.md") == nil, "a web page is not a file")
    t.check(!all.contains { $0.path.hasSuffix("contrato-acme.md") }, "a wrapper is not listed by itself")

    if let c = entry("2026-10-01-contrato-acme.pdf") {
        t.eq(c.name, "Contrato Acme.pdf", "name from the wrapper's title + extension")
        t.eq(c.type, .pdf, "contract type")
        t.eq(c.origin, .upload, "contract origin")
        t.eq(c.size, 2048, "contract size")
        t.eq(c.projectSlug, "atlas", "contract project")
        t.eq(c.sourceId, "s-contrato", "contract source id from the wrapper")
        t.eq(DemoVault.fmt(c.date, "yyyy-MM-dd"), "2026-10-01", "date = imported (added:), not the document's own date")
        t.eq(c.summaryPath, "\(p)/wiki/sources/2026-10-01-contrato-acme.md", "summary page by sources:")
        t.eq(c.summaryTitle, "Contrato de servicios con Acme", "summary title")
        t.check(c.summary?.hasPrefix("Contrato anual") == true, "En breve without its label: \(c.summary ?? "nil")")
        t.check(c.people.contains { $0.path == "people/luis-perez.md" }, "people named by the summary page")
    } else { t.check(false, "contract indexed") }

    if let m = entry("2026-10-02-minuta.md") {
        t.eq(m.name, "Minuta de la visita", "a text document keeps its title")
        t.eq(m.type, .document, "minuta type")
    } else { t.check(false, "markdown document indexed") }

    t.eq(entry("2026-10-04-planta.jpg")?.origin, .dump, "dropped photo = Agregar al proyecto")
    t.eq(entry("2026-10-04-planta.jpg")?.type, .image, "photo type")
    t.eq(entry("2026-10-04-planta.jpg")?.summaryPath, "\(p)/wiki/sources/2026-10-04-planta.md", "summary page by file name")
    t.eq(entry("pizarron.png")?.origin, .capture, "captured image")
    t.eq(entry("suelta.gif")?.origin, .upload, "no wrapper = upload")
    t.eq(entry("suelta.gif")?.name, "suelta.gif", "no wrapper = file name")

    if let a = entry("Contrato firmado.pdf") {
        t.eq(a.origin, .email, "attachment origin")
        t.eq(a.threadKey, "contrato-acme", "attachment thread")
        t.eq(a.threadSubject, "Contrato Acme", "thread subject from the messages")
        t.eq(a.sender?.email, "ana@acme.com", "sender from the message the folder names")
        t.eq(a.messageFile, "2026-10-06-1015-ana-garcia.md", "message file")
        t.eq(DemoVault.fmt(a.date, "yyyy-MM-dd HH:mm"), DemoVault.fmt(SBDate.parseISO("2026-10-06T10:15:00-06:00")!.date, "yyyy-MM-dd HH:mm"), "date = the email's")
        t.check(a.people.contains { $0.path == "people/ana-garcia.md" }, "sender resolved to her person page")
        t.eq(a.threadPagePath, "\(p)/wiki/emails/contrato-acme.md", "thread page")
    } else { t.check(false, "attachment indexed") }
    t.eq(entry("Anexo precios.xlsx")?.type, .spreadsheet, "xlsx attachment")

    if let ppt = entry("presupuesto-v2.pptx") {
        t.eq(ppt.name, "Presupuesto v2.pptx", "name as _thread.json lists it")
        t.eq(ppt.type, .presentation, "pptx")
        t.eq(ppt.threadSubject, "Presupuesto 2027", "subject from _thread.json")
        t.eq(ppt.sourceId, "s-att-ppt", "attachment source from _thread.json")
        t.eq(ppt.webLink, "https://outlook.office.com/mail/id/AAMk1", "web link of its email")
        t.eq(ppt.externalId, "microsoft:AAMk1", "external id of its email")
        t.check(!ppt.people.contains { $0.email == "jaime@dive.ai" }, "the owner is not one of the people")
        t.check(ppt.people.contains { $0.path == "people/luis-perez.md" }, "Luis resolved")
    } else { t.check(false, "listed attachment indexed") }

    if let inbox = entry("factura.pdf") {
        t.check(inbox.projectSlug == nil, "inbox attachment has no project")
        t.eq(inbox.origin, .email, "inbox attachment origin")
        t.eq(inbox.sender?.display, "Proveedor", "inbox sender")
    } else { t.check(false, "inbox attachment indexed") }

    // Newest first.
    t.check(zip(all, all.dropFirst()).allSatisfy { $0.date >= $1.date }, "refresh sorts newest first")

    // Filters.
    t.eq(FileIndex.filter(all, FileQuery(text: "penalizacion")).map(\.name), ["Contrato Acme.pdf"], "search finds the summary text (no accents)")
    t.eq(FileIndex.filter(all, FileQuery(text: "ANEXO precios")).map(\.name), ["Anexo precios.xlsx"], "search by name, every word")
    t.eq(FileIndex.filter(all, FileQuery(text: "linea 3")).count, 1, "search the photo's page")
    t.eq(FileIndex.filter(all, FileQuery(type: .image)).count, 3, "type filter")
    t.eq(FileIndex.filter(all, FileQuery(origin: .email)).count, 4, "origin filter")
    t.eq(FileIndex.filter(all, FileQuery(origin: .email, project: "atlas")).count, 3, "origin + project")
    t.eq(FileIndex.filter(all, FileQuery(person: "people/ana-garcia.md")).map(\.threadKey), ["contrato-acme", "contrato-acme"], "person filter")
    let byName = FileIndex.filter(all, FileQuery(sort: .name)).map(\.name)
    t.eq(byName.first, "Anexo precios.xlsx", "sort by name")
    t.eq(FileIndex.filter(all, FileQuery(sort: .size)).first?.name, "Presupuesto v2.pptx", "sort by size")
    t.check(FileIndex.people(in: all).first?.path != nil, "people list for the filter")

    // What a ficha lists.
    let threadFiles = FileIndex.files(for: "\(p)/wiki/emails/contrato-acme.md", in: all, snapshot: snapshot)
    t.eq(Set(threadFiles.map(\.name)), ["Contrato firmado.pdf", "Anexo precios.xlsx"], "thread ficha: its attachments")
    let ana = FileIndex.files(for: "people/ana-garcia.md", in: all, snapshot: snapshot)
    t.eq(ana.count, 2, "person ficha: what she sent")
    let luis = Set(FileIndex.files(for: "people/luis-perez.md", in: all, snapshot: snapshot).map(\.name))
    t.check(luis.contains("Contrato Acme.pdf") && luis.contains("Presupuesto v2.pptx"), "person ficha: named + sent (\(luis))")
    let acme = Set(FileIndex.files(for: "orgs/acme.md", in: all, snapshot: snapshot).map(\.name))
    t.check(acme.contains("Presupuesto v2.pptx"), "company ficha: files of its people (\(acme))")
    t.eq(FileIndex.files(for: "\(p)/wiki/sources/2026-10-01-contrato-acme.md", in: all, snapshot: snapshot).map(\.name),
         ["Contrato Acme.pdf"], "document ficha: its own file")
    t.check(FileIndex.files(for: "\(p)/wiki/topics/penalizaciones.md", in: all, snapshot: snapshot).contains { $0.name == "Contrato Acme.pdf" },
            "topic ficha: files whose page it links")

    // Incremental: a changed summary page, a new file, a deleted one.
    put(root, "\(p)/wiki/sources/2026-10-04-planta.md", "---\ntype: source\ntitle: \"Visita a la planta\"\n---\n\n# Visita a la planta\n\nCompresor nuevo.\n")
    let url = root.appendingPathComponent("\(p)/wiki/sources/2026-10-04-planta.md")
    try? FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
    try? FileManager.default.removeItem(at: root.appendingPathComponent("\(p)/raw/assets/suelta.gif"))
    putData(root, "\(p)/raw/docs/nuevo.key", Data(repeating: 9, count: 100))
    let again = index.refresh(sources: sources, entities: snapshot)
    t.eq(again.count, 9, "one gone, one new")
    t.check(again.contains { $0.name == "nuevo.key" && $0.type == .presentation }, "new keynote file")
    t.eq(FileIndex.filter(again, FileQuery(text: "compresor")).count, 1, "changed summary page re-read")
    t.eq(FileIndex.filter(again, FileQuery(text: "linea 3")).count, 0, "old summary text gone")
    t.eq(index.entries.count, 9, "entries kept from the last refresh")
}

@MainActor private func testDemoFiles(_ t: Tester, root: URL) {
    _ = try? DemoVault.create(at: root, scale: 0)
    let snapshot = EntityIndex(vaultRoot: root).refresh()
    let all = FileIndex(vaultRoot: root).refresh(entities: snapshot)
    t.check(all.count >= 6, "the demo vault has files (\(all.count))")
    t.check(all.contains { $0.origin == .email && $0.type == .pdf && $0.sender != nil }, "demo: a PDF attachment with its sender")
    t.check(all.contains { $0.type == .image }, "demo: an image")
    t.check(all.contains { $0.origin == .dump }, "demo: something added with Agregar al proyecto")
    t.check(all.contains { $0.summary != nil }, "demo: a file with its En breve")
}

/// A file saved from the quick capture is tagged `origin: capture` and shows as "Captura" in Archivos.
@MainActor private func testCaptureOrigin(_ t: Tester, root: URL) async {
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: FilesNoTranscriber())
    engine.autoProcess = false
    engine.start()
    do {
        let acme = try engine.projects.create(name: "Acme", description: "Cliente", emoji: "🚀")
        let file = root.appendingPathComponent("minuta-captura.txt")
        try "Minuta rápida de la visita.".write(to: file, atomically: true, encoding: .utf8)
        try await engine.importFileAsync(file, projectSlug: acme.slug, origin: "capture")
        let other = root.appendingPathComponent("subido.txt")
        try "Otro documento.".write(to: other, atomically: true, encoding: .utf8)
        try await engine.importFileAsync(other, projectSlug: acme.slug)
        let all = FileIndex(vaultRoot: engine.vault.root).refresh(entities: EntityIndex(vaultRoot: engine.vault.root).refresh())
        t.eq(all.first { $0.name.contains("minuta-captura") }?.origin, .capture, "quick capture file = Captura")
        t.eq(all.first { $0.name.contains("subido") }?.origin, .upload, "plain import = Subido")
    } catch {
        t.check(false, "files-capture: \(error)")
    }
}

private final class FilesNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
