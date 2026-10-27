import BrainCore
import SwiftUI

/// Inicio · Reuniones · Correo · Pendientes · Personas, then Proyectos (CONTRACT §15.2). Header: the brand and the ⌘K
/// search; footer: the one recording control and the queue line.
struct SidebarView: View {
    @Environment(AppState.self) private var state
    @Binding var showNewProject: Bool
    @ViewState private var editing: Project?

    var body: some View {
        List(selection: selection) {
            Section {
                item(L("home.title"), symbol: "house").tag(SidebarItem.home)
                    // Re-clicking the selected row doesn't go through the selection binding: pop Inicio to its root.
                    .simultaneousGesture(TapGesture().onEnded {
                        if state.selection?.normalized == .home { state.homePopToken += 1 }
                    })
                item(L("sidebar.meetings"), symbol: "calendar").tag(SidebarItem.meetings)
                item(L("sidebar.mail"), symbol: "envelope").tag(SidebarItem.mail)
                item(L("tasks.title"), symbol: "checklist")
                    .badge(overdueBadge)
                    .help(state.overdueCount > 0 ? L("mytasks.overdueHelp", state.overdueCount) : "")
                    .tag(SidebarItem.tasks)
                item(L("sidebar.people"), symbol: "person.2").tag(SidebarItem.people)
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
                Text(L("sidebar.projects"))
                    .font(Brand.font(11, .semibold))
                    .foregroundStyle(Brand.color.text2)
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

    /// Selection through `SidebarItem.normalized`, so an alias set elsewhere (`.myTasks`, `.brain`) still highlights
    /// its row. Clicking "Inicio" while on Inicio goes back to its root (from a page, the timeline, the graph…).
    private var selection: Binding<SidebarItem?> {
        Binding(get: { state.selection?.normalized ?? state.selection }, set: { item in
            if item == .home, state.selection?.normalized == .home { state.homePopToken += 1 }
            state.selection = item
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

/// ≤ 96 pt: the recording control and, under it, the queue line.
private struct SidebarFooter: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RecordControl(placement: .sidebar)
            QueueStatusLine(showsProgressBar: false)
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
