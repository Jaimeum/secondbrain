import BrainCore
import SwiftUI

/// Sidebar "Correo" (CONTRACT §12.4 + §12.7 + §15.2): the connected inbox on the left, the message on the right with
/// one smart "Guardar en …" button. Read only: nothing is sent, moved or deleted in the mailbox.
/// Layout (§15.3): list ≥ 260 and reader ≥ 320 side by side; below 620 pt one column, the reader pushed over the list.
struct MailView: View {
    @Environment(AppState.self) private var state
    @ViewState private var model: MailModel
    /// Single-column mode: the reader is showing (pushed over the list).
    @ViewState private var narrowShowsDetail = false
    // MARK: v0.7 backfill — §17.6 multi-select and its confirmation sheet.
    @ViewState private var selection = MailSelection()
    @ViewState private var batch: MailBatchModel?
    @ViewState private var pickedDestination: String?? = nil

    static let listMinWidth: CGFloat = 260
    static let detailMinWidth: CGFloat = 320
    /// Below this the two columns don't fit (260 + 320 + divider + slack): one column with push.
    static let splitMinWidth: CGFloat = 620

    init(model: MailModel? = nil, selection: MailSelection? = nil) {
        _model = ViewState(initialValue: model ?? MailModel())
        _selection = ViewState(initialValue: selection ?? MailSelection())   // v0.7 backfill: snapshots pass one
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
                GeometryReader { geo in
                    if geo.size.width >= Self.splitMinWidth {
                        split(width: geo.size.width)
                    } else {
                        singleColumn
                    }
                }
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .background(Brand.color.surface)
        .navigationTitle(L("mail.title"))
        .navigationSubtitle(model.query.isEmpty ? L("mail.subtitle") : L("mail.results", model.query))
        .toolbar {
            ToolbarItem {
                Button { state.requestEmail() } label: { Label(L("mail.paste"), systemImage: "doc.on.clipboard") }
                    .help(L("mail.paste"))
            }
            // §14.4 + §15.2: "Reglas…" lives in the ⋯ menu (same place in Correo and Reuniones), not as a bar button.
            ToolbarItem { ToolbarMoreMenu(mail: model.messages) }
                .brandOwnBackground()
        }
        .task(id: hasMailAccounts) {
            guard hasMailAccounts else { return }
            model.start(state: state)
            MailAutoImporter.shared.runNow()   // MARK: v0.4 routing — §14.5 on opening Correo
        }
        .onAppear { model.isOnScreen = true }
        .onDisappear { model.isOnScreen = false }
        .onChange(of: state.accountsRevision) { model.accountsChanged() }
        .onChange(of: state.vaultRevision) { model.vaultChanged() }
        .onChange(of: state.engine.routing.settings) { model.routingChanged() }   // MARK: v0.4 routing
        .onChange(of: model.messages.map(\.id)) { selection.keepOnly(model.messages.map(\.id)) }   // MARK: v0.7 backfill
        .onChange(of: model.accountId) { selection.clear(); pickedDestination = nil }
        .sheet(item: $batch) { MailBatchSheet(model: $0) }
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

    /// List about a third of the width (260…420), the reader the rest (≥ 320): computed from the space there is, so
    /// the two columns can never ask for more than the window has.
    private func split(width: CGFloat) -> some View {
        let list = min(max(Self.listMinWidth, (width * 0.36).rounded()), 420, width - Self.detailMinWidth - 1)
        return HStack(spacing: 0) {
            listPane()
                .frame(width: list)
            BrandColumnDivider()
            MailDetailView(model: model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The list with Correo's multi-select (v0.7 §17.6): "Guardar en …" opens the confirmation sheet.
    private func listPane(onOpen: (() -> Void)? = nil) -> some View {
        MailListPane(model: model, onOpen: onOpen, selection: selection, picked: $pickedDestination) { slug in
            guard let account = model.account else { return }
            let checked = model.messages.filter { selection.contains($0.id) }
            guard !checked.isEmpty else { return }
            let sheet = MailBatchModel(origin: .selection(checked, account), projectSlug: slug)
            sheet.onSaved = { [selection] in selection.clear() }
            batch = sheet
        }
    }

    @ViewBuilder private var singleColumn: some View {
        if narrowShowsDetail, model.selectedId != nil {
            VStack(spacing: 0) {
                HStack {
                    Button { narrowShowsDetail = false } label: {
                        Label(L("mail.backToList"), systemImage: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Brand.spacing.l)
                .padding(.vertical, Brand.spacing.s)
                MailDetailView(model: model)
            }
            .transition(.opacity)
        } else {
            listPane { narrowShowsDetail = true }
                .transition(.opacity)
        }
    }
}

// MARK: - Toolbar ⋯

/// The ⋯ menu of the Correo and Reuniones toolbars (§14.4 updated by §15.2): "Reglas…" opens the rules sheet in place.
/// `mail` feeds the sheet's "Probar" with the messages already loaded (Reuniones passes none).
struct ToolbarMoreMenu: View {
    var mail: [MailMessageSummary] = []
    @ViewState private var showsRules = false

    var body: some View {
        Menu {
            Button { showsRules = true } label: {
                Label(L("rules.button"), systemImage: "arrow.triangle.branch")
            }
            .help(L("rules.buttonHelp"))
        } label: {
            BrandMoreLabel()
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .accessibilityLabel(L("project.more"))
        .help(L("project.more"))
        .sheet(isPresented: $showsRules) { RulesSheet(mail: mail) }
    }
}

// MARK: - List

private struct MailListPane: View {
    @Environment(AppState.self) private var state
    @Bindable var model: MailModel
    /// The user opened a message (single-column mode pushes the reader).
    var onOpen: (() -> Void)? = nil
    // MARK: v0.7 backfill — checked messages, the bar's destination, "Guardar en …".
    var selection = MailSelection()
    @Binding var picked: String??
    var onSaveSelection: (String?) -> Void = { _ in }
    @ViewState private var connector = AccountConnector()
    @ViewState private var help: OrgHelpRequest?
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            content
            if selection.isActive {
                MailSelectionBar(selection: selection, model: model, picked: $picked, onSave: onSaveSelection)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let error = MailBatchSaver.shared.lastError {
                batchError(error)
            }
        }
        .animation(Brand.motion.animation(fast: true), value: selection.isActive)
        .background(Brand.color.surface)
        .sheet(item: $help) { request in OrgAccessHelpSheet(provider: request.provider) }
    }

    /// Account picker (only with more than one account) + search. Nothing else (§15.2).
    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            if model.accounts.count > 1 {
                BrandPicker(selection: Binding(get: { model.account?.id ?? "" }, set: { model.selectAccount($0) }),
                            options: model.accounts.map { ($0.id, $0.email) })
                    .accessibilityLabel(L("mail.account"))
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
                TextField(L("mail.search"), text: $model.query)
                    .textFieldStyle(.plain)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .focused($searchFocused)
                    .focusEffectDisabled()
                if !model.query.isEmpty {
                    Button { model.query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Brand.color.text3)
                    }
                    .buttonStyle(.plain)
                    .help(L("mail.clearSearch"))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.field, style: .continuous)
                .strokeBorder(searchFocused ? Brand.color.focusBorder : Brand.color.lineSoft, lineWidth: 1))
            .brandFocusHalo(searchFocused)
        }
        .padding(Brand.spacing.m)
    }

    @ViewBuilder private var content: some View {
        if let failure = model.failure {
            failureView(failure)
        } else if model.isLoading && model.messages.isEmpty {
            BrandLoader(size: 24, text: L("mail.loading"))
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
        let messages = model.visibleMessages
        let mine = Set(model.accounts.map(\.email))
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(messages) { message in
                        MailRow(message: message, isMine: mine.contains(message.from.email ?? ""),
                                isSelected: model.selectedId == message.id, source: index[message.id], model: model,
                                isChecked: selection.contains(message.id), selecting: selection.isActive,
                                onCheck: { selection.toggle(message.id) })
                            .contentShape(Rectangle())
                            .onTapGesture { click(message.id, in: messages) }
                            .id(message.id)
                    }
                    footer
                }
                .padding(.horizontal, Brand.spacing.s)
                .padding(.vertical, Brand.spacing.s)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, in: messages, proxy: proxy) }
            .onKeyPress(.upArrow) { step(-1, in: messages, proxy: proxy) }
            .onKeyPress(.return) {
                guard model.selectedId != nil, let onOpen else { return .ignored }
                onOpen()
                return .handled
            }
        }
    }

    /// ⌘-click checks/unchecks, ⇧-click checks a range (v0.7 §17.6); a plain click opens the message.
    private func click(_ id: String, in messages: [MailMessageSummary]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            selection.toggle(id, alsoOpen: model.selectedId)
        } else if flags.contains(.shift) {
            selection.extend(to: id, in: messages.map(\.id), open: model.selectedId)
        } else {
            open(id)
        }
    }

    /// A save in the background went wrong: one line under the list, dismissable.
    private func batchError(_ error: String) -> some View {
        HStack(alignment: .top, spacing: Brand.spacing.s) {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(Brand.caption)
                .foregroundStyle(Brand.color.danger)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { MailBatchSaver.shared.lastError = nil } label: {
                Image(systemName: "xmark").foregroundStyle(Brand.color.text3)
            }
            .buttonStyle(.plain)
            .help(L("common.close"))
        }
        .padding(Brand.spacing.m)
        .background(Brand.color.surface)
        .overlay(alignment: .top) { BrandEdgeFade().offset(y: -16) }
    }

    private func open(_ id: String) {
        listFocused = true
        model.select(id)
        onOpen?()
    }

    /// ↑ / ↓ move the selection like Mail does (the reader follows; single-column mode stays on the list).
    private func step(_ delta: Int, in messages: [MailMessageSummary], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !messages.isEmpty else { return .ignored }
        let current = messages.firstIndex { $0.id == model.selectedId } ?? (delta > 0 ? -1 : messages.count)
        let next = min(max(current + delta, 0), messages.count - 1)
        guard next != current else { return .handled }
        let id = messages[next].id
        model.select(id)
        withAnimation(Brand.motion.animation(fast: true)) { proxy.scrollTo(id) }
        return .handled
    }

    /// "Cargar más", its spinner, or why it failed (with "Reintentar") — always in the list (§15.2).
    @ViewBuilder private var footer: some View {
        if let error = model.loadMoreError {
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("mail.retry")) { model.loadMore() }
                    .buttonStyle(.brandSecondary)
            }
            .padding(Brand.spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if model.nextToken != nil {
            HStack {
                Spacer()
                if model.isLoadingMore {
                    BrandLoader(size: 18)
                } else {
                    Button(L("mail.loadMore")) { model.loadMore() }
                        .buttonStyle(.brandGhost)
                }
                Spacer()
            }
            .frame(height: 44)
        }
    }

    /// Message id → its source, for the "En el cerebro" chips (one pass over the sources per render).
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
        VStack(alignment: .leading, spacing: Brand.spacing.m) {
            switch failure {
            case .reconnect(let provider):
                Label(L("mail.reconnect.title", provider.displayName), systemImage: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("mail.reconnect")) { connector.start(provider, state: state) }
                    .buttonStyle(.brandPrimary)
                    .sheet(item: Bindable(connector).flow) { _ in TrustSheet(connector: connector, context: .mail) }
                if let error = connector.error {
                    Text(error).font(Brand.caption).foregroundStyle(Brand.color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .organization(let provider):
                Label(L("accounts.consentRequired"), systemImage: "building.2")
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("accounts.howToEnable")) { help = OrgHelpRequest(provider: provider) }
                    .buttonStyle(.brandPrimary)
                Button(L("mail.pasteInstead")) { state.requestEmail() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Brand.color.accent)
            case .other(let message):
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Brand.color.danger)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L("mail.retry")) { model.load(force: true) }
                    .buttonStyle(.brandSecondary)
            }
        }
        .font(Brand.body)
        .padding(Brand.spacing.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct MailRow: View {
    @Environment(AppState.self) private var state
    let message: MailMessageSummary
    let isMine: Bool
    let isSelected: Bool
    let source: SourceRecord?
    let model: MailModel
    // MARK: v0.7 backfill — the checkbox column (on hover, and for every row while a selection is going on).
    var isChecked = false
    var selecting = false
    var onCheck: () -> Void = {}
    @ViewState private var hovering = false

    /// On the selected fill (accentSoft) text2 falls under 4.5:1 at 11 pt: the full text color there.
    private var secondary: Color { isSelected ? Brand.color.text : Brand.color.text2 }

    var body: some View {
        HStack(alignment: .top, spacing: Brand.spacing.s) {
            ZStack(alignment: .top) {
                if selecting || hovering || isChecked {
                    MailRowCheckbox(checked: isChecked, toggle: onCheck)
                } else {
                    Circle()
                        .fill(message.isRead ? Color.clear : Brand.color.accent)
                        .frame(width: 7, height: 7)
                        .padding(.top, 5)
                        .accessibilityLabel(message.isRead ? "" : L("mail.unread"))
                }
            }
            .frame(width: 16)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(isMine ? L("mail.you") : message.from.display)
                        .font(Brand.font(13, message.isRead ? .medium : .semibold))
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .help(message.from.email ?? "")
                    Spacer(minLength: 4)
                    Text(Fmt.relative(message.date))
                        .font(Brand.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                HStack(spacing: 4) {
                    Text(message.subject.isEmpty ? L("mail.noSubject") : message.subject)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .help(message.subject)
                    if message.hasAttachments {
                        Image(systemName: "paperclip")
                            .font(Brand.caption)
                            .foregroundStyle(secondary)
                            .help(L("mail.attachments"))
                    }
                }
                Text(message.snippet)
                    .font(Brand.caption)
                    .foregroundStyle(secondary)
                    .lineLimit(2)
                if let source {
                    SavedChip(destination: state.projectName(source.projectSlug))
                        .padding(.top, 3)
                } else if let routed = model.routedDestination(for: message) {
                    // MARK: v0.4 routing — where a rule (or the default project) would send it.
                    RoutedProjectChip(label: state.projectName(routed.projectSlug),
                                      help: routed.rule.map { L("rules.mail.byRule", ruleLabel($0)) } ?? L("rules.mail.byDefault"))
                        .padding(.top, 3)
                }
            }
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One selection color (accentSoft); a checked row only gets the faint `hover` tone (its checkbox carries
        // the state). The inset separator hides on a filled row, so it never touches a rounded fill.
        .background(isSelected ? Brand.color.accentSoft : (isChecked ? Brand.color.hover : Color.clear),
                    in: RoundedRectangle(cornerRadius: Brand.radius.tile, style: .continuous))
        .overlay(alignment: .bottom) {
            if !isSelected && !isChecked {
                Rectangle().fill(Brand.color.lineSoft).frame(height: 1).padding(.leading, 32).padding(.trailing, 8)
            }
        }
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// "✓ Guardado" on a list row: the same word as the reader (§15.2), not interactive (a click selects the row; the
/// actions live in the reader's action bar and its ⋯). Where it went is in the tooltip.
struct SavedChip: View {
    let destination: String

    var body: some View {
        BrandChip(text: L("mail.saved"), symbol: "checkmark", active: true)
            .help(L("mail.savedIn", destination))
    }
}

/// "Aprendiendo de «…»… · Deshacer": the one transient message of Correo (§15.2), inset at the bottom of the reader
/// (the message scrolls above it), over its action bar. Fades in and out.
struct MailToastView: View {
    let toast: MailModel.Toast
    var onUndo: () -> Void

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            if toast.undoable {
                BrandLoader(size: 16)
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.color.success)
            }
            Text(toast.text)
                .font(Brand.body)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            if toast.undoable {
                Text(verbatim: "·").foregroundStyle(Brand.color.text3)
                Button(L("mail.undo"), action: onUndo)
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, 10)
        // It takes space now (it no longer floats over the message): no overlay shadow. Clipped to its shape: without
        // it, hairline marks showed just outside the capsule's ends.
        .background(Brand.color.card, in: Capsule())
        .overlay(Capsule().strokeBorder(Brand.color.lineSoft, lineWidth: 1))
        .clipShape(Capsule())
    }
}
