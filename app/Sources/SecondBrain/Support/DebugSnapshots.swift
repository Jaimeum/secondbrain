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
                await BackfillSnapshots.render(state: state, dir: dir)   // MARK: v0.7 backfill
                NSApp.terminate(nil)
                return
            }
            let project = state.projects.first
            let slug = project?.slug ?? ""
            let source = state.engine.sources.first { $0.projectSlug == slug && $0.status == .done }
            let email = (ProcessInfo.processInfo.environment["SB_SNAPSHOT_EMAIL"]).flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
            var shots: [(String, CGSize, AnyView)] = []
            if let project {
                shots.append(("tasks", CGSize(width: 900, height: 560), AnyView(TasksView(scope: .project(project.slug), onOpenPage: { _ in }))))
                shots.append(("timeline", CGSize(width: 900, height: 700), AnyView(BrainTimelineView(projectSlug: slug) { _, _ in })))
                shots.append(("sources", CGSize(width: 900, height: 560), AnyView(SourcesView(projectSlug: slug, onOpen: { _ in }))))
            }
            shots.append(("mytasks", CGSize(width: 900, height: 560), AnyView(TasksView(scope: .brain))))
            shots.append(("timeline-all", CGSize(width: 900, height: 700), AnyView(BrainTimelineView(projectSlug: nil) { _, _ in })))
            // Sheets at their declared ideal size and at their minimum (CONTRACT §15.3).
            shots.append(("email", CGSize(width: 760, height: 520),
                          AnyView(AddEmailSheet(request: EmailRequest(threadKey: nil, projectSlug: slug), initialText: email ?? ""))))
            shots.append(("email-min", CGSize(width: 640, height: 440),
                          AnyView(AddEmailSheet(request: EmailRequest(threadKey: nil, projectSlug: slug), initialText: email ?? ""))))
            if let source {
                shots.append(("export", CGSize(width: 540, height: 520), AnyView(ExportSheet(request: ExportRequest(target: .source(source))))))
                shots.append(("source-tasks", CGSize(width: 600, height: 560), AnyView(SourceTasksSheet(source: source))))
                shots.append(("change-date", CGSize(width: 460, height: 320), AnyView(ChangeDateSheet(source: source))))
            }
            if let thread = state.engine.emailThreads(projectSlug: nil).first {
                shots.append(("thread", CGSize(width: 680, height: 520), AnyView(ThreadSheet(threadKey: thread.key))))
                shots.append(("thread-min", CGSize(width: 560, height: 420), AnyView(ThreadSheet(threadKey: thread.key))))
            }
            shots.append(("note", CGSize(width: 560, height: 520), AnyView(NoteSheet(projectSlug: slug))))
            shots.append(("menubar", CGSize(width: 360, height: 600), AnyView(MenuBarView())))
            // MARK: v0.6 capture (§16.10): the quick capture panel empty, on a link, a pasted email and dropped files.
            @MainActor func capture(_ text: String, files: [URL] = []) -> AnyView {
                AnyView(QuickCaptureView(model: QuickCaptureModel(state: state, text: text, files: files))
                    .frame(width: QuickCapturePanel.width).fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: .infinity, alignment: .top))
            }
            shots.append(("capture", CGSize(width: 520, height: 250), capture("")))
            shots.append(("capture-note", CGSize(width: 520, height: 250),
                          capture("Llamar a Laura el jueves: quiere ver la propuesta con el descuento por volumen antes del comité.")))
            shots.append(("capture-link", CGSize(width: 520, height: 250), capture("https://www.contoso.com/blog/2026/plan-de-migracion")))
            shots.append(("capture-email", CGSize(width: 520, height: 280), capture("""
                De: Laura Méndez <laura@acmelogistics.com>
                Enviado: martes, 27 de octubre de 2026 10:14
                Para: Jaime <jaime@dive.ai>
                Asunto: Propuesta de rutas

                Hola Jaime, te mando los números que pediste.
                """)))
            shots.append(("capture-files", CGSize(width: 520, height: 320), capture("", files: [
                URL(fileURLWithPath: "/tmp/Propuesta Acme Logistics v3 (final, con descuentos por volumen).pdf"),
                URL(fileURLWithPath: "/tmp/Llamada con Laura.m4a"), URL(fileURLWithPath: "/tmp/notas.txt"),
                URL(fileURLWithPath: "/tmp/presupuesto.xlsx")])))
            // v0.3 (CONTRACT §12.6); run with SB_DEMO_ACCOUNTS=1 for mail/meetings with data.
            shots.append(("graph", CGSize(width: 1000, height: 680),
                          AnyView(GraphView(scope: Scope(projectSlug: project?.slug), onOpen: { _ in }))))
            shots.append(("graph-all", CGSize(width: 1000, height: 680), AnyView(GraphView(scope: .brain, onOpen: { _ in }))))
            shots.append(("mail", CGSize(width: 1000, height: 640), AnyView(MailView())))
            shots.append(("meetings", CGSize(width: 1000, height: 640), AnyView(MeetingsView())))
            shots.append(("meetings-week", CGSize(width: 1000, height: 640), AnyView(MeetingsView(initialSegment: .week))))   // MARK: v0.3 meetings
            shots.append(("meetings-past", CGSize(width: 1000, height: 640), AnyView(MeetingsView(initialSegment: .past))))
            if let account = state.engine.accounts.accounts.first,
               let event = try? await state.engine.accounts.provider(for: account)
                   .events(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(7 * 86_400)).first {
                shots.append(("prep", CGSize(width: 760, height: 640), AnyView(MeetingPrepView(event: event))))
            }
            // Ajustes on each tab: RulesSnapshots.settingsShots (settings-<tab>, settings-<tab>-min).
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
            shots.append(("github-trust", CGSize(width: 460, height: 470), AnyView(GitHubConnectSheet())))
            shots.append(("github-code", CGSize(width: 460, height: 400), AnyView(GitHubConnectSheet(preview: .code(GitHubDeviceCode(
                deviceCode: "demo", userCode: "ABCD-1234", verificationURI: URL(string: "https://github.com/login/device")!,
                expiresAt: Date().addingTimeInterval(900), interval: 5))))))
            shots.append(("github-org", CGSize(width: 560, height: 520), AnyView(GitHubOrgHelpSheet())))
            // Integration: the project screen with its tab bar (the sidebar lives in window-* now).
            if let project {
                shots.append(("web-project", CGSize(width: 1100, height: 720), AnyView(ProjectView(project: project))))
                // §15.5: the Contenido tab on each list.
                shots.append(("content-by-date", CGSize(width: 880, height: 600), AnyView(ProjectContentView(
                    project: project, selection: .constant(nil), initialMode: .byDate))))
                shots.append(("content-by-topic", CGSize(width: 880, height: 600), AnyView(ProjectContentView(
                    project: project, selection: .constant(nil), initialMode: .byTopic))))
            }
            // MARK: v0.5 shell (CONTRACT §15.5): Inicio, ⌘K, the recording control, the project sheet.
            await SearchIndex.shared.rebuild(state: state)
            shots.append(("home", CGSize(width: 900, height: 900), AnyView(HomeView())))
            shots.append(("home-narrow", CGSize(width: 680, height: 900), AnyView(HomeView())))
            shots.append(("home-empty", CGSize(width: 900, height: 620), AnyView(HomeView(previewEmpty: true))))
            shots.append(("search", CGSize(width: 760, height: 600), AnyView(SearchPalette(initialQuery: "comi"))))
            shots.append(("search-empty", CGSize(width: 760, height: 420), AnyView(SearchPalette())))
            // v0.6 search: full text (rows found by their page's text carry a snippet; "Ver n más").
            shots.append(("search-text", CGSize(width: 760, height: 620), AnyView(SearchPalette(initialQuery: "presupuesto"))))
            shots.append(("search-narrow", CGSize(width: 480, height: 600), AnyView(SearchPalette(initialQuery: "presupuesto"))))
            // The sidebar footer at its default width (220): the meeting card, a plain "Grabar", recording, an error.
            // When Grabar takes the footer (a meeting on, recording), "+ Agregar" sits under it as a secondary button
            // (§16.1), as in SidebarFooter.
            func footer(_ preview: RecordControlPreview?) -> AnyView {
                AnyView(VStack(alignment: .leading, spacing: 4) {
                    RecordControl(placement: .sidebar, preview: preview)
                    if preview != .plain { AddControl(secondary: true) }
                    QueueStatusLine(showsProgressBar: false)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .background(Brand.color.bg))
            }
            shots.append(("record-control", CGSize(width: 220, height: 170), footer(nil)))
            shots.append(("record-control-280", CGSize(width: 280, height: 170), footer(nil)))
            shots.append(("record-control-plain", CGSize(width: 220, height: 130), footer(.plain)))
            shots.append(("record-control-recording", CGSize(width: 220, height: 170), footer(.recording)))
            shots.append(("record-control-error", CGSize(width: 220, height: 170), footer(.plain)))
            shots.append(("new-project", CGSize(width: 480, height: 440), AnyView(NewProjectSheet())))
            if let project {
                shots.append(("edit-project", CGSize(width: 480, height: 440), AnyView(NewProjectSheet(editing: project))))
            }
            // MARK: v0.3 graph — focused graph + web views need a run loop and WKWebView.takeSnapshot.
            if let topic = await state.engine.graph(projectSlug: nil).nodes.filter({ $0.kind == .topic }).max(by: { $0.links < $1.links }) {
                shots.append(("graph-focus", CGSize(width: 1000, height: 680), AnyView(GraphView(scope: .brain, focus: topic.id, onOpen: { _ in }))))
                // v0.6 graph (§16.5): a project's graph with a global person selected and its ficha panel, at the
                // 700 pt minimum detail width.
                if let slug = topic.projectSlug,
                   let person = await state.engine.graph(projectSlug: slug).nodes.filter({ $0.kind == .person }).max(by: { $0.links < $1.links }) {
                    shots.append(("graph-project-focus", CGSize(width: 700, height: 600),
                                  AnyView(GraphView(scope: .project(slug), focus: person.id, onOpen: { _ in }))))
                }
                if let slug = topic.projectSlug {   // the wiki page header with "Ver en el grafo"
                    shots.append(("graph-wiki", CGSize(width: 1000, height: 400),
                                  AnyView(WikiBrowser(scope: .project(slug), selection: .constant(topic.id)))))
                }
            }
            shots += await RulesSnapshots.shots(state: state)   // MARK: v0.4 rules
            shots += CorrectionsModel.snapshotShots(state: state)   // MARK: v0.6 facts — editor + "Revisar cambios"
            let only = ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] ?? ""   // e.g. "graph": just those shots
            // v0.5 shell: these also render dark ("<name>-dark").
            var darkToo: Set<String> = ["home", "home-empty", "search", "search-empty", "search-text", "record-control", "record-control-plain",
                                        "record-control-recording", "record-control-error", "menubar", "new-project",
                                        "content-by-date", "content-by-topic", "capture", "capture-email"]
            darkToo.formUnion(CorrectionsModel.snapshotDarkNames)   // MARK: v0.6 facts
            for (name, size, view) in shots where only.isEmpty || name.hasPrefix(only) {
                for dark in darkToo.contains(name) ? [false, true] : [false] {
                    let file = dir.appendingPathComponent(name + (dark ? "-dark" : "") + ".png")
                    if name == "record-control-error" { state.recordingError = L("record.needsPermission") }
                    defer { if name == "record-control-error" { state.recordingError = nil } }
                    let previous = NSApp.appearance
                    NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    defer { NSApp.appearance = previous }
                    if name.hasPrefix("graph") || name.hasPrefix("web-") || name.hasPrefix("content-") {   // views with a WKWebView
                        await GraphSnapshot.render(view.environment(state), size: size, to: file)
                        continue
                    }
                    await render(view.environment(state), size: size, dark: dark, to: file)
                }
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
        // ⌘K finds meetings by their page's title, also without a source record on this Mac (§15.2).
        await SearchIndex.shared.rebuild(state: state)
        let found = SearchIndex.shared.results(for: "comi")
        let meetings = found.first { $0.group == .meetings }?.items.map(\.title) ?? []
        log("search comi → \(found.map { "\($0.group.rawValue)=\($0.items.map(\.title))" }.joined(separator: " "))")
        log("search comi meetings \(meetings.contains("Comité de la alianza") ? "PASS" : "FAIL")")
        let ids = SearchIndex.shared.items.map(\.id)
        log("search ids unique \(Set(ids).count == ids.count ? "PASS" : "FAIL (\(ids.count - Set(ids).count) dup)")")
    }

    /// "onboarding-accounts" and "onboarding-accounts-next" (after pressing Return = the primary button).
    private static func renderOnboardingAccounts(state: AppState, dir: URL) async {
        let size = CGSize(width: 760, height: 620)
        let host = NSHostingView(rootView: OnboardingView(initialStep: .accounts).environment(state)
            .frame(width: size.width, height: size.height).brandEnvironment())
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

    /// Every sidebar item inside the real `MainView` (NavigationSplitView, toolbar, tab bar, sidebar footer), and the
    /// project on each tab (`window-project-<tab>-…`), all through the router. `min` = the minimum window.
    private static func renderWindows(state: AppState, dir: URL) async {
        var items: [(name: String, item: SidebarItem, tab: ProjectTab?)] = [
            ("home", .home, nil), ("ask", .ask, nil), ("graph", .graph, nil), ("tasks", .tasks, nil),
            ("people", .people, nil), ("files", .files, nil), ("mail", .mail, nil), ("meetings", .meetings, nil), ("unassigned", .unassigned, nil),
        ]
        if let project = state.projects.first {
            items.append(("project", .project(project.slug), nil))
            let tabs: [(String, ProjectTab)] = [("summary", .summary), ("content", .content), ("files", .files), ("ask", .ask), ("graph", .graph),
                                                ("tasks", .tasks), ("people", .people)]
            for (tabName, tab) in tabs { items.append(("project-\(tabName)", .project(project.slug), tab)) }
            items.append(("project-ask-thread", .project(project.slug), .ask))   // MARK: v0.6 ask — list + inspector
        }
        items.append(("ask-thread", .ask, nil))   // MARK: v0.6 ask
        // ⌘K over Inicio (the palette inside the real window, with its query).
        items.append(("search", .home, nil))
        // MARK: v0.6 entity — fichas (§16.13): a person's global ficha (Personas), the same person filtered to the
        // first project (pushed over its Resumen), and a global page's ficha in Inicio.
        var fichas: [String: Destination] = [:]
        if let project = state.projects.first {
            let snap = EntityIndex.shared(vaultRoot: state.engine.vault.root).refresh()
            if let person = snap.people(ofProject: project.slug).first {
                fichas["entity-global"] = .entity(person.path, .brain)
                fichas["entity-filtered"] = .entity(person.path, .project(project.slug))
                items.append(("entity-global", .people, nil))
                items.append(("entity-filtered", .project(project.slug), nil))
            }
            if snap.entity("index.md") != nil {
                fichas["entity-home"] = .entity("index.md", .brain)
                items.append(("entity-home", .home, nil))
            }
        }
        // v0.6 tasks: Pendientes with Proyecto / Persona / Buscar set (§16.13 "Pendientes con filtros").
        items.append(("tasks-filtered", .tasks, nil))
        let only = ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] ?? ""
        for entry in items where only.isEmpty || entry.name.hasPrefix(only) {
            for (sizeName, size) in [("1100", CGSize(width: 1100, height: 720)), ("min", CGSize(width: 920, height: 620))] {
                for dark in [false, true] {
                    if let destination = fichas[entry.name] {
                        if entry.name == "entity-filtered", case .project(let slug) = entry.item {
                            state.navigate(to: .projectTab(slug, .summary))
                        }
                        state.navigate(to: destination)
                    } else if case .project(let slug) = entry.item, let tab = entry.tab {
                        state.navigate(to: .projectTab(slug, tab))
                    } else {
                        state.navigate(to: .sidebar(entry.item))
                    }
                    state.searchPresented = false   // "search" lays its own palette (with a query) over the window
                    if entry.name.hasSuffix("ask-thread") {   // MARK: v0.6 ask
                        AskSnapshots.seed(state: state, scope: entry.tab == nil ? .brain : Scope(projectSlug: state.currentProjectSlug))
                    }
                    TaskFilterStore.shared.filter = entry.name == "tasks-filtered" ? snapshotTaskFilter(state) : TaskFilter()
                    let file = "window-\(entry.name)-\(sizeName)-\(dark ? "dark" : "light").png"
                    let view = entry.name == "search"
                        ? AnyView(ZStack { MainView(); SearchPalette(initialQuery: "comi") })
                        : AnyView(MainView())
                    await renderWindow(view.environment(state), size: size, dark: dark, to: dir.appendingPathComponent(file))
                }
            }
        }
    }

    /// Two projects and "Lo que me debe Elena" (a demo-vault person with tasks in two projects): the filter bar set.
    private static func snapshotTaskFilter(_ state: AppState) -> TaskFilter {
        TaskFilter(projects: Set(state.projects.prefix(2).map(\.slug)),
                   person: TaskPerson(slug: "elena-castro", name: "Elena Castro"), relation: .owesMe)
    }

    private static func renderWindow(_ view: some View, size: CGSize, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).brandEnvironment())
        host.frame = CGRect(origin: .zero, size: size)
        // The whole app switches appearance (as AppState.applyAppearance does): AppKit-backed controls inside the
        // hosting view only follow NSApp.appearance when rendered offscreen.
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        defer { NSApp.appearance = previous }
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.backgroundColor = Brand.nsColor(dark ? 0x202721 : 0xF5F0E8)   // Brand bg
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.contentView = nil
    }

    private static func render(_ view: some View, size: CGSize, dark: Bool = false, to url: URL) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Brand.color.surface).brandEnvironment())
        host.frame = CGRect(origin: .zero, size: size)
        // An offscreen, never-ordered-in window gives the view a real layout/appearance context.
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
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
