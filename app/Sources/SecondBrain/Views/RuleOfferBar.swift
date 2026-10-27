import BrainCore
import SwiftUI

// v0.4 "Aprender de la asignación manual" (CONTRACT §14.3): after the user puts something in a project by hand, one
// quiet line offers the rule that would do it next time: «¿Todo lo de @acme.com a 🚀 Acme de ahora en adelante?»
// · Sí, siempre · Solo esta vez. Shared by Correo, "Agregar correo" and Sin asignar.

/// The offer on screen (at most one): asking for ~10 s, then "Regla creada · Deshacer" for a few seconds.
@MainActor @Observable
final class RuleOffer {
    enum Phase: Equatable { case asking, created, failed(String) }

    struct Current: Identifiable, Equatable {
        let id = UUID()
        var rule: RoutingRule
        /// Markdown: the sender/domain in bold.
        var prompt: String
        var phase: Phase = .asking
    }

    private(set) var current: Current?
    @ObservationIgnored private var timer: Task<Void, Never>?

    static let askSeconds: Double = 10
    static let doneSeconds: Double = 6

    /// Offers the rule for having put `subject` in `projectSlug` by hand. Nothing (false) without a project, when there
    /// is no sensible rule (mail from the owner to the owner…) or when an equivalent rule already exists.
    @discardableResult
    func propose(_ subject: RoutingSubject?, projectSlug: String?, state: AppState) -> Bool {
        guard let subject, let projectSlug, state.project(projectSlug) != nil,
              let rule = RoutingStore.suggestedRule(for: subject, projectSlug: projectSlug, language: Localizer.language),
              !state.engine.routing.hasEquivalentRule(rule)
        else { return false }
        show(rule, projectLabel: state.projectName(projectSlug))
        return true
    }

    /// Shows `rule` as the offer (snapshots use it directly).
    func show(_ rule: RoutingRule, projectLabel: String) {
        current = Current(rule: rule, prompt: Self.prompt(for: rule, projectLabel: projectLabel))
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
    }

    private func schedule(_ seconds: Double) {
        timer?.cancel()
        let id = current?.id
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled, let self, self.current?.id == id else { return }
            self.current = nil
        }
    }

    /// «¿Todo lo de **@acme.com** a 🚀 Acme de ahora en adelante?», worded after the rule's field.
    static func prompt(for rule: RoutingRule, projectLabel: String) -> String {
        guard let condition = rule.conditions.first else { return "" }
        let value = condition.value.trimmingCharacters(in: .whitespaces)
        let isEmail = value.contains("@") && !value.hasPrefix("@")
        let shown = "**" + (isEmail || value.hasPrefix("@") ? value : "@" + value) + "**"
        let key: String
        switch condition.field {
        case .recipient: key = "rules.offer.to"
        case .organizerEmail: key = "rules.offer.organizer"
        case .attendeeEmail, .attendeeDomain: key = "rules.offer.with"
        default: key = "rules.offer.from"
        }
        // "🤝 Alianza" never breaks right after its emoji.
        let label = projectLabel.replacingOccurrences(of: " ", with: "\u{00A0}", range: projectLabel.range(of: " "))
        return L(key, shown, label)
    }
}

/// The offer line. Renders nothing when there is no offer.
struct RuleOfferBar: View {
    @Environment(AppState.self) private var state
    let offer: RuleOffer

    var body: some View {
        if let current = offer.current {
            HStack(spacing: 10) {
                switch current.phase {
                case .asking:
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.accentColor)
                    Text(Self.attributed(current.prompt))
                        .font(.callout)
                        .lineLimit(3)
                        .layoutPriority(1)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button(L("rules.offer.always")) { offer.accept(state: state) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button(L("rules.offer.once")) { offer.dismiss() }
                        .controlSize(.small)
                case .created:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("rules.offer.created")).font(.callout)
                    Text("·").foregroundStyle(.tertiary)
                    Button(L("rules.offer.undo")) { offer.undo(state: state) }
                        .buttonStyle(.link)
                        .font(.callout.weight(.medium))
                    Spacer(minLength: 0)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange).lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25)))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    static func attributed(_ markdown: String) -> AttributedString {
        (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(markdown.replacingOccurrences(of: "**", with: ""))
    }
}

/// "🚀 Acme" chip for a mail the rules (or the default project) would send somewhere, same look as Reuniones' chip.
struct RoutedProjectChip: View {
    let label: String
    let help: String

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            Text(label)
        }
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.accentColor.opacity(0.14), in: Capsule())
        .fixedSize()
        .help(help)
    }
}
