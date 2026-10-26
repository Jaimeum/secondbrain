import ArgumentParser
import BrainCore
import Foundation

// v0.2 commands (CONTRACT §11): emails, tasks, templates, timeline, dates, export.

/// "2026-10-26T15:30:00-06:00", "2026-10-26 15:30", "2026-10-26", or anything an email client prints.
func parseUserDate(_ s: String) throws -> Date {
    if let d = SBDate.parseISO(s)?.date ?? EmailParser.parseDate(s) { return d }
    throw CLIError("Unrecognized date: \(s) (use e.g. 2026-10-26T15:30:00-06:00 or \"2026-10-26 15:30\")")
}

@MainActor func human(_ d: Date, time: Bool = true, _ engine: BrainEngine) -> String {
    SBDate.human(d, hasTime: time, language: engine.config.uiLanguage)
}

// MARK: - Emails

struct EmailCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "email", abstract: "Paste emails into the brain.",
                                                    subcommands: [Add.self, Threads.self, Mine.self])

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Parse a pasted email (file or stdin) and add it to a thread.",
            discussion: "Without --yes/--thread/--new it only shows what it understood and the thread suggestions.")
        @Option(help: "Read the email from this file (default: stdin)") var file: String?
        @Option(help: "Add to this existing thread (its key)") var thread: String?
        @Option(help: "Project for a new thread") var project: String?
        @Flag(help: "Accept the top thread suggestion if it is strong (≥ 0.8), else start a new thread") var yes = false
        @Flag(name: .customLong("new"), help: "Start a new thread") var newThread = false
        @Flag(help: "Process the queue right away") var run = false

        @MainActor func run() async throws {
            let text: String
            if let file {
                text = try String(contentsOf: URL(fileURLWithPath: (file as NSString).expandingTildeInPath), encoding: .utf8)
            } else {
                text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            }
            let engine = makeEngine()
            let messages = engine.parseEmails(text)
            guard let newest = messages.last else { throw CLIError("Nothing to parse.") }
            for (i, e) in messages.enumerated() {
                if messages.count > 1 { print("— Message \(i + 1)/\(messages.count)") }
                print("Subject: \(e.subject ?? "(none)")")
                print("From:    \(e.from.map(EmailParser.format) ?? "(unknown)")\(e.isFromOwner ? "  [you]" : "")")
                if !e.to.isEmpty { print("To:      \(e.to.map(EmailParser.format).joined(separator: ", "))") }
                if !e.cc.isEmpty { print("Cc:      \(e.cc.map(EmailParser.format).joined(separator: ", "))") }
                print("Date:    \(e.date.map { "\(human($0, engine)) (\(SBDate.iso($0)))" } ?? "(unknown — will use now)")")
                let preview = e.body.split(separator: "\n", omittingEmptySubsequences: true).prefix(3).joined(separator: " / ")
                print("Body:    \(preview.prefix(160))\(e.body.count > 160 ? "…" : "")")
                if let q = e.quotedHistory { print("Quoted:  \(q.count) chars of earlier messages") }
            }
            let matches = engine.matchThreads(for: newest)
            if matches.isEmpty { print("Threads: no similar thread — it would start a new one.") }
            for m in matches.prefix(5) {
                let last = m.thread.lastDate.map { human($0, time: false, engine) } ?? "?"
                print(String(format: "Thread:  %.2f  %@  «%@» (%d emails, last %@, %@) — %@", m.score, m.thread.key, m.thread.subject,
                             m.thread.messageCount, last, m.thread.projectSlug ?? "inbox", m.reason))
            }
            var key: String?
            if let thread {
                key = thread
            } else if newThread {
                key = nil
            } else if yes {
                key = matches.first.flatMap { $0.score >= 0.8 ? $0.thread.key : nil }
            } else {
                print("\nNot added. Use --yes, --thread <key> or --new.")
                return
            }
            let added = try engine.addEmails(messages, threadKey: key, projectSlug: project)
            if added.isEmpty { print("Already saved (duplicate): nothing added.") }
            for s in added {
                print("Added \(s.title) [\(s.id)] → \(s.rawPath ?? "?") thread=\(s.threadKey ?? "?") (\(s.status.rawValue))")
            }
            if run { await runQueue(engine) }
        }
    }

    struct Threads: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List email threads.")
        @Option var project: String?
        @MainActor func run() async throws {
            let engine = makeEngine()
            let threads = engine.emailThreads(projectSlug: project)
            if threads.isEmpty { print("No email threads.") }
            for t in threads {
                let range = [t.firstDate, t.lastDate].compactMap { $0.map { human($0, engine) } }.joined(separator: " → ")
                print("\(t.key)\t\(t.projectSlug ?? "inbox")\t\(t.messageCount) email(s)\t\(range)\t«\(t.subject)»")
                for e in engine.emails(inThread: t.key) {
                    print("    \(e.id)  \(human(e.timelineDate, engine))  \(e.status.rawValue)")
                }
            }
        }
    }

    struct Mine: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "mine", abstract: "Show or set your email addresses.")
        @Argument var addresses: [String] = []
        @MainActor func run() async throws {
            let engine = makeEngine()
            if !addresses.isEmpty { try engine.vault.setOwnerEmails(addresses) }
            let list = engine.vault.ownerEmails()
            print(list.isEmpty ? "(not set)" : list.joined(separator: ", "))
        }
    }
}

// MARK: - Tasks

struct TasksCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks", abstract: "List tasks from tasks.md.")
    @Option var project: String?
    @Flag(help: "Only mine") var mine = false
    @Flag(help: "Include done tasks") var all = false
    @Option(help: "Only tasks citing this source") var source: String?
    @Flag(help: "Print as an exported checklist (markdown)") var checklist = false

    @MainActor func run() async throws {
        let engine = makeEngine()
        var tasks = source != nil ? await engine.tasks(forSourceId: source!) : await engine.tasks(projectSlug: project)
        if mine { tasks = tasks.filter(\.isMine) }
        if !all { tasks = tasks.filter { !$0.done } }
        if checklist {
            print(engine.exportTasks(tasks, title: es(engine) ? "Pendientes" : "Tasks"))
            return
        }
        if tasks.isEmpty { print("No tasks.") }
        for t in tasks {
            var line = "\(t.id)  [\(t.done ? "x" : " ")] \(t.text)"
            line += "  — " + (t.isMine ? "me" : t.ownerName ?? "no owner")
            if let due = t.due { line += "  📅 \(human(due, time: false, engine))\(t.isOverdue ? " (overdue)" : "")" }
            if let d = t.doneDate { line += "  ✅ \(human(d, time: false, engine))" }
            if !t.sourceKeys.isEmpty { line += "  ← \(t.sourceKeys.joined(separator: ", "))" }
            print(line)
        }
    }
}

struct TaskCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "task", abstract: "Check or uncheck a task.",
                                                    subcommands: [Done.self, Undone.self])

    @MainActor static func set(_ id: String, done: Bool) async throws {
        let engine = makeEngine()
        let all = await engine.tasks(projectSlug: nil)
        let matches = all.filter { $0.id == id || $0.id.hasSuffix("#" + id) || $0.id.hasSuffix(id) }
        guard matches.count == 1, let task = matches.first else {
            throw CLIError(matches.isEmpty ? "No task with id \(id) (see `sb tasks --all`)." : "Ambiguous id \(id).")
        }
        try engine.setTask(task, done: done)
        print("\(done ? "Done" : "Reopened"): \(task.text)")
    }

    struct Done: AsyncParsableCommand {
        @Argument var id: String
        @MainActor func run() async throws { try await TaskCmd.set(id, done: true) }
    }

    struct Undone: AsyncParsableCommand {
        @Argument var id: String
        @MainActor func run() async throws { try await TaskCmd.set(id, done: false) }
    }
}

// MARK: - Templates

struct TemplatesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "templates", abstract: "List page formats (templates).")
    @Option(help: "meeting | email | any") var scope: String?
    @MainActor func run() async throws {
        let engine = makeEngine()
        let list = engine.templates(scope: scope.flatMap(TemplateScope.init(rawValue:)))
        if list.isEmpty { print("No templates (vault not migrated yet?).") }
        for t in list { print("\(t.id)\t\(t.scope.rawValue)\t\(t.isBuiltIn ? "built-in" : "mine")\t\(t.name) — \(t.description)") }
    }
}

struct TemplateCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "template", abstract: "Create or choose page formats.",
                                                    subcommands: [Make.self, Default.self, Use.self, Delete.self])

    struct Make: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Let Claude write a format from a description.")
        @Argument var name: String
        @Argument var description: String
        @Flag(help: "Only enqueue") var noRun = false
        @MainActor func run() async throws {
            let engine = makeEngine()
            engine.makeTemplate(fromDescription: description, name: name)
            if noRun { print("Queued.") } else { await runQueue(engine) }
        }
    }

    struct Default: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show or set a project's default format.")
        @Argument var project: String
        @Argument var templateId: String?
        @Flag(help: "Clear it") var clear = false
        @MainActor func run() async throws {
            let engine = makeEngine()
            if clear || templateId != nil { try engine.setDefaultTemplate(projectSlug: project, templateId: clear ? nil : templateId) }
            print(engine.projects.get(project)?.defaultTemplate ?? "(default)")
        }
    }

    struct Use: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "use", abstract: "Choose the format of one source (before it is learned).")
        @Argument var sourceId: String
        @Argument var templateId: String
        @MainActor func run() async throws {
            let engine = makeEngine()
            guard engine.source(sourceId) != nil else { throw CLIError("No source \(sourceId)") }
            engine.setTemplate(sourceId: sourceId, templateId: templateId)
            print("\(sourceId) → \(templateId)")
        }
    }

    struct Delete: AsyncParsableCommand {
        @Argument var templateId: String
        @MainActor func run() async throws {
            try makeEngine().deleteTemplate(id: templateId)
            print("Deleted \(templateId)")
        }
    }
}

struct Reformat: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Rewrite one source's page with another format.")
    @Argument var sourceId: String
    @Argument var templateId: String
    @Flag(help: "Only enqueue") var noRun = false
    @MainActor func run() async throws {
        let engine = makeEngine()
        guard engine.source(sourceId) != nil else { throw CLIError("No source \(sourceId)") }
        guard engine.templates(scope: nil).contains(where: { $0.id == templateId }) else { throw CLIError("No template \(templateId)") }
        engine.reformat(sourceId: sourceId, templateId: templateId)
        if noRun { print("Queued.") } else { await runQueue(engine) }
    }
}

// MARK: - Dates

struct TimelineCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "timeline", abstract: "What happened when (by event date).")
    @Option var project: String?
    @MainActor func run() async throws {
        let engine = makeEngine()
        let entries = await engine.timeline(projectSlug: project)
        if entries.isEmpty { print("Nothing yet.") }
        let icons: [TimelineKind: String] = [.meeting: "🎙️", .email: "✉️", .document: "📄", .note: "📝", .url: "🔗",
                                             .decision: "⚖️", .milestone: "🚩", .task: "📅"]
        for e in entries {
            var line = "\(human(e.date, time: e.hasTime, engine))  \(icons[e.kind] ?? "•") \(e.title)"
            if let added = e.addedAt, abs(added.timeIntervalSince(e.date)) > 86_400 {
                line += "  (" + (es(engine) ? "agregado " : "added ") + human(added, time: false, engine) + ")"
            }
            if project == nil, let p = e.projectSlug { line += "  [\(p)]" }
            print(line)
        }
    }
}

struct SetDate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "set-date", abstract: "Correct when a source happened.")
    @Argument var sourceId: String
    @Argument(help: "ISO date, e.g. 2026-10-20T10:00:00-06:00") var date: String
    @Flag(help: "Process the queue right away (re-learns it if it was already learned)") var run = false
    @MainActor func run() async throws {
        let engine = makeEngine()
        try engine.setEventDate(sourceId: sourceId, date: try parseUserDate(date))
        let s = engine.source(sourceId)
        print("\(sourceId): happened \(s?.eventDate.map { "\(human($0, engine)) (\(SBDate.iso($0)))" } ?? "?") · \(s?.status.rawValue ?? "")")
        if run { await runQueue(engine) }
    }
}

// MARK: - Export

struct Export: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Export a source (summary + tasks [+ transcript]) or a wiki page.")
    @Argument(help: "A source id or a vault-relative page path") var target: String
    @Option(help: "md | txt | docx | pdf | html | rtf") var format: String = "md"
    @Option(help: "Output file") var out: String
    @Flag(help: "Include the transcript / the thread's emails / the document text") var transcript = false
    @Flag(help: "Transcript without timestamps") var noTimestamps = false
    @Flag(help: "Leave out the summary page") var noSummary = false
    @Flag(help: "Leave out the tasks") var noTasks = false
    @Flag(help: "Markdown only: keep [[wikilinks]]") var keepWikilinks = false
    @Flag(help: "Markdown only: keep the frontmatter") var keepFrontmatter = false

    @MainActor func run() async throws {
        let formats: [String: ExportFormat] = ["md": .markdown, "markdown": .markdown, "txt": .text, "text": .text, "docx": .docx,
                                               "word": .docx, "pdf": .pdf, "html": .html, "rtf": .rtf]
        guard let fmt = formats[format.lowercased()] else { throw CLIError("Unknown format \(format)") }
        let engine = makeEngine()
        var options = ExportOptions()
        options.includeTranscript = transcript
        options.includeTimestamps = !noTimestamps
        options.includeSummary = !noSummary
        options.includeTasks = !noTasks
        options.keepWikilinks = keepWikilinks
        options.keepFrontmatter = keepFrontmatter
        let doc = engine.source(target) != nil
            ? try await engine.exportDocument(sourceId: target, options: options)
            : try await engine.exportDocument(pagePath: target, options: options)
        let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
        try Exporter.export(markdown: doc.markdown, title: doc.title, format: fmt, options: options, to: url)
        print("Exported «\(doc.title)» → \(url.path)")
    }
}
