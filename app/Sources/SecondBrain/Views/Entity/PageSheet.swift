import BrainCore
import SwiftUI

/// A vault page read in a sheet without leaving the screen (CONTRACT §16.4): used only where there is no navigation
/// stack (Correo, Reuniones, the global Pendientes, Sin asignar). Links navigate inside the sheet with Atrás (⌘[); "Abrir"
/// closes it and goes to the page's place through the router. Replaces v0.5's `VaultPageSheet` and
/// `PagePreviewSheet`. Sized per §15.3.
struct PageSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let path: String
    /// Overrides "Abrir" (default: `AppState.navigate(to: .entity(path, scope))`).
    var onOpen: ((String) -> Void)? = nil
    /// The place the sheet was opened from: "Abrir" opens the page in that context.
    var scope: Scope = .brain

    @ViewState private var stack: [String] = []
    @ViewState private var title = ""

    private var shown: String { stack.last ?? path }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: shown) { next in
                if next != shown { stack.append(next) }
            }
        }
        .background(Brand.color.surface)
        .frame(minWidth: 560, idealWidth: 680, minHeight: 420, idealHeight: 520)
        .task(id: shown) {
            let vault = state.engine.vault, page = shown
            title = await Task.detached { vault.title(of: page) }.value
        }
    }

    private var header: some View {
        HStack(spacing: Brand.spacing.s) {
            Button { _ = stack.popLast() } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Brand.color.text2)
            .keyboardShortcut("[", modifiers: .command)
            .disabled(stack.isEmpty)
            .opacity(stack.isEmpty ? 0 : 1)   // keeps its 22 pt: the title never shifts
            .accessibilityHidden(stack.isEmpty)
            .help(L("wiki.back"))
            Image(systemName: SourceLabels.symbol(forPath: shown)).foregroundStyle(Brand.color.text2)
            Text(title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(title)
            Spacer(minLength: Brand.spacing.s)
            // §16.6: Editar here too. The editor is presented by the main window, so this sheet closes first.
            if Corrections.isEditable(shown) {
                let edit = Button {
                    let target = shown
                    dismiss()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        state.editPage(target)
                    }
                } label: {
                    Label(L("entity.edit"), systemImage: "pencil")
                }
                .buttonStyle(.brandSecondary)
                .help(L("entity.editHelp"))
                ViewThatFits(in: .horizontal) {
                    edit
                    edit.labelStyle(.iconOnly)
                }
            }
            let open = Button {
                let target = shown
                dismiss()
                if let onOpen { onOpen(target) } else { state.navigate(to: .entity(target, scope)) }
            } label: {
                Label(L("page.open"), systemImage: "arrow.up.forward.square")
            }
            .buttonStyle(.brandSecondary)
            .help(L("page.openHelp"))
            ViewThatFits(in: .horizontal) {
                open
                open.labelStyle(.iconOnly)
            }
            Button(L("common.close")) { dismiss() }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }
}

/// `.sheet(item:)` wrapper for a vault path.
struct VaultPageItem: Identifiable, Equatable {
    let path: String
    var id: String { path }
}
