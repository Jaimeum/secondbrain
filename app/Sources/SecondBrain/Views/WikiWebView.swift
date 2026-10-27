import AppKit
import BrainCore
import SwiftUI
import WebKit

/// Renders a vault markdown page with the bundled markdown-it. `[[wikilinks]]` are resolved in Swift
/// (VaultStore.resolveWikilink) and come back as `sbwiki://page/<path>` navigations.
struct WikiWebView: NSViewRepresentable {
    let vault: VaultStore
    let path: String?
    /// Leave out the "Tipo" chip (the surrounding header already names the page).
    var hideType = false
    var onNavigate: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> WikiWKWebView {
        let webView = WikiWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        // A forced appearance (Ajustes → Apariencia) applies at once, like the graph (CONTRACT §12.7, §15.1 Tema).
        webView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.sendTheme() }
        webView.allowsMagnification = true
        let dir = AppResources.webDirectory
        webView.loadFileURL(dir.appendingPathComponent("wiki.html"), allowingReadAccessTo: dir)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WikiWKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.show(path)
    }

    static func dismantleNSView(_ webView: WikiWKWebView, coordinator: Coordinator) {
        coordinator.stopWatching()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: WikiWebView
        weak var webView: WikiWKWebView?
        private var loaded = false
        private var shownPath: String?
        private weak var shownVault: VaultStore?
        private var shownModified: Date?
        private var watchTimer: Timer?
        private var renderGeneration = 0

        init(parent: WikiWebView) { self.parent = parent }

        func show(_ path: String?) {
            // A different vault (switched in Settings) with the same relative path is a different page.
            guard path != shownPath || parent.vault !== shownVault else { return }
            shownPath = path
            shownVault = parent.vault
            render(keepScroll: false)
            startWatching()
        }

        private func modificationDate() -> Date? {
            guard let shownPath else { return nil }
            let url = parent.vault.url(for: shownPath)
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }

        private func startWatching() {
            watchTimer?.invalidate()
            watchTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.loaded, self.shownPath != nil else { return }
                    if self.modificationDate() != self.shownModified { self.render(keepScroll: true) }
                }
            }
        }

        func stopWatching() {
            watchTimer?.invalidate()
            watchTimer = nil
        }

        private func render(keepScroll: Bool) {
            guard loaded, let webView else { return }
            let vault = parent.vault
            var payload: [String: Any] = [
                "keepScroll": keepScroll,
                "backlinksTitle": L("wiki.backlinks"),
                // Only these keys become chips; anything else in the front matter stays hidden (wiki.js PROP_ORDER).
                "propLabels": Self.propLabels(),
                // Front-matter values in the user's words; "" hides a technical one (CONTRACT §12.7: no raw slugs).
                "propValues": [
                    "type": Dictionary(uniqueKeysWithValues: Self.typeValues.map { ($0, L("prop.type.\($0)")) })
                        .merging(Self.hiddenTypes.map { ($0, "") }) { a, _ in a },
                    "status": Dictionary(uniqueKeysWithValues: Self.statusValues.map { ($0, L("prop.status.\($0)")) }),
                ],
                "locale": Localizer.locale.identifier.replacingOccurrences(of: "_", with: "-"),
                "lang": Localizer.language,
                "theme": theme(of: webView),
                "path": shownPath ?? "",
                "hideType": parent.hideType,
            ]
            renderGeneration += 1
            let generation = renderGeneration
            guard let path = shownPath else {
                payload["markdown"] = ""
                payload["emptyText"] = L("wiki.noPageSelected")
                send(payload, to: webView)
                return
            }
            shownModified = modificationDate()
            payload["emptyText"] = L("wiki.emptyPage")
            // Resolving links and backlinks walks (and reads) the whole vault: keep it off the main thread.
            Task {
                let page = await Task.detached { () -> [String: Any] in
                    let markdown = (try? vault.read(path)) ?? ""
                    let targets = Self.wikilinkTargets(in: markdown)
                    let resolved = vault.resolveWikilinks(targets, from: path)  // already off the main thread
                    var links: [String: Any] = [:]
                    for target in targets { links[target] = resolved[target] ?? NSNull() }
                    let backlinks = vault.backlinks(to: path).filter { $0.path != path }.map { ["path": $0.path, "title": $0.title] }
                    // Project and people chips show names, not slugs.
                    let head = markdown.hasPrefix("---") ? String(markdown.prefix(4000)) : ""
                    var projectNames: [String: String] = [:]
                    if head.contains("\nproject:") || head.contains("\nprojects:") {
                        for p in ProjectManager(vaultRoot: vault.root).list() { projectNames[p.slug] = "\(p.emoji) \(p.name)" }
                    }
                    var peopleNames: [String: String] = [:]
                    if head.contains("\npeople:") {
                        for p in MeetingPeopleIndex.load(vault: vault).people { peopleNames[p.slug] = p.title }
                    }
                    return ["markdown": markdown, "links": links, "backlinks": backlinks,
                            "projectNames": projectNames, "peopleNames": peopleNames]
                }.value
                guard generation == renderGeneration, path == shownPath, let webView = self.webView else { return }
                send(payload.merging(page) { _, new in new }, to: webView)
            }
        }

        func sendTheme() {
            guard loaded, let webView else { return }
            webView.evaluateJavaScript("SB.setTheme('\(theme(of: webView))')")
        }

        /// The page follows the window's appearance (the app may force light/dark), not the system's.
        private func theme(of view: NSView) -> String {
            view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }

        /// Chip labels. `organization` / `projects` show only once their strings exist (a missing key returns itself).
        private static func propLabels() -> [String: String] {
            var labels = [
                "type": L("prop.type"), "date": L("prop.date"), "updated": L("prop.updated"),
                "status": L("prop.status"), "duration": L("prop.duration"),
                "project": L("prop.project"), "people": L("prop.people"), "role": L("prop.role"),
            ]
            let projects = L("prop.projects")
            labels["projects"] = projects == "prop.projects" ? L("prop.project") : projects
            let organization = L("prop.organization")
            if organization != "prop.organization" { labels["organization"] = organization }
            return labels
        }

        private func send(_ payload: [String: Any], to webView: WKWebView) {
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("SB.render(\(json))")
        }

        static let typeValues = ["meeting", "transcript", "email", "email-thread", "document", "note", "url", "person", "topic",
                                 "decision", "question", "overview", "timeline", "tasks", "template", "source"]
        static let hiddenTypes = ["index", "log", "health", "people"]
        static let statusValues = ["active", "paused", "done", "dropped", "proposed", "accepted", "superseded", "reversed",
                                   "open", "waiting", "closed", "answered", "processed"]

        nonisolated private static let wikilinkRegex = try! NSRegularExpression(pattern: #"\[\[([^\[\]\|#\n]+)(?:#[^\[\]\|\n]*)?(?:\|[^\[\]\n]*)?\]\]"#)

        nonisolated static func wikilinkTargets(in text: String) -> [String] {
            let ns = text as NSString
            return wikilinkRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map {
                ns.substring(with: $0.range(at: 1)).trimmingCharacters(in: .whitespaces)
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            render(keepScroll: false)
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            guard let url = action.request.url else { return decisionHandler(.cancel) }

            if url.scheme == "sbwiki" {
                let encoded = url.absoluteString.replacingOccurrences(of: "sbwiki://page/", with: "")
                if let path = encoded.removingPercentEncoding { parent.onNavigate(path) }
                return decisionHandler(.cancel)
            }
            if ["http", "https", "mailto"].contains(url.scheme ?? "") {
                NSWorkspace.shared.open(url)
                return decisionHandler(.cancel)
            }
            if url.isFileURL, url.lastPathComponent != "wiki.html" {
                // A plain markdown link like [x](other-page.md): resolve it like a wikilink (walks the vault: off main).
                let name = url.deletingPathExtension().lastPathComponent
                if let path = shownPath {
                    let vault = parent.vault
                    Task {
                        let resolved = await vault.resolveWikilinksAsync([name], from: path)
                        guard let target = resolved[name], vault === self.parent.vault else { return }
                        self.parent.onNavigate(target)
                    }
                }
                return decisionHandler(.cancel)
            }
            decisionHandler(.allow)
        }
    }
}

/// A WKWebView that reports appearance changes, so a forced light/dark reaches the page without a reload.
final class WikiWKWebView: WKWebView {
    var onAppearanceChange: (() -> Void)?

    /// Files dropped on a page belong to the surrounding view (Contenido imports them, CONTRACT §15.2), so the web
    /// view never registers as a drag destination.
    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}
