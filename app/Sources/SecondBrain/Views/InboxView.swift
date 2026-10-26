import BrainCore
import SwiftUI

/// "Sin asignar": recordings and files that still need a project. Claude suggests one; one click assigns it.
struct InboxView: View {
    @Environment(AppState.self) private var state
    @ViewState private var error: String?
    @ViewState private var showNote = false

    private var waiting: [SourceRecord] {
        state.engine.sources.filter { $0.status == .needsProject }
    }

    private var other: [SourceRecord] {
        state.engine.sources.filter { $0.projectSlug == nil && $0.status != .needsProject && $0.status != .done }
    }

    var body: some View {
        Group {
            if waiting.isEmpty && other.isEmpty {
                EmptyStateView(symbol: "tray", title: L("inbox.emptyTitle"), message: L("inbox.emptyMessage"))
            } else {
                List {
                    if !waiting.isEmpty {
                        Section(L("inbox.needsProject")) {
                            ForEach(waiting) { source in
                                InboxRow(source: source, onError: { error = $0 })
                            }
                        }
                    }
                    if !other.isEmpty {
                        Section(L("inbox.inProgress")) {
                            ForEach(other) { source in
                                HStack {
                                    Image(systemName: source.kind.symbol).foregroundStyle(.secondary)
                                    Text(source.title)
                                    Spacer()
                                    StatusPill(status: source.status, progress: source.progress)
                                    if source.status == .failed {
                                        Button(L("sources.retry")) { state.engine.retry(sourceId: source.id) }
                                            .controlSize(.small)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle(L("inbox.title"))
        .navigationSubtitle(L("inbox.subtitle"))
        .toolbar {
            Button { showNote = true } label: { Label(L("sources.newNote"), systemImage: "square.and.pencil") }
        }
        .sheet(isPresented: $showNote) { NoteSheet(projectSlug: nil) }
        .alert(L("common.oops"), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button(L("common.ok")) { error = nil }
        } message: {
            Text(error ?? "")
        }
    }
}

private struct InboxRow: View {
    @Environment(AppState.self) private var state
    let source: SourceRecord
    var onError: (String) -> Void

    @ViewState private var showNewProject = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: source.kind.symbol).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                if let suggestion = suggestedProject {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("inbox.suggestion", "\(suggestion.emoji) \(suggestion.name)"))
                            .font(.callout)
                        if let reason = source.suggestionReason, !reason.isEmpty {
                            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer()
                    Button(L("inbox.assign")) { assign(suggestion.slug) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Text(source.suggestedProject == nil && source.suggestionReason == nil
                         ? L("inbox.thinking") : L("inbox.noSuggestion"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                Menu(suggestedProject == nil ? L("inbox.choose") : L("inbox.other")) {
                    ForEach(state.projects) { project in
                        Button("\(project.emoji) \(project.name)") { assign(project.slug) }
                    }
                    Divider()
                    Button(L("sidebar.newProject")) { showNewProject = true }
                }
                .fixedSize()
            }
            .padding(10)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showNewProject) {
            NewProjectSheet { project in assign(project.slug) }
        }
    }

    private var suggestedProject: Project? { state.project(source.suggestedProject) }

    private var subtitle: String {
        var parts = [source.kind.label, Fmt.date(source.createdAt)]
        if let d = source.durationSeconds, d > 0 { parts.append(Fmt.shortDuration(d)) }
        return parts.joined(separator: " · ")
    }

    private func assign(_ slug: String) {
        do { try state.engine.assign(sourceId: source.id, to: slug) } catch {
            onError((error as? EngineError)?.errorDescription ?? L("sources.moveFailed"))
        }
    }
}
