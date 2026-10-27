import AppKit
import BrainCore
import SwiftUI
import WebKit

/// "Formatos" (Ajustes → Formatos, CONTRACT §15.2): how I write the summary of each meeting or email. A flexible list
/// (200–260) beside the preview; actions = "Usar por defecto ▾" · "Editar" · ⋯ (Duplicar, Crear con IA, Eliminar).
/// Editing hides the list and gives the editor the whole width.
struct TemplatesView: View {
    @Environment(AppState.self) private var state

    @ViewState private var selection: String?
    @ViewState private var editing: TemplateInfo?
    @ViewState private var showMake = false
    @ViewState private var pendingDelete: TemplateInfo?
    @ViewState private var error: String?

    private var selected: TemplateInfo? { state.template(selection) }

    var body: some View {
        Group {
            if let editing {
                TemplateEditor(original: editing) { saved in
                    self.editing = nil
                    if let saved { selection = saved.id }
                }
                .id(editing.id + editing.name)
            } else {
                HStack(spacing: 0) {
                    listColumn
                        .frame(minWidth: 200, idealWidth: 230, maxWidth: 260)
                    Rectangle().fill(Brand.color.line).frame(width: 1)
                    Group {
                        if let selected {
                            detail(selected)
                        } else {
                            EmptyStateView(symbol: "doc.richtext", title: L("tpl.pickOne"), message: L("tpl.explain"))
                        }
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                }
            }
        }
        .background(Brand.color.surface)
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

    // MARK: List

    private var listColumn: some View {
        VStack(spacing: 0) {
            // Plain header rows instead of Sections: the inset list pins section headers on an opaque white band.
            // No List selection: macOS paints it in the system accent (blue); rows draw `accentSoft` themselves.
            List {
                header(L("tpl.mine"))
                ForEach(state.templates.filter { !$0.isBuiltIn }) { row($0) }
                if !state.templates.contains(where: { !$0.isBuiltIn }) {
                    Text(L("tpl.noneYet"))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                        .listRowSeparator(.hidden)
                }
                header(L("tpl.builtin")).padding(.top, 8)
                ForEach(state.templates.filter(\.isBuiltIn)) { row($0) }
            }
            .listStyle(.inset)
            .alternatingRowBackgrounds(.disabled)
            .scrollContentBackground(.hidden)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack {
                Button {
                    editing = TemplateInfo(id: "", name: "", description: "", scope: .meeting, isBuiltIn: false,
                                           body: TemplateEditor.blankBody)
                } label: {
                    Label(L("tpl.new"), systemImage: "plus")
                }
                .buttonStyle(.brandSecondary)
                .help(L("tpl.new"))
                Spacer(minLength: 0)
            }
            .padding(10)
        }
        .background(Brand.color.surface)
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Brand.font(11, .semibold))
            .foregroundStyle(Brand.color.text2)
            .listRowSeparator(.hidden)
            .selectionDisabled()
    }

    private func row(_ t: TemplateInfo) -> some View {
        let isSelected = selection == t.id
        return Button { selection = t.id } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(t.name)
                        .font(isSelected ? Brand.callout : Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if usedAsDefault(t) > 0 {
                        Image(systemName: "star.fill")
                            .font(Brand.font(9))
                            .foregroundStyle(Brand.color.accent)
                            .help(L("tpl.defaultIn", usedAsDefault(t)))
                    }
                }
                Text(t.scope.label).font(Brand.caption).foregroundStyle(Brand.color.text2).lineLimit(1)
            }
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowSeparator(.hidden)
        .listRowBackground(
            RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                .fill(isSelected ? Brand.color.accentSoft : Color.clear)
                .padding(.horizontal, 8)
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func usedAsDefault(_ t: TemplateInfo) -> Int {
        state.projects.filter { $0.defaultTemplate == t.id }.count
    }

    // MARK: Detail

    private func detail(_ t: TemplateInfo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                // Title and actions share a line when they fit, otherwise the actions go under the title.
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 12) {
                        title(t)
                        Spacer(minLength: 8)
                        actions(t)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        title(t)
                        actions(t)
                    }
                }
                if !t.description.isEmpty {
                    Text(t.description)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }
            .padding(.horizontal, Brand.spacing.content)
            .padding(.vertical, 16)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            MarkdownPreview(markdown: TemplateEditor.previewMarkdown(t.body))
        }
    }

    private func title(_ t: TemplateInfo) -> some View {
        Text(t.name)
            .font(Brand.title)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .truncationMode(.tail)
            .layoutPriority(1)
    }

    @ViewBuilder private func actions(_ t: TemplateInfo) -> some View {
        HStack(spacing: 8) {
            let n = usedAsDefault(t)
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
                SettingsMenuLabel(title: n > 0 ? L("tpl.defaultIn", n) : L("tpl.useAsDefault"), symbol: n > 0 ? "star.fill" : "star")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(state.projects.isEmpty)
            Button(L("tpl.edit")) { editing = t }
                .buttonStyle(.brandPrimary)
                .help(t.isBuiltIn ? L("tpl.editCopyHelp") : "")
            Menu {
                Button(L("tpl.duplicate")) { duplicate(t) }
                Button(L("tpl.makeAI")) { showMake = true }
                if !t.isBuiltIn {
                    Divider()
                    Button(L("sources.delete"), role: .destructive) { pendingDelete = t }
                }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Brand.color.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help(L("rules.more"))
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

/// Name, description, scope and the markdown structure, with a live rendered preview: side by side from 700 pt,
/// otherwise one pane with "Editar | Vista previa".
struct TemplateEditor: View {
    @Environment(AppState.self) private var state
    let original: TemplateInfo
    var onDone: (TemplateInfo?) -> Void

    @ViewState private var draft = TemplateInfo(id: "", name: "", description: "", scope: .meeting, isBuiltIn: false, body: "")
    @ViewState private var preview = ""
    @ViewState private var error: String?
    @ViewState private var previewTask: Task<Void, Never>?
    @ViewState private var pane = Pane.edit

    private enum Pane: Hashable { case edit, preview }

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
                HStack(spacing: 8) {
                    TextField(L("tpl.name"), text: $draft.name)
                        .textFieldStyle(.roundedBorder)
                        .font(Brand.font(15, .medium))
                    Picker("", selection: $draft.scope) {
                        Text(TemplateScope.meeting.label).tag(TemplateScope.meeting)
                        Text(TemplateScope.email.label).tag(TemplateScope.email)
                        Text(TemplateScope.any.label).tag(TemplateScope.any)
                    }
                    .labelsHidden()
                    .frame(maxWidth: 200)
                }
                TextField(L("tpl.description"), text: $draft.description).textFieldStyle(.roundedBorder)
                if original.isBuiltIn {
                    Label(L("tpl.builtinCopyNote"), systemImage: "info.circle")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            GeometryReader { geo in
                if geo.size.width >= 700 {
                    HStack(spacing: 0) {
                        structurePane.frame(maxWidth: .infinity)
                        Rectangle().fill(Brand.color.line).frame(width: 1)
                        previewPane.frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Picker("", selection: $pane) {
                            Text(L("tpl.edit")).tag(Pane.edit)
                            Text(L("tpl.preview")).tag(Pane.preview)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        .padding([.top, .leading], 12)
                        if pane == .edit { structurePane } else { previewPane }
                    }
                }
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack(spacing: 8) {
                if let error {
                    Text(error).foregroundStyle(Brand.color.danger).font(Brand.caption).lineLimit(2)
                }
                Spacer()
                Button(L("common.cancel")) { onDone(nil) }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(L("tpl.save"), action: save)
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(12)
        }
        .background(Brand.color.surface)
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

    private var structurePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("tpl.structure")).font(Brand.font(11, .semibold)).foregroundStyle(Brand.color.text2)
            TextEditor(text: $draft.body)
                .font(Brand.mono)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
            Text(L("tpl.structureHint"))
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var previewPane: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("tpl.preview"))
                .font(Brand.font(11, .semibold))
                .foregroundStyle(Brand.color.text2)
                .padding([.top, .leading], 12)
            MarkdownPreview(markdown: preview)
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

    /// Instructions for me live in `<!-- … -->`; the preview shows them as italic notes instead of hiding them.
    static func previewMarkdown(_ body: String) -> String {
        var text = body
        if text.hasPrefix("---"), let end = text.range(of: "\n---", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
            text = String(text[end.upperBound...])
        }
        return text.replacing(#/<!--\s*([\s\S]*?)\s*-->/#) { match in
            let lines = String(match.1).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            return "*" + lines.joined(separator: " ").replacingOccurrences(of: "*", with: "") + "*"
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
            Text(L("tpl.makeTitle")).font(Brand.title).foregroundStyle(Brand.color.text)
            Text(L("tpl.makeHint")).foregroundStyle(Brand.color.text2).fixedSize(horizontal: false, vertical: true)
            TextField(L("tpl.name"), text: $name, prompt: Text(L("tpl.makeNamePlaceholder")))
                .textFieldStyle(.roundedBorder)
                .disabled(jobId != nil)
            TextEditor(text: $description)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 140)
                .padding(6)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
                .disabled(jobId != nil)
                .overlay(alignment: .topLeading) {
                    if description.isEmpty {
                        Text(L("tpl.makeDescPlaceholder")).foregroundStyle(Brand.color.text3).padding(12).allowsHitTesting(false)
                    }
                }
            if jobId != nil {
                HStack(spacing: 8) {
                    if failed || job?.status == .failed {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                        Text(job?.error ?? L("tpl.makeFailed")).foregroundStyle(Brand.color.text)
                    } else if finished {
                        Image(systemName: "checkmark.circle").foregroundStyle(Brand.color.success)
                        Text(L("tpl.makeDone")).foregroundStyle(Brand.color.text)
                    } else {
                        BrandLoader(size: 18,
                                    text: job?.message ?? (job?.status == .running ? L("tpl.makeRunning") : L("tpl.makeQueued")))
                    }
                }
            }
            HStack(spacing: 8) {
                Spacer()
                if jobId == nil {
                    Button(L("common.cancel")) { dismiss() }
                        .buttonStyle(.brandSecondary)
                        .keyboardShortcut(.cancelAction)
                    Button(L("tpl.makeGo"), action: make)
                        .buttonStyle(.brandPrimary)
                        .keyboardShortcut(.defaultAction)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                                  || description.trimmingCharacters(in: .whitespacesAndNewlines).count < 10)
                } else {
                    Button(finished ? L("common.done") : L("tpl.makeBackground")) {
                        finish()
                    }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 360, idealHeight: 440)
        .background(Brand.color.surface)
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

/// Renders a markdown string with the same look as the wiki (bundled markdown-it), no vault links. Follows the window's
/// light/dark appearance like `WikiWebView`.
struct MarkdownPreview: NSViewRepresentable {
    let markdown: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WikiWKWebView {
        let webView = WikiWKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.onAppearanceChange = { [weak coordinator = context.coordinator] in coordinator?.sendTheme() }
        let dir = AppResources.webDirectory
        webView.loadFileURL(dir.appendingPathComponent("wiki.html"), allowingReadAccessTo: dir)
        context.coordinator.webView = webView
        return webView
    }

    func updateNSView(_ webView: WikiWKWebView, context: Context) {
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

        func sendTheme() {
            guard loaded, let webView else { return }
            webView.evaluateJavaScript("SB.setTheme('\(Self.theme(of: webView))')")
        }

        /// The page follows the window's appearance (the app may force light/dark), not the system's.
        private static func theme(of view: NSView) -> String {
            view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? "dark" : "light"
        }

        private func flush() {
            guard loaded, let webView, let markdown = pending, markdown != shown else { return }
            shown = markdown
            let payload: [String: Any] = ["markdown": markdown, "keepScroll": true, "links": [:], "backlinks": [],
                                          "emptyText": L("tpl.previewEmpty"), "theme": Self.theme(of: webView)]
            guard let data = try? JSONSerialization.data(withJSONObject: payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("SB.render(\(json))")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            flush()
            sendTheme()
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
