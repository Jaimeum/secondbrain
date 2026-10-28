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
    @ViewState private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("owner.label")).font(Brand.callout).foregroundStyle(Brand.color.text)
            TextField("", text: $name, prompt: Text(L("owner.placeholder")))
                .onSubmit(save)
                .brandField()
            if let saveError { OwnerSaveError(message: saveError) }
            if showsHint {
                Text(L("owner.hint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.engineStarted) { load() }
        .onDisappear(perform: save)
        // Saved shortly after typing stops, not only on Return or when the field goes away.
        .task(id: name) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { save() }
        }
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
            saveError = nil
        } catch {
            saveError = FriendlyError.message(error)
        }
    }
}

/// The owner's addresses (people/README.md `- **Correo:**`): the connected accounts always count, so they're merged in
/// and shown as chips; the field holds only the other addresses.
@MainActor
enum OwnerAddresses {
    /// Addresses of the connected mail accounts (lowercased; the Mac Calendar has none).
    static func fromAccounts(_ state: AppState) -> [String] {
        state.engine.accounts.accounts
            .filter { $0.provider != .local && $0.email.contains("@") }
            .map { $0.email.lowercased() }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    }

    /// Makes sure every connected account's address is stored (pasted mail and meetings read only the stored list).
    static func merge(state: AppState) {
        guard state.engineStarted else { return }
        let vault = state.engine.vault
        let stored = vault.ownerEmails()
        let missing = fromAccounts(state).filter { !stored.contains($0) }
        guard !missing.isEmpty else { return }
        try? vault.setOwnerEmails(stored + missing)
    }
}

/// "Mis direcciones de correo": chips for the connected accounts, a field for any other address.
struct OwnerAddressesField: View {
    @Environment(AppState.self) private var state
    var showsHint = true
    @ViewState private var text = ""
    @ViewState private var loaded: String?
    @ViewState private var vault: VaultStore?
    @ViewState private var saveError: String?

    private var accountEmails: [String] { state.engineStarted ? OwnerAddresses.fromAccounts(state) : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("settings.ownerEmails")).font(Brand.callout).foregroundStyle(Brand.color.text)
            if !accountEmails.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(accountEmails, id: \.self) { email in
                        BrandChip(text: email, symbol: "checkmark")
                            .frame(maxWidth: 260, alignment: .leading)
                            .help(email)
                    }
                }
            }
            TextField("", text: $text, prompt: Text(accountEmails.isEmpty ? L("owner.emailsPlaceholder")
                                                                           : L("settings.ownerEmails.extraPlaceholder")))
                .onSubmit(save)
                .brandField()
            if let saveError { OwnerSaveError(message: saveError) }
            if showsHint {
                Text(accountEmails.isEmpty ? L("owner.emailsHint") : L("settings.ownerEmails.hint"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: load)
        .onChange(of: state.engineStarted) { load() }
        .onChange(of: state.accountsRevision) {
            OwnerAddresses.merge(state: state)
            reloadText()
        }
        .onDisappear(perform: save)
        .task(id: text) {
            try? await Task.sleep(for: .milliseconds(800))
            if !Task.isCancelled { save() }
        }
    }

    private func load() {
        guard vault == nil, state.engineStarted else { return }
        vault = state.engine.vault
        OwnerAddresses.merge(state: state)
        reloadText()
    }

    /// The field shows the stored addresses that aren't a connected account. Typed, unsaved input is saved first, so an
    /// account connecting meanwhile never wipes it.
    private func reloadText() {
        guard let vault else { return }
        if loaded != nil, text != loaded { save() }
        let accounts = Set(accountEmails)
        let extra = vault.ownerEmails().filter { !accounts.contains($0) }.joined(separator: ", ")
        text = extra
        loaded = extra
    }

    private func save() {
        guard let vault, text != loaded else { return }
        let typed = text.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "\n" })
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { $0.contains("@") }
        let accounts = vault === state.engine.vault ? accountEmails : []
        do {
            try vault.setOwnerEmails(accounts + typed.filter { !accounts.contains($0) })
            loaded = text
            saveError = nil
        } catch {
            saveError = FriendlyError.message(error)
        }
    }
}

/// "No pude guardar: …" under an owner field, in `warning`.
private struct OwnerSaveError: View {
    let message: String

    var body: some View {
        Label(L("owner.saveFailed", message), systemImage: "exclamationmark.triangle")
            .font(Brand.caption)
            .foregroundStyle(Brand.color.warning)
            .fixedSize(horizontal: false, vertical: true)
    }
}
