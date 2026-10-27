import BrainCore
import SwiftUI

// v0.4 "Aprender de la asignación manual" (CONTRACT §14.3): after the user puts something in a project by hand, one
// quiet line offers the rule that would do it next time: «¿Mandar siempre lo de @acme.com a 🚀 Acme?» (§15.4)
// · Sí, siempre · Solo esta vez. Shared by Correo, "Agregar correo" and Sin asignar.

/// The offer on screen: asking for 10 s, then "Regla creada · Deshacer" for 6 s. One mechanism for every place that
/// offers a rule (Correo, "Agregar correo", Sin asignar, Reuniones), and at most one offer on screen in the whole app:
/// showing one dismisses any other.
@MainActor @Observable
final class RuleOffer {
    enum Phase: Equatable { case asking, created, failed(String) }

    struct Current: Identifiable, Equatable {
        let id = UUID()
        var rule: RoutingRule
        /// «¿Mandar siempre lo de **@acme.com** a 🚀 Acme?» (who in bold).
        var question: AttributedString
        var phase: Phase = .asking
    }

    private(set) var current: Current?
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let askSeconds: Double = 10
    static let doneSeconds: Double = 6
    /// The offer currently on screen, wherever it is (§14.3: never more than one).
    private static weak var active: RuleOffer?

    /// Offers the rule for having put `subject` in `projectSlug` by hand. Nothing (false) without a project, when there
    /// is no sensible rule (mail from the owner to the owner…), when an equivalent rule already exists, or when a rule
    /// already matches `subject` (the user overrode it: a new rule, added last, could never win over it).
    @discardableResult
    func propose(_ subject: RoutingSubject?, projectSlug: String?, state: AppState) -> Bool {
        guard let subject, let projectSlug, state.project(projectSlug) != nil,
              let rule = RoutingStore.offeredRule(for: subject, projectSlug: projectSlug, existing: state.engine.routing.rules,
                                                  language: Localizer.language)
        else { return false }
        show(rule, projectLabel: state.projectName(projectSlug), kind: subject.kind)
        return true
    }

    /// Shows `rule` as the offer (Reuniones computes its own rule; snapshots use it directly).
    func show(_ rule: RoutingRule, projectLabel: String, kind: RoutingSubject.Kind = .mail) {
        if let other = Self.active, other !== self { other.dismiss() }
        Self.active = self
        current = Current(rule: rule, question: Self.question(for: rule, projectLabel: projectLabel, kind: kind))
        schedule(Self.askSeconds)
    }

    /// "Sí, siempre".
    func accept(state: AppState) {
        guard var offer = current, offer.phase == .asking else { return }
        do {
            try state.engine.routing.add(offer.rule)
            offer.phase = .created
        } catch {
            offer.phase = .failed(FriendlyError.message(error))
        }
        current = offer
        schedule(Self.doneSeconds)
    }

    /// "Deshacer" after "Regla creada".
    func undo(state: AppState) {
        guard let offer = current, offer.phase == .created else { return }
        do {
            try state.engine.routing.remove(id: offer.rule.id)
            dismiss()
        } catch {
            current?.phase = .failed(FriendlyError.message(error))
            schedule(Self.doneSeconds)
        }
    }

    /// "Solo esta vez", or the action it was about was undone.
    func dismiss() {
        timer?.cancel()
        current = nil
        if Self.active === self { Self.active = nil }
    }

    private func schedule(_ seconds: Double) {
        timer?.cancel()
        let id = current?.id
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.dismiss()
        }
    }

    /// The question, worded after the rule's first field and what was assigned (§15.4): mail «¿Mandar siempre lo de
    /// **@acme.com** a 🚀 Acme?», meeting «¿Las reuniones que organiza **ana@acme.com** a 🚀 Acme…?». Who goes in
    /// bold; neither value is read as Markdown.
    static func question(for rule: RoutingRule, projectLabel: String, kind: RoutingSubject.Kind) -> AttributedString {
        guard let condition = rule.conditions.first else { return AttributedString(projectLabel) }
        let value = condition.value.trimmingCharacters(in: .whitespaces)
        let isEmail = value.contains("@") && !value.hasPrefix("@")
        let who = isEmail || value.hasPrefix("@") ? value : "@" + value
        let key: String
        switch (kind, condition.field) {
        case (.meeting, .organizerEmail), (.meeting, .senderEmail), (.meeting, .senderDomain): key = "rules.meetingOffer.organizer"
        case (.meeting, _): key = "rules.meetingOffer.with"
        case (.mail, .recipient): key = "rules.offer.to"
        case (.mail, .attendeeEmail), (.mail, .attendeeDomain): key = "rules.offer.with"
        case (.mail, _): key = "rules.offer.from"
        }
        // "☁️ Migración a la nube" stays on one line (the project reads as one name); a very long name is shortened so
        // it can never overflow the line.
        let short = projectLabel.count > 32
            ? String(projectLabel.prefix(31)).trimmingCharacters(in: .whitespaces) + "…" : projectLabel
        let label = short.replacingOccurrences(of: " ", with: "\u{00A0}")
        let marker = "\u{1}"
        var out = AttributedString()
        let parts = L(key, marker, label).components(separatedBy: marker)
        for (i, part) in parts.enumerated() {
            out += AttributedString(part)
            if i < parts.count - 1 {
                var bold = AttributedString(who)
                bold.inlinePresentationIntent = .stronglyEmphasized
                out += bold
            }
        }
        return out
    }
}

/// The offer line. Renders nothing when there is no offer. Question and buttons on one line when they fit, else the
/// question wraps and the buttons go below it (§15.3: nothing fixed-size next to variable text). `compact` (under a
/// meeting's chip) only tightens the padding.
struct RuleOfferBar: View {
    @Environment(AppState.self) private var state
    let offer: RuleOffer
    var compact = false

    var body: some View {
        if let current = offer.current {
            Group {
                switch current.phase {
                case .asking:
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            icon
                            question(current).lineLimit(1)
                            Spacer(minLength: 8)
                            buttons
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                icon
                                question(current)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            buttons
                        }
                    }
                case .created:
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.color.success)
                        Text(L("rules.offer.created")).foregroundStyle(Brand.color.text).lineLimit(1)
                        Text(verbatim: "·").foregroundStyle(Brand.color.text3)
                        Button(L("rules.offer.undo")) { offer.undo(state: state) }
                            .buttonStyle(.plain)
                            .font(Brand.callout)
                            .foregroundStyle(Brand.color.accent)
                        Spacer(minLength: 0)
                    }
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Brand.color.danger)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(Brand.body)
            .padding(.horizontal, compact ? 10 : 12)
            .padding(.vertical, compact ? 7 : 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
            .transition(.opacity)
        }
    }

    private var icon: some View {
        Image(systemName: "arrow.triangle.branch").foregroundStyle(Brand.color.accent)
    }

    private func question(_ current: RuleOffer.Current) -> some View {
        Text(current.question).foregroundStyle(Brand.color.text)
    }

    /// Two short, fixed labels: side by side, or stacked when even that doesn't fit.
    private var buttons: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { always; once }.fixedSize()
            VStack(alignment: .leading, spacing: 6) { always; once }
        }
    }

    private var always: some View {
        Button(L("rules.offer.always")) { offer.accept(state: state) }.buttonStyle(.brandPrimary)
    }

    private var once: some View {
        Button(L("rules.offer.once")) { offer.dismiss() }.buttonStyle(.brandSecondary)
    }
}

/// A rule's name about to go inside the quotes of "Por la regla «%@»": its own quotes become the inner quotes of the
/// language (“…” in Spanish, ‘…’ in English), so "por la regla «El asunto contiene «2027»»" never shows.
func ruleNameForQuotes(_ name: String) -> String {
    if Localizer.language == "en" {
        return name.replacingOccurrences(of: "«", with: "\u{2018}").replacingOccurrences(of: "»", with: "\u{2019}")
            .replacingOccurrences(of: "\u{201C}", with: "\u{2018}").replacingOccurrences(of: "\u{201D}", with: "\u{2019}")
    }
    return name.replacingOccurrences(of: "«", with: "\u{201C}").replacingOccurrences(of: "»", with: "\u{201D}")
}

/// What "Por la regla «…»" names, the same in Correo, "Agregar correo", the mail list and Reuniones: the rule's own
/// name, else its conditions without the destination (the button or chip next to it already shows the project).
func ruleLabel(_ rule: RoutingRule) -> String {
    ruleNameForQuotes(RoutingStore.conditionSummary(rule, language: Localizer.language))
}

/// "Va a 🚀 Acme" chip for a mail the rules (or the default project) would send somewhere — a destination, not a
/// place it is already in ("En el cerebro" says that). Truncates instead of overflowing a narrow list.
struct RoutedProjectChip: View {
    let label: String
    let help: String

    var body: some View {
        BrandChip(text: L("rules.mail.chip", label), symbol: "arrow.right")
            .help(help)
    }
}
