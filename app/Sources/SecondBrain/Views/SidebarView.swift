import AppKit
import BrainCore
import SwiftUI

/// Inicio · Preguntar · Grafo · Pendientes · Personas, then Fuentes (Correo · Reuniones · Sin asignar) and Proyectos
/// (CONTRACT §16.1). Header: the brand and the ⌘K search; footer: "+ Agregar" (and the recording card while a meeting
/// is on or a recording runs) over the queue line.
struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var showNewProject: Bool
    @ViewState private var editing: Project?

    var body: some View {
        List(selection: selection) {
            Section {
                ForEach(SidebarItem.main, id: \.self) { entry in
                    row(entry)
                }
            }

            Section {
                ForEach(SidebarItem.sources, id: \.self) { entry in
                    row(entry)
                }
                // Only while something waits (or while on it, so assigning the last one doesn't pull the screen away).
                let waiting = state.unassignedCount
                if waiting > 0 || state.selection == .unassigned {
                    item(SidebarItem.unassigned)
                        .badge(waiting)
                        .tag(SidebarItem.unassigned)
                }
            } header: {
                sectionHeader(L("sidebar.sources"))
            }

            Section {
                ForEach(state.projects) { project in
                    ProjectRow(project: project, inProgress: state.inProgressCount(project.slug))
                        .brandSidebarRow(selected: state.selection == .project(project.slug))
                        .tag(SidebarItem.project(project.slug))
                        .contextMenu {
                            Button(L("project.edit")) { editing = project }
                            Button(L("email.addEllipsis")) { state.requestEmail(projectSlug: project.slug) }
                        }
                }
                Button {
                    showNewProject = true
                } label: {
                    Label {
                        Text(L("sidebar.newProject")).lineLimit(1)
                    } icon: {
                        Image(systemName: "plus").foregroundStyle(Brand.color.text2)
                    }
                    .foregroundStyle(Brand.color.text2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listItemTint(Brand.color.text2)
                .brandSidebarRow(selected: false)
            } header: {
                sectionHeader(L("sidebar.projects"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Brand.color.bg)
        .background(SidebarHighlightRemover())
        .safeAreaInset(edge: .top, spacing: 0) {
            SidebarHeader()
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooter()
        }
        .sheet(item: $editing) { project in
            NewProjectSheet(editing: project)
        }
    }

    @ViewBuilder private func row(_ entry: SidebarItem) -> some View {
        switch entry {
        case .home:
            item(entry).tag(entry)
                // Re-clicking the selected row doesn't go through the selection binding: pop Inicio to its root.
                .simultaneousGesture(TapGesture().onEnded {
                    if state.selection == .home { state.homePopToken += 1 }
                })
        case .tasks:
            item(entry)
                .badge(overdueBadge)
                .help(state.overdueCount > 0 ? L("mytasks.overdueHelp", state.overdueCount) : "")
                .tag(entry)
        default:
            item(entry).tag(entry)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(Brand.font(11, .semibold))
            .foregroundStyle(Brand.color.text2)
    }

    /// Every click goes through the router (§16.12), which drops requests left for other screens.
    private var selection: Binding<SidebarItem?> {
        Binding(get: { state.selection }, set: { item in
            if let item { state.navigate(to: .sidebar(item)) } else { state.selection = nil }
        })
    }

    /// The icon has a fixed tint (the sidebar list's own tint follows vibrancy and goes dark olive on the dark `bg`):
    /// `text2`, or `accent` with the title when the row is the selected one.
    private func item(_ entry: SidebarItem) -> some View {
        let selected = state.selection == entry
        return Label {
            Text(entry.title).lineLimit(1)
        } icon: {
            Image(systemName: entry.symbol).foregroundStyle(selected ? Brand.color.accent : Brand.color.text2)
        }
        .listItemTint(selected ? Brand.color.accent : Brand.color.text2)
        .brandSidebarRow(selected: selected)
    }

    /// Count of my overdue tasks in the warning tone (a plain badge can't be tinted, so it's text).
    private var overdueBadge: Text? {
        guard state.overdueCount > 0 else { return nil }
        return Text("\(state.overdueCount)").foregroundStyle(Brand.color.warning)
    }
}

/// Brand mark + wordmark, and the "Buscar o preguntar… ⌘K" button that opens the palette. The mark pulses calmly
/// when something was learned (motion spec C).
private struct SidebarHeader: View {
    @Environment(AppState.self) private var state

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            BrandLogo(size: 20)
                .brandPulse(trigger: state.historyRevision)
                .padding(.leading, 4)
            Button {
                state.searchPresented = true
            } label: {
                // The whole placeholder with "⌘K"; then "⌘K" stays and the placeholder truncates; only very narrow
                // drops the hint (it is also in the tooltip).
                ViewThatFits(in: .horizontal) {
                    searchLabel(shortcut: true)
                    searchLabel(shortcut: true, truncates: true)
                    searchLabel(shortcut: false, truncates: true)
                }
                .font(Brand.body)
                .padding(.horizontal, 6)
                .frame(height: 28)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                    .strokeBorder(Brand.color.lineSoft, lineWidth: 1))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("search.placeholder") + "  ⌘K")
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(Brand.color.bg)
    }

    private func searchLabel(shortcut: Bool, truncates: Bool = false) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(Brand.color.text3)
            Text(L("search.placeholder"))
                .foregroundStyle(Brand.color.text3)
                .lineLimit(1)
                .fixedSize(horizontal: !truncates, vertical: false)
            Spacer(minLength: 2)
            if shortcut {
                // The same key chip as Inicio's search field.
                Text(verbatim: "⌘K")
                    .font(Brand.font(10, .medium))
                    .foregroundStyle(Brand.color.text3)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Brand.color.cardAlt, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .fixedSize()
            }
        }
    }
}

/// Same icon column as the items above: the project's emoji is the label's icon.
private struct ProjectRow: View {
    let project: Project
    let inProgress: Int

    var body: some View {
        Label {
            HStack(spacing: 6) {
                Text(project.name).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if inProgress > 0 {
                    HStack(spacing: 4) {
                        BrandLoader(size: 12)
                        Text("\(inProgress)")
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .monospacedDigit()
                    }
                    .help(L("sidebar.inProgress", inProgress))
                }
            }
        } icon: {
            Text(project.emoji).font(Brand.font(13))
        }
    }
}

/// ≤ 96 pt (§16.1): "+ Agregar" and the queue line. Recording takes the footer only while a calendar meeting is on
/// or a recording runs (the record-soft card of §15.2); "+ Agregar" then shrinks to a "+" beside the queue line.
private struct SidebarFooter: View {
    @Environment(AppState.self) private var state

    var body: some View {
        let recordTakesOver = state.isRecording || state.isRecorderBusy
            || MeetingBanner.recordableNow(state: state, now: MeetingsModel.shared.now) != nil
        VStack(alignment: .leading, spacing: 4) {
            if recordTakesOver {
                // §16.1: Grabar takes the footer; "+ Agregar" stays a real button, secondary, right under it.
                RecordControl(placement: .sidebar)
                AddControl(secondary: true)
                QueueStatusLine(showsProgressBar: false)
            } else {
                AddControl()
                QueueStatusLine(showsProgressBar: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // No hard top line: the list fades into `bg` above the footer (§15.1 calm surfaces).
        .background(alignment: .top) {
            LinearGradient(colors: [Brand.color.bg.opacity(0), Brand.color.bg], startPoint: .top, endPoint: .bottom)
                .frame(height: 16)
                .offset(y: -16)
                .allowsHitTesting(false)
        }
        .background(Brand.color.bg)
    }
}

/// "+ Agregar" (§16.1): Nota · Archivo… · Enlace… · Pegar correo ⌘⇧V · Grabar, into the project on screen (else
/// Sin asignar / classified). `compact` = a "+" only; `secondary` = full width but regular size (under the Grabar
/// card while a meeting is on or recording).
/// v0.6: G1 may reuse it in the menu bar.
struct AddControl: View {
    @Environment(AppState.self) private var state
    var compact = false
    var secondary = false
    @ViewState private var error: String?

    var body: some View {
        Menu {
            Button { state.noteRequest = NoteRequest(projectSlug: state.currentProjectSlug) } label: {
                Label(L("add.note"), systemImage: "square.and.pencil")
            }
            Button(action: addFiles) { Label(L("add.file"), systemImage: "doc.badge.plus") }
            Button { state.linkRequest = LinkRequest(projectSlug: state.currentProjectSlug) } label: {
                Label(L("add.link"), systemImage: "link")
            }
            // ⌘⇧V is the app menu's (Edit › Pegar correo); the label shows it.
            Button { state.requestEmail() } label: { Label(L("add.email"), systemImage: "envelope") }
            Button { state.dumpRequest = DumpRequest(projectSlug: state.currentProjectSlug) } label: {   // v0.7 (§17.3)
                Label(L("add.dump"), systemImage: "tray.and.arrow.down")
            }
            .disabled(state.projects.isEmpty)
            Divider()
            Button { state.recordNow(placement: .sidebar, meeting: false) } label: {
                Label(state.isRecording ? L("add.stopRecording") : L("record.start"), systemImage: "record.circle")
            }
            .disabled(state.isRecorderBusy)
        } label: {
            AddControlLabel(compact: compact, secondary: secondary)
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .frame(maxWidth: compact ? nil : .infinity)
        .fixedSize(horizontal: compact, vertical: false)
        .help(L("add.help"))
        .disabled(!state.engineStarted)
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }

    /// Files import right away with their own dates, into the project on screen (like a drop).
    private func addFiles() {
        guard let batch = SourceImport.chooseFiles() else { return }
        let slug = state.currentProjectSlug
        Task {
            let failed = await SourceImport.importURLs(batch.urls, projectSlug: slug, state: state)
            if !failed.isEmpty { error = failed.joined(separator: "\n") }
        }
    }
}

/// The face of "+ Agregar": a quiet capsule on `card` (no system bordered button, no blue chevron box) with the "+"
/// in a small `accentSoft` circle, the label in `text` and a faint `text3` chevron that says it opens a menu. Hover
/// warms the capsule to `cardAlt` and fills the circle with `accent`. `secondary` is shorter (under the Grabar card);
/// `compact` is the circle alone.
private struct AddControlLabel: View {
    let compact: Bool
    let secondary: Bool
    @ViewState private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Group {
            if compact {
                plusGlyph(size: 22)
            } else {
                HStack(spacing: 8) {
                    plusGlyph(size: secondary ? 18 : 20)
                    Text(L("add.title"))
                        .font(Brand.callout)
                        .foregroundStyle(Brand.color.text)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.down")
                        .font(Brand.font(9, .semibold))
                        .foregroundStyle(Brand.color.text3)
                }
                .padding(.leading, secondary ? 5 : 6)
                .padding(.trailing, 12)
                .frame(height: secondary ? 28 : 32)
                .background(Capsule(style: .continuous).fill(hovering ? Brand.color.cardAlt : Brand.color.card))
                .overlay(Capsule(style: .continuous).strokeBorder(Brand.color.lineSoft, lineWidth: 1))
            }
        }
        .contentShape(Capsule(style: .continuous))
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering = $0 }
        .animation(Brand.motion.fast, value: hovering)
        .accessibilityLabel(L("add.title"))
    }

    private func plusGlyph(size: CGFloat) -> some View {
        Image(systemName: "plus")
            .font(Brand.font(size * 0.5, .semibold))
            .foregroundStyle(hovering ? Brand.color.onAccent : Brand.color.accent)
            .frame(width: size, height: size)
            .background(Circle().fill(hovering ? Brand.color.accent : Brand.color.accentSoft))
    }
}

// MARK: Sidebar rows

private struct BrandSidebarRow: ViewModifier {
    let selected: Bool
    @ViewState private var hovering = false

    func body(content: Content) -> some View {
        content
            .foregroundStyle(selected ? Brand.color.accent : Brand.color.text)
            .fontWeight(selected ? .medium : .regular)
            .onHover { hovering = $0 }
            .listRowBackground(
                RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous)
                    .fill(selected ? Brand.color.accentSoft : hovering ? Brand.color.hover : .clear)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .animation(Brand.motion.fast, value: hovering)
                    .animation(Brand.motion.fast, value: selected)
            )
    }
}

private extension View {
    /// Brand selection for a sidebar row (§15.1): `accentSoft` rounded fill with `accent` title and icon, a faint
    /// `hover` fill under the pointer. Replaces the system highlight (the user's macOS accent, often blue), which
    /// `SidebarHighlightRemover` switches off.
    func brandSidebarRow(selected: Bool) -> some View { modifier(BrandSidebarRow(selected: selected)) }
}

/// Turns off the sidebar table's own selection highlight (it paints the user's macOS accent color, which `.tint`
/// doesn't reach) while keeping its selection, keyboard navigation and accessibility: the brand fill is drawn by
/// `brandSidebarRow`. Finds the nearest `NSTableView` around the list it sits behind.
private struct SidebarHighlightRemover: NSViewRepresentable {
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) { nsView.apply() }

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
            DispatchQueue.main.async { [weak self] in self?.apply() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.apply() }
        }

        /// Only a source-list table under this probe (the sidebar's), never a table of the detail column.
        func apply() {
            guard window != nil else { return }
            let mine = convert(bounds, to: nil)
            var ancestor = superview
            while let view = ancestor {
                if let table = Self.firstSourceList(in: view, overlapping: mine) {
                    if table.selectionHighlightStyle != .none { table.selectionHighlightStyle = .none }
                    return
                }
                ancestor = view.superview
            }
        }

        private static func firstSourceList(in view: NSView, overlapping rect: CGRect) -> NSTableView? {
            if let table = view as? NSTableView, table.style == .sourceList || table.selectionHighlightStyle == .sourceList,
               let scroll = table.enclosingScrollView, scroll.convert(scroll.bounds, to: nil).intersects(rect) {
                return table
            }
            for sub in view.subviews {
                if let table = firstSourceList(in: sub, overlapping: rect) { return table }
            }
            return nil
        }
    }
}
