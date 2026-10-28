import BrainCore
import SwiftUI

/// The ficha of the node selected in the graph, compact (CONTRACT §16.5: a short §16.4 beside the graph, without
/// leaving it): kind, title, project, date and connections; "Abrir" (= double click) goes to the full ficha where it
/// lives; the page Claude wrote, compact; and what it is connected to. A link inside the page or a connected row that
/// is a node of this graph selects it here; anything else opens where it lives.
/// v0.6 integration: once `EntityCard(path:scope:onOpen:)` (entity pages) exists, it can replace the page body.
struct GraphNodePanel: View {
    @Environment(AppState.self) private var state
    let node: GraphNode
    let neighbours: [GraphNode]
    let scope: Scope
    let projects: [Project]
    var isNode: (String) -> Bool
    /// A node id (a project hub is `project:<slug>`) or a vault page.
    var onOpen: (String) -> Void
    var onSelect: (String) -> Void
    var onClose: () -> Void

    /// The page the panel shows: a project hub stands for its overview.
    private var page: String {
        node.kind == .project ? "projects/\(node.projectSlug ?? "")/wiki/overview.md" : node.id
    }

    private var project: Project? { node.projectSlug.flatMap { slug in projects.first { $0.slug == slug } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Brand.color.line).frame(height: 1)
            WikiWebView(vault: state.engine.vault, path: page, hideType: true, compact: true) { link in
                if let id = GraphView.nodeId(for: link), isNode(id) { onSelect(id) } else { onOpen(link) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if !neighbours.isEmpty {
                Rectangle().fill(Brand.color.line).frame(height: 1)
                connected
            }
        }
        .background(Brand.color.surface)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.s) {
            HStack(spacing: Brand.spacing.xs + 2) {
                Image(systemName: GraphKindStyle.symbol(node.kind))
                    .font(Brand.caption)
                Text(L("graph.kind.\(node.kind.rawValue)"))
                    .font(Brand.font(11, .medium))
                    .lineLimit(1)
                Spacer(minLength: Brand.spacing.s)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(Brand.font(11, .semibold))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help(L("graph.panel.close"))
                .accessibilityLabel(L("graph.panel.close"))
            }
            .foregroundStyle(Brand.color.text2)

            Text(node.title)
                .font(Brand.section)
                .foregroundStyle(Brand.color.text)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .help(node.title)

            Text(meta)
                .font(Brand.caption)
                .foregroundStyle(Brand.color.text2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: Brand.spacing.s) {
                Button { onOpen(node.id) } label: {
                    Label(L("graph.panel.open"), systemImage: "arrow.up.right")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.brandPrimary)
                .help(L(node.kind == .project ? "graph.panel.openProjectHelp" : "graph.panel.openHelp"))
                if EntityView.isEditable(page) {
                    Button { state.editPage(page) } label: {
                        Label(L("entity.edit"), systemImage: "pencil").labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.brandSecondary)
                    .help(L("entity.editHelp"))
                }
                Spacer(minLength: 0)
            }
            .padding(.top, Brand.spacing.xs)
        }
        .padding(Brand.spacing.l)
    }

    /// "🚀 Kickoff · 3 mar 2026 · 12 conexiones": the project only where the graph mixes projects (the whole brain).
    private var meta: String {
        var parts: [String] = []
        if scope.isBrain, node.kind != .project, let project { parts.append("\(project.emoji) \(project.name)") }
        if let date = node.date {
            parts.append(date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(Localizer.locale)))
        }
        parts.append(L("graph.panel.links", node.links))
        return parts.joined(separator: " · ")
    }

    private var connected: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L("graph.connected"))
                .font(Brand.font(11, .semibold))
                .foregroundStyle(Brand.color.text2)
                .padding(.bottom, Brand.spacing.xs)
            ForEach(neighbours, id: \.id) { other in
                NeighbourRow(node: other) { onSelect(other.id) }
            }
        }
        .padding(.horizontal, Brand.spacing.m)
        .padding(.vertical, Brand.spacing.m)
    }
}

/// One "Conectado con" row: selects that node in the graph.
private struct NeighbourRow: View {
    let node: GraphNode
    var action: () -> Void
    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Brand.spacing.s) {
                Image(systemName: GraphKindStyle.symbol(node.kind))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .frame(width: 16)
                Text(node.title)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Brand.spacing.xs)
            .padding(.vertical, 4)
            .background(hovering ? Brand.color.accentSoft : .clear,
                        in: RoundedRectangle(cornerRadius: Brand.radius.control - 2))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(node.title)
        .accessibilityHint(L("graph.panel.selectHelp"))
    }
}
