import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.7 dump — "Agregar al proyecto" (CONTRACT §17.3).

struct DumpCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "dump", abstract: "\"Agregar al proyecto\" (v0.7).",
                                                    subcommands: [DumpSelfTestCmd.self])
}

/// `sb dump selftest [--dir <tmp>]`: names, the /file-dump answer, importing several files + text (no ingest jobs, one
/// /file-dump job), the prompt's arguments, a simulated Claude run (one Historial entry for all, the note becomes an
/// in-person meeting with its day, page found by Contenido/timeline), Deshacer, failure and retry, the vault template.
struct DumpSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of Agregar al proyecto.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-dump-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("dump-names") { testDumpNames(t) }
        t.group("dump-parse") { testDumpParse(t) }
        await t.groupAsync("dump-flow") { await testDumpFlow(t, root: root.appendingPathComponent("flow")) }
        await t.groupAsync("dump-failure") { await testDumpFailure(t, root: root.appendingPathComponent("failure")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

@MainActor private func testDumpNames(_ t: Tester) {
    let day = SBDate.parseISO("2026-10-27 18:30")!.date
    t.eq(FileDumpNames.noteBase(title: "Visita a la planta", date: day), "2026-10-27-dump-visita-a-la-planta", "note base")
    t.eq(FileDumpNames.noteSlug(rawPath: "projects/a/raw/notes/2026-10-27-dump-visita-planta.md"), "visita-planta", "note slug")
    t.check(FileDumpNames.noteSlug(rawPath: "projects/a/raw/notes/2026-10-27-idea.md") == nil, "plain note has no dump slug")
    let yesterday = SBDate.parseISO("2026-10-26")!.date
    t.eq(FileDumpNames.meetingKey(rawPath: "projects/a/raw/notes/2026-10-27-dump-visita-planta.md", eventDate: yesterday),
         "2026-10-26-presencial-visita-planta", "meeting key takes the day it happened")
    t.eq(FileDumpNames.meetingKey(rawPath: "projects/a/raw/notes/2026-10-27-dump-visita-planta.md", eventDate: nil),
         "2026-10-27-presencial-visita-planta", "meeting key defaults to the note's day")
    t.eq(FileDumpNames.kind(of: URL(fileURLWithPath: "/x/Foto.JPG")), .image, "jpg → image")
    t.eq(FileDumpNames.kind(of: URL(fileURLWithPath: "/x/contrato.pdf")), .document, "pdf → document")
    var src = SourceRecord(id: "x", kind: .inPerson, title: "t", projectSlug: "a", status: .done,
                           rawPath: "projects/a/raw/notes/2026-10-27-dump-visita-planta.md")
    src.eventDate = yesterday
    t.eq(FileDumpNames.pageKey(of: src), "2026-10-26-presencial-visita-planta", "in-person page key")
    src.kind = .note
    t.eq(FileDumpNames.pageKey(of: src), "2026-10-27-dump-visita-planta", "note page key = raw key")
}

@MainActor private func testDumpParse(_ t: Tester) {
    let json = #"{"summary":"Lo archivé así:\n- [[2026-10-26-presencial-x|Visita]]","items":[{"raw":"r.md","as":"in-person","page":"projects/a/wiki/meetings/2026-10-26-presencial-x.md","title":"Visita"},{"raw":null,"as":"person","page":"people/luis.md","title":"Luis"}],"meeting":{"date":"2026-10-26","time":"9:30","title":"Visita a la planta"}}"#
    let r = FileDumpResult.parse(json)
    t.check(r.summary.hasPrefix("Lo archivé así:"), "summary")
    t.eq(r.items.count, 2, "items")
    t.eq(r.items.first?.kind, "in-person", "item kind")
    t.check(r.isMeeting, "meeting detected")
    t.eq(r.meetingTitle, "Visita a la planta", "meeting title")
    t.eq(r.meetingDate.map { SBDate.iso($0).prefix(16) }.map(String.init), "2026-10-26T09:30", "meeting date + time (H:MM padded)")
    let fenced = FileDumpResult.parse("Listo.\n```json\n{\"summary\":\"Filed it like this:\\n- a\",\"items\":[],\"meeting\":null}\n```")
    t.eq(fenced.summary, "Filed it like this:\n- a", "fenced JSON")
    t.check(!fenced.isMeeting, "null meeting = not a meeting")
    let md = FileDumpResult.parse("Lo archivé así:\n- Nota sobre precios")
    t.eq(md.summary, "Lo archivé así:\n- Nota sobre precios", "markdown answer kept as summary")
    t.check(md.items.isEmpty && !md.isMeeting, "markdown: no items")
    let noSummary = FileDumpResult.parse(#"{"items":[{"as":"document","page":"projects/a/wiki/sources/k.md","title":"Contrato"}]}"#)
    t.eq(noSummary.summary, "- [[k|Contrato]]", "summary falls back to the pages")
}

@MainActor private func makeDumpEngine(_ root: URL) throws -> (BrainEngine, Project) {
    try? FileManager.default.removeItem(at: root)
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: DumpNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let project = try engine.projects.create(name: "Acme", description: "", emoji: "🚀")
    return (engine, project)
}

@MainActor private func dropFiles(in root: URL) throws -> [URL] {
    let fm = FileManager.default
    let inbox = root.appendingPathComponent("drop")
    try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
    let doc = inbox.appendingPathComponent("Contrato Acme.txt")
    try "Contrato de servicios entre Acme y Dive. Vigencia: 12 meses. Firma antes del 30 de octubre.".write(to: doc, atomically: true, encoding: .utf8)
    let png = inbox.appendingPathComponent("Linea 2.png")
    // A 1×1 PNG.
    let bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1,
                          8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89, 0, 0, 0, 0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0, 1, 0, 0,
                          5, 0, 1, 0x0D, 0x0A, 0x2D, 0xB4, 0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82]
    try Data(bytes).write(to: png)
    return [doc, png]
}

@MainActor private func testDumpFlow(_ t: Tester, root: URL) async {
    defer { FileDumpSimulator.run = nil }
    do {
        let fm = FileManager.default
        let (engine, project) = try makeDumpEngine(root)
        let slug = project.slug
        t.check(fm.fileExists(atPath: engine.vault.url(for: ".claude/commands/file-dump.md").path), "vault has /file-dump")
        let command = (try? engine.vault.read(".claude/commands/file-dump.md")) ?? ""
        t.check(command.contains("-presencial-") && command.contains("\"items\"") && !command.contains("placeholder"),
                "/file-dump is the real command")
        let manual = (try? engine.vault.read("CLAUDE.md")) ?? ""
        t.check(manual.contains("meeting_kind: in-person") && manual.contains("🤝"), "CLAUDE.md describes in-person meetings")

        let files = try dropFiles(in: root)
        let text = "Visita a la planta con Luis Pérez\n\nAyer revisamos la línea 2. Luis manda el layout el viernes."
        let before = engine.sources.count
        let record = try await engine.addToProject(slug, files: files, text: text)
        let added = engine.sources.filter { record.sourceIds.contains($0.id) }
        t.eq(engine.sources.count - before, 3, "three sources (2 files + text)")
        t.eq(Set(added.map(\.kind)), Set([.document, .image, .note]), "kinds document, image, note")
        let doc = added.first { $0.kind == .document }, img = added.first { $0.kind == .image }, note = added.first { $0.kind == .note }
        t.check(doc?.rawPath?.hasPrefix("projects/\(slug)/raw/docs/") == true, "document in raw/docs")
        t.check(img?.rawPath?.hasPrefix("projects/\(slug)/raw/assets/") == true, "image in raw/assets")
        t.check(note?.rawPath?.contains("/raw/notes/") == true && note?.rawPath?.contains("-dump-visita-a-la-planta-con-luis-perez") == true,
                "text → raw/notes/<date>-dump-<slug>.md (\(note?.rawPath ?? "-"))")
        if let raw = img?.rawPath, let text = try? engine.vault.read(raw) {
            t.check(text.contains("type: image") && text.contains("origin: dump"), "image raw: type image, origin dump")
            let original = text.components(separatedBy: "\n").first { $0.hasPrefix("original_file:") }
                .map { $0.dropFirst("original_file:".count).trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? ""
            t.check(original.hasSuffix(".png") && fm.fileExists(atPath: engine.vault.url(for: (raw as NSString).deletingLastPathComponent + "/" + original).path),
                    "image file copied next to its raw")
        } else { t.check(false, "image raw readable") }
        t.check(added.allSatisfy { $0.status == .queued }, "sources wait for /file-dump")
        t.eq(engine.jobs.filter { $0.kind == .ingest }.count, 0, "no ingest jobs")
        t.eq(engine.jobs.filter { $0.kind == .fileDump }.count, 1, "one /file-dump job")
        t.eq(engine.dumpPendingSourceIds(), Set(record.sourceIds), "pending dump covers its sources")
        t.eq(engine.dumps(projectSlug: slug).first?.id, record.id, "drop listed for the project")

        // The prompt's arguments.
        let args = engine.fileDumpArguments(record)
        let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any] ?? [:]
        t.eq(obj["project"] as? String, slug, "args: project")
        t.check(obj["hint"] is NSNull, "args: no hint")
        let argFiles = obj["files"] as? [[String: Any]] ?? []
        t.eq(argFiles.count, 2, "args: two files")
        t.check(argFiles.contains { $0["kind"] as? String == "image" && ($0["original"] as? String)?.hasSuffix(".png") == true },
                "args: image with its original")
        t.check(argFiles.contains { $0["name"] as? String == "Contrato Acme.txt" }, "args: dropped name")
        let argNote = obj["note"] as? [String: Any]
        t.eq(argNote?["slug"] as? String, "visita-a-la-planta-con-luis-perez", "args: note slug")

        // Simulated Claude: files the text as an in-person meeting of yesterday and the contract as a document.
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: Date())!
        let day = DateFormatter.dumpDay.string(from: yesterday)
        let meetingPath = "projects/\(slug)/wiki/meetings/\(day)-presencial-visita-a-la-planta-con-luis-perez.md"
        let docKey = ((doc?.rawPath ?? "") as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        let docPage = "projects/\(slug)/wiki/sources/\(docKey).md"
        var seenArgs = ""
        FileDumpSimulator.run = { arguments, vault in
            seenArgs = arguments
            let write = { (path: String, body: String) in
                let url = vault.appendingPathComponent(path)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? body.write(to: url, atomically: true, encoding: .utf8)
            }
            write(meetingPath, "---\ntype: meeting\nmeeting_kind: in-person\ntitle: \"Visita a la planta\"\ndate: \(day)\n---\n\n# Visita a la planta\n")
            write(docPage, "---\ntype: source\nsource_type: document\ntitle: \"Contrato Acme\"\n---\n\n# Contrato Acme\n")
            return """
            {"summary":"Lo archivé así:\\n- La visita como reunión presencial: [[\(day)-presencial-visita-a-la-planta-con-luis-perez|Visita a la planta]].\\n- El contrato: [[\(docKey)|Contrato Acme]].","items":[{"raw":"x","as":"in-person","page":"\(meetingPath)","title":"Visita a la planta"},{"raw":"y","as":"document","page":"\(docPage)","title":"Contrato Acme"}],"meeting":{"date":"\(day)","time":null,"title":"Visita a la planta"}}
            """
        }
        await engine.runUntilIdle()
        t.eq(seenArgs, args, "Claude got the arguments")
        t.eq(engine.jobs.count, 0, "queue empty")
        let done = engine.sources.filter { record.sourceIds.contains($0.id) }
        t.check(done.count == 3 && done.allSatisfy { $0.status == .done }, "all sources done")
        let hids = Set(done.compactMap(\.historyId))
        t.eq(hids.count, 1, "one Historial entry for the whole drop")
        let filedNote = done.first { $0.id == record.noteSourceId }
        t.eq(filedNote?.kind, .inPerson, "the note became an in-person meeting")
        t.eq(filedNote?.title, "Visita a la planta", "meeting title from Claude")
        t.eq(filedNote?.eventDate.map { DateFormatter.dumpDay.string(from: $0) }, day, "meeting dated the day it happened")
        t.eq(filedNote.flatMap { engine.pagePath(forSourceId: $0.id) }, meetingPath, "page of the in-person meeting found")
        let entry = hids.first.flatMap { engine.history.entry(id: $0) }
        t.eq(entry?.kind, .fileDump, "history kind fileDump")
        t.check(entry.flatMap { engine.history.summary(entryId: $0.id) }?.hasPrefix("Lo archivé así:") == true, "Historial shows the summary")
        let saved = engine.dumps(projectSlug: slug).first
        t.eq(saved?.status, .done, "drop done")
        t.eq(saved?.items.count, 2, "drop items")
        t.check(saved?.summary?.contains("reunión presencial") == true, "drop summary")
        let timeline = await engine.timeline(projectSlug: slug)
        let meetingEntry = timeline.first { $0.sourceId == record.noteSourceId }
        t.eq(meetingEntry?.kind, .meeting, "timeline: in-person meeting is a meeting")
        t.eq(meetingEntry?.pagePath, meetingPath, "timeline: opens its page")
        t.eq(meetingEntry?.title, "Visita a la planta", "timeline: title from the page")

        // Deshacer: the pages, the sources and their raw files go.
        let raws = done.compactMap(\.rawPath)
        try engine.undoDump(id: record.id)
        t.check(!fm.fileExists(atPath: engine.vault.url(for: meetingPath).path), "undo removed the meeting page")
        t.check(!fm.fileExists(atPath: engine.vault.url(for: docPage).path), "undo removed the document page")
        t.check(engine.sources.allSatisfy { !record.sourceIds.contains($0.id) }, "undo removed the sources")
        t.check(raws.allSatisfy { !fm.fileExists(atPath: engine.vault.url(for: $0).path) }, "undo removed the raw files")
        t.eq(engine.dumps(projectSlug: slug).first?.status, .undone, "drop marked undone")
        t.check(hids.first.flatMap { engine.history.entry(id: $0) }?.undone == true, "Historial entry undone")

        // Marked in-person by the owner + a plain markdown answer: still an in-person meeting.
        FileDumpSimulator.run = { _, _ in "Lo archivé así:\n- Comida con Ana." }
        let marked = try await engine.addToProject(slug, files: [], text: "Comida con Ana: quiere la propuesta el lunes", inPerson: true)
        t.eq(engine.source(marked.noteSourceId ?? "")?.kind, .inPerson, "marked in-person from the start")
        t.check(engine.fileDumpArguments(marked).contains("\"hint\":\"in-person\""), "hint passed to Claude")
        await engine.runUntilIdle()
        t.eq(engine.source(marked.noteSourceId ?? "")?.kind, .inPerson, "stays in-person with a markdown answer")
        t.eq(engine.dumps(projectSlug: slug).first?.summary, "Lo archivé así:\n- Comida con Ana.", "markdown summary kept")

        // Cancel before it runs.
        let pending = try await engine.addToProject(slug, files: [], text: "Idea suelta")
        try engine.undoDump(id: pending.id)
        t.eq(engine.jobs.filter { $0.kind == .fileDump }.count, 0, "cancelled drop leaves no job")
        t.check(engine.source(pending.noteSourceId ?? "") == nil, "cancelled drop leaves no source")

        // Nothing to add.
        do {
            _ = try await engine.addToProject("no-existe", files: [], text: "x")
            t.check(false, "unknown project refused")
        } catch { t.check(true, "unknown project refused") }
    } catch {
        t.check(false, "dump flow: \(error)")
    }
}

@MainActor private func testDumpFailure(_ t: Tester, root: URL) async {
    defer { FileDumpSimulator.run = nil }
    do {
        let (engine, project) = try makeDumpEngine(root)
        FileDumpSimulator.run = { _, _ in throw ClaudeError.notInstalled }
        let record = try await engine.addToProject(project.slug, files: [], text: "Nota que fallará")
        await engine.runUntilIdle()
        t.eq(engine.dumps(projectSlug: project.slug).first?.status, .failed, "drop failed")
        t.eq(engine.source(record.noteSourceId ?? "")?.status, .failed, "its source failed")
        FileDumpSimulator.run = { _, _ in #"{"summary":"Lo archivé así:\n- Nota.","items":[],"meeting":null}"# }
        engine.retryDump(id: record.id)
        t.eq(engine.jobs.filter { $0.kind == .fileDump }.count, 1, "retry queues /file-dump again")
        await engine.runUntilIdle()
        t.eq(engine.dumps(projectSlug: project.slug).first?.status, .done, "retry done")
        t.eq(engine.source(record.noteSourceId ?? "")?.kind, .note, "a plain note stays a note")
        t.eq(engine.source(record.noteSourceId ?? "")?.status, .done, "source done after retry")
    } catch {
        t.check(false, "dump failure: \(error)")
    }
}

private extension DateFormatter {
    static let dumpDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

private final class DumpNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
