import AppKit
import BrainCore
import SwiftUI

// Small pieces shared by many screens: dates, template pickers, chips, wrapping rows, page preview, source labels.

/// "¿Cuándo pasó?": collapsed to "Ahora · Cambiar" (now is right for almost everything); the date + time picker and
/// its hint appear only after "Cambiar". Used by the note, import and email sheets.
struct WhenField: View {
    @Binding var date: Date
    var hint: String = L("when.hint")
    var initiallyExpanded = false

    @ViewState private var expanded = false

    /// Within a few minutes of now: shown as "Ahora".
    private var isNow: Bool { abs(date.timeIntervalSinceNow) < 5 * 60 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(L("when.title"))
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.text)
                    .lineLimit(1)
                if expanded || initiallyExpanded {
                    BrandDateField(date: $date, maxDate: Date().addingTimeInterval(366 * 86400))
                        .accessibilityLabel(L("when.title"))
                    if !Calendar.current.isDateInToday(date) {
                        Text(Fmt.relativeDay(date))
                            .font(Brand.caption)
                            .foregroundStyle(Brand.color.text2)
                            .lineLimit(1)
                    }
                } else {
                    Text(isNow ? L("when.now") : Fmt.dayTime(date))
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(1)
                    Text(verbatim: "·").foregroundStyle(Brand.color.text3)
                    Button(L("when.change")) {
                        withAnimation(Brand.motion.animation(fast: true)) { expanded = true }
                    }
                    .buttonStyle(.plain)
                    .font(Brand.callout)
                    .foregroundStyle(Brand.color.accent)
                }
            }
            if expanded || initiallyExpanded {
                Text(hint)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

    @Environment(\.labelsVisibility) private var labelsVisibility

    /// A brand pop-up (never the system one with its accent chevron box), with its label in front unless the caller
    /// hides labels.
    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            if labelsVisibility != .hidden {
                Text(label).foregroundStyle(Brand.color.text).lineLimit(1).fixedSize()
            }
            BrandPicker(selection: $selection,
                        options: [(String?.none, defaultTitle)]
                            + state.templates(for: scope).map { (Optional($0.id), $0.name) })
                .accessibilityLabel(label)
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

/// Title + subtitle block of the small sheets (Cambiar fecha, Cambiar formato, Exportar).
struct SheetTitleBlock: View {
    let title: String
    var subtitle: String? = nil
    var symbol: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
                .lineLimit(1)
            if let subtitle, !subtitle.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    if let symbol {
                        Image(systemName: symbol).foregroundStyle(Brand.color.text2).imageScale(.small)
                    }
                    Text(subtitle)
                        .font(Brand.body)
                        .foregroundStyle(Brand.color.text2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "Cambiar fecha…": corrects when a source happened; I re-learn it to place it right in the timeline.
struct ChangeDateSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord

    @ViewState private var date = Date()
    @ViewState private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.l) {
            SheetTitleBlock(title: L("dates.changeTitle"), subtitle: source.title, symbol: source.symbol)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text(source.eventLabel).foregroundStyle(Brand.color.text2).gridColumnAlignment(.trailing)
                    BrandDateField(date: $date)
                        .accessibilityLabel(source.eventLabel)
                }
                GridRow {
                    Text(source.addedLabel).foregroundStyle(Brand.color.text2)
                    Text(Fmt.eventDate(source.createdAt)).foregroundStyle(Brand.color.text2).lineLimit(1)
                }
            }
            .font(Brand.body)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Brand.color.text3)
                Text(source.historyId != nil || source.status == .done ? L("dates.changeRelearn") : L("dates.changeHint"))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.body)
            .foregroundStyle(Brand.color.text2)
            if let error {
                Text(error).font(Brand.body).foregroundStyle(Brand.color.danger).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Brand.spacing.s) {
                Spacer(minLength: 0)
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
                Button(L("dates.changeSave"), action: save)
                    .buttonStyle(.brandPrimary)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(minWidth: 400, idealWidth: 460, maxWidth: 560)
        .background(Brand.color.surface)
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

/// "Cambiar formato…": rewrites only the page of this source with another template.
struct ReformatSheet: View {
    @Environment(AppState.self) private var state
    @Environment(\.dismiss) private var dismiss
    let source: SourceRecord

    @ViewState private var templateId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.l) {
            SheetTitleBlock(title: L("reformat.title"), subtitle: source.title, symbol: source.symbol)
            HStack(spacing: Brand.spacing.s) {
                Text(L("tpl.picker")).foregroundStyle(Brand.color.text).lineLimit(1).fixedSize()
                BrandPicker(selection: $templateId,
                            options: state.templates(for: TemplateScope(kind: source.kind) ?? .meeting)
                                .map { (Optional($0.id), $0.name) })
                    .accessibilityLabel(L("tpl.picker"))
            }
            .frame(maxWidth: 360, alignment: .leading)
            if let template = state.template(templateId), !template.description.isEmpty {
                Text(template.description)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "info.circle").foregroundStyle(Brand.color.text3)
                Text(L("reformat.hint")).fixedSize(horizontal: false, vertical: true)
            }
            .font(Brand.body)
            .foregroundStyle(Brand.color.text2)
            HStack(spacing: Brand.spacing.s) {
                Spacer(minLength: 0)
                Button(L("common.cancel")) { dismiss() }
                    .buttonStyle(.brandGhost)
                    .keyboardShortcut(.cancelAction)
                Button(L("reformat.go")) {
                    if let templateId { state.engine.reformat(sourceId: source.id, templateId: templateId) }
                    dismiss()
                }
                .buttonStyle(.brandPrimary)
                .keyboardShortcut(.defaultAction)
                .disabled(templateId == nil || templateId == source.templateId)
            }
        }
        .padding(Brand.spacing.xxl)
        .frame(minWidth: 400, idealWidth: 460, maxWidth: 560)
        .background(Brand.color.surface)
        .onAppear {
            state.reloadTemplates()
            templateId = source.templateId ?? state.templates(for: TemplateScope(kind: source.kind) ?? .meeting).first?.id
        }
    }
}

/// A brand capsule label for task rows ("Yo", "Kickoff con Acme", "27 oct · hoy"): one line, truncates, readable at
/// 11 pt (AA). Same symbol semantics as `BrandChip` (the symbol carries the tone), plus `maxWidth` and strikethrough.
/// - `neutral`: `text` on sand, symbol `text2`.
/// - `accent` ("Yo", "Hecho el…"): `accent` text and symbol on `accentSoft`.
/// - `warning` (due today / overdue): `warning` symbol on `warningSoft`, text in `text` (warning text on its soft
///   background measures ~3.3:1, below AA at this size).
struct Chip: View {
    enum Tone { case neutral, accent, warning }

    let text: String
    var tone: Tone = .neutral
    var symbol: String? = nil
    /// Done items: the text struck through and quieter (`text2`).
    var strikethrough = false
    /// Caps the chip so a long title truncates instead of widening the row.
    var maxWidth: CGFloat? = nil

    private var textColor: Color {
        switch tone {
        case .accent: Brand.color.accent
        case .neutral, .warning: strikethrough ? Brand.color.text2 : Brand.color.text
        }
    }

    private var symbolColor: Color {
        switch tone {
        case .neutral: Brand.color.text2
        case .accent: Brand.color.accent
        case .warning: Brand.color.warning
        }
    }

    private var fill: Color {
        switch tone {
        case .neutral: Brand.color.cardAlt
        case .accent: Brand.color.accentSoft
        case .warning: Brand.color.warningSoft
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).imageScale(.small).foregroundStyle(symbolColor)
            }
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
                .strikethrough(strikethrough, color: Brand.color.text2)
                .foregroundStyle(textColor)
        }
        .font(Brand.font(11, .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .background(Capsule().fill(fill))
        .contentShape(Capsule())
    }
}

/// Left-aligned rows that wrap (task chips). A child wider than the row is proposed the row's width, so a chip with
/// `lineLimit(1)` truncates instead of overflowing.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = arrange(maxWidth: maxWidth, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + lineSpacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(maxWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                                      proposal: ProposedViewSize(width: size.width, height: size.height))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            var size = subviews[index].sizeThatFits(.unspecified)
            if size.width > maxWidth {   // too wide for any row: give it the row's width (it truncates)
                size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
                size.width = min(size.width, maxWidth)
            }
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > maxWidth, !current.indices.isEmpty {
                rows.append(current)
                current = Row(indices: [index], sizes: [size], width: size.width, height: size.height)
            } else {
                current.indices.append(index)
                current.sizes.append(size)
                current.width = needed
                current.height = max(current.height, size.height)
            }
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

/// What a `[[key]]` citation is called on screen: the meeting/email title (never the raw slug), its kind symbol, and
/// the page it opens (nil = not found in the vault).
struct SourceLabel: Equatable {
    var title: String
    var symbol: String
    var help: String
    var path: String?
    /// The vault was asked (a nil `path` then means "no page").
    var resolved = false
}

/// O(1) lookups of `[[key]]` citations, with the same rule as `AppState.source(forKey:)`: the first record whose raw
/// file name is the key, else the last message of the email thread with that key.
struct SourceIndex {
    private var byKey: [String: SourceRecord] = [:]
    private var byThread: [String: SourceRecord] = [:]

    init(_ sources: [SourceRecord]) {
        for source in sources {
            if let key = source.sourceKey, byKey[key] == nil { byKey[key] = source }
            if let thread = source.threadKey { byThread[thread] = source }
        }
    }

    func source(forKey key: String) -> SourceRecord? { byKey[key] ?? byThread[key] }
}

/// Resolves citation keys to titles via the engine's records and the vault (`resolveWikilinksAsync` + `title(of:)`),
/// cached per project + key. When the vault changes the cache goes stale: stale labels keep showing (no flicker)
/// but no longer claim "not found", and the next `resolve` replaces them.
@MainActor @Observable
final class SourceLabels {
    static let shared = SourceLabels()

    private var cache: [String: SourceLabel] = [:]
    /// Labels from before the last vault change, shown until re-resolved.
    @ObservationIgnored private var stale: [String: SourceLabel] = [:]
    @ObservationIgnored private var revision = -1
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var indexedSources: [SourceRecord] = []
    @ObservationIgnored private var cachedIndex = SourceIndex([])

    private static func cacheKey(_ key: String, _ projectSlug: String) -> String { projectSlug + "|" + key }

    /// The engine's records indexed by citation key, rebuilt only when `engine.sources` changes (an identical array
    /// compares by storage first, so the check is cheap). Reading it from a body observes `engine.sources`.
    func index(_ state: AppState) -> SourceIndex {
        let sources = state.engine.sources
        if sources != indexedSources {
            indexedSources = sources
            cachedIndex = SourceIndex(sources)
        }
        return cachedIndex
    }

    /// Best label right now: cached for this vault revision, else the previous one (never "missing"), else the
    /// engine's record, else a date-based fallback ("Reunión · 26 oct").
    func label(for key: String, projectSlug: String, state: AppState) -> SourceLabel {
        let id = Self.cacheKey(key, projectSlug)
        if revision == state.vaultRevision, let cached = cache[id] { return cached }
        if var old = (revision == state.vaultRevision ? nil : cache[id]) ?? stale[id] {
            old.resolved = false
            return old
        }
        if let source = index(state).source(forKey: key) {
            return SourceLabel(title: source.title, symbol: source.symbol, help: source.datesHelp)
        }
        return Self.fallback(key)
    }

    @ObservationIgnored private var queued: [String: Set<String>] = [:]   // project → keys waiting for the next batch
    @ObservationIgnored private var flush: Task<Void, Never>?

    /// Looks the keys up in the vault (off the main thread) and caches the result. Calls made in the same moment (every
    /// row of a list) are batched into one vault walk per project.
    func resolve(_ keys: [String], projectSlug: String, state: AppState) async {
        if revision != state.vaultRevision {
            revision = state.vaultRevision
            stale.merge(cache) { _, new in new }
            cache = [:]
            inFlight = []
        }
        let missing = Set(keys).filter {
            let id = Self.cacheKey($0, projectSlug)
            return cache[id] == nil && !inFlight.contains(id)
        }
        guard !missing.isEmpty else { return }
        inFlight.formUnion(missing.map { Self.cacheKey($0, projectSlug) })
        queued[projectSlug, default: []].formUnion(missing)
        if flush == nil {
            flush = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(30))
                await self?.runBatch(state: state)
            }
        }
        await flush?.value
    }

    private func runBatch(state: AppState) async {
        let batch = queued
        queued = [:]
        flush = nil
        let vault = state.engine.vault, generation = revision
        let found: [String: [String: [String]]] = await Task.detached(priority: .userInitiated) {
            var out: [String: [String: [String]]] = [:]
            for (slug, keys) in batch {
                let base = "projects/\(slug)/wiki/index.md"
                for (key, path) in vault.resolveWikilinks(Array(keys), from: base) {
                    out[slug, default: [:]][key] = [path, vault.title(of: path)]
                }
            }
            return out
        }.value
        guard generation == revision else { return }   // the vault changed meanwhile: the cache was reset
        let index = index(state)
        for (slug, keys) in batch {
            for key in keys {
                let source = index.source(forKey: key)
                var label = source.map { SourceLabel(title: $0.title, symbol: $0.symbol, help: $0.datesHelp) } ?? Self.fallback(key)
                if let hit = found[slug]?[key], hit.count == 2 {
                    let path = hit[0], title = hit[1]
                    label.path = path
                    let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                    if source == nil, !title.isEmpty, title != fileName {
                        label.title = title
                        label.symbol = Self.symbol(forPath: path)
                    }
                }
                label.resolved = true
                let id = Self.cacheKey(key, slug)
                cache[id] = label
                stale[id] = nil
                inFlight.remove(id)
            }
        }
    }

    /// "Reunión · 26 oct" from a dated key (`2026-10-26-0900-…`), else the slug made readable ("Comité de la alianza").
    static func fallback(_ key: String) -> SourceLabel {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        var date: Date?
        if parts.count >= 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) {
            date = Calendar.current.date(from: DateComponents(year: y, month: m, day: d))
        }
        let isEmail = key.lowercased().contains("correo") || key.lowercased().contains("email")
        if let date {
            let day = Fmt.dayTime(date, hasTime: false)
            var rest = Array(parts.dropFirst(3))
            if let first = rest.first, first.count == 4, Int(first) != nil { rest.removeFirst() }   // HHmm
            let readable = humanize(rest.joined(separator: " "))
            return SourceLabel(title: L(isEmail ? "tasks.sourceEmail" : "tasks.sourceMeeting", day),
                               symbol: isEmail ? "envelope" : "waveform",
                               help: readable.isEmpty ? day : "\(readable) · \(day)")
        }
        let readable = humanize(key.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " "))
        return SourceLabel(title: readable.isEmpty ? L("tasks.sourceUnknown") : readable,
                           symbol: isEmail ? "envelope" : "doc.text", help: readable)
    }

    private static func humanize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first else { return "" }
        return first.uppercased() + trimmed.dropFirst()
    }

    /// Kind symbol from where a page lives in the vault.
    static func symbol(forPath path: String) -> String {
        if path.contains("/meetings/") { return SourceKind.meeting.symbol }
        if path.contains("/emails/") { return SourceKind.email.symbol }
        if path.hasPrefix("people/") { return "person" }
        return "doc.text"
    }
}

/// Where a source's summary lives in the wiki: `wiki/meetings|sources/<key>.md`, or `wiki/emails/<thread>.md`.
enum SourcePages {
    static func candidates(for source: SourceRecord) -> [String] {
        guard let slug = source.projectSlug else { return [] }
        let wiki = "projects/\(slug)/wiki/"
        var out: [String] = []
        if source.kind == .email, let thread = source.threadKey { out.append(wiki + "emails/\(thread).md") }
        if source.kind == .inPerson, let key = FileDumpNames.pageKey(of: source) { out.append(wiki + "meetings/\(key).md") }   // v0.7
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
