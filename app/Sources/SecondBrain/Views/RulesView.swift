import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.4): the rules screen. The same rows live in Ajustes → Reglas (a Form section) and in the
// "Reglas…" sheet of Correo and Reuniones. Order = priority (drag to reorder); the first rule that matches wins.

/// Opens `RuleEditorSheet` for a new rule or a copy of an existing one.
struct RuleEditorItem: Identifiable {
    let id = UUID()
    var rule: RoutingRule
    var isNew: Bool
}

/// Ajustes → Reglas.
struct RulesSection: View {
    @Environment(AppState.self) private var state
    @ViewState private var editing: RuleEditorItem?

    var body: some View {
        Section {
            RulesRows(store: state.engine.routing, editing: $editing)
        } header: {
            Text(L("rules.title"))
        } footer: {
            Text(L("rules.footer")).foregroundStyle(.secondary)
        }
        .sheet(item: $editing) { item in
            RuleEditorSheet(store: state.engine.routing, item: item)
        }
        .onAppear { state.engine.routing.refresh() }   // `sb rules add` or another Mac may have changed them
    }
}

/// The "Reglas…" button of Correo and Reuniones (one line in their toolbars). `mail`: the messages on screen, for
/// "Probar" in the editor.
struct RulesToolbarButton: View {
    var mail: [MailMessageSummary] = []
    @ViewState private var showing = false

    var body: some View {
        Button { showing = true } label: {
            Label(L("rules.button"), systemImage: "arrow.triangle.branch")
        }
        .help(L("rules.buttonHelp"))
        .sheet(isPresented: $showing) { RulesSheet(mail: mail) }
    }
}

/// The rules as a sheet.
struct RulesSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    /// nil = the vault's rules (snapshots pass another store).
    var store: RoutingStore?
    var mail: [MailMessageSummary] = []
    @ViewState private var editing: RuleEditorItem?

    private var routing: RoutingStore { store ?? state.engine.routing }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("rules.title")).font(.title3.weight(.semibold))
                    Text(L("rules.subtitle")).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 4)
            Form {
                Section {
                    RulesRows(store: routing, editing: $editing)
                } footer: {
                    if !routing.rules.isEmpty { Text(L("rules.footer")).foregroundStyle(.secondary) }
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 600, height: 560)
        .sheet(item: $editing) { item in
            RuleEditorSheet(store: routing, item: item, mail: mail)
        }
        .onAppear { routing.refresh() }   // `sb rules add` or another Mac may have changed them
    }
}

/// The rows: each rule (toggle · name · "n veces" · menu), "Nueva regla", where the rest goes, and the auto-check switch.
struct RulesRows: View {
    @Environment(AppState.self) private var state
    let store: RoutingStore
    @Binding var editing: RuleEditorItem?
    @ViewState private var error: String?
    @ViewState private var deleted: (rule: RoutingRule, index: Int)?

    private var lang: String { state.config.uiLanguage }

    var body: some View {
        if store.rules.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 26))
                    .foregroundStyle(.tertiary)
                Text(L("rules.empty"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
        } else {
            ForEach(store.rules) { rule in
                row(rule)
            }
            .onMove { from, to in attempt { try store.move(fromOffsets: from, toOffset: to) } }
        }
        if let deleted {
            HStack(spacing: 8) {
                Text(L("rules.deleted")).foregroundStyle(.secondary)
                Button(L("rules.undo")) { restore(deleted) }.buttonStyle(.link)
                Spacer()
            }
            .font(.callout)
        }
        HStack {
            Button {
                editing = RuleEditorItem(rule: newRule(), isNew: true)
            } label: {
                Label(L("rules.new"), systemImage: "plus")
            }
            Spacer()
        }
        Picker(L("rules.default.label"), selection: defaultBinding) {
            Text(L("rules.unassigned")).tag("")
            if !state.projects.isEmpty { Divider() }
            ForEach(state.projects) { p in Text("\(p.emoji) \(p.name)").tag(p.slug) }
            if let slug = store.settings.defaultProjectSlug, state.project(slug) == nil { Text(slug).tag(slug) }
        }
        VStack(alignment: .leading, spacing: 2) {
            Toggle(L("rules.autoImport"), isOn: autoBinding)
            Text(store.rules.contains(where: \.autoAddMail) ? L("rules.autoImport.on") : L("rules.autoImport.none"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func row(_ rule: RoutingRule) -> some View {
        HStack(spacing: 10) {
            if store.rules.count > 1 {
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help(L("rules.dragHelp"))
            }
            Toggle("", isOn: Binding(get: { rule.enabled }, set: { on in
                var r = rule
                r.enabled = on
                attempt { try store.update(r) }
            }))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
            .help(rule.enabled ? L("rules.turnOff") : L("rules.turnOn"))
            VStack(alignment: .leading, spacing: 2) {
                Text(store.displayName(for: rule, projects: state.projects, language: lang))
                    .lineLimit(2)
                    .foregroundStyle(rule.enabled ? .primary : .secondary)
                HStack(spacing: 6) {
                    Text(Self.hits(rule.hits))
                    if rule.autoAddMail {
                        Text("·")
                        Label(L("rules.autoBadge"), systemImage: "tray.and.arrow.down").labelStyle(.titleAndIcon)
                    }
                    if !rule.enabled {
                        Text("·")
                        Text(L("rules.off"))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Button(L("rules.edit")) { editing = RuleEditorItem(rule: rule, isNew: false) }
                Button(L("rules.duplicate")) { duplicate(rule) }
                if let i = store.rules.firstIndex(where: { $0.id == rule.id }), store.rules.count > 1 {
                    // Drag also works; these keep reordering possible from the keyboard and inside Ajustes.
                    Divider()
                    Button(L("rules.moveUp")) { attempt { try store.move(fromOffsets: IndexSet(integer: i), toOffset: i - 1) } }
                        .disabled(i == 0)
                    Button(L("rules.moveDown")) { attempt { try store.move(fromOffsets: IndexSet(integer: i), toOffset: i + 2) } }
                        .disabled(i == store.rules.count - 1)
                }
                Divider()
                Button(L("rules.delete"), role: .destructive) { delete(rule) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("rules.more"))
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = RuleEditorItem(rule: rule, isNew: false) }
    }

    /// "Aún sin usar" · "1 vez" · "12 veces".
    static func hits(_ n: Int) -> String {
        switch n {
        case 0: L("rules.hits.zero")
        case 1: L("rules.hits.one")
        default: L("rules.hits.other", n)
        }
    }

    private var defaultBinding: Binding<String> {
        Binding(get: { store.settings.defaultProjectSlug ?? "" },
                set: { slug in attempt { try store.setDefaultProject(slug.isEmpty ? nil : slug) } })
    }

    /// "Revisar el correo cada 15 min": the vault's rules go through `MailAutoImporter` (turning it on checks right away);
    /// another store (snapshots) only saves the switch.
    private var autoBinding: Binding<Bool> {
        let isVault = store === state.engine.routing
        return Binding(get: { isVault ? MailAutoImporter.shared.isEnabled : store.settings.autoImportEnabled },
                       set: { on in attempt { isVault ? try MailAutoImporter.shared.setEnabled(on) : try store.setAutoImportEnabled(on) } })
    }

    private func newRule() -> RoutingRule {
        RoutingRule(conditions: [RuleCondition(field: .senderEmail, op: .is, value: "")], projectSlug: state.projects.first?.slug)
    }

    private func duplicate(_ rule: RoutingRule) {
        var copy = RoutingRule(name: rule.name.isEmpty ? "" : L("rules.copyName", rule.name), enabled: rule.enabled,
                               conditions: rule.conditions, projectSlug: rule.projectSlug, autoAddMail: rule.autoAddMail)
        copy.hits = 0
        attempt {
            try store.add(copy)
            if let from = store.rules.firstIndex(where: { $0.id == copy.id }),
               let original = store.rules.firstIndex(where: { $0.id == rule.id }) {
                try store.move(fromOffsets: IndexSet(integer: from), toOffset: original + 1)
            }
        }
        editing = RuleEditorItem(rule: copy, isNew: false)
    }

    private func delete(_ rule: RoutingRule) {
        guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        attempt {
            try store.remove(id: rule.id)
            deleted = (rule, index)
        }
    }

    private func restore(_ d: (rule: RoutingRule, index: Int)) {
        attempt {
            try store.add(d.rule)
            if let from = store.rules.firstIndex(where: { $0.id == d.rule.id }), d.index < from {
                try store.move(fromOffsets: IndexSet(integer: from), toOffset: d.index)
            }
        }
        deleted = nil
    }

    private func attempt(_ body: () throws -> Void) {
        do {
            try body()
            error = nil
        } catch {
            self.error = FriendlyError.message(error)
        }
    }
}
