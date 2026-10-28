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
        // Same column width as the other tabs (640 + padding). The tab already says "Reglas": no page title.
        RulesPanel(store: state.engine.routing, showsTitle: false)
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
            BrandSheetFooter {
                Spacer()
                Button(L("common.done")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.defaultAction)
            }
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
    /// The sheet shows "Reglas" as its title; Ajustes → Reglas doesn't repeat the tab's name.
    var showsTitle = true
    @ViewState private var editing: RuleEditorItem?
    @ViewState private var error: String?
    @ViewState private var deleted: (rule: RoutingRule, index: Int)?
    // MARK: v0.7 backfill — "Traer anteriores…" (§17.6): from a rule's menu, or right after creating a mail rule.
    @ViewState private var backfill: RuleBackfillItem?
    @ViewState private var createdRule: RoutingRule?
    /// Only the vault's rules look in the mailbox (snapshots pass another store).
    private var backfills: Bool { store === state.engine.routing }

    private var lang: String { state.config.uiLanguage }

    /// One row of the list (two lines of text + padding), used to size the card to its rows.
    private static let rowHeight: CGFloat = 52
    private var listHeight: CGFloat { CGFloat(store.rules.count) * Self.rowHeight + 22 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if store.rules.isEmpty {
                empty
            } else {
                list
            }
            footer
            // Leftover height goes below the controls, never inside the card.
            Spacer(minLength: 0)
        }
        .animation(Brand.motion.animation(), value: deleted?.rule.id)
        .onChange(of: editing?.id) { if editing != nil { deleted = nil } }
        .sheet(item: $editing, onDismiss: {
            if let rule = createdRule, backfills, canBackfill(rule, state: state) { backfill = RuleBackfillItem(rule: rule) }
            createdRule = nil
        }) { item in
            RuleEditorSheet(store: store, item: item, mail: mail, onCreated: { createdRule = $0 })
        }
        .sheet(item: $backfill) { RuleBackfillSheet(rule: $0.rule) }
        .onAppear { store.refresh() }   // `sb rules add` or another Mac may have changed them
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                if showsTitle {
                    Text(L("rules.title")).font(Brand.title).foregroundStyle(Brand.color.text)
                }
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
        .padding(.top, showsTitle ? 20 : Brand.spacing.contentWide)
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
                // No row rules: the rows breathe apart instead (§15.1 calm surfaces).
                row(rule)
                    .listRowSeparator(.hidden)
            }
            .onMove { from, to in attempt { try store.move(fromOffsets: from, toOffset: to) } }
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds(.disabled)
        .scrollContentBackground(.hidden)
        .background(Brand.color.card)
        .clipShape(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.lineSoft))
        // Sized to its rows (scrolls when they don't fit), so no empty block sits under the last rule.
        .frame(minHeight: min(120, listHeight), idealHeight: listHeight, maxHeight: listHeight)
        .padding(.horizontal, Brand.spacing.contentWide)
        .layoutPriority(1)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let deleted {
                HStack(spacing: 8) {
                    Text(L("rules.deleted")).foregroundStyle(Brand.color.text2)
                    Button(L("rules.undo")) { restore(deleted) }
                        .buttonStyle(.settingsLink)
                }
                .transition(.opacity)
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
                BrandMenuPicker(title: defaultTitle, selection: defaultBinding, maxWidth: 200) {
                    Text(L("rules.unassigned")).tag("")
                    if !state.projects.isEmpty { Divider() }
                    ForEach(state.projects) { p in Text("\(p.emoji) \(p.name)").tag(p.slug) }
                    if let slug = store.settings.defaultProjectSlug, state.project(slug) == nil { Text(slug).tag(slug) }
                }
            }
            // v0.7 (§17.5): the switch also drives following saved threads, so it shows with any mail account.
            if store.rules.contains(where: \.autoAddMail) || state.engine.accounts.accounts.contains(where: \.provider.hasMail) {
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
                if backfills, canBackfill(rule, state: state) {
                    Button(L("batch.bringEarlier")) { backfill = RuleBackfillItem(rule: rule) }
                }
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
                BrandMoreLabel()
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.plain)
            .fixedSize()
            .help(L("rules.more"))
        }
        .padding(.vertical, 6)
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

    /// What the "el resto va a" pull-down shows: the project, "Sin asignar", or a slug that no longer exists.
    private var defaultTitle: String {
        guard let slug = store.settings.defaultProjectSlug, !slug.isEmpty else { return L("rules.unassigned") }
        if let p = state.project(slug) { return "\(p.emoji) \(p.name)" }
        return slug
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
        // v0.6 (§16.10): new mail rules save the next matching mail by themselves.
        RoutingRule(conditions: [RuleCondition(field: .senderEmail, op: .is, value: "")], projectSlug: state.projects.first?.slug,
                    autoAddMail: true)
    }

    private func duplicate(_ rule: RoutingRule) {
        var copy = RoutingRule(name: rule.name.isEmpty ? "" : L("rules.copyName", rule.name), enabled: rule.enabled,
                               conditions: rule.conditions, projectSlug: rule.projectSlug, autoAddMail: rule.autoAddMail)
        copy.hits = 0
        attempt {
            try store.add(copy)
            // Only a copy that is really in the store opens in the editor.
            editing = RuleEditorItem(rule: copy, isNew: false)
            if let from = store.rules.firstIndex(where: { $0.id == copy.id }),
               let original = store.rules.firstIndex(where: { $0.id == rule.id }) {
                try store.move(fromOffsets: IndexSet(integer: from), toOffset: original + 1)
            }
        }
    }

    private func delete(_ rule: RoutingRule) {
        guard let index = store.rules.firstIndex(where: { $0.id == rule.id }) else { return }
        attempt {
            try store.remove(id: rule.id)
            deleted = (rule, index)
        }
        // "Regla eliminada · Deshacer" lasts a few seconds (a later deletion replaces it).
        let id = rule.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            if deleted?.rule.id == id { deleted = nil }
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
