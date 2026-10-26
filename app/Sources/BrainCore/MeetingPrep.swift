import Foundation

// "Prepararme" (CONTRACT §12.7): instant local cards (no Claude) + the question that "Preparar con Claude" asks.

/// What the vault already knows for a meeting, read straight from the files (instant, no Claude).
public struct MeetingPrepData: Sendable, Equatable {
    /// A wiki page with its title and when it happened.
    public struct PageRef: Sendable, Hashable {
        public var title: String
        public var path: String
        public var date: Date?
        public init(title: String, path: String, date: Date?) { self.title = title; self.path = path; self.date = date }
    }

    public struct Attendee: Sendable, Identifiable, Hashable {
        public var id: String               // email, else the name
        public var name: String
        public var email: String?
        public var personPath: String?      // people/<slug>.md when the brain knows them
        public var lastMeeting: PageRef?    // the latest meeting page they appear in (by event date)
        public var openTasks: [TaskItem]    // open tasks they own, this project's first
        public init(id: String, name: String, email: String?, personPath: String? = nil, lastMeeting: PageRef? = nil,
                    openTasks: [TaskItem] = []) {
            self.id = id; self.name = name; self.email = email; self.personPath = personPath
            self.lastMeeting = lastMeeting; self.openTasks = openTasks
        }
    }

    public var projectSlug: String?
    public var attendees: [Attendee]
    /// My open tasks in the event's project (soonest first).
    public var myTasks: [TaskItem]
    /// The latest decision page of the project.
    public var lastDecision: PageRef?

    public init(projectSlug: String?, attendees: [Attendee] = [], myTasks: [TaskItem] = [], lastDecision: PageRef? = nil) {
        self.projectSlug = projectSlug; self.attendees = attendees; self.myTasks = myTasks; self.lastDecision = lastDecision
    }

    /// The brain knows nothing useful yet (no known people, no tasks, no decisions).
    public var knowsNothing: Bool {
        myTasks.isEmpty && lastDecision == nil
            && attendees.allSatisfy { $0.personPath == nil && $0.lastMeeting == nil && $0.openTasks.isEmpty }
    }
}

public enum MeetingPrep {
    /// Reads the vault (people pages, meeting pages, tasks.md, decisions) for `event`. Synchronous file I/O: call it off
    /// the main thread (`BrainEngine.meetingPrep`). The owner (`ownerEmails`, `owner: true` pages) is left out.
    public static func localData(event: CalendarEvent, projectSlug: String?, vault: VaultStore, projectSlugs: [String],
                                 ownerEmails: Set<String>, now: Date = Date()) -> MeetingPrepData {
        let people = MeetingPeopleIndex.load(vault: vault)
        let owner = vault.ownerInfo()
        let ownerEmails = Set(ownerEmails.map { $0.lowercased() })
        let meetings = meetingPages(vault: vault, before: now)
        let allTasks = projectSlugs.flatMap { vault.tasks(projectSlug: $0, owner: owner) }.filter { !$0.done }

        var attendees: [MeetingPrepData.Attendee] = []
        var seen = Set<String>()
        for address in event.attendees {
            if let email = address.email?.lowercased(), ownerEmails.contains(email) { continue }
            let person = people.person(for: address)
            if person?.isOwner == true { continue }
            if let slug = person?.slug, owner.slugs.contains(slug) { continue }
            let name = person?.title ?? address.name ?? address.email ?? "?"
            let id = address.email?.lowercased() ?? MeetingPeopleIndex.norm(name)
            guard seen.insert(person?.path ?? id).inserted else { continue }
            var attendee = MeetingPrepData.Attendee(id: id, name: name, email: address.email?.lowercased(), personPath: person?.path)
            if let person {
                attendee.lastMeeting = meetings.first { $0.mentions(person.slug) }?.ref
            }
            let names = Set(([name, address.name ?? ""] + (person?.aliases ?? [])).map(MeetingPeopleIndex.norm).filter { !$0.isEmpty })
            attendee.openTasks = allTasks
                .filter { task in
                    if let slug = person?.slug, task.ownerSlug == slug { return true }
                    guard !task.isMine, let owner = task.ownerName.map(MeetingPeopleIndex.norm) else { return false }
                    return names.contains(owner)
                }
                .sorted { a, b in
                    let pa = a.projectSlug == projectSlug, pb = b.projectSlug == projectSlug
                    if pa != pb { return pa }
                    return (a.due ?? .distantFuture, a.text) < (b.due ?? .distantFuture, b.text)
                }
            attendees.append(attendee)
        }

        var data = MeetingPrepData(projectSlug: projectSlug, attendees: attendees)
        if let projectSlug {
            data.myTasks = allTasks.filter { $0.isMine && $0.projectSlug == projectSlug }
                .sorted { ($0.due ?? .distantFuture, $0.text) < ($1.due ?? .distantFuture, $1.text) }
            data.lastDecision = latestPage(vault: vault, under: "projects/\(projectSlug)/wiki/decisions", before: now)
        }
        return data
    }

    /// The question for "Preparar con Claude": fixed sections **Quiénes**, **Pendientes abiertos**, **Para preguntar**
    /// (3) and an agenda, in the UI language, citing the wiki.
    public static func prepPrompt(event: CalendarEvent, language: String, projectName: String? = nil) -> String {
        let l = Lang(language)
        let when = SBDate.human(event.start, hasTime: !event.isAllDay, language: language)
        let minutes = Int((event.end.timeIntervalSince(event.start) / 60).rounded())
        let who = event.attendees.map { a -> String in
            switch (a.name, a.email) {
            case let (name?, email?): return "\(name) <\(email)>"
            default: return a.display
            }
        }
        var out = l.t("Prepárame para la reunión «\(event.title)» (\(when), \(minutes) min).",
                      "Prepare me for the meeting “\(event.title)” (\(when), \(minutes) min).")
        if let projectName { out += "\n" + l.t("Proyecto: \(projectName).", "Project: \(projectName).") }
        out += "\n" + l.t("Asistentes: ", "Attendees: ") + (who.isEmpty ? l.t("(sin lista)", "(no list)") : who.joined(separator: ", "))
        if let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines), !notes.isEmpty {
            out += "\n" + l.t("Notas de la invitación:", "Invitation notes:") + "\n" + notes
        }
        out += "\n\n" + l.t("""
            Usa solo lo que dice el wiki y cita cada dato con [[…]]. No inventes: si no sabes algo de alguien, dilo en una línea. \
            Responde en español con exactamente estas secciones, en este orden:
            ## Quiénes
            Una viñeta por asistente (yo no): quién es, qué tiene que ver con el proyecto, la última vez que hablamos y qué quedó.
            ## Pendientes abiertos
            Lo que yo debo y lo que me deben a mí relacionado con esta reunión, con fecha si la hay.
            ## Para preguntar
            Exactamente 3 preguntas concretas para hacer en la reunión.
            ## Agenda sugerida
            De 3 a 5 puntos, con minutos aproximados, que quepan en la reunión.
            """, """
            Use only what the wiki says and cite every fact with [[…]]. Don't make things up: if you know nothing about someone, \
            say so in one line. Answer in English with exactly these sections, in this order:
            ## Who
            One bullet per attendee (not me): who they are, how they relate to the project, the last time we talked and what \
            was left open.
            ## Open items
            What I owe and what is owed to me related to this meeting, with dates when known.
            ## To ask
            Exactly 3 concrete questions to ask in the meeting.
            ## Suggested agenda
            3 to 5 points, with approximate minutes, that fit in the meeting.
            """)
        return out
    }

    // MARK: Pages

    struct MeetingPage {
        var ref: MeetingPrepData.PageRef
        var text: String
        func mentions(_ slug: String) -> Bool {
            text.contains("[[\(slug)]]") || text.contains("[[\(slug)|") || text.contains("[[people/\(slug)")
        }
    }

    /// Every `projects/*/wiki/meetings/*.md` that happened before `now`, newest first.
    static func meetingPages(vault: VaultStore, before now: Date) -> [MeetingPage] {
        vault.markdownFiles(under: "projects")
            .filter { $0.contains("/wiki/meetings/") }
            .compactMap { path -> MeetingPage? in
                guard let text = try? vault.read(path) else { return nil }
                let ref = pageRef(path: path, text: text)
                if let d = ref.date, d > now { return nil }
                return MeetingPage(ref: ref, text: text)
            }
            .sorted { ($0.ref.date ?? .distantPast) > ($1.ref.date ?? .distantPast) }
    }

    static func latestPage(vault: VaultStore, under dir: String, before now: Date) -> MeetingPrepData.PageRef? {
        vault.markdownFiles(under: dir)
            .compactMap { path in (try? vault.read(path)).map { pageRef(path: path, text: $0) } }
            .filter { ($0.date ?? .distantPast) <= now }
            .max { ($0.date ?? .distantPast, $0.path) < ($1.date ?? .distantPast, $1.path) }
    }

    static func pageRef(path: String, text: String) -> MeetingPrepData.PageRef {
        let title = Frontmatter.field("title", in: text) ?? ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let date = (Frontmatter.field("event_date", in: text) ?? Frontmatter.field("date", in: text)).flatMap(SBDate.parseISO)?.date
        return MeetingPrepData.PageRef(title: title, path: path, date: date)
    }
}

public extension BrainEngine {
    /// `MeetingPrep.localData` off the main thread, with the owner's addresses from people/README and the accounts.
    func meetingPrep(for event: CalendarEvent, projectSlug: String?) async -> MeetingPrepData {
        let vault = self.vault, projects = self.projects
        let accountEmails = Set(accounts.accounts.map(\.email))
        return await Task.detached(priority: .userInitiated) {
            let emails = Set(vault.ownerEmails()).union(accountEmails)
            return MeetingPrep.localData(event: event, projectSlug: projectSlug, vault: vault,
                                         projectSlugs: projects.list().map(\.slug), ownerEmails: emails)
        }.value
    }
}
