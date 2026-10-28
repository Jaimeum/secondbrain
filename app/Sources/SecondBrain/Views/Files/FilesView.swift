import AppKit
import BrainCore
import Quartz
import QuickLook
import SwiftUI

/// Archivos (CONTRACT §17.2): every file of the brain (`.brain`, sidebar ⌘6) or of one project (`ProjectTab.files`) —
/// documents, images and saved email attachments — with search (name + the text of its summary page), filters
/// Tipo · Origen · Persona (· Proyecto in the global view), sort, a list with thumbnails and a right panel (preview,
/// "En breve", actions). Space = Quick Look; dragging a row to another app copies the file. "Descartados (n)" lists the
/// attachments that were not kept (§17.1), with Rescatar / Eliminar ya.
struct FilesView: View {
    @Environment(AppState.self) private var state
    let scope: Scope

    @ViewState private var query = ""
    @ViewState private var type: FileType?
    @ViewState private var origin: FileOrigin?
    @ViewState private var person: String?
    @ViewState private var project: String?
    @ViewState private var sort: FileSort = .date
    /// Kept in the model per place: the view can be rebuilt (tab switches, the router) without losing them.
    private var selection: String? {
        get { model.selection[scope.key] }
        nonmutating set { model.selection[scope.key] = newValue }
    }
    private var showDiscarded: Bool {
        get { model.discardedShown.contains(scope.key) }
        nonmutating set { if newValue { model.discardedShown.insert(scope.key) } else { model.discardedShown.remove(scope.key) } }
    }
    @ViewState private var quickLook: URL?
    @ViewState private var busy: Set<String> = []
    @ViewState private var error: String?
    @FocusState private var listFocused: Bool

    private var model: FilesModel { FilesModel.shared }

    /// The files of this place.
    private var scoped: [FileEntry] {
        guard let slug = scope.projectSlug else { return model.entries }
        return model.entries.filter { $0.projectSlug == slug }
    }

    private var shown: [FileEntry] {
        FileIndex.filter(scoped, FileQuery(text: query, type: type, origin: origin, person: person,
                                           project: scope.isBrain ? project : nil, sort: sort))
    }

    private var discardedHere: [DiscardedItem] {
        guard let slug = scope.projectSlug else { return model.discarded }
        return model.discarded.filter { $0.project == slug }
    }

    private var selected: FileEntry? { selection.flatMap { s in scoped.first { $0.path == s } } }

    var body: some View {
        Group {
            if !model.loaded {
                BrandLoader(size: 28).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scoped.isEmpty && discardedHere.isEmpty {
                EmptyStateView(symbol: "doc.on.doc", title: L("files.empty.title"), message: L("files.empty.message"))
            } else {
                VStack(spacing: 0) {
                    toolbar
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                    if showDiscarded {
                        discardedList
                    } else {
                        GeometryReader { geo in
                            HStack(spacing: 0) {
                                fileList
                                    .frame(maxWidth: .infinity)
                                Rectangle().fill(Brand.color.line).frame(width: 1)
                                panel
                                    .frame(width: Self.panelWidth(for: geo.size.width))
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Brand.color.surface)
        .modifier(BrainTitle(isBrain: scope.isBrain))
        .quickLookPreview($quickLook)
        .task(id: "\(state.vaultGeneration)-\(state.vaultRevision)") {
            await model.refresh(state: state)
            consumePending()
        }
        .onChange(of: model.pendingFile) { consumePending() }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    static func panelWidth(for total: CGFloat) -> CGFloat { min(360, max(280, (total * 0.4).rounded())) }

    /// A file asked for from elsewhere (⌘K, a ficha): clear the filters that would hide it and select it.
    private func consumePending() {
        if model.pendingDiscarded {
            model.pendingDiscarded = false
            showDiscarded = true
        }
        guard model.loaded, let path = model.pendingFile, scoped.contains(where: { $0.path == path }) else { return }
        model.pendingFile = nil
        query = ""; type = nil; origin = nil; person = nil; project = nil
        showDiscarded = false
        selection = path
    }

    // MARK: Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            HStack(spacing: Brand.spacing.s) {
                SearchFieldRow(placeholder: L("files.search"), text: $query)
                    .frame(maxWidth: 360)
                    .disabled(showDiscarded)
                Spacer(minLength: Brand.spacing.s)
                sortMenu.disabled(showDiscarded)
                Button { showDiscarded.toggle() } label: {
                    BrandChip(text: L("files.discarded", discardedHere.count), symbol: "trash", active: showDiscarded)
                }
                .buttonStyle(.plain)
                .help(L("files.discarded.help"))
            }
            if !showDiscarded {
                HStack(spacing: Brand.spacing.xs) {
                    filterMenu(title: L("files.filter.type"), all: L("files.filter.anyType"), value: $type,
                               options: FileType.allCases.filter { t in scoped.contains { $0.type == t } }.map { ($0, Self.label($0)) })
                    filterMenu(title: L("files.filter.origin"), all: L("files.filter.anyOrigin"), value: $origin,
                               options: FileOrigin.allCases.filter { o in scoped.contains { $0.origin == o } }.map { ($0, Self.label($0)) })
                    filterMenu(title: L("files.filter.person"), all: L("files.filter.anyPerson"), value: $person,
                               options: FileIndex.people(in: scoped).prefix(40).map { ($0.key, $0.name) })
                    if scope.isBrain {
                        filterMenu(title: L("files.filter.project"), all: L("files.filter.anyProject"), value: $project,
                                   options: state.projects.filter { p in scoped.contains { $0.projectSlug == p.slug } }
                                       .map { ($0.slug, $0.emoji + " " + $0.name) })
                    }
                    if type != nil || origin != nil || person != nil || project != nil || !query.isEmpty {
                        Button(L("files.clear")) {
                            query = ""; type = nil; origin = nil; person = nil; project = nil
                        }
                        .buttonStyle(.borderless)
                        .font(Brand.font(11, .medium))
                        .foregroundStyle(Brand.color.accent)
                    }
                    Spacer(minLength: Brand.spacing.s)
                    Text(L("files.count", shown.count))
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text2)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, Brand.spacing.s)
    }

    private func filterMenu<T: Hashable>(title: String, all: String, value: Binding<T?>, options: [(T, String)]) -> some View {
        let current = options.first { $0.0 == value.wrappedValue }?.1
        return Menu {
            Button { value.wrappedValue = nil } label: {
                if value.wrappedValue == nil { Label(all, systemImage: "checkmark") } else { Text(all) }
            }
            if !options.isEmpty { Divider() }
            ForEach(options, id: \.0) { option in
                Button { value.wrappedValue = option.0 } label: {
                    if value.wrappedValue == option.0 { Label(option.1, systemImage: "checkmark") } else { Text(option.1) }
                }
            }
        } label: {
            BrandChip(text: current ?? title, symbol: "chevron.down", active: current != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
    }

    private var sortMenu: some View {
        Menu {
            ForEach(FileSort.allCases, id: \.self) { s in
                Button { sort = s } label: {
                    if sort == s { Label(Self.label(s), systemImage: "checkmark") } else { Text(Self.label(s)) }
                }
            }
        } label: {
            BrandChip(text: Self.label(sort), symbol: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("files.sort.help"))
    }

    // MARK: List

    private var fileList: some View {
        let rows = shown
        return Group {
            if rows.isEmpty {
                EmptyStateView(symbol: "magnifyingglass", title: L("files.noMatch.title"), message: L("files.noMatch.message"))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(rows) { entry in
                                FileRow(entry: entry, showProject: scope.isBrain, isSelected: selection == entry.path,
                                        url: url(entry))
                                    .id(entry.path)
                                    .onTapGesture {
                                        listFocused = true
                                        selection = entry.path
                                    }
                                    .onTapGesture(count: 2) { NSWorkspace.shared.open(url(entry)) }
                                    .onDrag { NSItemProvider(contentsOf: url(entry)) ?? NSItemProvider() }
                            }
                        }
                        .padding(Brand.spacing.s)
                    }
                    .focusable()
                    .focused($listFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.space) {
                        guard let entry = selected else { return .ignored }
                        quickLook = quickLook == nil ? url(entry) : nil
                        return .handled
                    }
                    .onKeyPress(.downArrow) { step(1, rows: rows, proxy: proxy) }
                    .onKeyPress(.upArrow) { step(-1, rows: rows, proxy: proxy) }
                    .onKeyPress(.return) {
                        guard let entry = selected else { return .ignored }
                        NSWorkspace.shared.open(url(entry))
                        return .handled
                    }
                    .onAppear { if let selection { proxy.scrollTo(selection, anchor: .center) } }
                    .onChange(of: selection) { if let selection { proxy.scrollTo(selection) } }
                }
            }
        }
    }

    private func step(_ delta: Int, rows: [FileEntry], proxy: ScrollViewProxy) -> KeyPress.Result {
        guard !rows.isEmpty else { return .ignored }
        let index = selection.flatMap { s in rows.firstIndex { $0.path == s } } ?? (delta > 0 ? -1 : rows.count)
        let next = rows[max(0, min(rows.count - 1, index + delta))]
        selection = next.path
        if quickLook != nil { quickLook = url(next) }
        return .handled
    }

    private func url(_ entry: FileEntry) -> URL { state.engine.vault.url(for: entry.path) }

    // MARK: Panel

    @ViewBuilder private var panel: some View {
        if let entry = selected {
            FilePanel(entry: entry, url: url(entry), scope: scope) { quickLook = url(entry) }
                .id(entry.path)
        } else {
            EmptyStateView(symbol: "doc.viewfinder", title: L("files.pick"), message: L("files.pickMessage"))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Descartados

    private var discardedList: some View {
        let items = discardedHere
        return Group {
            if items.isEmpty {
                EmptyStateView(symbol: "trash", title: L("files.discarded.emptyTitle"), message: L("files.discarded.emptyMessage"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        Text(L("files.discarded.notice"))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .padding(.horizontal, Brand.spacing.s)
                            .padding(.bottom, Brand.spacing.xs)
                        ForEach(items) { item in
                            DiscardedRow(item: item, showProject: scope.isBrain, busy: busy.contains(item.id),
                                         url: model.discardedStore(state).fileURL(of: item),
                                         onRescue: { rescue(item) }, onDelete: { delete(item) })
                        }
                    }
                    .padding(Brand.spacing.s)
                }
            }
        }
    }

    /// "Rescatar": out of the store and into the brain, as if it had been saved (into its project, else Sin asignar).
    private func rescue(_ item: DiscardedItem) {
        let store = model.discardedStore(state)
        busy.insert(item.id)
        Task {
            defer { busy.remove(item.id) }
            do {
                guard let (rescued, file) = try store.rescue(id: item.id) else { return }
                // The engine imports it as a document of the project (raw/docs; an image goes through the same
                // pipeline); the temporary copy goes away after.
                try await state.engine.importFileAsync(file, projectSlug: rescued.project)
                try? FileManager.default.removeItem(at: file)
                state.bumpVault()
                await model.refresh(state: state, force: true)
            } catch {
                self.error = L("files.discarded.rescueFailed", item.name)
            }
        }
    }

    private func delete(_ item: DiscardedItem) {
        let store = model.discardedStore(state)
        store.delete(id: item.id)
        Task { await model.refresh(state: state, force: true) }
    }

    // MARK: Words

    static func label(_ type: FileType) -> String { L("files.type.\(type.rawValue)") }
    static func label(_ origin: FileOrigin) -> String { L("files.origin.\(origin.rawValue)") }
    static func label(_ sort: FileSort) -> String { L("files.sort.\(sort.rawValue)") }

    /// "✉️ Contrato Acme · de Ana García" / "Subido" / "Agregado al proyecto" / "Captura rápida".
    static func originLine(_ entry: FileEntry) -> String {
        switch entry.origin {
        case .email:
            let subject = entry.threadSubject ?? entry.threadKey ?? ""
            if let sender = entry.sender { return L("files.from.thread", subject, sender.display) }
            return "✉️ " + subject
        case .upload: return L("files.from.upload")
        case .dump: return L("files.from.dump")
        case .capture: return L("files.from.capture")
        }
    }

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    static func reason(_ reason: DiscardReason) -> String {
        switch reason {
        case .inlineImage: L("files.reason.inlineImage")
        case .smallImage: L("files.reason.smallImage")
        case .junkName: L("files.reason.junkName")
        case .junkType: L("files.reason.junkType")
        case .duplicate: L("files.reason.duplicate")
        case .claude(let why): L("files.reason.claude", why)
        case .user: L("files.reason.user")
        }
    }
}

/// "Archivos" as the window title only in the sidebar item (a project keeps its own title).
private struct BrainTitle: ViewModifier {
    let isBrain: Bool
    func body(content: Content) -> some View {
        if isBrain { content.navigationTitle(L("sidebar.files")) } else { content }
    }
}

// MARK: - Rows

/// Thumbnail · name · origin · date and size · project chip.
private struct FileRow: View {
    @Environment(AppState.self) private var state
    let entry: FileEntry
    let showProject: Bool
    let isSelected: Bool
    let url: URL

    @ViewState private var hovering = false

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            FileThumbnail(url: url, type: entry.type, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(isSelected ? Brand.callout : Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(FilesView.originLine(entry))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            if showProject {
                // The project's emoji (its name on hover): the file name keeps the room.
                BrandChip(text: state.project(entry.projectSlug)?.emoji ?? "📥")
                    .fixedSize()
                    .help(state.project(entry.projectSlug)?.name ?? L("files.filter.inbox"))
                    .accessibilityLabel(state.project(entry.projectSlug)?.name ?? L("files.filter.inbox"))
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.day(entry.date))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                Text(FilesView.size(entry.size))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text3)
            }
            .lineLimit(1)
            .monospacedDigit()
            .fixedSize()
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
            .fill(isSelected ? Brand.color.accentSoft : (hovering ? Brand.color.cardAlt.opacity(0.55) : Color.clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(entry.name)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A discarded attachment: name, sender · reason · days left, Rescatar / Eliminar ya.
private struct DiscardedRow: View {
    @Environment(AppState.self) private var state
    let item: DiscardedItem
    let showProject: Bool
    let busy: Bool
    let url: URL
    var onRescue: () -> Void
    var onDelete: () -> Void

    private var daysLeft: Int {
        let end = item.discardedAt.addingTimeInterval(DiscardedStore.lifetime)
        return max(0, Int(ceil(end.timeIntervalSinceNow / 86_400)))
    }

    private var detail: String {
        var parts: [String] = []
        if let from = item.from, let sender = EmailParser.parseAddresses(from).first { parts.append(L("files.discarded.from", sender.display)) }
        parts.append(FilesView.reason(item.reason))
        parts.append(FilesView.size(item.size))
        if showProject, let project = state.project(item.project) { parts.append(project.emoji + " " + project.name) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            FileThumbnail(url: url, type: FileType.of(extension: (item.name as NSString).pathExtension), side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(detail)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(L("files.discarded.daysLeft", daysLeft))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if busy {
                ProgressView().controlSize(.small)
            } else {
                Button(L("files.discarded.rescue"), action: onRescue)
                    .buttonStyle(.brandSecondary)
                    .help(L("files.discarded.rescueHelp"))
                Button(action: onDelete) { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Brand.color.danger)
                    .help(L("files.discarded.delete"))
                    .accessibilityLabel(L("files.discarded.delete"))
            }
        }
        .padding(.horizontal, Brand.spacing.s)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

/// A file's thumbnail (QuickLookThumbnailing), or its kind's symbol while it loads or when there is none.
struct FileThumbnail: View {
    let url: URL
    let type: FileType
    var side: CGFloat = 34

    @ViewState private var image: NSImage?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        ZStack {
            shape.fill(Brand.color.cardAlt)
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: type.symbol)
                    .font(Brand.font(side * 0.42))
                    .foregroundStyle(Brand.color.text2)
            }
        }
        .frame(width: side, height: side)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Brand.color.line, lineWidth: 1))
        .task(id: url) { image = await FileThumbnails.shared.image(for: url, side: side) }
        .accessibilityHidden(true)
    }
}

// MARK: - Panel

/// The selected file: preview, name and facts, origin (with "Abrir en Outlook/Gmail"), "En breve", people, actions.
private struct FilePanel: View {
    @Environment(AppState.self) private var state
    let entry: FileEntry
    let url: URL
    let scope: Scope
    var onQuickLook: () -> Void

    @ViewState private var copied = false

    private var provider: AccountProvider? {
        entry.externalId.flatMap { $0.split(separator: ":").first }.flatMap { AccountProvider(rawValue: String($0)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilePreview(url: url)
                .frame(height: 230)
                .background(Brand.color.card)
                .overlay(alignment: .bottomTrailing) {
                    Button(action: onQuickLook) { Image(systemName: "eye") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Brand.color.text2)
                        .padding(Brand.spacing.s)
                        .help(L("files.action.quickLook"))
                }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: Brand.spacing.m) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.name)
                            .font(Brand.section)
                            .foregroundStyle(Brand.color.text)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        Text([FilesView.label(entry.type), FilesView.size(entry.size), Fmt.dayTime(entry.date)].joined(separator: " · "))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                        HStack(spacing: Brand.spacing.xs) {
                            Image(systemName: entry.origin == .email ? "envelope" : originSymbol)
                                .imageScale(.small)
                                .foregroundStyle(Brand.color.text2)
                            Text(FilesView.originLine(entry).replacingOccurrences(of: "✉️ ", with: ""))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(2)
                        }
                        if scope.isBrain {
                            BrandChip(text: state.project(entry.projectSlug).map { $0.emoji + " " + $0.name } ?? L("files.filter.inbox"))
                                .padding(.top, 2)
                        }
                    }
                    actions
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("files.panel.inShort"))
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.text)
                        Text(entry.summary ?? L("files.panel.noSummary"))
                            .font(Brand.body)
                            .foregroundStyle(entry.summary == nil ? Brand.color.text3 : Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !entry.people.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L("files.panel.people"))
                                .font(Brand.callout)
                                .foregroundStyle(Brand.color.text)
                            FlowChips(people: entry.people) { path in state.navigate(to: .entity(path, scope)) }
                        }
                    }
                }
                .padding(Brand.spacing.m)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Brand.color.surface)
    }

    private var originSymbol: String {
        switch entry.origin {
        case .email: "envelope"
        case .upload: "arrow.up.doc"
        case .dump: "tray.and.arrow.down"
        case .capture: "bolt"
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            // Narrow panels drop labels instead of cutting them ("Mostrar en Fin…").
            ViewThatFits(in: .horizontal) {
                mainRow(finderIconOnly: false)
                mainRow(finderIconOnly: true)
            }
            ViewThatFits(in: .horizontal) {
                moreRow.labelStyle(.titleAndIcon)
                moreRow.labelStyle(.iconOnly)
            }
            if entry.origin == .email {
                OpenOriginalButton(link: entry.webLink, provider: provider)
            }
        }
    }

    private func mainRow(finderIconOnly: Bool) -> some View {
        HStack(spacing: Brand.spacing.s) {
            Button { NSWorkspace.shared.open(url) } label: { Label(L("files.action.open"), systemImage: "arrow.up.forward.app") }
                .buttonStyle(.brandPrimary)
                .labelStyle(.titleAndIcon)
                .help(L("files.action.openHelp"))
            let finder = Button { NSWorkspace.shared.activateFileViewerSelecting([url]) } label: {
                Label(L("files.action.finder"), systemImage: "folder")
            }
            .buttonStyle(.brandSecondary)
            .help(L("files.action.finder"))
            if finderIconOnly { finder.labelStyle(.iconOnly) } else { finder.labelStyle(.titleAndIcon) }
        }
        .fixedSize()
    }

    private var moreRow: some View {
        HStack(spacing: Brand.spacing.s) {
            if let page = entry.summaryPath {
                Button { state.navigate(to: .entity(page, scope)) } label: {
                    Label(L("files.action.ficha"), systemImage: "doc.text.magnifyingglass")
                }
                .buttonStyle(.brandSecondary)
                .help(L("files.action.ficha"))
            }
            if let thread = entry.threadPagePath {
                Button { state.navigate(to: .entity(thread, scope)) } label: {
                    Label(L("files.action.thread"), systemImage: "envelope")
                }
                .buttonStyle(.brandSecondary)
                .help(L("files.action.thread"))
            }
            Button(action: copy) {
                Label(copied ? L("files.action.copied") : L("files.action.copy"), systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.brandSecondary)
            .help(L("files.action.copyHelp"))
        }
        .fixedSize()
    }

    /// The file itself on the pasteboard (paste it in Finder, Mail, Slack…).
    private func copy() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([url as NSURL])
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

/// People chips that wrap; a chip with a person page opens it.
private struct FlowChips: View {
    let people: [FilePerson]
    var onOpen: (String) -> Void

    var body: some View {
        FilesFlowLayout(spacing: 6) {
            ForEach(people, id: \.key) { person in
                if let path = person.path {
                    Button { onOpen(path) } label: { BrandChip(text: person.name, symbol: "person") }
                        .buttonStyle(.plain)
                        .help(person.email ?? person.name)
                } else {
                    BrandChip(text: person.name, symbol: "person").help(person.email ?? person.name)
                }
            }
        }
    }
}

/// Left-to-right rows that wrap.
private struct FilesFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing
            row = max(row, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + row)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            row = max(row, size.height)
        }
    }
}

/// `QLPreviewView` (compact): PDFs, images, Office documents, text.
private struct FilePreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .compact) ?? QLPreviewView()
        view.autostarts = true
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if (view.previewItem as? NSURL) as URL? != url { view.previewItem = url as NSURL }
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: ()) {
        view.close()
    }
}
