import BrainCore
import SwiftUI

/// "Your name": tells Claude who «Yo» is in every transcript (stored in the vault's people/README.md).
struct OwnerNameField: View {
    @Environment(AppState.self) private var state
    var showsHint = true
    @ViewState private var name = ""
    @ViewState private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("owner.label"), text: $name, prompt: Text(L("owner.placeholder")))
                .onSubmit(save)
            if showsHint {
                Text(L("owner.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            guard !loaded else { return }
            name = state.engine.vault.ownerName() ?? ""
            loaded = true
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard loaded, state.engineStarted else { return }
        try? state.engine.vault.setOwnerName(name)
    }
}
