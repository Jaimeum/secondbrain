import ArgumentParser
import BrainCore
import Foundation

// MARK: v0.6 entity (CONTRACT §16.4, §16.13)

/// `sb entity show <path> [--project slug] [--dir vault]` · `sb entity selftest [--dir tmp]`.
struct EntityCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "entity", abstract: "Fichas: what the brain knows about a page.",
                                                    subcommands: [Show.self, EntitySelfTestCmd.self])

    struct Show: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print a page's ficha sections.")
        @Argument(help: "Vault-relative path (e.g. people/ana-garcia.md)") var path: String
        @Option(help: "Filter to this project") var project: String?
        @Option(help: "Vault folder (default: the configured vault)") var dir: String?

        func run() async throws {
            let root = dir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? AppConfig.load().vaultURL
            let snap = EntityIndex(vaultRoot: root).refresh()
            guard let e = snap.entity(path) else { throw CLIError("No page \(path) in the index (\(snap.entities.count) pages)") }
            print("\(e.kind.rawValue) «\(e.title)» project=\(e.projectSlug ?? "-") projects=\(snap.projects(of: path))")
            print("outgoing \(e.outgoing.count) · backlinks \(snap.backlinks[path]?.count ?? 0)")
            for section in snap.sections(for: path, projectSlug: project) {
                print("## \(section.kind.rawValue) (\(section.rows.count))")
                for row in section.rows { print("  - \(row.title)" + (row.date.map { " · \(SBDate.iso($0))" } ?? "")) }
            }
        }
    }
}

struct EntitySelfTestCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "selftest", abstract: "Offline self-test of the entity index.")
    @Option(help: "Scratch folder (created/emptied)") var dir: String?

    @MainActor func run() async throws {
        let t = Tester(filter: nil)
        let root = URL(fileURLWithPath: ((dir ?? NSTemporaryDirectory() + "sb-entity-selftest") as NSString).expandingTildeInPath)
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await t.groupAsync("entity") { await testEntityIndex(t, root: root) }
        print("\n\(t.passed) passed, \(t.failures.count) failed")
        for f in t.failures { print("  ✗ \(f)") }
        if !t.failures.isEmpty { throw ExitCode(1) }
    }
}

/// The index over the demo vault: kinds by folder, titles, backlinks, the ficha's sections (global and filtered to a
/// project), tasks that name a person, `orgs/` and `facts.md`, project people with include/exclude in `project.json`,
/// and the incremental refresh (unchanged → same snapshot; a new page → new backlink; a deleted page → gone).
@MainActor func testEntityIndex(_ t: Tester, root: URL) async {
    let vault = root.appendingPathComponent("vault")
    do { _ = try DemoVault.create(at: vault, scale: 0) } catch {
        t.check(false, "demo vault: \(error)")
        return
    }
    let fm = FileManager.default
    func write(_ rel: String, _ text: String) {
        let url = vault.appendingPathComponent(rel)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
    write("orgs/banco-nubia.md", "---\ntype: org\ntitle: \"Banco Nubia\"\n---\n\n# Banco Nubia\n\nBanco socio de [[alianza-banco-nubia/wiki/overview|la alianza]].\n")
    write("facts.md", "# Hechos confirmados por ti\n\n- 2026-10-27 · Andrés Silva es el CTO de Banco Nubia. ([[andres-silva]], [[banco-nubia]])\n")

    let index = EntityIndex(vaultRoot: vault)
    let snap = index.refresh()
    let atlas = "lanzamiento-atlas", nubia = "alianza-banco-nubia"
    let andres = "people/andres-silva.md"

    // --- Kinds, titles, exclusions.
    t.eq(snap.entity(andres)?.kind, .person, "people/ → person")
    t.eq(snap.entity(andres)?.title, "Andrés Silva", "person title from the page")
    t.eq(snap.entity(andres)?.role, "CTO", "role from front matter")
    t.eq(snap.entity(andres)?.org, "Banco Nubia", "organization from front matter")
    t.eq(EntityIndex.plainName("[[banco-nubia]]"), "Banco Nubia", "org: [[slug]] alone shows a name, not the link")
    t.eq(EntityIndex.plainName("[[acme|Acme S.A.]]"), "Acme S.A.", "org: [[slug|label]] shows its label")
    t.eq(EntityIndex.plainName("Acme"), "Acme", "a plain org name as is")
    t.eq(snap.entity(andres)?.id, "people/andres-silva", "id = path without .md")
    t.eq(snap.entity("orgs/banco-nubia.md")?.kind, .org, "orgs/ → org")
    t.eq(snap.entity("facts.md")?.kind, .facts, "facts.md → facts")
    t.eq(snap.entity("projects/\(atlas)/wiki/overview.md")?.kind, .project, "overview → project")
    t.eq(snap.entity("projects/\(atlas)/wiki/tasks.md")?.isNavigation, true, "tasks.md is navigation")
    t.check(snap.entity("people/README.md") == nil, "people/README.md is not an entity")
    t.check(snap.entity("CLAUDE.md") == nil, "CLAUDE.md is not an entity")
    t.check(!snap.entities.keys.contains { $0.contains("/raw/") }, "no raw/ in the index")
    t.check(!snap.entities.keys.contains { $0.hasPrefix("templates/") || $0.hasPrefix("_inbox/") }, "no templates/ or _inbox/")
    let meetings = snap.entities.values.filter { $0.kind == .meeting }
    t.check(!meetings.isEmpty, "meetings indexed")
    t.check(meetings.allSatisfy { $0.eventDate != nil }, "every meeting has an event date")
    t.check(snap.entities.values.contains { $0.kind == .decision }, "decisions indexed")
    t.check(snap.entities.values.contains { $0.kind == .email }, "email threads indexed")

    // --- Backlinks and links.
    let back = snap.backlinks[andres] ?? []
    t.check(back.contains { $0.contains("/wiki/meetings/") }, "a meeting links to Andrés (backlink)")
    t.check(back.contains("facts.md"), "facts.md links to Andrés")
    t.check(!back.contains { $0.hasSuffix("/wiki/tasks.md") || $0.hasSuffix("/wiki/index.md") }, "navigation pages are not backlinks")
    t.check(snap.entity(andres)?.outgoing.contains("projects/\(nubia)/wiki/overview.md") == true, "person links to the project overview")
    t.eq(snap.orgPath("Banco Nubia"), "orgs/banco-nubia.md", "plain org name resolves to orgs/")
    t.check(snap.entity(andres)?.frontLinks.contains("orgs/banco-nubia.md") == true, "plain `organization:` links the org page")
    t.check((snap.backlinks["orgs/banco-nubia.md"] ?? []).contains(andres), "org gets the person as backlink")

    // --- Sections (global).
    let sections = snap.sections(for: andres)
    func rows(_ kind: EntitySectionKind, _ s: [EntitySection]) -> [EntityRow] { s.first { $0.kind == kind }?.rows ?? [] }
    t.check(rows(.projects, sections).contains { $0.target == .project(nubia) }, "Proyectos lists the alliance")
    let meetingRows = rows(.meetings, sections)
    t.check(meetingRows.count >= 2, "Reuniones has Andrés's meetings (\(meetingRows.count))")
    let dates = meetingRows.compactMap(\.date)
    t.eq(dates, dates.sorted(by: >), "Reuniones newest first")
    t.check(!rows(.emails, sections).isEmpty, "Correos has his thread")
    t.check(rows(.related, sections).contains { $0.target == .page("orgs/banco-nubia.md") }, "Relacionados has the org")
    t.check(rows(.related, sections).contains { $0.target == .page("facts.md") }, "Relacionados has facts.md")
    t.check(!rows(.tasks, sections).isEmpty, "Pendientes has the task he owns")
    t.check(sections.map(\.kind) == EntitySectionKind.allCases.filter { k in sections.contains { $0.kind == k } },
            "sections in the contract's order")
    t.check(!sections.contains { $0.rows.isEmpty }, "no empty section")

    // --- Filtered to a project: only that project's pages; no Proyectos section.
    let ana = "people/carlos-vega.md"
    let anaProjects = snap.projects(of: ana)
    t.check(anaProjects.count >= 2, "Carlos is in several projects (\(anaProjects))")
    if let first = anaProjects.first {
        let filtered = snap.sections(for: ana, projectSlug: first)
        t.check(!filtered.contains { $0.kind == .projects }, "filtered: no Proyectos")
        let pageRows = filtered.flatMap(\.rows).filter { if case .page = $0.target { return true }; return false }
        t.check(pageRows.allSatisfy { $0.projectSlug == first || $0.projectSlug == nil }, "filtered: only pages of \(first)")
        t.check(rows(.tasks, filtered).allSatisfy { $0.projectSlug == first }, "filtered: only tasks of \(first)")
        let all = snap.sections(for: ana).flatMap(\.rows).count
        t.check(filtered.flatMap(\.rows).count < all, "filtered has fewer rows than global")
    }

    // --- Project people + include/exclude in project.json.
    let peopleNubia = snap.people(ofProject: nubia)
    t.check(peopleNubia.contains { $0.path == andres }, "Andrés is in the alliance's Personas")
    t.check(!peopleNubia.contains { $0.path == "people/jaime-ruiz.md" }, "the owner is not listed")
    t.check(peopleNubia.first { $0.path == andres }?.sources ?? 0 > 0, "Andrés has sources in the project")
    t.check(peopleNubia.first { $0.path == andres }?.lastContact != nil, "Andrés has a last contact")
    let pm = ProjectManager(vaultRoot: vault)
    let outsider = snap.allPeople.first { !snap.projects(of: $0.path).contains(atlas) && !$0.isOwner && $0.path != andres }
    t.check(outsider != nil, "someone is not in Atlas")
    if let outsider {
        _ = try? pm.setPerson(outsider.baseName, included: true, in: atlas)
        t.eq(pm.get(atlas)?.people?.include, [outsider.baseName], "include persisted in project.json")
        let s2 = index.refresh()
        t.check(s2.people(ofProject: atlas).contains { $0.path == outsider.path && $0.manual }, "added person shows (manual)")
        _ = try? pm.setPerson(outsider.baseName, included: false, in: atlas)
        t.eq(pm.get(atlas)?.people?.exclude, [outsider.baseName], "exclude persisted; include cleared")
        t.eq(pm.get(atlas)?.people?.include ?? [], [], "include no longer has them")
        let s3 = index.refresh()
        t.check(!s3.people(ofProject: atlas).contains { $0.path == outsider.path }, "removed person is gone")
    }
    _ = try? pm.setPerson("andres-silva", included: false, in: nubia)
    t.check(!index.refresh().people(ofProject: nubia).contains { $0.path == andres }, "exclude beats links")
    _ = try? pm.setPerson("andres-silva", included: true, in: nubia)
    t.check(index.refresh().people(ofProject: nubia).contains { $0.path == andres }, "include again restores")
    let decoded = pm.get(nubia)
    t.check(decoded != nil, "project.json with people still decodes")

    // --- Incremental refresh.
    let before = index.refresh()
    let again = index.refresh()
    t.eq(again.revision, before.revision, "nothing changed → same snapshot")
    write("projects/\(atlas)/wiki/topics/nuevo-tema.md", "---\ntype: topic\n---\n\n# Nuevo tema\n\nHablado con [[andres-silva|Andrés]].\n")
    let after = index.refresh()
    t.check(after.revision > before.revision, "a new page → new snapshot")
    t.eq(after.entity("projects/\(atlas)/wiki/topics/nuevo-tema.md")?.kind, .topic, "new topic indexed")
    t.check((after.backlinks[andres] ?? []).contains("projects/\(atlas)/wiki/topics/nuevo-tema.md"), "new backlink")
    t.check(after.projects(of: andres).contains(atlas), "the new link ties Andrés to Atlas")
    try? fm.removeItem(at: vault.appendingPathComponent("projects/\(atlas)/wiki/topics/nuevo-tema.md"))
    let removed = index.refresh()
    t.check(removed.entity("projects/\(atlas)/wiki/topics/nuevo-tema.md") == nil, "deleted page leaves the index")
    t.check(!(removed.backlinks[andres] ?? []).contains { $0.hasSuffix("nuevo-tema.md") }, "its backlink is gone")
}
