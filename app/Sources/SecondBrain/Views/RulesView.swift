import BrainCore
import SwiftUI

// v0.4 routing (CONTRACT §14.4, §15.2): the rules screen. The same panel lives in Ajustes → Reglas and in the "Reglas…"
// sheet of Correo and Reuniones. Order = priority (drag to reorder); the first rule that matches wins.

/// Opens `RuleEditorSheet` for a new rule or a copy of an existing one.
struct RuleEditorItem: Identifiable {
    let id = UUID()
    var rule: RoutingRule
    var isNew: Bool
}

/// Ajustes → Reglas.
struct RulesSettingsPage: View {
    @Environment(AppState.self) private var state

    var body: some View {
        // Same column width as the other tabs (640 + padding).
        RulesPanel(store: state.engine.routing)
            .frame(maxWidth: 688)
            .frame(maxWidth: .infinity)
            .background(Brand.color.surface)
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

    private var routing: RoutingStore { store ?? state.engine.routing }

    var body: some View {
        VStack(spacing: 0) {
            RulesPanel(store: routing, mail: mail)
            Rectangle().fill(Brand.color.line).frame(height: 1)
            HStack {
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 380, idealHeight: 520)
        .background(Brand.color.surface)
    }
}

/// Title + "Nueva regla", the rules (toggle · name → destination · "n veces" · ⋯, drag to reorder), then where the
/// rest goes and — only when a rule adds mail by itself — the auto-check switch.
struct RulesPanel: View {
    @Environment(AppState.self) private var state
    let store: RoutingStore
    var mail: [MailMessageSummary] = []
    @ViewState private var editing: RuleEditorItem?
    @ViewState private var error: String?
    @ViewState private var deleted: (rule: RoutingRule, index: Int)?

    private var lang: String { state.config.uiLanguage }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.rules.isEmpty {
                empty
            } else {
                list
            }
            footer
        }
        .sheet(item: $editing) { item in
            RuleEditorSheet(store: store, item: item, mail: mail)
        }
        .onAppear { store.refresh() }   // `sb rules add` or another Mac may have changed them
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("rules.title")).font(Brand.title).foregroundStyle(Brand.color.text)
                Text(L("rules.subtitle"))
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                editing = RuleEditorItem(rule: newRule(), isNew: true)
            } label: {
                Label(L("rules.new"), systemImage: "plus")
            }
            .buttonStyle(.brandPrimary)
        }
        .padding(.horizontal, Brand.spacing.contentWide)
        .padding(.top, 20)
        .padding(.bottom, 12)
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(Brand.font(26))
                .foregroundStyle(Brand.color.text3)
            Text(L("rules.empty"))
                .foregroundStyle(Brand.color.text2)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    /// A real List: `.onMove` reorders by drag there (it does nothing inside a grouped Form on macOS).
    private var list: some View {
        List {
            ForEach(store.rules) { rule in
                row(rule)
                    .listRowSeparatorTint(Brand.color.line)
            }
            .onMove { from, to in attempt { try store.move(fromOffsets: from, toOffset: to) } }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Brand.color.card)
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.line))
        .padding(.horizontal, Brand.spacing.contentWide)
        .frame(minHeight: 120, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let deleted {
                HStack(spacing: 8) {
                    Text(L("rules.deleted")).foregroundStyle(Brand.color.text2)
                    Button(L("rules.undo")) { restore(deleted) }
                        .buttonStyle(.settingsLink)
                }
            }
            if store.rules.count > 1 {
                Text(L("rules.footer"))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 12) {
                Text(L("rules.default.label"))
                    .foregroundStyle(Brand.color.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Picker("", selection: defaultBinding) {
                    Text(L("rules.unassigned")).tag("")
                    if !state.projects.isEmpty { Divider() }
                    ForEach(state.projects) { p in Text("\(p.emoji) \(p.name)").tag(p.slug) }
                    if let slug = store.settings.defaultProjectSlug, state.project(slug) == nil { Text(slug).tag(slug) }
                }
                .labelsHidden()
                .frame(maxWidth: 240)
            }
            if store.rules.contains(where: \.autoAddMail) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("rules.autoImport")).foregroundStyle(Brand.color.text)
                        Text(L("rules.autoImport.on"))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Toggle("", isOn: autoBinding).toggleStyle(.switch).labelsHidden()
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, Brand.spacing.contentWide)
        .padding(.vertical, 14)
    }

    private func row(_ rule: RoutingRule) -> some View {
        HStack(spacing: 10) {
            if store.rules.count > 1 {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Brand.color.text3)
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
                    .foregroundStyle(rule.enabled ? Brand.color.text : Brand.color.text2)
                Text(caption(rule))
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Menu {
                Button(L("rules.edit")) { editing = RuleEditorItem(rule: rule, isNew: false) }
                Button(L("rules.duplicate")) { duplicate(rule) }
                if let i = store.rules.firstIndex(where: { $0.id == rule.id }), store.rules.count > 1 {
                    // Drag also works; these keep reordering possible from the keyboard.
                    Divider()
                    Button(L("rules.moveUp")) { attempt { try store.move(fromOffsets: IndexSet(integer: i), toOffset: i - 1) } }
                        .disabled(i == 0)
                    Button(L("rules.moveDown")) { attempt { try store.move(fromOffsets: IndexSet(integer: i), toOffset: i + 2) } }
                        .disabled(i == store.rules.count - 1)
                }
                Divider()
                Button(L("rules.delete"), role: .destructive) { delete(rule) }
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(Brand.color.text2)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
            .help(L("rules.more"))
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = RuleEditorItem(rule: rule, isNew: false) }
    }

    /// "→ 🚀 Atlas · 12 veces · Agrega automáticamente" (the destination only for named rules: generated names say it).
    private func caption(_ rule: RoutingRule) -> String {
        var parts: [String] = []
        if !rule.name.trimmingCharacters(in: .whitespaces).isEmpty {
            parts.append("→ " + RoutingStore.projectLabel(rule.projectSlug, projects: state.projects, language: lang))
        }
        parts.append(Self.hits(rule.hits))
        if rule.autoAddMail { parts.append(L("rules.autoBadge")) }
        if !rule.enabled { parts.append(L("rules.off")) }
        return parts.joined(separator: " · ")
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
