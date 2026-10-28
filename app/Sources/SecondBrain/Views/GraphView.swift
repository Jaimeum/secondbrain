import AppKit
import BrainCore
import SwiftUI
import WebKit

/// Grafo (CONTRACT §12.2 + §12.7, v0.6 §16.5): how everything the brain learned connects, one view for both scopes.
/// `.brain` is the sidebar's Grafo, colored by project (soft halos, a name at each cluster); `.project` is the project
/// tab, colored by kind (chips filter) and holding the global people and companies linked to the project. No scope
/// switch. One click selects a node: it is highlighted and its ficha opens in the side panel (`GraphNodePanel`)
/// without leaving the graph; "Abrir" in the panel, or a double click, goes to the full ficha (§16.4). The time strip
/// replays how the brain grew. Rendering lives in `web/graph.*` (canvas + D3).
/// `focus` = a vault-relative page to select on arrival ("Ver en el grafo"); `onOpen` opens a page (default: the
/// router, in this scope).
struct GraphView: View {
    @Environment(AppState.self) private var state
    let scope: Scope
    var focus: String? = nil
    var onOpen: ((String) -> Void)? = nil

    @ViewState private var loaded: GraphPayloadData?
    @ViewState private var controller = GraphController()
    /// The selected node (a click in the graph, "Ver en el grafo", a row of the panel): highlighted in the graph and
    /// shown in the side panel. Swift owns it; the page reports the user's clicks (`sbgraph://select/<id>`).
    @ViewState private var selected: String?

    /// The side panel's width: the graph keeps ≥ 400 pt next to it at the 700 pt minimum detail width (§15.3).
    static let panelWidth: CGFloat = 300

    var body: some View {
        Group {
            if let loaded, loaded.knowledgeCount > 0 {
                HStack(spacing: 0) {
                    GraphWebView(data: loaded, payload: payloadBase(), focus: selected, controller: controller,
                                 onOpen: open, onSelect: { selected = $0 })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(alignment: .topLeading) {
                            // ⌘F: the page also listens, but the web view does not always get the key first.
                            Button("") { controller.toggleSearch() }
                                .keyboardShortcut("f", modifiers: .command)
                                .opacity(0)
                                .frame(width: 0, height: 0)
                                .accessibilityHidden(true)
                        }
                    if let id = selected, let node = loaded.nodes[id] {
                        Rectangle().fill(Brand.color.line).frame(width: 1)
                        GraphNodePanel(node: node, neighbours: loaded.neighbours(of: id, limit: 6), scope: scope,
                                       projects: state.projects,
                                       isNode: { loaded.nodes[$0] != nil },
                                       onOpen: open, onSelect: { selected = $0 }, onClose: { selected = nil })
                            .frame(width: Self.panelWidth)
                    }
                }
            } else if loaded == nil {
                BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if projectSlug != nil {
                // No extra "Grabar" here (§15.2: one record control); "+ Agregar" is in the toolbar.
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: L("graph.empty.title"),
                               message: L("graph.emptyAny.message"), actionTitle: L("graph.empty.seeContent")) {
                    if let slug = projectSlug { state.navigate(to: .projectTab(slug, .content)) }
                }
            } else {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: L("graph.empty.title"),
                               message: L("graph.emptyAny.message"))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
        .onAppear {
            if selected == nil { selected = Self.nodeId(for: focus) }
            consumePendingFocus()
        }
        .onChange(of: focus) { _, new in if let id = Self.nodeId(for: new) { selected = id } }
        .onChange(of: state.pendingGraphFocus) { consumePendingFocus() }
        .task(id: TaskKey(revision: state.vaultRevision, scope: scopeKey)) {
            let graph = await state.engine.graph(projectSlug: projectSlug)
            let data = await Task.detached(priority: .userInitiated) { GraphPayloadData(graph) }.value
            guard !Task.isCancelled else { return }
            if data != loaded { loaded = data }
        }
    }

    private struct TaskKey: Hashable { let revision: Int; let scope: String }

    private var projectSlug: String? { scope.projectSlug }

    private var scopeKey: String { projectSlug.map { "project:\($0)" } ?? "global" }

    /// "Abrir" / double click (§16.4): the full ficha where it lives. A project hub is the project's ficha (Resumen);
    /// inside a project (`onOpen` set by ProjectView) it is the project's overview in Contenido.
    private func open(_ id: String) {
        if id.hasPrefix("project:") {
            let slug = String(id.dropFirst("project:".count))
            if let onOpen { onOpen("projects/\(slug)/wiki/overview.md") } else { state.navigate(to: .projectTab(slug, .summary)) }
            return
        }
        if let onOpen { onOpen(id) } else { state.navigate(to: .entity(id, scope)) }
    }

    /// The sidebar's Grafo takes "Ver en el grafo" from `pendingGraphFocus` (a project's tab gets it from ProjectView
    /// through `focus`). Selecting the node also opens its panel.
    private func consumePendingFocus() {
        guard projectSlug == nil, state.selection == .graph, let page = state.pendingGraphFocus else { return }
        state.pendingGraphFocus = nil
        selected = Self.nodeId(for: page)
    }

    /// The graph node a page stands for: a project's index page has no node of its own, it is the project hub.
    static func nodeId(for page: String?) -> String? {
        guard let page else { return nil }
        let parts = page.split(separator: "/")
        if parts.count == 4, parts[0] == "projects", parts[2] == "wiki", parts[3] == "index.md" { return "project:\(parts[1])" }
        return page
    }

    /// Everything but nodes/edges: labels, palette, flags.
    private func payloadBase() -> [String: Any] {
        var singular: [String: String] = [:]
        var plural: [String: String] = [:]
        for k in GraphKindStyle.all {
            singular[k.rawValue] = L("graph.kind.\(k.rawValue)")
            plural[k.rawValue] = L("graph.kinds.\(k.rawValue)")
        }
        let labels: [String: Any] = [
            "lang": Localizer.language,
            "kinds": singular, "kindsPlural": plural,
            "open": L("graph.open"), "openOverview": L("graph.openOverview"),
            "links": L("graph.links"), "showAll": L("graph.showAll"), "fit": L("graph.fit"), "search": L("graph.search"),
            "play": L("graph.play"), "today": L("graph.today"), "hint": L("graph.hint.panel"), "close": L("graph.close"),
            "connected": L("graph.connected"), "matches": L("graph.matches"), "noMatches": L("graph.noMatches"),
            "overview": L("graph.overviewLabel"),
        ]
        let projects = state.projects.map { p -> [String: Any] in
            ["slug": p.slug, "name": p.name, "emoji": p.emoji, "color": GraphPalette.hex(slug: p.slug)]
        }
        return [
            "labels": labels,
            "colorBy": projectSlug == nil ? "project" : "kind",
            "projects": projects,
            "scopeKey": scopeKey,
            "today": Date().timeIntervalSince1970 * 1000,
            "hint": !UserDefaults.standard.bool(forKey: GraphSession.hintDismissedKey),
            // The ficha of the selected node is Swift's side panel (§16.5): the page's own peek card stays hidden.
            "panel": true,
            // Snapshots settle the layout at once; SB_GRAPH_LIVE=1 keeps the live behaviour (replay) to capture it.
            "snapshot": DebugSnapshots.directory != nil && ProcessInfo.processInfo.environment["SB_GRAPH_LIVE"] != "1",
        ]
    }
}

/// Every kind the graph draws, with its SF Symbol (the same icons `graph.js` draws as inline SVG).
enum GraphKindStyle {
    static let all: [GraphNodeKind] = [.project, .meeting, .email, .document, .note, .url, .person, .org, .topic, .decision,
                                       .question, .task, .page,
                                       .repo]   // MARK: v0.4 github

    static func symbol(_ kind: GraphNodeKind) -> String {
        switch kind {
        case .project: "folder"
        case .meeting: "waveform"
        case .email: "envelope"
        case .document: "doc.text"
        case .note: "note.text"
        case .url: "link"
        case .person: "person"
        case .org: "building.2"
        case .topic: "lightbulb"
        case .decision: "checkmark.seal"
        case .question: "questionmark.bubble"
        case .task: "checklist"
        case .page: "doc"
        case .repo: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// A project's tone in the graph: the brand's categorical palette by a stable hash of the slug (`Brand.projectHex`),
/// the same color the sidebar and project chips use. This is the only place the web graph gets project colors from:
/// `graph.js` never hashes, it uses `projects[].color` as sent.
enum GraphPalette {
    static func hex(slug: String) -> String { Brand.projectHex(slug: slug) }
}

@MainActor
enum GraphSession {
    /// The "watch it grow" replay plays the first time a graph opens in each launch.
    static var replayed = false
    static let hintDismissedKey = "graph.hintDismissed"
}

/// Nodes and edges serialized once, off the main thread (thousands of nodes), and compared cheaply on reload (by the
/// JSON alone: the lookups below are derived from it).
struct GraphPayloadData: Equatable, Sendable {
    let json: String
    let nodeCount: Int
    /// Pages that are knowledge (not just a project and its empty overview/tasks/timeline): 0 = empty state.
    let knowledgeCount: Int
    /// The side panel's lookups: every node by id and each node's neighbours.
    let nodes: [String: GraphNode]
    private let adjacency: [String: [String]]

    static func == (a: GraphPayloadData, b: GraphPayloadData) -> Bool { a.json == b.json }

    /// What the node is connected to, most connected first (the panel's "Conectado con").
    func neighbours(of id: String, limit: Int = 8) -> [GraphNode] {
        (adjacency[id] ?? []).compactMap { nodes[$0] }
            .sorted { ($0.links, $1.title) > ($1.links, $0.title) }
            .prefix(limit).map { $0 }
    }

    init(_ graph: KnowledgeGraph) {
        struct Node: Encodable { let id, title, kind: String; let project: String?; let date: Double?; let links: Int }
        struct Edge: Encodable { let source, target: String; let weight: Int }
        struct Body: Encodable { let nodes: [Node]; let edges: [Edge] }
        let body = Body(
            nodes: graph.nodes.map {
                Node(id: $0.id, title: $0.title, kind: $0.kind.rawValue, project: $0.projectSlug,
                     date: $0.date.map { $0.timeIntervalSince1970 * 1000 }, links: $0.links)
            },
            edges: graph.edges.map { Edge(source: $0.source, target: $0.target, weight: $0.weight) })
        json = (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"nodes":[],"edges":[]}"#
        nodeCount = graph.nodes.count
        knowledgeCount = graph.nodes.filter { $0.kind != .page && $0.kind != .project }.count
        nodes = Dictionary(graph.nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var adjacency: [String: [String]] = [:]
        for e in graph.edges {
            adjacency[e.source, default: []].append(e.target)
            adjacency[e.target, default: []].append(e.source)
        }
        self.adjacency = adjacency
    }
}

/// Lets SwiftUI (the ⌘F shortcut) talk to the page.
@MainActor
final class GraphController {
    weak var webView: WKWebView?
    func toggleSearch() { webView?.evaluateJavaScript("SB.toggleSearch()") }
}

/// The WKWebView that hosts `graph.html`. Sends `SB.render(payload)` when the graph changes, `SB.focus(id)` when the
/// focus changes and `SB.setTheme` when the appearance changes; receives `sbgraph://open/<id>` and, when the user
/// selects a node in the page, `sbgraph://select/<id>` (empty = nothing selected).
struct GraphWebView: NSViewRepresentable {
    let data: GraphPayloadData
    let payload: [String: Any]
    /// The selected node; nil = none.
    let focus: String?
    let controller: GraphController
    var onOpen: (String) -> Void
    var onSelect: (String?) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> GraphWKWebView {
        let webView = GraphWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.sendTheme() }
        let dir = AppResources.webDirectory
        webView.loadFileURL(dir.appendingPathComponent("graph.html"), allowingReadAccessTo: dir)
        context.coordinator.webView = webView
        controller.webView = webView
        return webView
    }

    func updateNSView(_ webView: GraphWKWebView, context: Context) {
        context.coordinator.parent = self
        controller.webView = webView
        context.coordinator.update()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: GraphWebView
        weak var webView: GraphWKWebView?
        private var loaded = false
        private var sentData: GraphPayloadData?
        private var sentScope: String?
        private var sentFocus: String?
        private var sentLanguage: String?

        init(parent: GraphWebView) { self.parent = parent }

        func update() {
            guard loaded, let webView else { return }
            let scope = parent.payload["scopeKey"] as? String
            if parent.data != sentData || scope != sentScope || Localizer.language != sentLanguage {
                var payload = parent.payload
                payload["theme"] = theme(of: webView)
                // Only a new selection moves the view: a reload under the same selection keeps it where it is.
                let newFocus = sentData == nil || parent.focus != sentFocus
                payload["focus"] = newFocus ? parent.focus ?? NSNull() : NSNull()
                let replay = !GraphSession.replayed && parent.focus == nil && !(payload["snapshot"] as? Bool ?? false)
                payload["replay"] = replay
                if replay { GraphSession.replayed = true }
                guard let extra = try? JSONSerialization.data(withJSONObject: payload),
                      let extraJSON = String(data: extra, encoding: .utf8) else { return }
                webView.evaluateJavaScript("SB.render(Object.assign(\(parent.data.json), \(extraJSON)))")
                if parent.focus == nil, sentFocus != nil { webView.evaluateJavaScript("SB.focus(null)") }
                sentData = parent.data
                sentScope = scope
                sentFocus = parent.focus
                sentLanguage = Localizer.language
            } else if parent.focus != sentFocus {
                sentFocus = parent.focus
                let arg = parent.focus.flatMap { try? JSONSerialization.data(withJSONObject: [$0], options: [.fragmentsAllowed]) }
                    .flatMap { String(data: $0, encoding: .utf8) }.map { String($0.dropFirst().dropLast()) } ?? "null"
                webView.evaluateJavaScript("SB.focus(\(arg))")
            }
        }

        func sendTheme() {
            guard loaded, let webView else { return }
            webView.evaluateJavaScript("SB.setTheme('\(theme(of: webView))')")
        }

        /// The web view follows the window's appearance (the app may force light/dark): tell the page explicitly.
        private func theme(of view: NSView) -> String {
            view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            update()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }
            if url.scheme == "sbgraph" {
                let rest = url.absoluteString.replacingOccurrences(of: "sbgraph://", with: "")
                if rest.hasPrefix("open/"), let path = String(rest.dropFirst(5)).removingPercentEncoding {
                    parent.onOpen(path)
                } else if rest.hasPrefix("select/"), let id = String(rest.dropFirst(7)).removingPercentEncoding {
                    // The page already shows this selection: remember it so it is not sent back.
                    sentFocus = id.isEmpty ? nil : id
                    parent.onSelect(sentFocus)
                } else if rest.hasPrefix("hint-dismissed") {
                    UserDefaults.standard.set(true, forKey: GraphSession.hintDismissedKey)
                }
                return decisionHandler(.cancel)
            }
            if url.isFileURL, url.lastPathComponent == "graph.html" { return decisionHandler(.allow) }
            decisionHandler(.cancel)
        }
    }
}

/// A WKWebView that reports appearance changes (Ajustes → Apariencia switches without a reload).
final class GraphWKWebView: WKWebView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

// MARK: - Snapshots (development only, SB_SNAPSHOT_DIR)

@MainActor
enum GraphSnapshot {
    /// Renders a view that contains the graph web view: needs a real run loop and `WKWebView.takeSnapshot`, since
    /// `cacheDisplay` does not capture web content. Waits for the page to lay out and draw.
    static func render(_ view: some View, size: CGSize, to url: URL, wait: Double = 6) async {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height)
            .background(Brand.color.surface).brandEnvironment())
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(for: .seconds(Double(ProcessInfo.processInfo.environment["SB_GRAPH_WAIT"] ?? "") ?? wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        // Every web view in the tree (the graph, and the page in its side panel), drawn over the cached SwiftUI layer.
        let webs = findWebViews(in: host)
        if let graph = webs.first(where: { $0 is GraphWKWebView }) {
            if let bench = try? await graph.evaluateJavaScript("SB.bench()") as? String {
                print("GRAPH BENCH \(url.lastPathComponent): \(bench)")
            }
            if ProcessInfo.processInfo.environment["SB_GRAPH_SELFCHECK"] == "1",
               let check = try? await graph.evaluateJavaScript("SB.selfcheck()") as? String {
                print("GRAPH CHECK \(url.lastPathComponent): \(check)")
            }
        }
        var shots: [(NSImage, CGRect)] = []
        for web in webs {
            if let shot = try? await web.takeSnapshot(configuration: WKSnapshotConfiguration()) {
                shots.append((shot, web.convert(web.bounds, to: host)))
            }
        }
        let composed = NSImage(size: size)
        composed.lockFocus()
        rep.draw(in: CGRect(origin: .zero, size: size))
        for (shot, frame) in shots {
            // `host` is flipped (SwiftUI); AppKit drawing here is not.
            let y = host.isFlipped ? size.height - frame.maxY : frame.minY
            shot.draw(in: CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
        }
        composed.unlockFocus()
        if let tiff = composed.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
        window.orderOut(nil)
        window.contentView = nil
    }

    private static func findWebViews(in view: NSView) -> [WKWebView] {
        if let web = view as? WKWebView { return [web] }
        return view.subviews.flatMap { findWebViews(in: $0) }
    }
}
