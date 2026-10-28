import BrainCore
import SwiftUI

/// "Agregar al proyecto" (CONTRACT §17.3): the big box at the top of Resumen — drop files and/or write or paste free
/// text, Agregar ⌘↩ imports them and runs `/file-dump`, and the last 10 drops show how they were filed.
// v0.7: filled in by dump (stub: draws nothing, so Resumen looks as before).
struct ProjectDropBox: View {
    @Environment(AppState.self) private var state
    let project: Project

    var body: some View {
        EmptyView()
    }
}
