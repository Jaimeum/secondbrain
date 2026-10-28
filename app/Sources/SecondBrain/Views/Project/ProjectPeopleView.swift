import BrainCore
import SwiftUI

/// A project's "Personas" tab (CONTRACT §16.2): the people linked to the project (graph edges + `project.json`
/// `people.include/exclude`), with role, company, last contact and number of sources; a click opens the person's
/// ficha filtered to the project; "+ Agregar persona" and "Quitar del proyecto".
/// v0.6: filled in by B (entity pages). Placeholder until then.
struct ProjectPeopleView: View {
    let project: Project

    var body: some View {
        EmptyStateView(symbol: ProjectTab.people.symbol, title: L("sidebar.people"), message: "")
            .background(Brand.color.surface)
    }
}
