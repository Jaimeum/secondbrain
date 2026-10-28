import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.6 facts — `sb facts selftest` (CONTRACT §16.6, §16.13)

struct FactsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "facts", abstract: "Confirmed facts and hand edits (v0.6).",
                                                    subcommands: [FactsSelfTestCmd.self])
}

/// `sb facts selftest [--dir <tmp>]`: hand edit → /propagate answer (a fake runner output) → review → apply (pages +
/// facts.md, one Historial entry) → undo; plus the vault template and its migration. No Claude, no network.
struct FactsSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of edits, /propagate and facts.md.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-facts-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("facts-template") { testFactsTemplate(t, root: root.appendingPathComponent("template")) }
        t.group("facts-parse") { testFactsParse(t) }
        t.group("facts-apply") { testFactsApply(t, root: root.appendingPathComponent("apply")) }
        t.group("facts-safety") { testFactsSafety(t, root: root.appendingPathComponent("safety")) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

/// New vaults get facts.md, orgs/ and /propagate; a template-v4 vault gets them on migration, its pages untouched.
@MainActor func testFactsTemplate(_ t: Tester, root: URL) {
    let fm = FileManager.default
    let vault = VaultStore(root: root)
    do {
        _ = try vault.migrateIfNeeded()
    } catch {
        t.check(false, "install template: \(error)")
        return
    }
    t.check(VaultStore.bundledTemplateVersion >= 5, "template version bumped (\(VaultStore.bundledTemplateVersion))")
    for path in ["facts.md", "orgs/README.md", ".claude/commands/propagate.md"] {
        t.check(fm.fileExists(atPath: vault.url(for: path).path), "fresh vault has \(path)")
    }
    let claude = (try? vault.read("CLAUDE.md")) ?? ""
    t.check(claude.contains("facts.md") && claude.contains("## 17."), "CLAUDE.md has the facts section")
    t.check(!claude.contains("They never edit the wiki by hand"), "the owner may edit")
    t.check(claude.contains("orgs/<name>.md") && claude.contains("org: \"[[acme]]\""), "CLAUDE.md has orgs/ and org:")
    let query = (try? vault.read(".claude/commands/query.md")) ?? ""
    t.check(query.contains("prioritize the project") && query.contains("Never read other projects"), "query.md project-scope rule")
    for cmd in ["ingest", "query", "classify", "lint"] {
        t.check(((try? vault.read(".claude/commands/\(cmd).md")) ?? "").contains("facts.md"), "\(cmd).md reads facts.md")
    }
    let propagate = (try? vault.read(".claude/commands/propagate.md")) ?? ""
    t.check(propagate.contains("$ARGUMENTS") && propagate.contains("\"edits\""), "propagate.md asks for the JSON")
    t.check(vault.pages(projectSlug: nil).contains { $0.path == "facts.md" }, "facts.md is a global page")

    // Back to template v4: the v0.6 files are missing, a page of the owner's exists.
    try? fm.removeItem(at: vault.url(for: "facts.md"))
    try? fm.removeItem(at: vault.url(for: "orgs"))
    try? fm.removeItem(at: vault.url(for: ".claude/commands/propagate.md"))
    try? "4\n".write(to: vault.url(for: ".secondbrain/template-version"), atomically: true, encoding: .utf8)
    let person = "---\ntype: person\ntitle: \"Ana\"\n---\n\n# Ana\n"
    try? fm.createDirectory(at: vault.url(for: "people"), withIntermediateDirectories: true)
    try? person.write(to: vault.url(for: "people/ana.md"), atomically: true, encoding: .utf8)
    guard let result = try? vault.migrateIfNeeded() else {
        t.check(false, "migration ran")
        return
    }
    t.eq(result.fromVersion, 4, "migrated from v4")
    t.check(result.copied.contains("facts.md") && result.copied.contains("orgs/README.md"), "migration copied facts.md and orgs/: \(result.copied)")
    t.check(result.updatedCommands.contains(".claude/commands/propagate.md"), "migration added /propagate")
    t.eq((try? vault.read("people/ana.md")) ?? "", person, "existing page untouched")
}

/// Claude's answer: bare, fenced, after text; garbage → nil. The diff and the arguments of the command.
@MainActor func testFactsParse(_ t: Tester) {
    let json = #"{"facts":["Javier Ruiz no forma parte del equipo de Angela Torres. ([[javier-ruiz]], [[angela-torres]])"],"edits":[{"path":"people/angela-torres.md","before":"a","after":"b","reason":"r"}]}"#
    t.eq(Corrections.parse(json)?.edits.count, 1, "bare JSON")
    t.eq(Corrections.parse("Revisé el cerebro.\n\n```json\n\(json)\n```\n")?.facts.count, 1, "fenced JSON after text")
    t.eq(Corrections.parse("Listo: {\"facts\":[],\"edits\":[]}")?.edits.count, 0, "empty answer after text")
    t.check(Corrections.parse("No encontré nada.") == nil, "no JSON → nil")
    t.eq(Corrections.parse(#"{"edits":[{"path":"x.md","before":"a"}]}"#)?.edits.first?.after, "", "missing fields default")

    let diff = Corrections.diff(before: "a\nb\nc\nd\ne", after: "a\nb\nC\nd\ne", context: 1)
    t.eq(diff, "  b\n- c\n+ C\n  d", "one-hunk diff with context")
    t.eq(Corrections.diff(before: "x", after: "x"), "", "no change, no diff")
    let args = Corrections.propagateArguments(path: "projects/kickoff/wiki/overview.md", title: "Kickoff", before: "a\nb", after: "a\nc")
    let obj = (try? JSONSerialization.jsonObject(with: Data(args.utf8))) as? [String: Any]
    t.eq(obj?["project"] as? String, "kickoff", "arguments: project slug")
    t.eq(obj?["path"] as? String, "projects/kickoff/wiki/overview.md", "arguments: path")
    t.check((obj?["diff"] as? String)?.contains("+ c") == true, "arguments: diff")
    t.check(!args.contains("\n"), "arguments are one line")

    t.check(Corrections.isEditable("people/ana.md") && Corrections.isEditable("facts.md") && Corrections.isEditable("projects/x/wiki/overview.md"),
            "wiki pages are editable")
    t.check(!Corrections.isEditable("projects/x/raw/notes/a.md") && !Corrections.isEditable("_inbox/notes/a.md")
            && !Corrections.isEditable("CLAUDE.md") && !Corrections.isEditable("projects/x/CLAUDE.md")
            && !Corrections.isEditable(".claude/commands/query.md") && !Corrections.isEditable("../x.md")
            && !Corrections.isEditable("people/ana.pdf"), "raw, manuals and app files are not")

    let edit = ProposedEdit(path: "p.md", before: "- **Equipo:** Javier  \n- Sofía", after: "- Sofía")
    t.eq(Corrections.applying(edit, to: "# P\n- **Equipo:** Javier\n- Sofía\n"), "# P\n- Sofía\n", "match ignores trailing spaces")
    t.check(Corrections.applying(ProposedEdit(path: "p.md", before: "nope", after: "x"), to: "# P\n") == nil, "missing excerpt → nil")
    let date = DateComponents(calendar: Calendar.current, year: 2026, month: 10, day: 27, hour: 12).date!
    t.eq(Corrections.factLine("- Javier no es del equipo de Angela.\n", date: date, fallbackLinks: ["javier-ruiz"]),
         "- 2026-10-27 · Javier no es del equipo de Angela. ([[javier-ruiz]])", "fact line with fallback link")
    t.eq(Corrections.factLine("A ([[a]])", date: date, fallbackLinks: ["b"]), "- 2026-10-27 · A ([[a]])", "own links kept")
    t.check(Corrections.factLine("  ", date: date) == nil, "empty fact → nil")
}

/// Hand edit → validated proposal → apply (pages + facts.md in ONE entry) → undo restores everything.
@MainActor func testFactsApply(_ t: Tester, root: URL) {
    let fm = FileManager.default
    let vaultURL = root.appendingPathComponent("vault")
    let vault = VaultStore(root: vaultURL)
    let history = HistoryStore(vaultRoot: vaultURL, historyDir: root.appendingPathComponent("history"))
    do { _ = try vault.migrateIfNeeded() } catch { t.check(false, "install: \(error)"); return }
    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(at: vault.url(for: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: vault.url(for: path), atomically: true, encoding: .utf8)
    }
    func read(_ path: String) -> String { (try? vault.read(path)) ?? "<missing>" }
    let javier = "---\ntype: person\ntitle: \"Javier Ruiz\"\n---\n\n# Javier Ruiz\n\n## Rol y contexto\n- Parte del equipo de [[angela-torres|Angela Torres]] ([[2026-10-20-1000-kickoff]])\n"
    let angela = "---\ntype: person\ntitle: \"Angela Torres\"\npeople: [\"[[javier-ruiz]]\", \"[[sofia-mora]]\"]\n---\n\n# Angela Torres\n\n- **Equipo:** [[javier-ruiz|Javier Ruiz]], [[sofia-mora|Sofía Mora]]\n"
    let overview = "---\ntype: overview\ntitle: \"Kickoff\"\n---\n\n# Kickoff\n\n## Personas\n- Angela Torres lidera; su equipo: Javier Ruiz y Sofía Mora.\n"
    let raw = "---\ntype: transcript\n---\n**[00:01:00] Yo:** Javier está con Angela.\n"
    write("people/javier-ruiz.md", javier)
    write("people/angela-torres.md", angela)
    write("projects/kickoff/wiki/overview.md", overview)
    write("projects/kickoff/raw/meetings/2026-10-20-1000-kickoff.md", raw)
    let factsBefore = read("facts.md")

    // 1. The owner's hand edit: one undoable entry with before/after.
    let edited = javier.replacingOccurrences(of: "- Parte del equipo de [[angela-torres|Angela Torres]] ([[2026-10-20-1000-kickoff]])",
                                             with: "- Trabaja con [[angela-torres|Angela Torres]], pero no es de su equipo.")
    let handEntry = try? vault.saveHandEdit(path: "people/javier-ruiz.md", text: edited, title: "Editaste: Javier Ruiz", history: history)
    t.check(handEntry != nil, "hand edit recorded")
    t.eq(handEntry?.kind, .manualEdit, "hand edit is a manual edit")
    t.eq(handEntry?.changes.map(\.path), ["people/javier-ruiz.md"], "hand edit changes one page")
    t.eq(read("people/javier-ruiz.md"), edited, "page written")
    if let id = handEntry?.id {
        let d = history.diff(entryId: id, path: "people/javier-ruiz.md")
        t.eq(d.before, javier, "history keeps before")
        t.eq(d.after, edited, "history keeps after")
    }
    do {
        let same = try vault.saveHandEdit(path: "people/javier-ruiz.md", text: edited, title: "x", history: history)
        t.check(same == nil, "saving the same text records nothing")
    } catch {
        t.check(false, "saving the same text: \(error)")
    }

    // 2. /propagate's answer (what a fake runner returns), validated against the vault.
    let answer = """
    Revisé las páginas que mencionan a Javier.
    {"facts":["Javier Ruiz no forma parte del equipo de Angela Torres. ([[javier-ruiz]], [[angela-torres]])","Javier trabaja con Angela."],
     "edits":[
      {"path":"people/angela-torres.md","before":"people: [\\"[[javier-ruiz]]\\", \\"[[sofia-mora]]\\"]","after":"people: [\\"[[sofia-mora]]\\"]","reason":"Quitar a Javier de la lista."},
      {"path":"people/angela-torres.md","before":"- **Equipo:** [[javier-ruiz|Javier Ruiz]], [[sofia-mora|Sofía Mora]]","after":"- **Equipo:** [[sofia-mora|Sofía Mora]]","reason":"Ponía a Javier en el equipo de Angela."},
      {"path":"projects/kickoff/wiki/overview","before":"- Angela Torres lidera; su equipo: Javier Ruiz y Sofía Mora.","after":"- Angela Torres lidera; su equipo: Sofía Mora. Javier Ruiz colabora sin ser parte del equipo ([[facts|Hechos confirmados]]).","reason":"Decía que Javier era del equipo."},
      {"path":"projects/kickoff/raw/meetings/2026-10-20-1000-kickoff.md","before":"Javier está con Angela.","after":"x","reason":"raw"},
      {"path":"people/javier-ruiz.md","before":"# Javier Ruiz","after":"# J","reason":"the edited page"},
      {"path":"log.md","before":"# ","after":"x","reason":"log"},
      {"path":"people/nadie.md","before":"a","after":"b","reason":"missing page"},
      {"path":"people/angela-torres.md","before":"Javier es jefe","after":"x","reason":"not in the page"},
      {"path":"people/angela-torres.md","before":"# Angela Torres","after":"# Angela Torres","reason":"no change"}
     ]}
    """
    guard let parsed = Corrections.parse(answer) else {
        t.check(false, "fake answer parses")
        return
    }
    t.eq(parsed.edits.count, 9, "all proposals parsed")
    let proposal = vault.validated(parsed, editedPath: "people/javier-ruiz.md")
    t.eq(proposal.edits.map(\.path), ["people/angela-torres.md", "people/angela-torres.md", "projects/kickoff/wiki/overview.md"],
         "only applicable edits kept (raw, edited page, log, missing, stale, no-op dropped; .md added)")
    t.eq(proposal.facts.count, 2, "facts kept")
    t.eq(vault.validated(parsed, editedPath: Corrections.factsPath).facts.count, 0, "editing facts.md itself adds no facts")

    // 2b. Shape seen from the real Claude (sonnet, 2026-10-27): `before`/`after` wrapped in newlines around one line.
    let realEdit = ProposedEdit(path: "x.md", before: "\n- En su equipo está [[carlos-vega|Carlos Vega]].\n", after: "\n")
    let realPage = "# Ana García\n\n- Rol: CFO\n\n- En su equipo está [[carlos-vega|Carlos Vega]].\n"
    t.eq(Corrections.applying(realEdit, to: realPage), "# Ana García\n\n- Rol: CFO\n\n",
         "newline-wrapped edit from the real Claude removes exactly that line")

    // 3. Apply: the owner unchecked nothing. A page changed since Claude read it → that edit is stale, the rest applies.
    let changedOverview = overview + "\n## Nuevo\n- algo\n"
    let stale = ProposedEdit(path: "projects/kickoff/wiki/overview.md", before: "- algo que ya no está", after: "x")
    write("projects/kickoff/wiki/overview.md", changedOverview)
    let date = DateComponents(calendar: Calendar.current, year: 2026, month: 10, day: 27, hour: 12).date!
    guard let result = try? vault.applyCorrections(proposal.edits + [stale], facts: proposal.facts, title: "Corregiste el cerebro",
                                                   projectSlug: nil, fallbackLinks: ["javier-ruiz"], history: history,
                                                   language: "es", date: date) else {
        t.check(false, "apply ran")
        return
    }
    t.eq(result.pages, ["people/angela-torres.md", "projects/kickoff/wiki/overview.md"], "two pages changed")
    t.eq(result.stale.map(\.before), ["- algo que ya no está"], "stale edit reported, not forced")
    t.eq(result.factsAdded, 2, "two facts added")
    t.eq(result.entry?.kind, .manualEdit, "one manual-edit entry")
    t.eq(result.entry?.changes.map(\.path), ["facts.md", "people/angela-torres.md", "projects/kickoff/wiki/overview.md"],
         "ONE entry for pages + facts.md")
    let newAngela = read("people/angela-torres.md")
    t.check(!newAngela.contains("javier") && newAngela.contains("[[sofia-mora|Sofía Mora]]"), "angela-torres.md corrected (front-matter + body)")
    t.check(read("projects/kickoff/wiki/overview.md").contains("su equipo: Sofía Mora. Javier Ruiz colabora")
            && read("projects/kickoff/wiki/overview.md").contains("## Nuevo"), "overview corrected, later text kept")
    t.eq(read("projects/kickoff/raw/meetings/2026-10-20-1000-kickoff.md"), raw, "raw source untouched")
    let facts = read("facts.md")
    t.check(facts.contains("# Hechos confirmados por ti") && facts.range(of: "## Hechos\n")!.lowerBound < facts.range(of: "- 2026-10-27")!.lowerBound,
            "facts.md keeps its header; facts go under ## Hechos")
    t.check(facts.contains("\n- 2026-10-27 · Javier Ruiz no forma parte del equipo de Angela Torres. ([[javier-ruiz]], [[angela-torres]])\n"),
            "fact line in the §16.6 format")
    t.check(facts.contains("\n- 2026-10-27 · Javier trabaja con Angela. ([[javier-ruiz]])\n"), "fact without links gets the edited page")
    t.check(facts.contains("updated: 2026-10-27"), "facts.md updated: set")

    // Same facts again → nothing new; "Solo esta página" with an empty proposal → nothing at all.
    let again = try? vault.applyCorrections([], facts: proposal.facts, title: "x", projectSlug: nil, fallbackLinks: ["javier-ruiz"],
                                            history: history, language: "es", date: date)
    t.eq(again?.factsAdded, 0, "duplicate facts skipped")
    t.check(again?.entry == nil, "no entry when nothing changed")

    // 4. Undo the propagation: pages and facts.md back, byte for byte. Then undo the hand edit.
    if let id = result.entry?.id {
        do {
            try history.undo(entryId: id)
            t.eq(read("people/angela-torres.md"), angela, "undo restores angela-torres.md")
            t.eq(read("projects/kickoff/wiki/overview.md"), changedOverview, "undo restores the overview")
            t.eq(read("facts.md"), factsBefore, "undo restores facts.md")
        } catch {
            t.check(false, "undo propagation: \(error)")
        }
    }
    if let id = handEntry?.id {
        do {
            try history.undo(entryId: id)
            t.eq(read("people/javier-ruiz.md"), javier, "undo restores the hand-edited page")
        } catch {
            t.check(false, "undo hand edit: \(error)")
        }
    }

    // 5. A vault without facts.md: the first fact creates it (header + line), and undo removes it again.
    try? fm.removeItem(at: vault.url(for: "facts.md"))
    let line = Corrections.factLine("Javier Ruiz no forma parte de Kickoff.", date: date, fallbackLinks: ["javier-ruiz"]) ?? ""
    let created = try? vault.applyCorrections([], facts: ["Javier Ruiz no forma parte de Kickoff."], title: "Hecho confirmado",
                                              projectSlug: "kickoff", fallbackLinks: ["javier-ruiz"], history: history,
                                              language: "en", date: date)
    t.eq(created?.entry?.changes.first?.change, .added, "facts.md created")
    t.check(read("facts.md").contains("# Facts you confirmed") && read("facts.md").hasSuffix(line + "\n"), "new facts.md has header + line")
    if let id = created?.entry?.id {
        try? history.undo(entryId: id)
        t.check(!fm.fileExists(atPath: vault.url(for: "facts.md").path), "undo removes the created facts.md")
    }
}

/// What must never silently lose the owner's or Claude's text: whole-line matching of proposed edits, a page changed
/// on disk while the editor was open, a page that isn't UTF-8, a multi-file write that fails half-way, and a
/// `project.json` with a partial `people`.
@MainActor func testFactsSafety(_ t: Tester, root: URL) {
    let fm = FileManager.default
    let vaultURL = root.appendingPathComponent("vault")
    let vault = VaultStore(root: vaultURL)
    let history = HistoryStore(vaultRoot: vaultURL, historyDir: root.appendingPathComponent("history"))
    try? fm.createDirectory(at: vaultURL.appendingPathComponent("people"), withIntermediateDirectories: true)
    func write(_ path: String, _ text: String) {
        try? fm.createDirectory(at: vault.url(for: path).deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: vault.url(for: path), atomically: true, encoding: .utf8)
    }
    func read(_ path: String) -> String { (try? vault.read(path)) ?? "<missing>" }

    // 1. `before` is whole lines: "- Ana" never matches inside "- Ana María (CFO)".
    let team = "# Equipo\n- Ana María (CFO)\n- Ana\n- Luis\n"
    let edit = ProposedEdit(path: "x.md", before: "- Ana", after: "- Ana (ya no está en el equipo)")
    t.eq(Corrections.applying(edit, to: team), "# Equipo\n- Ana María (CFO)\n- Ana (ya no está en el equipo)\n- Luis\n",
         "edit applied to the whole line, not inside a longer one")
    t.check(Corrections.applying(ProposedEdit(path: "x.md", before: "Ana María", after: "x"), to: team) == nil,
            "an excerpt from the middle of a line is not applied")
    t.eq(Corrections.applying(ProposedEdit(path: "x.md", before: "- Luis\n", after: "- Luis Pérez\n"), to: team),
         "# Equipo\n- Ana María (CFO)\n- Ana\n- Luis Pérez\n", "a before ending in a newline still matches")
    t.eq(Corrections.applying(ProposedEdit(path: "x.md", before: "- Ana", after: "- Ana B"), to: "- Ana  \r\n- Ana María\r\n"),
         "- Ana B\n- Ana María\r\n", "trailing spaces / CRLF fall back to the line-by-line match")
    t.check(Corrections.applying(ProposedEdit(path: "x.md", before: "- Ana", after: "x"), to: "- Ana María\n") == nil,
            "only a longer line → nothing to apply")

    // 2. A page changed on disk while the editor was open is refused, nothing written.
    let original = "---\ntype: person\ntitle: \"Ana\"\n---\n\n# Ana\n\n- Rol: CFO\n"
    write("people/ana.md", original)
    let byIngest = original + "- Nuevo: viene del ingest\n"
    write("people/ana.md", byIngest)
    do {
        _ = try vault.saveHandEdit(path: "people/ana.md", text: original.replacingOccurrences(of: "CFO", with: "CEO"),
                                   title: "x", history: history, basedOn: original)
        t.check(false, "a stale editor save is refused")
    } catch CorrectionError.changedOnDisk(let current) {
        t.eq(current, byIngest, "the conflict carries the page as it is now")
    } catch {
        t.check(false, "stale save: unexpected \(error)")
    }
    t.eq(read("people/ana.md"), byIngest, "the ingest's additions are kept")
    let ok = try? vault.saveHandEdit(path: "people/ana.md", text: byIngest + "- Mano\n", title: "x", history: history, basedOn: byIngest)
    t.check(ok != nil, "a save based on the current page goes through")

    // 3. A page that isn't UTF-8 is never replaced.
    let latin1 = Data([0x72, 0x65, 0x75, 0x6E, 0x69, 0xF3, 0x6E, 0x0A])   // "reunión" in Latin-1
    let latinURL = vault.url(for: "people/latin.md")
    try? latin1.write(to: latinURL)
    do {
        _ = try vault.saveHandEdit(path: "people/latin.md", text: "nuevo", title: "x", history: history)
        t.check(false, "a non-UTF-8 page is refused")
    } catch CorrectionError.notText {
        t.check(true, "non-UTF-8 page refused")
    } catch {
        t.check(false, "non-UTF-8: unexpected \(error)")
    }
    t.eq(try? Data(contentsOf: latinURL), latin1, "non-UTF-8 page untouched")

    // 4. A multi-file write that fails half-way leaves nothing changed and no Historial entry.
    write("people/b.md", "B\n")
    write("blocker.md", "a file, not a folder\n")
    let entriesBefore = history.entries().count
    do {
        _ = try history.recordManualEdits(title: "x", projectSlug: nil,
                                          files: [("people/ana.md", read("people/ana.md"), "cambiado\n"),
                                                  ("people/b.md", "B\n", "B2\n"),
                                                  ("blocker.md/dentro.md", nil, "no se puede\n")])
        t.check(false, "a write under a file fails")
    } catch {
        t.check(true, "failed write throws")
    }
    t.eq(read("people/b.md"), "B\n", "earlier file rolled back")
    t.check(read("people/ana.md") != "cambiado\n", "first file rolled back")
    t.eq(history.entries().count, entriesBefore, "no Historial entry for a failed write")
    let leftovers = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent("history").path)) ?? [])
        .filter { !fm.fileExists(atPath: root.appendingPathComponent("history/\($0)/entry.json").path) && !$0.hasPrefix(".") }
    t.eq(leftovers, [], "no partial history folder left")

    // 5. project.json with only one of include/exclude keeps the project.
    let projectDir = vaultURL.appendingPathComponent("projects/kickoff")
    try? fm.createDirectory(at: projectDir, withIntermediateDirectories: true)
    let json = #"{"slug":"kickoff","name":"Kickoff","description":"","emoji":"🚀","createdAt":"2026-10-27T10:00:00Z","people":{"include":["ana"]}}"#
    try? Data(json.utf8).write(to: projectDir.appendingPathComponent("project.json"))
    let pm = ProjectManager(vaultRoot: vaultURL)
    t.eq(pm.get("kickoff")?.people?.include, ["ana"], "people with only include decodes")
    t.eq(pm.get("kickoff")?.people?.exclude, [], "missing exclude = []")
    let bad = #"{"slug":"kickoff","name":"Kickoff","description":"","emoji":"🚀","createdAt":"2026-10-27T10:00:00Z","people":"ana"}"#
    try? Data(bad.utf8).write(to: projectDir.appendingPathComponent("project.json"))
    t.check(pm.get("kickoff") != nil && pm.get("kickoff")?.people == nil, "a malformed people field never hides the project")
}
