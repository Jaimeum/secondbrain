import ArgumentParser
import BrainCore
import Foundation

/// `sb search …` (CONTRACT §16.7): the ⌘K full-text index from the terminal.
struct SearchCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search", abstract: "Full-text search over the wiki (what ⌘K finds by text).",
        subcommands: [Query.self, SearchSelfTestCmd.self], defaultSubcommand: Query.self)

    struct Query: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "query", abstract: "Search the vault's wiki pages.")
        @Argument(help: "Words to find") var words: [String]
        @Option(help: "Rows to print") var limit = 20

        @MainActor func run() async throws {
            let engine = makeEngine()
            let index = FullTextIndex()
            let started = Date()
            index.refresh(root: engine.vault.root)
            let built = Date().timeIntervalSince(started)
            let query = words.joined(separator: " ")
            let hits = index.search(query, limit: limit)
            print("\(index.count) pages indexed in \(Int(built * 1000)) ms · \(hits.count) shown")
            for hit in hits {
                let info = index.page(hit.path)
                print("\(String(format: "%.2f", hit.score))  [\(info?.kind.rawValue ?? "?")] \(info?.title ?? hit.path)  — \(hit.path)")
                if !hit.titleMatch, let parts = index.snippet(path: hit.path, query: query) {
                    print("      " + parts.map { $0.bold ? "**\($0.text)**" : $0.text }.joined())
                }
            }
        }
    }
}

/// `sb search selftest [--dir <tmp>] [--pages 2000]`: folding, tokens, plain text, kinds, the index (AND, prefixes,
/// title over body, snippets), incremental refresh (changed, new, deleted files; raw/ never), and speed on a generated
/// vault.
struct SearchSelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of the ⌘K full-text index.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?
    @Option(help: "Pages of the generated vault for the speed check") var pages = 2000

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-search-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        t.group("search-text") { testSearchText(t) }
        t.group("search-index") { testSearchIndex(t, root: root.appendingPathComponent("vault")) }
        t.group("search-speed") { testSearchSpeed(t, root: root.appendingPathComponent("big"), pages: pages) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

private func write(_ root: URL, _ path: String, _ text: String) {
    let url = root.appendingPathComponent(path)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? text.write(to: url, atomically: true, encoding: .utf8)
}

@MainActor func testSearchText(_ t: Tester) {
    t.eq(FullTextIndex.fold("Reunión con ÁNGELA Ñandú"), "reunion con angela nandu", "fold accents and case")
    t.eq(FullTextIndex.queryWords("  Comité, de la ALIANZA!  comité"), ["comite", "de", "la", "alianza"], "query words folded, unique")
    let tokens = FullTextIndex.tokens("Hola, José-María 2026")
    t.eq(tokens.map(\.term), ["hola", "jose", "maria", "2026"], "tokens")
    t.eq(tokens.map(\.start), [0, 6, 11, 17], "token offsets (scalars)")
    let plain = FullTextIndex.plainText("# Título\n\n- **Javier** habló con [[angela-torres|Ángela]] y [[kickoff]].\n\n| a | b |\n|---|---|\n> cita `code`")
    t.eq(plain, "Título Javier habló con Ángela y kickoff. a b cita code", "plain text without markdown")
    t.eq(FullTextIndex.kind(of: "people/javier.md"), .person, "kind person")
    t.eq(FullTextIndex.kind(of: "orgs/acme.md"), .org, "kind org")
    t.eq(FullTextIndex.kind(of: "questions/q.md"), .question, "kind global question")
    t.eq(FullTextIndex.kind(of: "facts.md"), .note, "kind facts.md")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/overview.md"), .project, "kind project page")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/meetings/m.md"), .meeting, "kind meeting")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/emails/e.md"), .email, "kind email")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/sources/s.md"), .note, "kind source")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/decisions/d.md"), .decision, "kind decision")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/topics/x.md"), .topic, "kind topic")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/repos/r.md"), .repo, "kind repo")
    t.eq(FullTextIndex.kind(of: "projects/k/wiki/questions/q.md"), .question, "kind project question")
    t.check(!FullTextIndex.isIndexed("projects/k/raw/notes/n.md"), "raw/ not indexed")
    t.check(!FullTextIndex.isIndexed("projects/k/wiki/log.md"), "log.md not indexed")
    t.check(!FullTextIndex.isIndexed("projects/k/wiki/tasks.md"), "tasks.md not indexed")
    t.check(!FullTextIndex.isIndexed("CLAUDE.md"), "CLAUDE.md not indexed")
    t.check(FullTextIndex.isIndexed("facts.md"), "facts.md indexed")
    t.eq(FullTextIndex.titleScore("comite de la alianza", query: "comi"), 3, "title prefix")
    t.eq(FullTextIndex.titleScore("el comite", query: "comi"), 2, "title word start")
    t.eq(FullTextIndex.titleScore("subcomite", query: "comi"), 1, "title contains")
    t.eq(FullTextIndex.titleScore("alianza comite", query: "comite alianza"), 1, "title every word")
    t.eq(FullTextIndex.titleScore("alianza", query: "comite"), 0, "title no match")
}

@MainActor func testSearchIndex(_ t: Tester, root: URL) {
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let filler = String(repeating: "Se habló del presupuesto y del calendario general del trimestre. ", count: 3)
    write(root, "people/javier-ruiz.md", "---\ntype: person\n---\n# Javier Ruiz\n\nIngeniero. \(filler)Trabaja con [[angela-torres|Ángela Torres]] en el piloto.")
    write(root, "people/angela-torres.md", "# Ángela Torres\n\nDirectora del equipo de datos.")
    write(root, "orgs/acme.md", "# Acme\n\nCliente del piloto de logística.")
    write(root, "facts.md", "# Hechos confirmados por ti\n\n- 2026-10-27 · Javier Ruiz no forma parte del equipo de Angela Torres.")
    write(root, "log.md", "# Log\n\nJavier piloto")
    write(root, "projects/kickoff/wiki/overview.md", "# Kickoff — En breve\n\nLanzamiento del piloto con Acme.")
    write(root, "projects/kickoff/wiki/tasks.md", "# Pendientes\n\n- [ ] Javier: llamar a Acme")
    write(root, "projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md",
          "---\ntype: meeting\ndate: 2026-10-26\n---\n# Comité de la alianza\n\n\(filler)Acordamos que la migración de facturación empieza en noviembre. \(filler)")
    write(root, "projects/kickoff/wiki/decisions/presupuesto.md", "# Presupuesto aprobado\n\nSe aprueba el piloto.")
    write(root, "projects/kickoff/wiki/topics/migracion.md", "# Migración\n\nPlan de la migración de facturación.")
    write(root, "projects/kickoff/raw/notes/secreto.md", "# Nota cruda\n\nzanahoria migración")

    let index = FullTextIndex()
    let first = index.refresh(root: root)
    t.eq(first.updated, 8, "first refresh reads every wiki page (not raw/, log, tasks)")
    t.eq(index.search("zanahoria").count, 0, "raw/ text is not found")
    t.eq(index.search("llamar").count, 0, "tasks.md is not indexed")
    let again = index.refresh(root: root)
    t.check(again.updated == 0 && again.removed == 0, "second refresh reads nothing: \(again)")

    // Accent- and case-insensitive, both ways.
    t.check(index.search("MIGRACION").contains { $0.path.hasSuffix("comite.md") }, "unaccented query finds accented body")
    t.check(index.search("angela").contains { $0.path == "people/angela-torres.md" }, "angela finds Ángela")
    write(root, "orgs/datos.md", "# Datos\n\nEl área de análisis.")
    index.refresh(root: root)
    t.check(index.search("ánálisis").contains { $0.path == "orgs/datos.md" }, "accented query finds plain/other accents")

    // AND: every word must appear (title or body).
    t.eq(Set(index.search("migracion noviembre").map(\.path)), ["projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md"], "AND of words")
    t.eq(index.search("migracion jirafa").count, 0, "a missing word excludes")
    // Prefix (type-ahead).
    t.check(index.search("factur").count == 2, "prefix finds facturación in two pages")
    t.check(index.search("piloto acm").contains { $0.path == "orgs/acme.md" }, "last word by prefix")

    // Titles weigh more than bodies.
    let mig = index.search("migracion")
    t.eq(mig.first?.path, "projects/kickoff/wiki/topics/migracion.md", "title match ranks first")
    if let title = mig.first, let body = mig.first(where: { $0.path.hasSuffix("comite.md") }) {
        t.check(title.titleMatch && !body.titleMatch && title.score > body.score, "title score > body score")
        t.check(body.score <= FullTextIndex.maxBodyScore && title.score >= FullTextIndex.titleBoost + 1, "score bands")
    } else {
        t.check(false, "migracion finds title and body pages")
    }

    // Snippet: ±60 around the match, cut at words, match in bold.
    if let parts = index.snippet(path: "projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md", query: "migracion") {
        let text = parts.map(\.text).joined()
        t.eq(parts.filter(\.bold).map(\.text), ["migración"], "snippet bolds the match, original accents")
        t.check(text.hasPrefix("…") && text.hasSuffix("…"), "snippet ellipses on both sides: \(text)")
        t.check(text.count <= 2 * FullTextIndex.snippetContext + "migración".count + 2, "snippet ±60: \(text.count)")
        let inner = text.dropFirst().dropLast()
        t.check(!inner.hasPrefix(" ") && inner.first.map { $0.isUppercase || $0.isLowercase } == true, "snippet starts at a word")
    } else {
        t.check(false, "snippet for a body match")
    }
    if let parts = index.snippet(path: "facts.md", query: "javier angela") {
        t.eq(parts.filter(\.bold).map(\.text), ["Javier", "Angela"], "every query word bold")
        t.check(parts.first?.text != "…", "match near the start: no leading ellipsis")
    } else {
        t.check(false, "facts.md snippet")
    }
    t.check(index.snippet(path: "orgs/acme.md", query: "jirafa") == nil, "no snippet without a match")

    // Pages and kinds.
    t.eq(index.page("projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md")?.title, "Comité de la alianza", "title from heading")
    t.eq(index.page("projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md")?.projectSlug, "kickoff", "project slug")
    t.check(index.page("projects/kickoff/wiki/meetings/2026-10-26-0900-comite.md")?.date != nil, "date from front-matter")
    t.eq(index.page("orgs/acme.md")?.kind, .org, "org kind in the index")

    // Incremental: a changed page drops its old words; a new page appears; a deleted one goes.
    Thread.sleep(forTimeInterval: 0.02)
    write(root, "orgs/acme.md", "# Acme\n\nCliente de transporte marítimo.")
    write(root, "questions/quien-es-javier.md", "# ¿Quién es Javier?\n\nIngeniero del piloto.")
    try? FileManager.default.removeItem(at: root.appendingPathComponent("projects/kickoff/wiki/decisions/presupuesto.md"))
    let delta = index.refresh(root: root)
    t.eq(delta.updated, 2, "refresh reads only the changed and the new page")
    t.eq(delta.removed, 1, "refresh drops the deleted page")
    t.check(!index.search("logistica").contains { $0.path == "orgs/acme.md" }, "old words of a changed page are gone")
    t.check(index.search("maritimo").contains { $0.path == "orgs/acme.md" }, "new words of a changed page are found")
    t.check(index.search("quien").contains { $0.path == "questions/quien-es-javier.md" }, "new page found")
    t.eq(index.search("presupuesto aprobado").count, 0, "deleted page not found")
    t.check(index.page("projects/kickoff/wiki/decisions/presupuesto.md") == nil, "deleted page gone from pages()")
    index.reset()
    t.eq(index.count, 0, "reset empties")
}

/// A generated vault of `pages` pages (~2 KB each): first build, a one-file refresh and typical queries are timed.
@MainActor func testSearchSpeed(_ t: Tester, root: URL, pages: Int) {
    let words = ["reunión", "presupuesto", "migración", "facturación", "cliente", "logística", "calendario", "piloto",
                 "contrato", "equipo", "datos", "análisis", "riesgo", "entrega", "diseño", "acuerdo", "proveedor",
                 "lanzamiento", "revisión", "seguimiento", "propuesta", "costos", "integración", "servidor", "móvil"]
    let names = ["Javier", "Ángela", "Lucía", "Martín", "Sofía", "Diego", "Valentina", "Tomás", "Camila", "Andrés"]
    var rng = SystemRandomNumberGenerator()
    let folders = ["meetings", "emails", "sources", "topics", "decisions"]
    for i in 0..<pages {
        var body = ""
        for s in 0..<30 {
            let sentence = (0..<10).map { _ in words.randomElement(using: &rng)! }.joined(separator: " ")
            body += "\(names[(i + s) % names.count]) habló de \(sentence) código\(i)x\(s). "
            if s % 6 == 5 { body += "\n\n" }
        }
        let path: String
        switch i % 10 {
        case 0: path = "people/persona-\(i).md"
        case 1: path = "orgs/empresa-\(i).md"
        default: path = "projects/p\(i % 7)/wiki/\(folders[i % folders.count])/2026-10-\(String(format: "%02d", i % 28 + 1))-0900-pagina-\(i).md"
        }
        write(root, path, "---\ntype: page\n---\n# Página \(i) sobre \(words[i % words.count])\n\n\(body)")
    }
    let index = FullTextIndex()
    var started = Date()
    index.refresh(root: root)
    let build = Date().timeIntervalSince(started)
    t.eq(index.count, pages, "generated vault indexed")
    print("    build \(pages) pages: \(Int(build * 1000)) ms")
    t.check(build < 8, "first build of \(pages) pages under 8 s (\(Int(build * 1000)) ms)")

    started = Date()
    let noop = index.refresh(root: root)
    let walk = Date().timeIntervalSince(started)
    print("    refresh, nothing changed: \(Int(walk * 1000)) ms")
    t.check(noop.updated == 0 && walk < 1, "no-change refresh under 1 s (\(Int(walk * 1000)) ms)")

    Thread.sleep(forTimeInterval: 0.02)
    write(root, "people/persona-0.md", "# Persona cero\n\nAhora trabaja en ornitorrinco.")
    started = Date()
    let one = index.refresh(root: root)
    let incremental = Date().timeIntervalSince(started)
    print("    refresh, one page changed: \(Int(incremental * 1000)) ms")
    t.eq(one.updated, 1, "one changed page re-read")
    t.check(incremental < 1, "one-page refresh under 1 s (\(Int(incremental * 1000)) ms)")
    t.eq(index.search("ornitorrinco").map(\.path), ["people/persona-0.md"], "changed page found after refresh")

    // Typed queries (prefixes as one types, common and rare words), each with snippets for 12 rows like the palette.
    let queries = ["m", "mi", "mig", "migra", "migración", "javier pres", "código17x3", "angela cliente riesgo", "zzz", "p", "pro"]
    var worst = 0.0, total = 0.0
    for q in queries {
        started = Date()
        let hits = index.search(q)
        for hit in hits.prefix(12) where !hit.titleMatch { _ = index.snippet(path: hit.path, query: q) }
        let took = Date().timeIntervalSince(started)
        worst = max(worst, took)
        total += took
    }
    print("    queries: avg \(String(format: "%.1f", total / Double(queries.count) * 1000)) ms · worst \(String(format: "%.1f", worst * 1000)) ms")
    t.check(worst < 0.15, "every query under 150 ms on \(pages) pages (worst \(Int(worst * 1000)) ms)")
    t.check(index.search("código17x3").contains { $0.path.hasSuffix("pagina-17.md") }, "rare word found among \(pages) pages")
}
