import AppKit
import BrainCore
import SwiftUI

// Small pieces shared by the v0.2 screens: dates, template pickers, chips.

/// "¿Cuándo pasó?": a date + time picker with a short hint, used by the note, import and email sheets.
struct WhenField: View {
    @Binding var date: Date
    var hint: String = L("when.hint")

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Text(L("when.title")).font(.headline)
                DatePicker("", selection: $date, in: ...Date().addingTimeInterval(366 * 86400),
                           displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                    .fixedSize()
                if !Calendar.current.isDateInToday(date) {
                    Text(Fmt.relativeDay(date)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// "Formato": picks one of the vault's templates for a kind of source; nil = the project's default.
struct TemplatePicker: View {
    @Environment(AppState.self) private var state
    let scope: TemplateScope
    @Binding var selection: String?
    var projectSlug: String?
    var label: String = L("tpl.picker")

    var body: some View {
        Picker(label, selection: $selection) {
            Text(defaultTitle).tag(String?.none)
            Divider()
            ForEach(state.templates(for: scope)) { template in
                Text(template.name).tag(Optional(template.id))
            }
        }
        .onAppear { state.reloadTemplates() }
    }

    private var defaultTitle: String {
        let defaultId = state.project(projectSlug)?.defaultTemplate
            ?? (scope == .email ? "correo-hilo" : TemplateInfo.standardId)
        let name = state.template(defaultId)?.name ?? L("tpl.standard")
        return L("tpl.defaultNamed", name)
    }
}

/// "Cambiar fecha…": corrects when a source happened; Claude re-learns it to place it right in the timeline.
struct ChangeDateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord

    @ViewState private var date = Date()
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("dates.changeTitle")).font(.title2.weight(.semibold))
            Text(source.title).font(.headline).lineLimit(2)
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent(source.eventLabel) {
                    DatePicker("", selection: $date, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .fixedSize()
                }
                LabeledContent(source.addedLabel) {
                    Text(Fmt.eventDate(source.createdAt)).foregroundStyle(.secondary)
                }
            }
            Label(source.historyId != nil || source.status == .done ? L("dates.changeRelearn") : L("dates.changeHint"),
                  systemImage: "info.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("dates.changeSave"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear { date = source.timelineDate }
    }

    private func save() {
        do {
            try state.engine.setEventDate(sourceId: source.id, date: date)
            state.bumpVault()
            dismiss()
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}

/// "Regenerar con otro formato…": rewrites only the page of this source with another template.
struct ReformatSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord

    @ViewState private var templateId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("reformat.title")).font(.title2.weight(.semibold))
            Text(source.title).font(.headline).lineLimit(2)
            Picker(L("tpl.picker"), selection: $templateId) {
                ForEach(state.templates(for: source.kind == .email ? .email : .meeting)) { template in
                    Text(template.name).tag(Optional(template.id))
                }
            }
            if let template = state.template(templateId), !template.description.isEmpty {
                Text(template.description).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Label(L("reformat.hint"), systemImage: "info.circle")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(L("common.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("reformat.go")) {
                    if let templateId { state.engine.reformat(sourceId: source.id, templateId: templateId) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(templateId == nil || templateId == source.templateId)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            state.reloadTemplates()
            templateId = source.templateId ?? state.templates(for: source.kind == .email ? .email : .meeting).first?.id
        }
    }
}

/// A rounded, tinted label ("Yo", "🎙️ Kickoff").
struct Chip: View {
    let text: String
    var tint: Color = .secondary
    var symbol: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background((tint == .secondary ? Color.primary : tint).opacity(0.08), in: Capsule())
        .fixedSize()
    }
}

/// Where a source's summary lives in the wiki: `wiki/meetings|sources/<key>.md`, or `wiki/emails/<thread>.md`.
enum SourcePages {
    static func candidates(for source: SourceRecord) -> [String] {
        guard let slug = source.projectSlug else { return [] }
        let wiki = "projects/\(slug)/wiki/"
        var out: [String] = []
        if source.kind == .email, let thread = source.threadKey { out.append(wiki + "emails/\(thread).md") }
        if let key = source.sourceKey {
            out.append(wiki + (source.kind == .meeting ? "meetings/" : "sources/") + key + ".md")
            out.append(wiki + (source.kind == .meeting ? "sources/" : "meetings/") + key + ".md")
        }
        return out
    }

    /// The summary page when it exists (checked on disk), else nil.
    static func summaryPage(for source: SourceRecord, vault: VaultStore) -> String? {
        candidates(for: source).first { FileManager.default.fileExists(atPath: vault.url(for: $0).path) }
    }

    /// The text under `## Acuerdos` / `## Agreements` of a page, up to the next `## ` heading.
    static func agreementsSection(of markdown: String) -> String? {
        var lines: [String] = []
        var inside = false
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                let title = line.dropFirst(3).trimmingCharacters(in: .whitespaces).lowercased()
                inside = title.hasPrefix("acuerdos") || title.hasPrefix("agreements")
                continue
            }
            if inside { lines.append(line) }
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return inside && !text.isEmpty ? text : nil
    }
}

/// Presents an export for a source, page, thread or task list (one sheet, everywhere).
struct ExportRequest: Identifiable {
    enum Target {
        case source(SourceRecord)
        case page(path: String, title: String)
        case tasks([TaskItem], title: String)
    }
    let id = UUID()
    let target: Target
}
