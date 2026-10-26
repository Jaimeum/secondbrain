import AppKit
import BrainCore
import SwiftUI

/// Development only: `SB_SNAPSHOT_DIR=<dir>` renders the v0.2 screens offscreen to PNGs and quits, so layout can be
/// reviewed without driving (or even showing) the real window. Optional `SB_SNAPSHOT_EMAIL=<file>`: a pasted email
/// used for the "Agregar correo" sheet. Never active in normal use.
@MainActor
enum DebugSnapshots {
    static var directory: URL? {
        guard let dir = ProcessInfo.processInfo.environment["SB_SNAPSHOT_DIR"], !dir.isEmpty else { return nil }
        return URL(fileURLWithPath: dir)
    }

    static func runIfRequested(state: AppState) {
        guard let dir = directory else { return }
        Task {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(2))
            if ProcessInfo.processInfo.environment["SB_SNAPSHOT_SELFTEST"] == "1" { await selfTest(state: state, dir: dir) }
            let project = state.projects.first
            let slug = project?.slug ?? ""
            let source = state.engine.sources.first { $0.projectSlug == slug && $0.status == .done }
            let email = (ProcessInfo.processInfo.environment["SB_SNAPSHOT_EMAIL"]).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            var shots: [(String, CGSize, AnyView)] = []
            if let project {
                shots.append(("tasks", CGSize(width: 900, height: 560), AnyView(ProjectTasksView(project: project, onOpen: { _ in }))))
                shots.append(("timeline", CGSize(width: 900, height: 700), AnyView(BrainTimelineView(projectSlug: slug) { _, _ in })))
                shots.append(("sources", CGSize(width: 900, height: 560), AnyView(SourcesView(projectSlug: slug, onOpen: { _ in }))))
            }
            shots.append(("mytasks", CGSize(width: 900, height: 560), AnyView(MyTasksView())))
            shots.append(("timeline-all", CGSize(width: 900, height: 700), AnyView(BrainTimelineView(projectSlug: nil) { _, _ in })))
            shots.append(("templates", CGSize(width: 1000, height: 640), AnyView(TemplatesView())))
            shots.append(("email", CGSize(width: 820, height: 640),
                          AnyView(AddEmailSheet(request: EmailRequest(threadKey: nil, projectSlug: slug), initialText: email ?? ""))))
            if let source {
                shots.append(("export", CGSize(width: 540, height: 520), AnyView(ExportSheet(request: ExportRequest(target: .source(source))))))
                shots.append(("source-tasks", CGSize(width: 600, height: 560), AnyView(SourceTasksSheet(source: source))))
                shots.append(("change-date", CGSize(width: 460, height: 320), AnyView(ChangeDateSheet(source: source))))
            }
            if let thread = state.engine.emailThreads(projectSlug: nil).first {
                shots.append(("thread", CGSize(width: 720, height: 640), AnyView(ThreadSheet(threadKey: thread.key))))
            }
            shots.append(("note", CGSize(width: 560, height: 520), AnyView(NoteSheet(projectSlug: slug))))
            shots.append(("menubar", CGSize(width: 310, height: 420), AnyView(MenuBarView())))
            // v0.3 (CONTRACT §12.6); run with SB_DEMO_ACCOUNTS=1 for mail/meetings with data.
            shots.append(("graph", CGSize(width: 1000, height: 680),
                          AnyView(GraphView(scope: project.map { .project($0.slug) } ?? .global, focus: nil, onOpen: { _ in }))))
            shots.append(("graph-all", CGSize(width: 1000, height: 680), AnyView(GraphView(scope: .global, focus: nil, onOpen: { _ in }))))
            shots.append(("mail", CGSize(width: 1000, height: 640), AnyView(MailView())))
            shots.append(("meetings", CGSize(width: 1000, height: 640), AnyView(MeetingsView())))
            if let account = state.engine.accounts.accounts.first,
               let event = try? await state.engine.accounts.provider(for: account)
                   .events(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(7 * 86_400)).first {
                shots.append(("prep", CGSize(width: 760, height: 640), AnyView(MeetingPrepView(event: event))))
            }
            shots.append(("settings-accounts", CGSize(width: 560, height: 900), AnyView(SettingsView())))
            shots.append(("orghelp", CGSize(width: 620, height: 520), AnyView(OrgAccessHelpSheet(provider: .microsoft))))
            // MARK: v0.3 accounts — the connect sheet's trust step and the organization-block fork
            shots.append(("trust", CGSize(width: 460, height: 470),
                          AnyView(TrustSheet(connector: AccountConnector(preview: ConnectFlow(provider: .microsoft, phase: .trust))))))
            shots.append(("blocked", CGSize(width: 460, height: 520), AnyView(AccountBlockedView(
                provider: .microsoft, reason: .consent, context: .meetings, onUseMacCalendar: {}, onClose: {}))))
            shots.append(("connect-empty", CGSize(width: 760, height: 460), AnyView(ConnectAccountsEmptyState(
                symbol: "calendar", title: L("meetings.empty.title"), message: L("meetings.empty.message")))))
            for (name, size, view) in shots {
                await render(view.environment(state), size: size, to: dir.appendingPathComponent(name + ".png"))
            }
            exit(0)
        }
    }

    /// Exercises the v0.2 paths the screens use and prints what happened (development only).
    private static func selfTest(state: AppState, dir: URL) async {
        let engine = state.engine
        func log(_ s: String) { print("SELFTEST " + s); fflush(stdout) }
        let slug = state.projects.first?.slug
        if let path = ProcessInfo.processInfo.environment["SB_SNAPSHOT_EMAIL"], let text = try? String(contentsOfFile: path, encoding: .utf8) {
            let email = engine.parseEmail(text)
            log("parsed subject=\(email.subject ?? "-") from=\(email.from?.display ?? "-") date=\(email.date.map { Fmt.eventDate($0) } ?? "-") mine=\(email.isFromOwner)")
            let matches = engine.matchThreads(for: email)
            log("matches=\(matches.map { "\($0.thread.subject):\($0.score)" })")
            do {
                let strong = matches.first { $0.score >= 0.8 }
                let src = try engine.addEmail(email, threadKey: strong?.thread.key, projectSlug: strong == nil ? slug : nil)
                log("added email source=\(src.id) thread=\(src.threadKey ?? "-") event=\(Fmt.eventDate(src.timelineDate)) dates='\(src.datesLine)'")
            } catch { log("addEmail error: \(FriendlyError.message(error))") }
            for t in engine.emailThreads(projectSlug: nil) { log("thread \(t.key) «\(t.subject)» n=\(t.messageCount) project=\(t.projectSlug ?? "inbox")") }
        }
        let model = TaskListModel()
        await model.load { await engine.tasks(projectSlug: slug) }
        log("tasks=\(model.tasks.count) mine=\(model.tasks.filter(\.isMine).count) overdue=\(model.tasks.filter(\.isOverdue).count)")
        if let task = model.tasks.first(where: { !$0.done }) {
            model.toggle(task, state: state)
            log("toggle → done=\(model.isDone(task)) error=\(model.error ?? "none")")
            await model.load { await engine.tasks(projectSlug: slug) }
            let reloaded = model.tasks.first { $0.text == task.text }
            log("after reload done=\(reloaded?.done ?? false) line=\(reloaded?.line ?? "-")")
            if let reloaded { model.toggle(reloaded, state: state); log("toggle back error=\(model.error ?? "none")") }
        }
        let timeline = await engine.timeline(projectSlug: nil)
        log("timeline entries=\(timeline.count) kinds=\(Set(timeline.map(\.kind.rawValue)).sorted())")
        if let src = engine.sources.first(where: { $0.status == .done && $0.kind == .meeting }) {
            for format in ExportFormat.allCases {
                do {
                    var options = ExportOptions()
                    options.includeTranscript = true
                    let doc = try await engine.exportDocument(sourceId: src.id, options: options)
                    let url = dir.appendingPathComponent("\(Fmt.fileDay(src.timelineDate)) \(doc.title).\(format.fileExtension)")
                    try Exporter.export(markdown: doc.markdown, title: doc.title, format: format, options: options, to: url)
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
                    log("export \(format.rawValue) ok \(size) bytes → \(url.lastPathComponent)")
                } catch { log("export \(format.rawValue) error: \(FriendlyError.message(error))") }
            }
        }
        log("migrationNotice=\(engine.migrationNotice ?? "nil") templates=\(state.templates.count)")
    }

    private static func render(_ view: some View, size: CGSize, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)))
        host.frame = CGRect(origin: .zero, size: size)
        // An offscreen, never-ordered-in window gives the view a real layout/appearance context.
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(2.5))   // let .task loaders finish
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }
}
