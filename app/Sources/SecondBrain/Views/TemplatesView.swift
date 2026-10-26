import AppKit
import BrainCore
import SwiftUI
import WebKit

/// "Formatos": how Claude writes the summary of each meeting or email. List, preview, edit, duplicate,
/// create with AI, and set as a project's default.
struct TemplatesView: View {
    @Environment(AppState.self) private var state

    @ViewState private var selection: String?
    @ViewState private var editing: TemplateInfo?
    @ViewState private var showMake = false
    @ViewState private var pendingDelete: TemplateInfo?
    @ViewState private var error: String?

    private var selected: TemplateInfo? { state.template(selection) }

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $selection) {
                SwiftUI.Section(L("tpl.mine")) {
                    ForEach(state.templates.filter { !$0.isBuiltIn }) { row($0) }
                    if !state.templates.contains(where: { !$0.isBuiltIn }) {
                        Text(L("tpl.noneYet")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                SwiftUI.Section(L("tpl.builtin")) {
                    ForEach(state.templates.filter(\.isBuiltIn)) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 260)
            Divider()
            if let editing {
                TemplateEditor(original: editing) { saved in
                    self.editing = nil
                    if let saved { selection = saved.id }
                }
                .id(editing.id)
            } else if let selected {
                detail(selected)
            } else {
                EmptyStateView(symbol: "doc.richtext", title: L("tpl.pickOne"), message: L("tpl.explain"))
            }
        }
        .navigationTitle(L("tpl.title"))
        .navigationSubtitle(L("tpl.subtitle"))
        .toolbar {
            ToolbarItemGroup {
                Button {
                    editing = TemplateInfo(id: "", name: "", description: "", scope: .meeting, isBuiltIn: false,
                                           body: TemplateEditor.blankBody)
                } label: {
                    Label(L("tpl.new"), systemImage: "plus")
                }
                .help(L("tpl.new"))
                Button { showMake = true } label: { Label(L("tpl.makeAI"), systemImage: "sparkles") }
                    .help(L("tpl.makeAIHelp"))
            }
        }
        .onAppear {
            state.reloadTemplates()
            if selection == nil { selection = state.templates.first?.id }
        }
        .sheet(isPresented: $showMake) {
            MakeTemplateSheet { id in
                state.reloadTemplates()
                if let id { selection = id }
            }
        }
        .confirmationDialog(L("tpl.deleteConfirm", pendingDelete?.name ?? ""),
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button(L("sources.delete"), role: .destructive) {
                if let t = pendingDelete {
                    do {
                        try state.engine.deleteTemplate(id: t.id)
                        state.reloadTemplates()
                        selection = state.templates.first?.id
                    } catch { self.error = FriendlyError.message(error) }
                }
                pendingDelete = nil
            }
        } message: {
            Text(L("tpl.deleteMessage"))
        }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    private func row(_ t: TemplateInfo) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(t.name).lineLimit(1)
                if usedAsDefault(t) > 0 {
                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow)
                        .help(L("tpl.defaultIn", usedAsDefault(t)))
                }
            }
            Text(t.scope.label).font(.caption).foregroundStyle(.secondary)
        }
        .tag(Optional(t.id))
    }

    private func usedAsDefault(_ t: TemplateInfo) -> Int {
        state.projects.filter { $0.defaultTemplate == t.id }.count
    }

    private func detail(_ t: TemplateInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(t.name).font(.title2.weight(.semibold))
                        if t.isBuiltIn { Chip(text: L("tpl.builtinBadge"), symbol: "shippingbox") }
                        Chip(text: t.scope.label)
                    }
                    if !t.description.isEmpty {
                        Text(t.description).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Menu {
                    ForEach(state.projects) { project in
                        Button {
                            setDefault(project, t)
                        } label: {
                            if project.defaultTemplate == t.id {
                                Label("\(project.emoji) \(project.name)", systemImage: "checkmark")
                            } else {
                                Text("\(project.emoji) \(project.name)")
                            }
                        }
                    }
                } label: {
                    Label(L("tpl.useAsDefault"), systemImage: "star")
                }
                .fixedSize()
                .disabled(state.projects.isEmpty)
                Button(t.isBuiltIn ? L("tpl.editCopy") : L("tpl.edit")) { editing = t }
                    .help(t.isBuiltIn ? L("tpl.editCopyHelp") : "")
                Menu {
                    Button(L("tpl.duplicate")) { duplicate(t) }
                    if !t.isBuiltIn {
                        Divider()
                        Button(L("sources.delete"), role: .destructive) { pendingDelete = t }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(16)
            Divider()
            MarkdownPreview(markdown: TemplateEditor.previewMarkdown(t.body))
        }
    }

    private func setDefault(_ project: Project, _ t: TemplateInfo) {
        do {
            let newId = project.defaultTemplate == t.id ? nil : t.id
            try state.engine.setDefaultTemplate(projectSlug: project.slug, templateId: newId)
            state.reloadProjects()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    private func duplicate(_ t: TemplateInfo) {
        var copy = t
        copy.id = ""
        copy.isBuiltIn = false
        copy.name = L("tpl.copyOf", t.name)
        editing = copy
    }
}

/// Name, description, scope and the markdown structure, with a live rendered preview beside it.
struct TemplateEditor: View {
    @Environment(AppState.self) private var state
    let original: TemplateInfo
    var onDone: (TemplateInfo?) -> Void

    @ViewState private var draft = TemplateInfo(id: "", name: "", description: "", scope: .meeting, isBuiltIn: false, body: "")
    @ViewState private var preview = ""
    @ViewState private var error: String?
    @ViewState private var previewTask: Task<Void, Never>?

    static let blankBody = """
    ## En breve
    <!-- 3 a 5 viñetas con lo más importante -->

    ## Temas
    <!-- un subtítulo por tema, con lo que se dijo y quién lo dijo -->

    ## Acuerdos
    ### Mis compromisos
    ### Compromisos de los demás
    ### Acordado entre todos

    ## Próximos pasos
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField(L("tpl.name"), text: $draft.name).textFieldStyle(.roundedBorder).font(.title3)
                    Picker("", selection: $draft.scope) {
                        Text(TemplateScope.meeting.label).tag(TemplateScope.meeting)
                        Text(TemplateScope.email.label).tag(TemplateScope.email)
                        Text(TemplateScope.any.label).tag(TemplateScope.any)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                TextField(L("tpl.description"), text: $draft.description).textFieldStyle(.roundedBorder)
                if original.isBuiltIn {
                    Label(L("tpl.builtinCopyNote"), systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            HSplitView {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("tpl.structure")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    TextEditor(text: $draft.body)
                        .font(.system(size: 12.5, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.03))
                    Text(L("tpl.structureHint")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(minWidth: 280)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("tpl.preview")).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        .padding([.top, .leading], 12)
                    MarkdownPreview(markdown: preview)
                }
                .frame(minWidth: 280)
            }
            Divider()
            HStack {
                if let error { Text(error).foregroundStyle(.red).font(.callout) }
                Spacer()
                Button(L("common.cancel")) { onDone(nil) }.keyboardShortcut(.cancelAction)
                Button(L("tpl.save"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .onAppear {
            draft = original
            preview = Self.previewMarkdown(original.body)
        }
        .onChange(of: draft.body) {
            previewTask?.cancel()
            let body = draft.body
            previewTask = Task {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                preview = Self.previewMarkdown(body)
            }
        }
    }

    private func save() {
        do {
            let saved = try state.engine.saveTemplate(draft)
            state.reloadTemplates()
            onDone(saved)
        } catch {
            self.error = FriendlyError.message(error)
        }
    }

    /// Instructions for Claude live in `<!-- … -->`; the preview shows them as notes instead of hiding them.
    static func previewMarkdown(_ body: String) -> String {
        var text = body
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        return text.replacing(#/<!--\s*([\s\S]*?)\s*-->/#) { match in
            let lines = String(match.1).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return "*💬 " + lines.joined(separator: " ").replacingOccurrences(of: "*", with: "") + "*"
        }
    }
}

/// "Crear con IA": describe the format in plain words; Claude writes it (job `.makeTemplate`).
struct MakeTemplateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    var onFinished: (String?) -> Void

    @ViewState private var name = ""
    @ViewState private var description = ""
    /// Set once "Crear" was pressed: the jobs that existed before, so the new one can be found.
    @ViewState private var jobsBefore: Set<String>?
    @ViewState private var knownIds: Set<String> = []
    @ViewState private var sawJob = false
    @ViewState private var failed = false

    private var jobId: String? { jobsBefore == nil ? nil : (job?.id ?? "started") }

    private var job: Job? {
        guard let jobsBefore else { return nil }
        return state.engine.jobs.first { !jobsBefore.contains($0.id) && $0.kind == .makeTemplate }
    }

    /// The job ran and left the queue (done jobs are removed), or the new template already exists.
    private var finished: Bool {
        jobsBefore != nil && job == nil && (sawJob || state.templates.contains { !knownIds.contains($0.id) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("tpl.makeTitle")).font(.title2.weight(.semibold))
            Text(L("tpl.makeHint")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField(L("tpl.name"), text: $name, prompt: Text(L("tpl.makeNamePlaceholder")))
                .textFieldStyle(.roundedBorder)
                .disabled(jobId != nil)
            TextEditor(text: $description)
                .font(.body)
                .frame(minHeight: 140)
                .padding(6)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                .disabled(jobId != nil)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(L("tpl.makeDescPlaceholder")).foregroundStyle(.tertiary).padding(12).allowsHitTesting(false)
                    }
                }
            if jobId != nil {
                HStack(spacing: 8) {
                    if failed || job?.status == .failed {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text(job?.error ?? L("tpl.makeFailed")).font(.callout)
                    } else if finished {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        Text(L("tpl.makeDone")).font(.callout)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(job?.message ?? (job?.status == .running ? L("tpl.makeRunning") : L("tpl.makeQueued")))
                            .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            HStack {
                Spacer()
                if jobId == nil {
                    Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                    Button(L("tpl.makeGo"), action: make)
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                } else {
                    Button(finished ? L("common.done") : L("tpl.makeBackground")) {
                        finish()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .onChange(of: job?.id) {
            if job != nil { sawJob = true } else { state.reloadTemplates() }
        }
    }

    private func make() {
        knownIds = Set(state.templates.map(\.id))
        jobsBefore = Set(state.engine.jobs.map(\.id))
        state.engine.makeTemplate(fromDescription: description, name: name.trimmingCharacters(in: .whitespaces))
        if job != nil { sawJob = true }
    }

    private func finish() {
        state.reloadTemplates()
        let newId = state.templates.first { !knownIds.contains($0.id) }?.id
        onFinished(newId)
        dismiss()
    }
}

/// Renders a markdown string with the same look as the wiki (bundled markdown-it), no vault links.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        let dir = AppResources.webDirectory
        webView.loadFileURL(dir.appendingPathComponent("wiki.html"), allowingReadAccessTo: dir)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.show(markdown)
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var loaded = false
        private var pending: String?
        private var shown: String?

        func show(_ markdown: String) {
            pending = markdown
            flush()
        }

        private func flush() {
            guard loaded, let webView, let markdown = pending, markdown != shown else { return }
            shown = markdown
            let payload: [String: Any] = ["markdown": markdown, "keepScroll": true, "links": [:], "backlinks": [],
                                          "emptyText": L("tpl.previewEmpty")]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("SB.render(\(json))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
            if let url = action.request.url, url.isFileURL, url.lastPathComponent == "wiki.html" {
                return decisionHandler(.allow)
            }
            if let url = action.request.url, ["http", "https"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
            decisionHandler(.cancel)
        }
    }
}
