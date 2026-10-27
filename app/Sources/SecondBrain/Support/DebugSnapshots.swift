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
            state.engine.autoProcess = false   // a snapshot never starts a Claude job (AppState.launch also does this)
            try? await Task.sleep(for: .seconds(2))
            if ProcessInfo.processInfo.environment["SB_SNAPSHOT_SELFTEST"] == "1" { await selfTest(state: state, dir: dir) }
            // MARK: v0.5 ux — `SB_SNAPSHOT_WINDOW=1`: the whole main window (sidebar + detail) for every sidebar item,
            // light and dark, at the default size and at the minimum window size (where layouts break first).
            if ProcessInfo.processInfo.environment["SB_SNAPSHOT_WINDOW"] == "1" {
                await renderWindows(state: state, dir: dir)
                NSApp.terminate(nil)
                return
            }
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
            shots.append(("meetings-week", CGSize(width: 1000, height: 640), AnyView(MeetingsView(initialSegment: .week))))   // MARK: v0.3 meetings
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
                symbol: "calendar", title: L("meetings.empty.title"), message: L("meetings.empty.message"), context: .meetings))))
            // Integration: Correo never offers the Mac Calendar; a narrow Reuniones wraps the buttons without repeating any.
            shots.append(("connect-empty-mail", CGSize(width: 760, height: 460), AnyView(ConnectAccountsEmptyState(
                symbol: "envelope", title: L("mail.empty.title"), message: L("mail.empty.message"),
                secondaryTitle: L("mail.pasteInstead"), secondaryAction: {}, context: .mail))))
            shots.append(("connect-empty-narrow", CGSize(width: 440, height: 520), AnyView(ConnectAccountsEmptyState(
                symbol: "calendar", title: L("meetings.empty.title"), message: L("meetings.empty.message"), context: .meetings))))
            shots.append(("blocked-notregistered", CGSize(width: 460, height: 520), AnyView(AccountBlockedView(
                provider: .google, reason: .notRegistered, context: .mail, onUseMacCalendar: {}, onClose: {}))))
            // MARK: v0.4 github (CONTRACT §13.6); run with SB_DEMO_GITHUB=1 for an account and two followed repos.
            let repoSlug = state.engine.github.repos.first?.projectSlug ?? slug
            shots.append(("repos", CGSize(width: 900, height: 600), AnyView(ReposView(projectSlug: repoSlug))))
            shots.append(("repos-empty", CGSize(width: 900, height: 460), AnyView(ReposView(projectSlug: "-"))))
            shots.append(("add-repo", CGSize(width: 580, height: 580), AnyView(AddRepoSheet(projectSlug: repoSlug))))
            shots.append(("add-repo-branches", CGSize(width: 580, height: 580),
                          AnyView(AddRepoSheet(projectSlug: repoSlug, initialRepo: GitHubDemo.myRepos[2]))))
            shots.append(("settings-github", CGSize(width: 560, height: 520), AnyView(Form { GitHubSection() }.formStyle(.grouped))))
            shots.append(("github-trust", CGSize(width: 460, height: 470), AnyView(GitHubConnectSheet())))
            shots.append(("github-code", CGSize(width: 460, height: 400), AnyView(GitHubConnectSheet(preview: .code(GitHubDeviceCode(
                deviceCode: "demo", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: Date().addingTimeInterval(900), interval: 5))))))
            shots.append(("github-org", CGSize(width: 560, height: 520), AnyView(GitHubOrgHelpSheet())))
            // Integration: the main screens with their tab bars (Wiki · Grafo · …) and the sidebar footer banner.
            shots.append(("sidebar", CGSize(width: 260, height: 720), AnyView(SidebarView(showNewProject: .constant(false)))))
            if let project {
                shots.append(("web-project", CGSize(width: 1100, height: 720), AnyView(ProjectView(project: project))))
            }
            shots.append(("web-brain", CGSize(width: 1100, height: 720), AnyView(BrainView())))
            // MARK: v0.3 graph — focused graph + web views need a run loop and WKWebView.takeSnapshot.
            if let topic = await state.engine.graph(projectSlug: nil).nodes.filter({ $0.kind == .topic }).max(by: { $0.links < $1.links }) {
                shots.append(("graph-focus", CGSize(width: 1000, height: 680), AnyView(GraphView(scope: .global, focus: topic.id, onOpen: { _ in }))))
                if let slug = topic.projectSlug {   // the wiki page header with "Ver en el grafo"
                    shots.append(("graph-wiki", CGSize(width: 1000, height: 400),
                                  AnyView(WikiBrowser(scope: .project(slug), selection: .constant(topic.id)))))
                }
            }
            shots += await RulesSnapshots.shots(state: state)   // MARK: v0.4 rules
            let only = ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] ?? ""   // e.g. "graph": just those shots
            for (name, size, view) in shots where only.isEmpty || name.hasPrefix(only) {
                if name.hasPrefix("graph") || name.hasPrefix("web-") {   // views with a WKWebView
                    await GraphSnapshot.render(view.environment(state), size: size, to: dir.appendingPathComponent(name + ".png"))
                    continue
                }
                await render(view.environment(state), size: size, to: dir.appendingPathComponent(name + ".png"))
            }
            // Integration: the optional accounts step of the onboarding, then its primary button ("Más tarde" without
            // accounts) pressed through the default-action shortcut: the next shot must be the last step.
            if only.isEmpty || "onboarding-accounts".hasPrefix(only) {
                await renderOnboardingAccounts(state: state, dir: dir)
            }
            // MARK: v0.4 routing — the §14.3 offer in Correo after a manual pick (writes nothing).
            if only.isEmpty || "mail-rule-offer".hasPrefix(only), let mail = await MailModel.snapshotRuleOffer(state: state) {
                await render(MailView(model: mail).environment(state), size: CGSize(width: 1000, height: 640),
                             to: dir.appendingPathComponent("mail-rule-offer.png"))
            }
            if only.isEmpty || "mail-rule-routed".hasPrefix(only), let mail = await MailModel.snapshotRouted(state: state) {
                await render(MailView(model: mail).environment(state), size: CGSize(width: 1000, height: 640),
                             to: dir.appendingPathComponent("mail-rule-routed.png"))
            }
            // MARK: v0.3 mail — after the smart button: ✓ chips + "Aprendiendo del correo… · Deshacer" (writes to the vault).
            if let mail = await MailModel.snapshotAfterAdd(state: state) {
                await render(MailView(model: mail).environment(state), size: CGSize(width: 1000, height: 640),
                             to: dir.appendingPathComponent("mail-added.png"))
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

    /// "onboarding-accounts" and "onboarding-accounts-next" (after pressing Return = the primary button).
    private static func renderOnboardingAccounts(state: AppState, dir: URL) async {
        let size = CGSize(width: 760, height: 620)
        let host = NSHostingView(rootView: OnboardingView(initialStep: .accounts).environment(state)
            .frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        try? await Task.sleep(for: .seconds(1.5))
        writePNG(host, to: dir.appendingPathComponent("onboarding-accounts.png"))
        let ret = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                   windowNumber: window.windowNumber, context: nil, characters: "\r",
                                   charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)
        if let ret { _ = window.performKeyEquivalent(with: ret) }
        try? await Task.sleep(for: .seconds(1.5))
        writePNG(host, to: dir.appendingPathComponent("onboarding-accounts-next.png"))
        window.contentView = nil
        OnboardingStep.clearSaved()
    }

    private static func writePNG(_ host: NSView, to url: URL) {
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// Every top-level screen inside the real `MainView` (NavigationSplitView, toolbar, tab bar, sidebar footer).
    private static func renderWindows(state: AppState, dir: URL) async {
        var items: [(String, SidebarItem)] = [("brain", .brain), ("mytasks", .myTasks), ("inbox", .inbox), ("mail", .mail),
                                              ("meetings", .meetings), ("people", .people), ("templates", .templates)]
        if let project = state.projects.first { items.append(("project", .project(project.slug))) }
        let only = ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] ?? ""
        for (name, item) in items where only.isEmpty || name.hasPrefix(only) {
            for (sizeName, size) in [("1100", CGSize(width: 1100, height: 720)), ("min", CGSize(width: 860, height: 600))] {
                for dark in [false, true] {
                    state.selection = item
                    let file = "window-\(name)-\(sizeName)-\(dark ? "dark" : "light").png"
                    await renderWindow(MainView().environment(state), size: size, dark: dark, to: dir.appendingPathComponent(file))
                }
            }
        }
    }

    private static func renderWindow(_ view: some View, size: CGSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        // The whole app switches appearance (as AppState.applyAppearance does): AppKit-backed controls inside the
        // hosting view only follow NSApp.appearance when rendered offscreen.
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previous }
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
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
