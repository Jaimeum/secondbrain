import AppKit
import BrainCore
import SwiftUI

/// ⌘K (CONTRACT §15.2): a centered 560 pt overlay on `card` with the overlay shadow. ↑↓ move, ↩ opens (or asks when
/// nothing matches), ⌘↩ always asks, ⌥ asks the project on screen, esc closes. The last row is always
/// "Preguntar: «…»".
struct SearchPalette: View {
    @Environment(AppState.self) private var state
    var initialQuery = ""

    @ViewState private var query = ""
    @ViewState private var selected = 0
    @ViewState private var optionHeld = false
    @ViewState private var monitor: Any?
    @FocusState private var fieldFocused: Bool

    private var index: SearchIndex { SearchIndex.shared }

    static let width: CGFloat = 560
    static let rowHeight: CGFloat = 32
    static let headerHeight: CGFloat = 26
    static let maxListHeight: CGFloat = 400

    private enum RowKind: Hashable {
        case item(SearchItem)
        case ask
    }

    private struct Row: Identifiable, Hashable {
        let kind: RowKind
        var id: String {
            switch kind {
            case .item(let item): item.id
            case .ask: "ask"
            }
        }
    }

    private var trimmed: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [(SearchGroup, [SearchItem])] {
        trimmed.isEmpty ? index.suggestions(now: MeetingsModel.shared.now) : index.results(for: trimmed)
    }

    /// Selectable rows in display order (the ask row last).
    private func rows(_ groups: [(SearchGroup, [SearchItem])]) -> [Row] {
        var out = groups.flatMap { $0.1.map { Row(kind: .item($0)) } }
        if !trimmed.isEmpty { out.append(Row(kind: .ask)) }
        return out
    }

    /// ⌥ asks the project on screen.
    private var askProject: Project? {
        optionHeld ? state.project(state.currentProjectSlug) : nil
    }

    var body: some View {
        let groups = groups
        let rows = rows(groups)
        ZStack(alignment: .top) {
            Brand.color.shadow
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                field
                if !rows.isEmpty || !trimmed.isEmpty {
                    Rectangle().fill(Brand.color.line).frame(height: 1)
                    list(groups: groups, rows: rows)
                }
                Rectangle().fill(Brand.color.line).frame(height: 1)
                footer
            }
            .frame(width: Self.width)
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous)
                .strokeBorder(Brand.color.line, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: Brand.radius.sheet, style: .continuous))
            .brandOverlayShadow()
            .padding(.top, 72)
            .padding(.horizontal, 16)
        }
        .onAppear {
            query = initialQuery
            index.refresh(state: state, debounce: false)
            installMonitor()
            DispatchQueue.main.async { fieldFocused = true }
        }
        .onDisappear(perform: removeMonitor)
        .onChange(of: query) { selected = 0 }
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
        .frame(height: 48)
    }

    private func list(groups: [(SearchGroup, [SearchItem])], rows: [Row]) -> some View {
        let headers = groups.count + (trimmed.isEmpty || !groups.isEmpty ? 0 : 1)
        let height = min(Self.maxListHeight, CGFloat(rows.count) * Self.rowHeight + CGFloat(headers) * Self.headerHeight + 12)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(groups, id: \.0) { group, items in
                        header(group.title)
                        ForEach(items) { item in
                            rowView(Row(kind: .item(item)), rows: rows)
                        }
                    }
                    if !trimmed.isEmpty {
                        if groups.isEmpty {
                            Text(L("search.empty"))
                                .font(Brand.caption)
                                .foregroundStyle(Brand.color.text3)
                                .frame(height: Self.headerHeight, alignment: .bottomLeading)
                                .padding(.horizontal, 10)
                        }
                        rowView(Row(kind: .ask), rows: rows)
                    }
                }
                .padding(6)
            }
            .frame(height: height)
            .onChange(of: selected) { _, new in
                if rows.indices.contains(new) { proxy.scrollTo(rows[new].id) }
            }
        }
    }

    private func header(_ title: String) -> some View {
        Text(title)
            .font(Brand.font(11, .semibold))
            .foregroundStyle(Brand.color.text3)
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
                HStack(spacing: 8) {
                    Text(title(row))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .layoutPriority(1)
                    if case .item(let item) = row.kind, !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text3)
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
            .frame(height: Self.rowHeight)
            .background(isSelected ? Brand.color.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(row.id)
        .onHover { inside in if inside, position >= 0 { selected = position } }
    }

    @ViewBuilder private func icon(_ row: Row) -> some View {
        switch row.kind {
        case .item(let item):
            if let emoji = item.emoji {
                Text(emoji).font(Brand.font(13))
            } else {
                Image(systemName: item.symbol).foregroundStyle(Brand.color.text2)
            }
        case .ask:
            Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Brand.color.accent)
        }
    }

    private func title(_ row: Row) -> String {
        switch row.kind {
        case .item(let item): item.title
        case .ask:
            if let project = askProject {
                L("search.askProject", "\(project.emoji) \(project.name)", trimmed)
            } else {
                L("search.ask", trimmed)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            hint("arrow.up.arrow.down", L("search.hint.move"))
            hint("return", L("search.hint.open"))
            hint("command", L("search.hint.ask"))
            Spacer(minLength: 0)
            Text(verbatim: "esc")
                .font(Brand.font(11, .medium))
                .foregroundStyle(Brand.color.text3)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
    }

    private func hint(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text).lineLimit(1)
        }
        .font(Brand.caption)
        .foregroundStyle(Brand.color.text3)
    }

    // MARK: Keyboard

    private func installMonitor() {
        removeMonitor()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) }
            return consumed ? nil : event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// true = consumed.
    private func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            optionHeld = event.modifierFlags.contains(.option)
            return false
        }
        let rows = rows(groups)
        switch event.keyCode {
        case 125:   // ↓
            if !rows.isEmpty { selected = min(selected + 1, rows.count - 1) }
            return true
        case 126:   // ↑
            selected = max(selected - 1, 0)
            return true
        case 53:    // esc
            close()
            return true
        case 36, 76:   // return
            let flags = event.modifierFlags
            if flags.contains(.command) || flags.contains(.option) {
                ask(project: flags.contains(.option))
            } else if rows.indices.contains(selected) {
                activate(rows[selected])
            } else {
                ask(project: false)
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
            SearchIndex.noteOpened(item)
            close()
            SearchIndex.perform(item.target, state: state)
        case .ask:
            ask(project: askProject != nil)
        }
    }

    private func ask(project: Bool) {
        let q = trimmed
        guard !q.isEmpty else { return }
        close()
        state.ask(q, projectSlug: project ? state.currentProjectSlug : nil)
    }

    private func close() {
        removeMonitor()
        state.searchPresented = false
    }
}
