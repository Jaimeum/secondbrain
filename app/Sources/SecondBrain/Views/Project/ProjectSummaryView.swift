import BrainCore
import SwiftUI

/// A project's "Resumen" tab (CONTRACT §16.2), its default: the project's ficha (§16.4) with "En breve"
/// (`overview.md`), recent decisions, upcoming dates, people, recent activity and my open tasks.
/// v0.6: filled in by B (entity pages). Placeholder until then.
struct ProjectSummaryView: View {
    @Environment(AppState.self) private var state
    let project: Project

    var body: some View {
        EmptyStateView(symbol: ProjectTab.summary.symbol, title: "\(project.emoji) \(project.name)",
                       message: project.description, actionTitle: L("tabs.content")) {
            state.navigate(to: .projectTab(project.slug, .content))
        }
        .background(Brand.color.surface)
    }
}
