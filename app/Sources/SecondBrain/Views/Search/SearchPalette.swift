import AppKit
import BrainCore
import SwiftUI

/// ⌘K (CONTRACT §15.2): a centered 560 pt overlay on `card` with the overlay shadow. ↑↓ move, ↩ opens (or asks when
/// nothing matches), ⌘↩ always asks, esc closes. Always global (§16.7, no ⌥): the last row is always "Preguntar a
/// todo el cerebro: «…»", asked in a new conversation of the sidebar's Preguntar. Up to 4 rows per group, "Ver n más"
/// shows the rest; a row found by its page's text (not its title) shows the passage under the title.
struct SearchPalette: View {
    @Environment(AppState.self) private var state
    var initialQuery = ""

    @ViewState private var query = ""
    @ViewState private var selected = 0
    @ViewState private var monitor: Any?
    /// The window the palette lives in: its key monitor only handles keys typed there, never in a sheet or Ajustes.
    @ViewState private var host = HostWindow()
    /// Where the pointer was when ↑↓ last moved the selection: a row scrolling under a still pointer must not take the
    /// selection back (hover counts only after the mouse really moved).
    @ViewState private var pointerAtKeyMove: CGPoint?
    @FocusState private var fieldFocused: Bool

    private var index: SearchIndex { SearchIndex.shared }

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let maxListHeight: CGFloat = 400
    static let fieldHeight: CGFloat = 48
    static let footerHeight: CGFloat = 32

    /// A row found by its page's text: title line + snippet line.
    static let snippetRowHeight: CGFloat = 46

    private enum RowKind: Hashable {
        case item(SearchItem)
        /// "Ver n más" under a group with more results than it shows.
        case more(SearchGroup, Int)
        case ask
    }

    private struct Row: Identifiable, Hashable {
        let kind: RowKind
        var id: String {
            switch kind {
            case .item(let item): item.id
            case .more(let group, _): "more|" + group.rawValue
            case .ask: "ask"
            }
        }

        var height: CGFloat {
            if case .item(let item) = kind, item.snippet != nil { return SearchPalette.snippetRowHeight }
            return SearchPalette.rowHeight
        }
    }

    /// Groups opened with "Ver n más" (for this query).
    @ViewState private var expanded: Set<SearchGroup> = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [SearchSection] {
        trimmed.isEmpty ? index.suggestions(now: MeetingsModel.shared.now) : index.results(for: trimmed, expanded: expanded)
    }

    /// The rows of one group: its results, then "Ver n más" when it has more.
    private func sectionRows(_ section: SearchSection) -> [Row] {
        section.items.map { Row(kind: .item($0)) } + (section.more > 0 ? [Row(kind: .more(section.group, section.more))] : [])
    }

    /// Selectable rows in display order (the ask row last).
    private func rows(_ groups: [SearchSection]) -> [Row] {
        var out = groups.flatMap { sectionRows($0) }
        if !trimmed.isEmpty { out.append(Row(kind: .ask)) }
        return out
    }

    var body: some View {
        let groups = groups
        let rows = rows(groups)
        GeometryReader { geo in
            // Never taller than the space there is (a banner above the window content takes some of it).
            let top = min(72, geo.size.height * 0.1)
            let maxList = max(160, min(Self.maxListHeight, geo.size.height - top - Self.fieldHeight - Self.footerHeight - 24))
            ZStack(alignment: .top) {
                Brand.color.shadow
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture(perform: close)
                VStack(spacing: 0) {
                    field
                    // No rules between field, list and footer (§15.1): the list follows the field with a little
                    // space, and the footer is a faint tonal band clipped by the palette's rounded shape.
                    if !rows.isEmpty || !trimmed.isEmpty {
                        list(groups: groups, rows: rows, maxHeight: maxList)
                    }
                    footer
                        .background(Brand.color.cardAlt.opacity(0.4))
                }
                .frame(width: min(Self.width, max(320, geo.size.width - 32)))
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous)
                    .strokeBorder(Brand.color.lineSoft, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous))
                .brandOverlayShadow()
                .padding(.top, top)
                .padding(.horizontal, 16)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
        }
        .background(HostWindowReader(host: host))
        .onAppear {
            query = initialQuery
            index.refresh(state: state, debounce: false)
            installMonitor()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear(perform: removeMonitor)
        .onChange(of: query) {
            selected = 0
            expanded = []
        }
    }

    // MARK: Pieces

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(Brand.font(15))
                .foregroundStyle(Brand.color.text3)
            TextField(L("search.placeholder"), text: $query)
                .textFieldStyle(.plain)
                .font(Brand.font(15))
                .foregroundStyle(Brand.color.text)
                .focused($fieldFocused)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.fieldHeight)
    }

    private func list(groups: [SearchSection], rows: [Row], maxHeight: CGFloat) -> some View {
        let headers = groups.count + (trimmed.isEmpty || !groups.isEmpty ? 0 : 1)
        let rowsHeight = rows.reduce(0) { $0 + $1.height }
        let height = min(maxHeight, rowsHeight + CGFloat(headers) * Self.headerHeight + 12)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups) { section in
                        header(section.group.title)
                        ForEach(sectionRows(section)) { row in
                            rowView(row, rows: rows)
                        }
                    }
                    if !trimmed.isEmpty {
                        if groups.isEmpty {
                            Text(L("search.empty"))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.horizontal, 10)
                        }
                        rowView(Row(kind: .ask), rows: rows)
                    }
                }
                .padding(6)
            }
            .scrollIndicators(.never)   // no legacy scroller track against the rounded edge; arrows and the wheel scroll
            .frame(height: height)
            .onChange(of: selected) { _, new in
                if rows.indices.contains(new) { proxy.scrollTo(rows[new].id) }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Brand.font(11, .semibold))
            .foregroundStyle(Brand.color.text2)
            .textCase(.uppercase)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .frame(height: Self.headerHeight, alignment: .bottomLeading)
    }

    private func rowView(_ row: Row, rows: [Row]) -> some View {
        let position = rows.firstIndex(of: row) ?? -1
        let isSelected = position == selected
        return Button {
            activate(row)
        } label: {
            HStack(spacing: 10) {
                icon(row)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title(row))
                            .font(Brand.body)
                            .foregroundStyle(isMore(row) ? Brand.color.accent : Brand.color.text)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .layoutPriority(1)
                        if case .item(let item) = row.kind, !item.subtitle.isEmpty {
                            Text(item.subtitle)
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text2)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                    if case .item(let item) = row.kind, let snippet = item.snippet {
                        Text(Self.attributed(snippet))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "return")
                        .font(Brand.caption)
                        .foregroundStyle(Brand.color.text3)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: row.height)
            .background(isSelected ? Brand.color.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(row.id)
        .onHover { inside in
            guard inside, position >= 0 else { return }
            // A row that scrolled under a still pointer (↑↓) doesn't take the selection.
            if let atKey = pointerAtKeyMove {
                guard NSEvent.mouseLocation != atKey else { return }
                pointerAtKeyMove = nil
            }
            selected = position
        }
    }

    @ViewBuilder private func icon(_ row: Row) -> some View {
        switch row.kind {
        case .item(let item):
            if let emoji = item.emoji {
                Text(emoji).font(Brand.font(13))
            } else {
                Image(systemName: item.symbol).foregroundStyle(Brand.color.text2)
            }
        case .more:
            Image(systemName: "chevron.down").foregroundStyle(Brand.color.accent)
        case .ask:
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Brand.color.accent)
        }
    }

    private func title(_ row: Row) -> String {
        switch row.kind {
        case .item(let item): item.title
        case .more(_, let n): L("search.more", n)
        case .ask: L("search.askBrain", trimmed)
        }
    }

    private func isMore(_ row: Row) -> Bool {
        if case .more = row.kind { return true }
        return false
    }

    /// The snippet with the matching words in semibold (the text color stays the row's).
    static func attributed(_ parts: [SnippetPart]) -> AttributedString {
        var out = AttributedString()
        for part in parts {
            var piece = AttributedString(part.text)
            if part.bold { piece.inlinePresentationIntent = .stronglyEmphasized }
            out += piece
        }
        return out
    }

    /// "↑↓ moverte · ↩ abrir · ⌘↩ preguntar · esc".
    private var footer: some View {
        HStack(spacing: 14) {
            hints
            Spacer(minLength: 0)
            Text(verbatim: "esc")
                .font(Brand.font(11, .medium))
                .foregroundStyle(Brand.color.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: Self.footerHeight)
    }

    private var hints: some View {
        HStack(spacing: 14) {
            hint(["arrow.up.arrow.down"], L("search.hint.move"))
            hint(["return"], L("search.hint.open"))
            hint(["command", "return"], L("search.hint.askShort"))
        }
        .fixedSize()
    }

    /// Key symbols (all SF Symbols, one weight) and what they do.
    private func hint(_ symbols: [String], _ text: String) -> some View {
        HStack(spacing: 4) {
            HStack(spacing: 1) {
                ForEach(symbols, id: \.self) { Image(systemName: $0) }
            }
            Text(text).lineLimit(1)
        }
        .font(Brand.caption)
        .foregroundStyle(Brand.color.text3)
    }

    // MARK: Keyboard

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// true = consumed. Only keys typed in the palette's own window while no sheet is up on it: a sheet or the
    /// Ajustes window keeps its ↑↓, Return and Esc.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window = event.window, window === host.window, window.attachedSheet == nil else { return false }
        let rows = rows(groups)
        switch event.keyCode {
        case 125:   // ↓
            pointerAtKeyMove = NSEvent.mouseLocation
            if !rows.isEmpty { selected = min(selected + 1, rows.count - 1) }
            return true
        case 126:   // ↑
            pointerAtKeyMove = NSEvent.mouseLocation
            selected = max(selected - 1, 0)
            return true
        case 53:    // esc
            close()
            return true
        case 36, 76:   // return
            if event.modifierFlags.contains(.command) {
                ask()
            } else if rows.indices.contains(selected) {
                activate(rows[selected])
            } else {
                ask()
            }
            return true
        default:
            return false
        }
    }

    // MARK: Actions

    private func activate(_ row: Row) {
        switch row.kind {
        case .item(let item):
            SearchIndex.noteOpened(item, state: state)
            close()
            SearchIndex.perform(item.target, state: state)
        case .more(let group, _):
            // The selection stays on the same spot: now the first of the newly shown rows.
            expanded.insert(group)
        case .ask:
            ask()
        }
    }

    /// The whole brain, in a new conversation (§16.7).
    private func ask() {
        let q = trimmed
        guard !q.isEmpty else { return }
        close()
        state.ask(q, scope: .brain)
    }

    private func close() {
        removeMonitor()
        state.searchPresented = false
    }
}

/// The NSWindow a SwiftUI view is in (a reference box: setting it never re-renders the view).
final class HostWindow {
    weak var window: NSWindow?
}

private struct HostWindowReader: NSViewRepresentable {
    let host: HostWindow

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { host.window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if host.window !== view.window { DispatchQueue.main.async { host.window = view.window } }
    }
}
