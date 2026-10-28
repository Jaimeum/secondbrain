import BrainCore
import Foundation

// MARK: v0.6 capture — what "Captura rápida" saves each text as (§16.10), the formats of notes and documents, and
// the auto-add default of new mail rules.

@MainActor func testCapture(_ t: Tester, root: URL) async {
    func kind(_ s: String) -> String {
        switch CaptureDetector.detect(s) {
        case .note: "note"
        case .link(let url): "link:" + url.absoluteString
        case .email: "email"
        }
    }
    // Links: only when the whole text is one address.
    t.eq(kind("https://acme.com/blog/x?a=1"), "link:https://acme.com/blog/x?a=1", "https link")
    t.eq(kind("  http://acme.com \n"), "link:http://acme.com", "trimmed http link")
    t.eq(kind("www.acme.mx"), "link:https://www.acme.mx", "www → https")
    t.eq(kind("acme.com/precios"), "link:https://acme.com/precios", "bare host with path")
    t.eq(kind("mira esto https://acme.com"), "note", "link inside a sentence → note")
    t.eq(kind("v0.6"), "note", "version number is not a host")
    t.eq(kind("e.g."), "note", "abbreviation is not a host")
    t.eq(kind("3.14"), "note", "number is not a host")
    t.eq(kind("ana@acme.com"), "note", "an address alone is not a link")
    t.eq(kind("ftp://acme.com/x"), "note", "other schemes stay notes")
    // Emails: a sender header plus another header, or Gmail's copy.
    t.eq(kind("De: Ana <ana@acme.com>\nPara: Jaime <jaime@dive.ai>\nAsunto: Hola\n\nTexto"), "email", "Outlook es headers")
    t.eq(kind("From: ana@acme.com\nSubject: Hi\n\nBody text here"), "email", "English headers")
    t.eq(kind("Presupuesto\n\nLaura <laura@cliente.mx>\nmié, 21 oct 2026, 16:40\npara mí\n\nHola Jaime"), "email", "Gmail copy")
    t.eq(kind("Hablar de: precios con ana@acme.com\nFecha: jueves"), "note", "\"de:\" inside a line is not a header")
    t.eq(kind("Llamar a Laura el jueves"), "note", "plain note")
    t.eq(kind(""), "note", "empty → note")
    // Note titles: the first line, shortened at a word.
    t.eq(CaptureDetector.noteTitle("  # Idea para Acme\nmás texto"), "Idea para Acme", "title from first line")
    t.eq(CaptureDetector.noteTitle(String(repeating: "palabra ", count: 20), limit: 20), "palabra palabra…", "long title cut at a word")
    t.check(CaptureDetector.noteTitle(" \n ") == nil, "empty → no title")

    // TemplateScope: notes and documents (links read like documents); repo syncs have none.
    t.eq(TemplateScope(kind: .note), .note, "note scope")
    t.eq(TemplateScope(kind: .url), .document, "url → document scope")
    t.check(TemplateScope(kind: .github) == nil, "github → no scope")
    t.eq(TemplateScope(rawValue: "document"), .document, "document decodes")

    // New mail rules save the next ones by themselves; meeting rules have nothing to add.
    let mail = RoutingSubject(kind: .mail, sender: EmailAddress(name: nil, email: "ana@acme.com"), recipients: [], subject: "x", text: "")
    t.check(RoutingStore.suggestedRule(for: mail, projectSlug: "acme", language: "es")?.autoAddMail == true, "offered mail rule auto-adds")
    let meeting = RoutingSubject(kind: .meeting, sender: EmailAddress(name: nil, email: "ana@acme.com"), recipients: [], subject: "x", text: "")
    t.check(RoutingStore.suggestedRule(for: meeting, projectSlug: "acme", language: "es")?.autoAddMail == false, "meeting rule doesn't")

    // A project default made for notes formats notes; meeting formats don't reshape them.
    do {
        try? FileManager.default.removeItem(at: root)
        var config = AppConfig.default
        config.vaultPath = root.appendingPathComponent("vault").path
        config.dataPath = root.appendingPathComponent("data").path
        config.uiLanguage = "es"
        let engine = BrainEngine(config: config, transcriber: CaptureNoTranscriber())
        engine.autoProcess = false
        engine.start()
        let project = try engine.projects.create(name: "Acme", description: "", emoji: "🚀")
        let noteFormat = try engine.saveTemplate(TemplateInfo(id: "", name: "Nota breve", description: "", scope: .note,
                                                              isBuiltIn: false, body: "## Idea"))
        t.eq(engine.templates(scope: .note).contains { $0.id == noteFormat.id }, true, "note format listed for notes")
        t.eq(engine.templates(scope: .meeting).contains { $0.id == noteFormat.id }, false, "note format not listed for meetings")
        try engine.setDefaultTemplate(projectSlug: project.slug, templateId: noteFormat.id)
        try engine.addNote(title: "Idea", body: "Algo", projectSlug: project.slug)
        let note = engine.sources.last { $0.kind == .note }
        t.check(note.map { engine.templateId(for: $0) } == noteFormat.id, "project note default applies to notes")
        try engine.setDefaultTemplate(projectSlug: project.slug, templateId: TemplateInfo.standardId)
        t.check(note.map { engine.templateId(for: $0) } == .some(nil), "a meeting default doesn't reshape notes")
    } catch {
        t.check(false, "capture engine: \(error)")
    }
}

private final class CaptureNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
