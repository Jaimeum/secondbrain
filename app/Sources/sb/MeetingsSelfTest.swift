import BrainCore
import Foundation

/// v0.3 Reuniones checks (CONTRACT §12.5, §12.7): event phases and their boundaries, dedupe across accounts,
/// MeetingLinks persistence, the project suggestion, prep local data on a temp vault, the prep prompt, and the
/// recording ↔ event link (source + transcript frontmatter). No Claude, no audio, no calendar permission.
@MainActor func testMeetings(_ t: Tester, root: URL) async {
    let fm = FileManager.default
    try? fm.removeItem(at: root)
    try? fm.createDirectory(at: root, withIntermediateDirectories: true)
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a fixed instant: every check is time-zone independent
    func ev(_ id: String, _ title: String, start: Date, minutes: Double = 60, account: String = "microsoft:a@x.com",
            series: String? = nil, attendees: [EmailAddress] = [], join: URL? = nil, notes: String? = nil,
            allDay: Bool = false) -> CalendarEvent {
        CalendarEvent(id: id, accountId: account, seriesId: series, title: title, start: start,
                      end: start.addingTimeInterval(minutes * 60), isAllDay: allDay, joinURL: join, attendees: attendees, notes: notes)
    }

    // --- Phases: Prepararme → Grabar (start−2 min … end+5 min) → Aprendiendo… → Ver resumen ✓.
    let e = ev("e1", "Kickoff", start: t0)
    func phase(_ at: Date, recording: String? = nil, source: SourceRecord? = nil) -> MeetingPhase {
        MeetingAgenda.phase(of: e, now: at, recordingEventId: recording, source: source)
    }
    t.eq(phase(t0.addingTimeInterval(-121)), .upcoming, "phase 2:01 before start")
    t.eq(phase(t0.addingTimeInterval(-120)), .recordable, "phase exactly 2 min before start")
    t.eq(phase(t0.addingTimeInterval(30 * 60)), .recordable, "phase during")
    t.eq(phase(e.end.addingTimeInterval(300)), .recordable, "phase exactly end + 5 min")
    t.eq(phase(e.end.addingTimeInterval(301)), .over, "phase after end + 5 min")
    t.eq(phase(t0.addingTimeInterval(-3600), recording: "e1"), .recording, "recording this event wins")
    t.eq(phase(t0, recording: "other"), .recordable, "recording another event")
    var src = SourceRecord(id: "s1", kind: .meeting, title: "Kickoff", projectSlug: nil, status: .transcribing)
    src.calendarEventId = "e1"
    t.eq(phase(e.end.addingTimeInterval(3600), source: src), .learning, "transcribing → learning")
    src.status = .needsProject
    t.eq(phase(e.end.addingTimeInterval(3600), source: src), .learning, "needsProject → learning")
    src.status = .done
    t.eq(phase(e.end.addingTimeInterval(3600), source: src), .done, "done → Ver resumen")
    src.status = .failed
    t.eq(phase(t0, source: src), .failed, "failed → Reintentar")
    let allDay = ev("ad", "Offsite", start: t0, minutes: 24 * 60, allDay: true)
    t.eq(MeetingAgenda.phase(of: allDay, now: t0.addingTimeInterval(3600), recordingEventId: nil, source: nil), .upcoming,
         "all-day event never offers Grabar")
    t.eq(MeetingAgenda.phase(of: allDay, now: allDay.end.addingTimeInterval(1), recordingEventId: nil, source: nil), .over,
         "all-day event over")
    t.check(!MeetingAgenda.isOverrunning(e, now: e.end.addingTimeInterval(299), recordingEventId: "e1"), "no overrun at end + 4:59")
    t.check(MeetingAgenda.isOverrunning(e, now: e.end.addingTimeInterval(300), recordingEventId: "e1"), "overrun at end + 5 min")
    t.check(!MeetingAgenda.isOverrunning(e, now: e.end.addingTimeInterval(900), recordingEventId: nil), "no overrun when not recording")

    // --- Ahora / Siguiente.
    let later = ev("e2", "1:1", start: t0.addingTimeInterval(3 * 3600), minutes: 30)
    let events = [later, e, allDay]
    t.eq(MeetingAgenda.current(in: events, now: t0.addingTimeInterval(600))?.id, "e1", "current = in progress")
    t.eq(MeetingAgenda.next(in: events, now: t0.addingTimeInterval(600))?.id, "e2", "next skips the current and all-day")
    t.check(MeetingAgenda.current(in: events, now: t0.addingTimeInterval(-600)) == nil, "nothing current 10 min before")
    t.eq(MeetingAgenda.current(in: events, now: t0.addingTimeInterval(-60))?.id, "e1", "current from start − 2 min")

    // --- Dedupe across accounts: same title (case/accents/spaces ignored) + same minute.
    let ms = ev("ms-1", "Revisión  semanal", start: t0.addingTimeInterval(20),
                attendees: ["l", "c", "d"].map { EmailAddress(name: $0, email: "\($0)@x.com") })
    let gg = ev("g-1", "revision semanal", start: t0, account: "google:b@y.com",
                join: URL(string: "https://meet.google.com/abc"), notes: "Agenda")
    let other = ev("g-2", "Revisión semanal", start: t0.addingTimeInterval(3600), account: "google:b@y.com")
    let deduped = MeetingAgenda.dedupe([other, ms, gg])
    t.eq(deduped.count, 2, "dedupe keeps one copy per (title, start minute)")
    t.eq(deduped.first?.id, "ms-1", "dedupe keeps the richest copy, sorted by start")
    t.check(deduped.first?.joinURL?.host == "meet.google.com" && deduped.first?.notes == "Agenda", "dedupe borrows join link and notes")
    t.eq(MeetingAgenda.dedupe([ms, ms]).count, 1, "same event twice")

    // --- MeetingLinks: data/meetings.json, remembered per series.
    let linksURL = root.appendingPathComponent("data/meetings.json")
    let weekly1 = ev("w1", "Weekly", start: t0, series: "series-w")
    let weekly2 = ev("w2", "Weekly", start: t0.addingTimeInterval(7 * 86_400), series: "series-w")
    let single = ev("x1", "Single", start: t0)
    do {
        let links = MeetingLinks(fileURL: linksURL)
        t.check(links.choice(for: weekly1) == nil, "no choice yet")
        try links.set(.project("acme"), for: weekly1)
        try links.set(.noProject, for: single)
        let reread = MeetingLinks(fileURL: linksURL)
        t.eq(reread.choice(for: weekly2), .project("acme"), "series choice applies to the next occurrence (after reload)")
        t.eq(reread.choice(for: single), .noProject, "explicit Sin proyecto persists")
        try reread.set(nil, for: single)
        t.check(MeetingLinks(fileURL: linksURL).choice(for: single) == nil, "nil forgets the choice")
        let json = (try? String(contentsOf: linksURL, encoding: .utf8)) ?? ""
        t.check(json.contains("\"series-w\"") && json.contains("\"acme\""), "meetings.json stores the series")
    } catch {
        t.check(false, "MeetingLinks write: \(error)")
    }
    try? "{not json".write(to: linksURL, atomically: true, encoding: .utf8)
    t.check(MeetingLinks(fileURL: linksURL).choice(for: weekly1) == nil, "corrupt meetings.json → no choices, no crash")

    // --- Temp vault: owner, projects, people pages, tasks, meetings, a decision.
    var config = AppConfig.default
    config.vaultPath = root.appendingPathComponent("vault").path
    config.dataPath = root.appendingPathComponent("data").path
    config.uiLanguage = "es"
    let engine = BrainEngine(config: config, transcriber: MeetingsNoTranscriber())
    engine.autoProcess = false
    engine.start()
    let vault = engine.vault
    do {
        try vault.setOwnerName("Ana García")
        try vault.setOwnerEmails(["ana@contoso.com"])
        let redesign = try engine.projects.create(name: "Rediseño app", description: "", emoji: "🚀")
        let acme = try engine.projects.create(name: "Acme Logistics", description: "", emoji: "🚚")
        func write(_ rel: String, _ text: String) throws {
            let url = vault.url(for: rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try write("people/ana-garcia.md", "---\ntype: person\ntitle: \"Ana García\"\naliases: [\"ana@contoso.com\"]\nprojects: [\"\(redesign.slug)\"]\nowner: true\n---\n# Ana\n")
        try write("people/laura-mendez.md", """
            ---
            type: person
            title: "Laura Méndez"
            aliases: ["Laura", "laura.mendez@contoso.com"]
            projects: ["\(redesign.slug)"]
            owner: false
            ---
            # Laura Méndez
            """)
        // Block list + project only via a wikilink in the body.
        try write("people/diego-torres.md", """
            ---
            type: person
            title: "Diego Torres"
            aliases:
              - Diego
              - "diego.torres@contoso.com"
            ---
            # Diego Torres
            ## Proyectos
            - **[[projects/\(redesign.slug)/wiki/overview|Rediseño]]** — soporte
            """)
        try write("people/sofia-herrera.md", "---\ntype: person\ntitle: \"Sofía Herrera\"\naliases: [\"sofia@acme.com\"]\nprojects: [\"[[\(acme.slug)]]\"]\n---\n")

        let people = MeetingPeopleIndex.load(vault: vault)
        t.eq(people.person(for: EmailAddress(name: nil, email: "LAURA.MENDEZ@contoso.com"))?.slug, "laura-mendez", "person by email alias")
        t.eq(people.person(for: EmailAddress(name: "laura méndez", email: nil))?.slug, "laura-mendez", "person by name (accents/case)")
        t.eq(people.person(for: EmailAddress(name: "Diego", email: "d@other.com"))?.slug, "diego-torres", "person by block-list alias")
        t.eq(people.person(for: EmailAddress(name: "Diego Torres", email: nil))?.projects, [redesign.slug], "projects from a body wikilink")
        t.eq(people.person(for: EmailAddress(name: nil, email: "sofia@acme.com"))?.projects, [acme.slug], "projects: wikilink values")
        t.check(people.person(for: EmailAddress(name: "Nadie", email: "nadie@x.com")) == nil, "unknown person")

        // --- Suggestion heuristic.
        let me = EmailAddress(name: "Ana García", email: "ana@contoso.com")
        let laura = EmailAddress(name: "Laura Méndez", email: "laura.mendez@contoso.com")
        let diego = EmailAddress(name: "Diego Torres", email: "diego.torres@contoso.com")
        let sofia = EmailAddress(name: "Sofía Herrera", email: "sofia@acme.com")
        let suggester = MeetingProjectSuggester(people: people, projects: engine.projects.list(), ownerEmails: ["ana@contoso.com"])
        let byPeople = suggester.suggestProject(for: ev("p1", "Kickoff", start: t0, attendees: [me, laura, diego]))
        t.eq(byPeople?.projectSlug, redesign.slug, "suggest by attendees' people pages")
        t.eq(byPeople?.reason, .people(["Laura Méndez", "Diego Torres"]), "reason lists the people")
        let byTitle = suggester.suggestProject(for: ev("p2", "Llamada con ACME logistics — propuesta", start: t0, attendees: [me, laura]))
        t.eq(byTitle?.projectSlug, acme.slug, "title words beat one attendee")
        t.eq(byTitle?.reason, .title, "reason = title")
        t.check(suggester.suggestProject(for: ev("p3", "Kickoff", start: t0, attendees: [me])) == nil, "the owner alone suggests nothing")
        t.check(suggester.suggestProject(for: ev("p4", "Café", start: t0, attendees: [laura, sofia])) == nil, "a tie suggests nothing")
        t.check(suggester.suggestProject(for: ev("p5", "Acmed review", start: t0)) == nil, "partial words don't match")
        t.eq(suggester.suggestProject(for: ev("p6", "Revisión rediseño app", start: t0))?.projectSlug, redesign.slug,
             "accented project name in the title")

        // --- Prep local data.
        try write("projects/\(redesign.slug)/wiki/meetings/2026-10-01-1000-weekly.md",
                  "---\ntype: meeting\ntitle: \"Weekly viejo\"\nevent_date: \"2026-10-01T10:00:00Z\"\npeople: [\"[[laura-mendez]]\"]\n---\n# W\n")
        try write("projects/\(redesign.slug)/wiki/meetings/2026-10-20-1000-weekly.md",
                  "---\ntype: meeting\ntitle: \"Weekly reciente\"\nevent_date: \"2026-10-20T10:00:00Z\"\n---\nCon [[laura-mendez|Laura]].\n")
        try write("projects/\(acme.slug)/wiki/meetings/2026-10-22-0900-acme.md",
                  "---\ntype: meeting\ntitle: \"Acme futura\"\nevent_date: \"2099-01-01T09:00:00Z\"\npeople: [\"[[laura-mendez]]\"]\n---\n")
        try write("projects/\(redesign.slug)/wiki/decisions/2026-10-01-a.md", "---\ntype: decision\ntitle: \"Decisión vieja\"\ndate: 2026-10-01\n---\n")
        try write("projects/\(redesign.slug)/wiki/decisions/2026-10-15-b.md", "---\ntype: decision\ntitle: \"Lanzar en noviembre\"\ndate: 2026-10-15\n---\n")
        try write("projects/\(redesign.slug)/wiki/tasks.md", """
            ---
            type: tasks
            ---
            # Pendientes

            ## Abiertas

            ### Yo — [[ana-garcia|Ana García]]
            - [ ] Mandar bocetos — [[ana-garcia|Ana]] · 📅 2026-11-02
            - [ ] Revisar presupuesto — [[ana-garcia|Ana]] · 📅 2026-10-20
            - [x] Reservar sala — [[ana-garcia|Ana]] · 📅 2026-10-19 · ✅ 2026-10-19

            ### [[laura-mendez|Laura Méndez]]
            - [ ] Compartir métricas — [[laura-mendez|Laura]] · 📅 2026-10-30

            ### Diego
            - [ ] Juntar quejas — Diego Torres

            ## Sin dueño

            ## Hechas
            """)
        try write("projects/\(acme.slug)/wiki/tasks.md", """
            ## Abiertas
            ### [[laura-mendez|Laura Méndez]]
            - [ ] Enviar contrato — [[laura-mendez|Laura]] · 📅 2026-10-25
            """)
        let kickoff = ev("k1", "Kickoff rediseño", start: Date(timeIntervalSince1970: 1_793_000_000),
                         attendees: [me, laura, diego, EmailAddress(name: "Mariana López", email: "mariana@estudio.mx")],
                         notes: "1. Objetivo\n2. Quejas")
        let now = SBDate.parseISO("2026-10-26T12:00:00Z")!.date
        let data = MeetingPrep.localData(event: kickoff, projectSlug: redesign.slug, vault: vault,
                                         projectSlugs: engine.projects.list().map(\.slug), ownerEmails: ["ana@contoso.com"], now: now)
        t.eq(data.attendees.map(\.name), ["Laura Méndez", "Diego Torres", "Mariana López"], "prep: attendees without the owner")
        let l = data.attendees.first { $0.name == "Laura Méndez" }
        t.eq(l?.personPath, "people/laura-mendez.md", "prep: people page")
        t.eq(l?.lastMeeting?.title, "Weekly reciente", "prep: last meeting by date (future pages ignored, body links count)")
        t.eq(l?.openTasks.map(\.text), ["Compartir métricas", "Enviar contrato"], "prep: their open tasks, this project first")
        let d = data.attendees.first { $0.name == "Diego Torres" }
        t.eq(d?.openTasks.map(\.text), ["Juntar quejas"], "prep: task owned by plain-text name")
        t.check(d?.lastMeeting == nil, "prep: no meeting for Diego")
        let m = data.attendees.first { $0.name == "Mariana López" }
        t.check(m?.personPath == nil && m?.openTasks.isEmpty == true, "prep: unknown attendee")
        t.eq(data.myTasks.map(\.text), ["Revisar presupuesto", "Mandar bocetos"], "prep: my open tasks in the project, soonest first")
        t.eq(data.lastDecision?.title, "Lanzar en noviembre", "prep: last decision")
        t.check(!data.knowsNothing, "prep: knows something")
        let noProject = MeetingPrep.localData(event: kickoff, projectSlug: nil, vault: vault,
                                              projectSlugs: engine.projects.list().map(\.slug), ownerEmails: [], now: now)
        t.check(noProject.myTasks.isEmpty && noProject.lastDecision == nil, "prep without project: no project cards")
        t.check(!noProject.attendees.contains { $0.name == "Ana García" }, "prep: owner page (owner: true) excluded")
        let empty = MeetingPrep.localData(event: ev("z", "Nada", start: t0, attendees: [EmailAddress(name: "X Y", email: "x@y.z")]),
                                          projectSlug: nil, vault: vault, projectSlugs: [], ownerEmails: [], now: now)
        t.check(empty.knowsNothing, "prep: knowsNothing for strangers")
        let viaEngine = await engine.meetingPrep(for: kickoff, projectSlug: redesign.slug)
        t.eq(viaEngine.attendees.count, 3, "engine.meetingPrep off the main thread")

        // --- prepPrompt.
        let es = MeetingPrep.prepPrompt(event: kickoff, language: "es", projectName: "Rediseño app")
        for part in ["«Kickoff rediseño»", "Laura Méndez <laura.mendez@contoso.com>", "Mariana López", "Proyecto: Rediseño app",
                     "1. Objetivo", "## Quiénes", "## Pendientes abiertos", "## Para preguntar", "Exactamente 3", "## Agenda sugerida",
                     "[[…]]", "español"] {
            t.check(es.contains(part), "prepPrompt es contains \(part)")
        }
        let order = ["## Quiénes", "## Pendientes abiertos", "## Para preguntar", "## Agenda sugerida"].compactMap { es.range(of: $0)?.lowerBound }
        t.check(order.count == 4 && order == order.sorted(), "prepPrompt sections in order")
        let en = MeetingPrep.prepPrompt(event: kickoff, language: "en")
        t.check(en.contains("## Who") && en.contains("## To ask") && en.contains("Exactly 3") && !en.contains("Quiénes"), "prepPrompt en")
        t.check(!MeetingPrep.prepPrompt(event: ev("n", "Sin nada", start: t0), language: "es").contains("Notas de la invitación"),
                "prepPrompt without notes")

        // --- Recording ↔ event: source and transcript frontmatter.
        let manifest = SessionManifest(id: SessionManifest.newId(at: t0), title: "Kickoff rediseño", projectSlug: redesign.slug,
                                       startedAt: kickoff.start.addingTimeInterval(-90), micCaptured: true,
                                       calendarEventId: kickoff.id, attendees: ["Laura Méndez", "Diego Torres"])
        engine.recordingStarted(manifest)
        engine.linkCalendarEvent(sourceId: manifest.id, event: kickoff)
        let linked = engine.meetingSource(forEvent: kickoff.id)
        t.eq(linked?.id, manifest.id, "source found by calendar event")
        t.eq(linked?.eventDate, kickoff.start, "event date = the event's start")
        t.eq(MeetingAgenda.phase(of: kickoff, now: kickoff.end.addingTimeInterval(3600), recordingEventId: nil, source: linked),
             .learning, "recorded meeting → learning")
        let transcript = Transcript(language: "es", durationSeconds: 60,
                                    segments: [TranscriptSegment(start: 0, end: 2, speaker: "S1", track: "system", text: "Hola")])
        let raw = TranscriptWriter.render(transcript: transcript, manifest: manifest, title: "Kickoff", projectSlug: redesign.slug, language: "es")
        t.check(raw.contains("\nattendees: [\"Laura Méndez\", \"Diego Torres\"]\n---"), "transcript frontmatter lists attendees")
        var plain = manifest
        plain.attendees = nil
        t.check(!TranscriptWriter.render(transcript: transcript, manifest: plain, title: "K", projectSlug: nil, language: "es")
                    .contains("attendees:"), "no attendees line without attendees")
        let ingest = (try? String(contentsOf: vault.url(for: ".claude/commands/ingest.md"), encoding: .utf8)) ?? ""
        t.check(ingest.contains("`attendees:`"), "ingest command explains attendees")
    } catch {
        t.check(false, "meetings vault setup: \(error)")
    }
}

private final class MeetingsNoTranscriber: Transcribing, @unchecked Sendable {
    func prepare(progress: @escaping @Sendable (ModelPrepProgress) -> Void) async throws {}
    var isReady: Bool { true }
    func transcribe(sessionDir: URL, manifest: SessionManifest, progress: @escaping @Sendable (Double, String) -> Void) async throws -> Transcript {
        Transcript(language: "es", durationSeconds: 0, segments: [])
    }
}
