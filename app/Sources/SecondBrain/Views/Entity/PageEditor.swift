import AppKit
import BrainCore
import SwiftUI

/// "Editar" on any wiki page or ficha (CONTRACT §16.6), presented by MainView while `AppState.editingPage` is set.
/// A plain markdown editor (monospaced; the front-matter folded under "Propiedades"), Guardar ⌘S / Cancelar esc.
/// Saving writes the page with a Historial entry (Deshacer), closes, and hands the change to `CorrectionsModel`, which
/// asks `/propagate` for the other pages that still say what was corrected ("Revisar cambios en el cerebro").
struct PageEditorHost: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String

    @ViewState private var title = ""
    /// The text as read from disk (what the edit is compared with).
    @ViewState private var original = ""
    /// `---` … `---` block, without its delimiters (nil: the page has none).
    @ViewState private var frontMatter: String?
    @ViewState private var gap = ""
    @ViewState private var content = ""
    @ViewState private var showsFrontMatter = false
    @ViewState private var loaded = false
    @ViewState private var error: String?
    /// The page exists but isn't UTF-8 text: shown, never saved (saving would replace what can't be read).
    @ViewState private var unreadable = false
    /// The page changed on disk while editing (an ingest updated it): its text now. The footer offers Recargar
    /// (drop my edit, take the new page) or Guardar igual (my text wins, knowingly).
    @ViewState private var conflict: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            if !Corrections.isEditable(path) || unreadable {
                Text(L(unreadable ? "editor.notText" : "editor.notEditable"))
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if let yaml = frontMatter { frontMatterSection(yaml) }
                PlainTextEditor(text: $content)
                    .overlay { if !loaded { BrandLoader(size: 16) } }
                    .modifier(EditorTile(fill: Brand.color.card))
                footer
            }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 520)
        .task(id: path) { await load() }
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            Image(systemName: "pencil").foregroundStyle(Brand.color.text2)
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(L("common.cancel")) { dismiss() }
                .buttonStyle(.brandGhost)
                .keyboardShortcut(.cancelAction)
            Button(L("editor.save")) { save() }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!loaded || unreadable || !Corrections.isEditable(path))
                .help(L("editor.saveHelp"))
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }

    /// Front-matter folded by default: one line "Propiedades · n líneas"; unfolded, its own small editor.
    private func frontMatterSection(_ yaml: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(Brand.motion.animation(fast: true)) { showsFrontMatter.toggle() }
            } label: {
                HStack(spacing: Brand.spacing.xs) {
                    Image(systemName: showsFrontMatter ? "chevron.down" : "chevron.right")
                        .font(Brand.font(10, .semibold))
                        .frame(width: 12)
                    Text(L("editor.properties"))
                        .font(Brand.callout)
                    Text(L("editor.propertiesLines", yaml.components(separatedBy: "\n").count))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text3)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Brand.color.text2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, Brand.spacing.l)
            .padding(.vertical, Brand.spacing.s)
            if showsFrontMatter {
                PlainTextEditor(text: Binding(get: { frontMatter ?? "" }, set: { frontMatter = $0 }))
                    .frame(height: 140)
                    .modifier(EditorTile(fill: Brand.color.cardAlt))
                    .padding(.bottom, Brand.spacing.s)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Brand.spacing.s) {
            if conflict != nil {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                Text(L("editor.conflict"))
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(L("editor.reload")) { reload() }
                    .buttonStyle(.brandSecondary)
                    .help(L("editor.reloadHelp"))
                Button(L("editor.saveAnyway")) { save(over: conflict) }
                    .buttonStyle(.brandSecondary)
                    .help(L("editor.saveAnywayHelp"))
            } else if let error {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Brand.color.warning)
                Text(error)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(2)
            } else {
                Image(systemName: "sparkles").foregroundStyle(Brand.color.text3)
                Text(L("editor.propagateHint"))
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .font(Brand.caption)
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }

    private func load() async {
        let vault = state.engine.vault, path = self.path
        let (t, text, exists) = await Task.detached {
            (vault.title(of: path), try? vault.read(path), FileManager.default.fileExists(atPath: vault.url(for: path).path))
        }.value
        title = t
        unreadable = exists && text == nil
        show(text ?? "")
    }

    private func show(_ text: String) {
        original = text
        conflict = nil
        error = nil
        let parts = PageText.split(text)
        frontMatter = parts.frontMatter
        gap = parts.gap
        content = parts.body
        loaded = true
    }

    /// "Recargar" after a conflict: the page as it is now (my unsaved edit is dropped).
    private func reload() {
        guard let current = conflict else { return }
        show(current)
    }

    /// Saves over `original` (the text the editor started from); `over` = the page's text now, when the owner chose
    /// "Guardar igual" after a conflict (the diff for /propagate is then taken against it).
    private func save(over current: String? = nil) {
        guard !unreadable else { return }
        let text = PageText.join(PageText.Parts(frontMatter: frontMatter, gap: gap, body: content))
        let base = current ?? original
        guard text != base else {
            dismiss()
            return
        }
        do {
            try state.engine.saveHandEdit(path: path, text: text, basedOn: base)
            dismiss()
            CorrectionsModel.shared.start(state: state, path: path, before: base, after: text)
        } catch CorrectionError.changedOnDisk(let now) {
            conflict = now
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

/// A page split into its front-matter block and the rest, losslessly: `join(split(x)) == x`. `gap` is the closing
/// `---` line plus the blank lines after it (kept out of the editor so the body starts at its first line).
enum PageText {
    struct Parts {
        var frontMatter: String?
        var gap = ""
        var body: String
    }

    static func split(_ text: String) -> Parts {
        guard text.hasPrefix("---\n") else { return Parts(frontMatter: nil, body: text) }
        let lines = text.components(separatedBy: "\n")
        // A closing `---` on the last line (nothing after it, not even "\n") isn't split: joining would add a newline.
        guard let close = (1..<lines.count).first(where: { lines[$0].trimmingCharacters(in: .whitespaces) == "---" }),
              close < lines.count - 1 else {
            return Parts(frontMatter: nil, body: text)
        }
        var start = close + 1
        while start < lines.count - 1, lines[start].isEmpty { start += 1 }
        return Parts(frontMatter: lines[1..<close].joined(separator: "\n"),
                     gap: lines[close..<start].map { $0 + "\n" }.joined(),
                     body: lines[start...].joined(separator: "\n"))
    }

    static func join(_ parts: Parts) -> String {
        guard let frontMatter = parts.frontMatter else { return parts.body }
        return "---\n" + frontMatter + "\n" + parts.gap + parts.body
    }
}

/// Markdown is code-like: an NSTextView with the system's smart quotes, dashes and replacements off (they would break
/// YAML and wikilinks), monospaced, with undo.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let view = scroll.documentView as? NSTextView else { return scroll }
        view.delegate = context.coordinator
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .labelColor
        view.textContainerInset = NSSize(width: 12, height: 10)
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.smartInsertDeleteEnabled = false
        view.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? NSTextView, view.string != text else { return }
        view.string = text
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
        }
    }
}

/// A text editor inside the sheet as an inset rounded tile (`card` for the page, `cardAlt` for the properties) with a
/// `lineSoft` edge, so no full-bleed white area meets the sheet's edges (§15.1 calm surfaces).
private struct EditorTile: ViewModifier {
    let fill: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous)
        content
            .padding(10)
            .background(fill, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Brand.color.lineSoft, lineWidth: 1))
            .padding(.horizontal, Brand.spacing.l)
    }
}
