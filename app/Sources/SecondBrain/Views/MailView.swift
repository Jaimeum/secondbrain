import BrainCore
import SwiftUI

/// Sidebar "Correo" (CONTRACT §12.4 + §12.7): the connected inbox on the left, the message on the right with one
/// smart "Agregar a …" button. Read only: nothing is sent, moved or deleted in the mailbox.
struct MailView: View {
    @Environment(AppState.self) private var state
    @ViewState private var model: MailModel

    init(model: MailModel? = nil) {
        _model = ViewState(initialValue: model ?? MailModel())
    }

    private var hasMailAccounts: Bool {
        !state.engine.accounts.mailAccounts.isEmpty
    }

    var body: some View {
        Group {
            if !hasMailAccounts {
                ConnectAccountsEmptyState(symbol: "envelope", title: L("mail.empty.title"), message: L("mail.empty.message"),
                                          secondaryTitle: L("mail.pasteInstead"), secondaryAction: { state.requestEmail() },
                                          context: .mail)
            } else {
                HSplitView {
                    MailListPane(model: model)
                        .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
                    MailDetailView(model: model)
                        .frame(minWidth: 400, maxWidth: .infinity)
                        .overlay(alignment: .bottom) {
                            if let toast = model.toast {
                                MailToastView(toast: toast) { model.undo() }
                                    .padding(.bottom, 78)   // floats above the action bar
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                        .animation(.snappy(duration: 0.25), value: model.toast)
                }
            }
        }
        .navigationTitle(L("mail.title"))
        .navigationSubtitle(L("mail.subtitle"))
        .toolbar {
            ToolbarItem {
                Button { state.requestEmail() } label: { Label(L("mail.paste"), systemImage: "doc.on.clipboard") }
                    .help(L("mail.paste"))
            }
        }
        .task(id: hasMailAccounts) { if hasMailAccounts { model.start(state: state) } }
        .onChange(of: state.accountsRevision) { model.accountsChanged() }
        .onChange(of: state.vaultRevision) { model.refreshKnown() }
        .alert(L("activity.conflictTitle"), isPresented: Binding(get: { model.undoConflict != nil },
                                                                set: { if !$0 { model.undoConflict = nil } })) {
            Button(L("activity.undoAnyway"), role: .destructive) {
                if let conflict = model.undoConflict { model.forceUndo(conflict) }
            }
            Button(L("common.cancel"), role: .cancel) { model.undoConflict = nil }
        } message: {
            Text(L("activity.conflictMessage",
                   model.undoConflict?.paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") ?? ""))
        }
    }
}

// MARK: - List

private struct MailListPane: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MailModel
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.accounts.count > 1 {
                Picker(L("mail.account"), selection: Binding(get: { model.account?.id ?? "" }, set: { model.selectAccount($0) })) {
                    ForEach(model.accounts) { account in Text(account.email).tag(account.id) }
                }
                .labelsHidden()
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L("mail.search"), text: $model.query)
                    .textFieldStyle(.plain)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Text(model.query.isEmpty ? L("mail.inboxWindow") : L("mail.results", model.query))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Picker("", selection: Binding(get: { model.filter }, set: { model.setFilter($0) })) {
                    Text(L("mail.filter.known")).tag(MailModel.Filter.known)
                    Text(L("mail.filter.all")).tag(MailModel.Filter.all)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
        }
        .padding(10)
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure {
            failureView(failure)
        } else if model.isLoading && model.messages.isEmpty {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(L("mail.loading")).font(.callout).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if model.messages.isEmpty {
            EmptyStateView(symbol: model.query.isEmpty ? "tray" : "magnifyingglass",
                           title: model.query.isEmpty ? L("mail.nothingNew") : L("mail.noResults"),
                           message: model.query.isEmpty ? L("mail.nothingNew.message") : "")
        } else {
            list
        }
    }

    private var list: some View {
        let index = brainIndex
        return List(selection: Binding(get: { model.selectedId }, set: { model.select($0) })) {
            ForEach(model.visibleMessages) { message in
                MailRow(message: message, isMine: model.accounts.contains { $0.email == message.from.email },
                        source: index[message.id], model: model)
                    .tag(message.id)
            }
            if model.filter == .known, model.hiddenCount > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    if model.visibleMessages.isEmpty {
                        Text(L("mail.noKnown")).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(L("mail.hiddenUnknown", model.hiddenCount)).font(.caption).foregroundStyle(.secondary)
                    }
                    Button(L("mail.showAll")) { model.setFilter(.all) }.buttonStyle(.link).font(.callout)
                }
                .padding(.vertical, 6)
                .selectionDisabled()
            }
            if model.nextToken != nil {
                HStack {
                    Spacer()
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Button(L("mail.loadMore")) { model.loadMore() }
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
                .selectionDisabled()
            }
        }
        .listStyle(.inset)
    }

    /// Message id → its source, for the "✓ en el cerebro" chips (one pass over the sources per render).
    private var brainIndex: [String: SourceRecord] {
        guard let account = model.account else { return [:] }
        let prefix = account.provider.rawValue + ":"
        var out: [String: SourceRecord] = [:]
        for src in state.engine.sources {
            if let ext = src.externalId, ext.hasPrefix(prefix) { out[String(ext.dropFirst(prefix.count))] = src }
        }
        return out
    }

    @ViewBuilder private func failureView(_ failure: MailModel.Failure) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch failure {
            case .reconnect(let provider):
                Label(L("mail.reconnect.title", provider.displayName), systemImage: "person.crop.circle.badge.exclamationmark")
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("mail.reconnect")) { connector.start(provider, state: state) }
                    .buttonStyle(.borderedProminent)
                    .sheet(item: Bindable(connector).flow) { _ in TrustSheet(connector: connector, context: .mail) }
                if let error = connector.error {
                    Text(error).font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            case .organization(let provider):
                Label(L("accounts.consentRequired"), systemImage: "building.2")
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: provider) }
                    .buttonStyle(.borderedProminent)
                Button(L("mail.pasteInstead")) { state.requestEmail() }.buttonStyle(.link)
            case .other(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("mail.retry")) { model.load(force: true) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MailRow: View {
    let message: MailMessageSummary
    let isMine: Bool
    let source: SourceRecord?
    let model: MailModel

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Circle()
                .fill(message.isRead ? Color.clear : Color.accentColor)
                .frame(width: 7, height: 7)
                .padding(.top, 5)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isMine ? L("mail.you") : message.from.display)
                        .font(.body.weight(message.isRead ? .medium : .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Fmt.relative(message.date))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 4) {
                    Text(message.subject.isEmpty ? L("mail.noSubject") : message.subject)
                        .font(.callout).lineLimit(1)
                    if message.hasAttachments {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(.secondary)
                            .help(L("mail.attachments"))
                    }
                }
                Text(message.snippet)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(2)
                if let source {
                    InBrainChip(source: source, model: model)
                        .padding(.top, 3)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

/// "✓ en el cerebro" with its menu: Ver en el proyecto · Quitar.
struct InBrainChip: View {
    let source: SourceRecord
    let model: MailModel
    @ViewState private var confirmRemove = false

    var body: some View {
        Menu {
            Button(L("mail.openInProject")) { model.open(source) }
            Divider()
            Button(L("mail.remove"), role: .destructive) {
                if source.status == .done { confirmRemove = true } else { model.remove(source) }
            }
        } label: {
            Chip(text: L("mail.inBrain"), tint: .green)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .confirmationDialog(L("mail.removeConfirm"), isPresented: $confirmRemove) {
            Button(L("mail.remove"), role: .destructive) { model.remove(source) }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("mail.removeConfirm.message"))
        }
    }
}

/// "Aprendiendo del correo… · Deshacer" at the bottom.
private struct MailToastView: View {
    let toast: MailModel.Toast
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            if toast.undoable {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            }
            Text(toast.text).font(.callout)
            if toast.undoable {
                Text("·").foregroundStyle(.tertiary)
                Button(L("mail.undo"), action: onUndo)
                    .buttonStyle(.link)
                    .font(.callout.weight(.medium))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
    }
}
