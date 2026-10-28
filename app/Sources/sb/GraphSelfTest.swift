import BrainCore
import Foundation

/// Knowledge graph checks (CONTRACT §12.2) on the `sb demo-vault` sample: kinds, project hubs, people, no raw/ or
/// navigation pages, edges = resolved wikilinks, cache invalidation, and a stress run with ~1,000 pages.
@MainActor
func testGraph(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    let vaultURL = root.appendingPathComponent("vault")
    do { _ = try DemoVault.create(at: vaultURL, scale: 0) } catch {
        t.check(false, "demo vault: \(error)")
        return
    }
    let vault = VaultStore(root: vaultURL)
    let g = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: nil)
    let byId = Dictionary(uniqueKeysWithValues: g.nodes.map { ($0.id, $0) })

    // Size and kinds.
    t.check(g.nodes.count >= 70 && g.nodes.count <= 80, "global nodes \(g.nodes.count) ∉ 70…80")
    t.check(g.edges.count >= 200, "global edges \(g.edges.count) < 200")
    let kinds = Set(g.nodes.map(\.kind))
    for k in [GraphNodeKind.project, .meeting, .email, .document, .note, .url, .person, .topic, .decision, .question, .page] {
        t.check(kinds.contains(k), "kind \(k.rawValue) missing")
    }
    t.eq(g.nodes.filter { $0.kind == .person }.count, DemoVault.people.count, "people nodes")
    t.check(g.nodes.filter { $0.kind == .person }.allSatisfy { $0.projectSlug == nil && $0.id.hasPrefix("people/") }, "people are global")

    // Project hubs.
    let projects = ProjectManager(vaultRoot: vaultURL).list()
    t.eq(projects.count, 3, "projects")
    for p in projects {
        guard let hub = byId["project:\(p.slug)"] else { t.check(false, "hub of \(p.slug) missing"); continue }
        t.eq(hub.kind, .project, "hub kind")
        t.eq(hub.title, "\(p.emoji) \(p.name)", "hub title")
        t.eq(hub.projectSlug, p.slug, "hub project")
        let overview = "projects/\(p.slug)/wiki/overview.md"
        t.check(g.edges.contains { Set([$0.source, $0.target]) == Set([hub.id, overview]) }, "hub \(p.slug) ↔ overview")
        t.check(g.edges.contains { Set([$0.source, $0.target]) == Set([hub.id, "index.md"]) }, "global index → hub \(p.slug)")
    }

    // Never raw files, logs, lint reports or a project's index (navigation).
    for n in g.nodes {
        let name = (n.id as NSString).lastPathComponent
        t.check(!n.id.contains("/raw/"), "raw page in graph: \(n.id)")
        t.check(name != "log.md" && name != "health.md", "navigation page in graph: \(n.id)")
        t.check(!(n.id.hasPrefix("projects/") && name == "index.md"), "project index in graph: \(n.id)")
        t.check(!n.id.hasPrefix("people/README"), "people README in graph")
    }
    t.check(byId["index.md"] != nil, "global index.md is a node")

    // Kinds by folder / frontmatter.
    let atlas = "projects/lanzamiento-atlas/wiki"
    t.eq(byId["\(atlas)/topics/plan-de-lanzamiento.md"]?.kind, .topic, "topic kind")
    t.eq(byId["\(atlas)/emails/contrato-con-acme.md"]?.kind, .email, "email-thread kind")
    t.eq(byId["\(atlas)/tasks.md"]?.kind, .page, "tasks.md kind")
    t.eq(byId["\(atlas)/questions/quien-aprueba-presupuesto-marketing.md"]?.kind, .question, "question kind")
    t.check(g.nodes.contains { $0.kind == .url && $0.id.contains("/sources/") }, "source_type url → url")
    t.check(g.nodes.contains { $0.kind == .note && $0.id.contains("/sources/") }, "source_type note → note")

    // Dates from frontmatter (meetings all dated, within the last ~3 months; topics undated).
    let meetings = g.nodes.filter { $0.kind == .meeting }
    t.check(meetings.count >= 15, "meetings \(meetings.count)")
    t.check(meetings.allSatisfy { $0.date != nil }, "every meeting has a date")
    let dates = meetings.compactMap(\.date)
    if let first = dates.min(), let last = dates.max() {
        t.check(last.timeIntervalSince(first) > 70 * 86_400, "dates span ≥ 70 days")
        t.check(last <= Date() && first > Date().addingTimeInterval(-100 * 86_400), "dates within the last 100 days")
    }
    t.check(g.nodes.filter { $0.kind == .topic }.allSatisfy { $0.date == nil }, "topics have no date")

    // Edges: valid, undirected, deduped, no self loops; `links` = degree.
    var pairs = Set<Set<String>>()
    var degree: [String: Int] = [:]
    for e in g.edges {
        t.check(byId[e.source] != nil && byId[e.target] != nil, "edge to unknown node \(e.source) → \(e.target)")
        t.check(e.source != e.target, "self loop \(e.source)")
        t.check(e.weight >= 1, "edge weight")
        t.check(pairs.insert([e.source, e.target]).inserted, "duplicate edge \(e.source) ↔ \(e.target)")
        degree[e.source, default: 0] += 1
        degree[e.target, default: 0] += 1
    }
    t.check(g.nodes.allSatisfy { $0.links == degree[$0.id, default: 0] }, "links == degree")

    // Edges are the wikilinks VaultStore.resolveWikilinks resolves (raw targets excluded).
    let kickoff = g.nodes.first { $0.kind == .meeting && $0.id.contains("kickoff") }!.id
    let text = (try? vault.read(kickoff)) ?? ""
    let linkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\|#\n]+)"#)
    let ns = text as NSString
    let targets = linkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        .map { ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces) }
    let resolved = vault.resolveWikilinks(targets, from: kickoff).values.filter { !$0.contains("/raw/") }
    t.check(!resolved.isEmpty, "kickoff has links")
    for path in resolved where byId[path] != nil {
        t.check(pairs.contains([kickoff, path]), "kickoff ↔ \(path) missing")
    }
    t.check(!resolved.contains { $0.contains("/raw/") }, "kickoff raw link filtered")

    // Cross-project link and people between projects.
    t.check(pairs.contains(["projects/alianza-banco-nubia/wiki/topics/integracion-de-pagos.md", "\(atlas)/topics/app-movil-atlas.md"]),
            "cross-project edge integración de pagos ↔ app móvil")
    let carlos = byId["people/carlos-vega.md"]
    t.check((carlos?.links ?? 0) >= 8, "Carlos connects projects (\(carlos?.links ?? 0))")

    // One project: its pages + hub + its people, nothing else.
    let p = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas")
    let pIds = Set(p.nodes.map(\.id))
    t.check(p.nodes.allSatisfy { $0.kind == .person || $0.kind == .org || $0.projectSlug == "lanzamiento-atlas" }, "project graph has only its pages")
    t.check(pIds.contains("project:lanzamiento-atlas"), "project graph has its hub")
    t.check(!pIds.contains("project:migracion-a-la-nube"), "project graph has no other hub")
    t.check(pIds.contains("people/ana-garcia.md"), "Ana in Atlas")
    t.check(!pIds.contains("people/marta-rios.md"), "Marta not in Atlas")
    t.check(!pIds.contains("index.md"), "no global index in a project")
    t.check(p.edges.allSatisfy { pIds.contains($0.source) && pIds.contains($0.target) }, "project edges stay inside")
    t.check(p.nodes.count >= 25 && p.nodes.count < g.nodes.count, "project nodes \(p.nodes.count)")

    // A link to a raw email message counts as a link to its thread page.
    let thread = "\(atlas)/emails/contrato-con-acme.md"
    let rawDir = vaultURL.appendingPathComponent("projects/lanzamiento-atlas/raw/emails/contrato-con-acme")
    let message = ((try? fm.contentsOfDirectory(atPath: rawDir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted().first
    t.check(message != nil, "raw email message exists")
    if let message {
        let note = "\(atlas)/sources/2026-01-01-nota-de-prueba.md"
        let body = "---\ntype: source\nsource_type: note\ntitle: \"Nota de prueba\"\n---\n\n# Nota de prueba\n\nVer [[\((message as NSString).deletingPathExtension)]].\n"
        try? body.write(to: vaultURL.appendingPathComponent(note), atomically: true, encoding: .utf8)
        // Cache: the new page changes the vault signature, so the cached graph is rebuilt.
        let before = KnowledgeGraphBuilder.cachedGraph(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas")
        t.check(before.nodes.contains { $0.id == note }, "cache sees the new page")
        let p2 = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas")
        t.check(p2.edges.contains { Set([$0.source, $0.target]) == Set([note, thread]) }, "raw message link → thread page")
        try? fm.removeItem(at: vaultURL.appendingPathComponent(note))
        let after = KnowledgeGraphBuilder.cachedGraph(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas")
        t.check(!after.nodes.contains { $0.id == note }, "cache drops a deleted page")
    }
    let s1 = KnowledgeGraphBuilder.vaultSignature(vaultURL)
    t.eq(KnowledgeGraphBuilder.vaultSignature(vaultURL), s1, "signature is stable")

    // v0.6 (§16.4, §16.5): companies in orgs/ are global nodes; a project's graph holds the people and companies
    // linked to it (Ana's `organization: "Acme"` → orgs/acme.md), and project.json `people` include/exclude decides.
    let acme = "orgs/acme.md", nubia = "orgs/banco-nubia.md"
    try? fm.createDirectory(at: vaultURL.appendingPathComponent("orgs"), withIntermediateDirectories: true)
    try? "---\ntype: org\ntitle: \"Acme\"\n---\n\n# Acme\n\nCliente de Atlas.\n"
        .write(to: vaultURL.appendingPathComponent(acme), atomically: true, encoding: .utf8)
    try? "---\ntype: org\ntitle: \"Banco Nubia\"\nprojects: [\"alianza-banco-nubia\"]\n---\n\n# Banco Nubia\n"
        .write(to: vaultURL.appendingPathComponent(nubia), atomically: true, encoding: .utf8)
    try? "# Empresas\n".write(to: vaultURL.appendingPathComponent("orgs/README.md"), atomically: true, encoding: .utf8)
    let question = "questions/quien-es-acme.md"
    try? fm.createDirectory(at: vaultURL.appendingPathComponent("questions"), withIntermediateDirectories: true)
    try? "---\ntype: question\ntitle: \"¿Quién es Acme?\"\n---\n\n# ¿Quién es Acme?\n\nEl cliente de [[ana-garcia]].\n"
        .write(to: vaultURL.appendingPathComponent(question), atomically: true, encoding: .utf8)
    let og = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: nil)
    let orgNodes = og.nodes.filter { $0.kind == .org }
    // The demo vault brings its own orgs/ (acme, banco-nubia, dive); the README is never a node.
    t.eq(Set(orgNodes.map(\.id)), [acme, nubia, "orgs/dive.md"], "org nodes (no README)")
    t.check(orgNodes.allSatisfy { $0.projectSlug == nil }, "orgs are global")
    t.check(og.edges.contains { Set([$0.source, $0.target]) == Set(["people/ana-garcia.md", acme]) }, "Ana ↔ Acme (organization:)")
    let atlasGraph = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas")
    let atlasIds = Set(atlasGraph.nodes.map(\.id))
    t.check(atlasIds.contains(acme), "Acme in Atlas (through Ana)")
    t.check(!atlasIds.contains(nubia), "Banco Nubia not in Atlas")
    t.check(atlasGraph.nodes.allSatisfy { $0.kind == .person || $0.kind == .org || $0.projectSlug == "lanzamiento-atlas" },
            "project graph: its pages + linked people/orgs")
    let nubiaGraph = KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: "alianza-banco-nubia")
    t.check(nubiaGraph.nodes.contains { $0.id == nubia }, "Banco Nubia in its project (projects:)")
    t.check(!atlasIds.contains { $0.hasPrefix("questions/") }, "global questions stay out of a project")
    // project.json people: include adds a person, exclude removes one.
    let pjURL = vaultURL.appendingPathComponent("projects/lanzamiento-atlas/project.json")
    if let original = try? Data(contentsOf: pjURL),
       var json = (try? JSONSerialization.jsonObject(with: original)) as? [String: Any] {
        json["people"] = ["include": ["marta-rios"], "exclude": ["ana-garcia"]]
        try? JSONSerialization.data(withJSONObject: json).write(to: pjURL)
        let edited = Set(KnowledgeGraphBuilder.build(vaultRoot: vaultURL, projectSlug: "lanzamiento-atlas").nodes.map(\.id))
        t.check(edited.contains("people/marta-rios.md"), "project.json include adds Marta")
        t.check(!edited.contains("people/ana-garcia.md"), "project.json exclude removes Ana")
        t.check(!edited.contains(acme), "Acme leaves Atlas with Ana")
        try? original.write(to: pjURL)
    } else {
        t.check(false, "project.json readable")
    }
    t.eq(og.nodes.first { $0.id == question }?.kind, .question, "global question in the brain graph")
    try? fm.removeItem(at: vaultURL.appendingPathComponent("orgs"))
    try? fm.removeItem(at: vaultURL.appendingPathComponent(question))

    // Stress: ~1,000 pages build in reasonable time (debug build).
    let big = root.appendingPathComponent("big")
    do {
        _ = try DemoVault.create(at: big, scale: 250)
        let start = Date()
        let bg = KnowledgeGraphBuilder.build(vaultRoot: big, projectSlug: nil)
        let elapsed = Date().timeIntervalSince(start)
        print("  graph stress: \(bg.nodes.count) nodes, \(bg.edges.count) edges in \(String(format: "%.2f", elapsed)) s")
        t.check(bg.nodes.count > 900, "stress nodes \(bg.nodes.count)")
        t.check(elapsed < 15, "stress build took \(elapsed) s")
    } catch {
        t.check(false, "stress vault: \(error)")
    }
}
