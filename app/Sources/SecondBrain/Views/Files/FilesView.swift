import BrainCore
import SwiftUI

/// Archivos (CONTRACT §17.2): every file of the brain (`.brain`, sidebar ⌘6) or of one project (`ProjectTab.files`) —
/// documents, images and saved email attachments — with search, filters, preview and "Descartados (n)".
// v0.7: filled in by files (stub: the empty state).
struct FilesView: View {
    @Environment(AppState.self) private var state
    let scope: Scope

    var body: some View {
        EmptyStateView(symbol: "doc.on.doc", title: L("files.empty.title"), message: L("files.empty.message"))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Brand.color.surface)
            .modifier(BrainTitle(isBrain: scope.isBrain))
    }
}

/// "Archivos" as the window title only in the sidebar item (a project keeps its own title).
private struct BrainTitle: ViewModifier {
    let isBrain: Bool
    func body(content: Content) -> some View {
        if isBrain { content.navigationTitle(L("sidebar.files")) } else { content }
    }
}
