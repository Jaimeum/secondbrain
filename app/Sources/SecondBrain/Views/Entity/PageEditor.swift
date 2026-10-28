import BrainCore
import SwiftUI

/// "Editar" on any wiki page or ficha (CONTRACT §16.6), presented by MainView while `AppState.editingPage` is set.
/// v0.6: filled in by D (edit/propagate/facts) — markdown editor (monospaced, front-matter folded), Guardar ⌘S /
/// Cancelar esc, a Historial entry with before/after, then `/propagate` and the "Revisar cambios en el cerebro" sheet.
/// For now: the page's markdown, read-only, and Cancelar.
struct PageEditorHost: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String

    @ViewState private var text = ""
    @ViewState private var title = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Brand.spacing.s) {
                Image(systemName: "pencil").foregroundStyle(Brand.color.text2)
                Text(title)
                    .font(Brand.section)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(title)
                Spacer(minLength: Brand.spacing.s)
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandSecondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, Brand.spacing.l)
            .padding(.vertical, Brand.spacing.m)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ScrollView {
                Text(text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(Brand.color.text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Brand.spacing.l)
            }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 620, idealWidth: 760, minHeight: 420, idealHeight: 520)
        .task(id: path) {
            let vault = state.engine.vault, path = self.path
            let loaded = await Task.detached { (vault.title(of: path), (try? String(contentsOf: vault.url(for: path), encoding: .utf8)) ?? "") }.value
            title = loaded.0
            text = loaded.1
        }
    }
}
