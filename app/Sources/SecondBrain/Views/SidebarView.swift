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
                    item(SidebarItem.unassigned.title, symbol: SidebarItem.unassigned.symbol)
                        .badge(waiting)
                        .tag(SidebarItem.unassigned)
                }
            } header: {
                sectionHeader(L("sidebar.sources"))
            }

            Section {
                ForEach(state.projects) { project in
                    ProjectRow(project: project, inProgress: state.inProgressCount(project.slug))
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
            } header: {
                sectionHeader(L("sidebar.projects"))
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Brand.color.bg)
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
            item(entry.title, symbol: entry.symbol).tag(entry)
                // Re-clicking the selected row doesn't go through the selection binding: pop Inicio to its root.
                .simultaneousGesture(TapGesture().onEnded {
                    if state.selection == .home { state.homePopToken += 1 }
                })
        case .tasks:
            item(entry.title, symbol: entry.symbol)
                .badge(overdueBadge)
                .help(state.overdueCount > 0 ? L("mytasks.overdueHelp", state.overdueCount) : "")
                .tag(entry)
        default:
            item(entry.title, symbol: entry.symbol).tag(entry)
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

    /// The icon has a fixed tint: the sidebar list's own tint follows vibrancy and goes dark olive on the dark `bg`.
    private func item(_ title: String, symbol: String) -> some View {
        Label {
            Text(title).lineLimit(1)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Brand.color.text2)
        }
        .listItemTint(Brand.color.text2)
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
                    .strokeBorder(Brand.color.line, lineWidth: 1))
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
                RecordControl(placement: .sidebar)
                HStack(spacing: 6) {
                    QueueStatusLine(showsProgressBar: false)
                    Spacer(minLength: 4)
                    AddControl(compact: true)
                }
            } else {
                AddControl()
                QueueStatusLine(showsProgressBar: false)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Brand.color.bg)
        .overlay(alignment: .top) {
            Rectangle().fill(Brand.color.line).frame(height: 1)
        }
    }
}

/// "+ Agregar" (§16.1): Nota · Archivo… · Enlace… · Pegar correo ⌘⇧V · Grabar, into the project on screen (else
/// Sin asignar / classified). `compact` = a "+" only (beside the queue line while recording takes the footer).
/// v0.6: G1 may reuse it in the menu bar.
struct AddControl: View {
    @Environment(AppState.self) private var state
    var compact = false
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
            Divider()
            Button { state.recordNow(placement: .sidebar, meeting: false) } label: {
                Label(state.isRecording ? L("add.stopRecording") : L("record.start"), systemImage: "record.circle")
            }
            .disabled(state.isRecorderBusy)
        } label: {
            if compact {
                Image(systemName: "plus")
            } else {
                Label(L("add.title"), systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
        }
        .menuStyle(.button)
        .menuIndicator(compact ? .hidden : .visible)
        .buttonStyle(.bordered)
        .controlSize(compact ? .small : .large)
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
