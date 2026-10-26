import AppKit
import BrainCore
import SwiftUI
import WebKit

/// "Grafo" tab (CONTRACT §12.2 + §12.7): how everything the brain learned connects. The whole brain is colored by
/// project (soft halos, a name at each cluster); inside a project, by kind (chips filter). One click focuses a node and
/// opens its peek card; the time strip replays how the brain grew. Rendering lives in `web/graph.*` (canvas + D3).
/// `focus` = a vault-relative page to center on ("Ver en el grafo"); `onOpen` opens a page.
struct GraphView: View {
    @Environment(AppState.self) private var state
    let scope: WikiScope
    var focus: String?
    var onOpen: (String) -> Void

    @ViewState private var loaded: GraphPayloadData?
    @ViewState private var controller = GraphController()

    var body: some View {
        Group {
            if let loaded, loaded.knowledgeCount > 0 {
                GraphWebView(data: loaded, payload: payloadBase(), focus: graphFocus, controller: controller, onOpen: onOpen)
                    .background(alignment: .topLeading) {
                        // ⌘F: the page also listens, but the web view does not always get the key first.
                        Button("") { controller.toggleSearch() }
                            .keyboardShortcut("f", modifiers: .command)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .accessibilityHidden(true)
                    }
            } else if loaded == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                EmptyStateView(symbol: "point.3.connected.trianglepath.dotted", title: L("graph.empty.title"),
                               message: L("graph.empty.message"), actionTitle: L("record.start")) {
                    if case .project(let slug) = scope { state.recordingProjectSlug = slug }
                    state.toggleRecording()
                }
            }
        }
        .task(id: TaskKey(revision: state.vaultRevision, scope: scopeKey)) {
            let graph = await state.engine.graph(projectSlug: projectSlug)
            let data = await Task.detached(priority: .userInitiated) { GraphPayloadData(graph) }.value
            guard !Task.isCancelled else { return }
            if data != loaded { loaded = data }
        }
    }

    private struct TaskKey: Hashable { let revision: Int; let scope: String }

    private var projectSlug: String? {
        if case .project(let slug) = scope { return slug }
        return nil
    }

    private var scopeKey: String { projectSlug.map { "project:\($0)" } ?? "global" }

    /// A project's index page has no node of its own: it stands for the project hub.
    private var graphFocus: String? {
        guard let focus else { return nil }
        let parts = focus.split(separator: "/")
        if parts.count == 4, parts[0] == "projects", parts[2] == "wiki", parts[3] == "index.md" { return "project:\(parts[1])" }
        return focus
    }

    /// Everything but nodes/edges: labels, palette, flags.
    private func payloadBase() -> [String: Any] {
        let kinds: [GraphNodeKind] = [.project, .meeting, .email, .document, .note, .url, .person, .topic, .decision, .question, .task, .page]
        var singular: [String: String] = [:]
        var plural: [String: String] = [:]
        for k in kinds {
            singular[k.rawValue] = L("graph.kind.\(k.rawValue)")
            plural[k.rawValue] = L("graph.kinds.\(k.rawValue)")
        }
        let labels: [String: Any] = [
            "lang": Localizer.language,
            "kinds": singular, "kindsPlural": plural,
            "open": L("graph.open"), "openOverview": L("graph.openOverview"),
            "links": L("graph.links"), "showAll": L("graph.showAll"), "fit": L("graph.fit"), "search": L("graph.search"),
            "play": L("graph.play"), "today": L("graph.today"), "hint": L("graph.hint"), "close": L("graph.close"),
            "connected": L("graph.connected"), "matches": L("graph.matches"), "noMatches": L("graph.noMatches"),
        ]
        let projects = state.projects.enumerated().map { i, p -> [String: Any] in
            ["slug": p.slug, "name": p.name, "emoji": p.emoji, "color": GraphPalette.colors[i % GraphPalette.colors.count]]
        }
        return [
            "labels": labels,
            "colorBy": projectSlug == nil ? "project" : "kind",
            "projects": projects,
            "scopeKey": scopeKey,
            "today": Date().timeIntervalSince1970 * 1000,
            "hint": !UserDefaults.standard.bool(forKey: GraphSession.hintDismissedKey),
            // Snapshots settle the layout at once; SB_GRAPH_LIVE=1 keeps the live behaviour (replay) to capture it.
            "snapshot": DebugSnapshots.directory != nil && ProcessInfo.processInfo.environment["SB_GRAPH_LIVE"] != "1",
        ]
    }
}

/// Same 10 colors as `graph.js` (`PALETTE`), one per project in creation order.
enum GraphPalette {
    static let colors = ["#6e56cf", "#12a594", "#f76b15", "#d6409f", "#0090ff", "#30a46c", "#e5484d", "#05a2c2", "#ad7f58", "#8e4ec6"]
}

@MainActor
enum GraphSession {
    /// The "watch it grow" replay plays the first time a graph opens in each launch.
    static var replayed = false
    static let hintDismissedKey = "graph.hintDismissed"
}

/// Nodes and edges serialized once, off the main thread (thousands of nodes), and compared cheaply on reload.
struct GraphPayloadData: Equatable, Sendable {
    let json: String
    let nodeCount: Int
    /// Pages that are knowledge (not just a project and its empty overview/tasks/timeline): 0 = empty state.
    let knowledgeCount: Int

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
    }
}

/// Lets SwiftUI (the ⌘F shortcut) talk to the page.
@MainActor
final class GraphController {
    weak var webView: WKWebView?
    func toggleSearch() { webView?.evaluateJavaScript("SB.toggleSearch()") }
}

/// The WKWebView that hosts `graph.html`. Sends `SB.render(payload)` when the graph changes, `SB.focus(id)` when the
/// focus changes and `SB.setTheme` when the appearance changes; receives `sbgraph://open/<path>`.
struct GraphWebView: NSViewRepresentable {
    let data: GraphPayloadData
    let payload: [String: Any]
    let focus: String?
    let controller: GraphController
    var onOpen: (String) -> Void

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
                payload["focus"] = parent.focus ?? NSNull()
                let replay = !GraphSession.replayed && parent.focus == nil && !(payload["snapshot"] as? Bool ?? false)
                payload["replay"] = replay
                if replay { GraphSession.replayed = true }
                guard let extra = try? JSONSerialization.data(withJSONObject: payload),
                      let extraJSON = String(data: extra, encoding: .utf8) else { return }
                webView.evaluateJavaScript("SB.render(Object.assign(\(parent.data.json), \(extraJSON)))")
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
            .background(Color(nsColor: .windowBackgroundColor)))
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
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        if let web = findWebView(in: host) {
            if let bench = try? await web.evaluateJavaScript("SB.bench()") as? String {
                print("GRAPH BENCH \(url.lastPathComponent): \(bench)")
            }
            if ProcessInfo.processInfo.environment["SB_GRAPH_SELFCHECK"] == "1",
               let check = try? await web.evaluateJavaScript("SB.selfcheck()") as? String {
                print("GRAPH CHECK \(url.lastPathComponent): \(check)")
            }
            let config = WKSnapshotConfiguration()
            if let shot = try? await web.takeSnapshot(configuration: config) {
                let frame = web.convert(web.bounds, to: host)
                let composed = NSImage(size: size)
                composed.lockFocus()
                rep.draw(in: CGRect(origin: .zero, size: size))
                // `host` is flipped (SwiftUI); AppKit drawing here is not.
                let y = host.isFlipped ? size.height - frame.maxY : frame.minY
                shot.draw(in: CGRect(x: frame.minX, y: y, width: frame.width, height: frame.height))
                composed.unlockFocus()
                if let tiff = composed.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
                   let png = bmp.representation(using: .png, properties: [:]) {
                    try? png.write(to: url)
                }
                window.orderOut(nil)
                window.contentView = nil
                return
            }
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
        window.contentView = nil
    }

    private static func findWebView(in view: NSView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for sub in view.subviews { if let web = findWebView(in: sub) { return web } }
        return nil
    }
}
