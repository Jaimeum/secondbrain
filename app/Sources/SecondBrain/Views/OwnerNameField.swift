import BrainCore
import SwiftUI

/// "Your name": tells Claude who «Yo» is in every transcript (stored in the vault's people/README.md).
struct OwnerNameField: View {
    @Environment(AppState.self) private var state
    var showsHint = true
    @ViewState private var name = ""
    @ViewState private var loadedName: String?
    /// The vault the name was read from: after a vault switch, an edit still goes back to where it came from.
    @ViewState private var vault: VaultStore?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(L("owner.label"), text: $name, prompt: Text(L("owner.placeholder")))
                .onSubmit(save)
            if showsHint {
                Text(L("owner.hint")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.engineStarted) { load() }
        .onDisappear(perform: save)
    }

    private func load() {
        guard vault == nil, state.engineStarted else { return }
        let current = state.engine.vault
        vault = current
        let stored = current.ownerName() ?? ""
        name = stored
        loadedName = stored
    }

    private func save() {
        guard let vault, name != loadedName else { return }
        do {
            try vault.setOwnerName(name)
            loadedName = name
        } catch {}
    }
}
