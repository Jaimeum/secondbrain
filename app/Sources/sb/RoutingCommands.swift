import ArgumentParser
import BrainCore
import Foundation

/// v0.4 routing rules (CONTRACT §14.6): `sb rules`, `sb rules add|remove`, `sb route`.
struct RulesCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rules", abstract: "List or edit the routing rules (mail and meetings → projects).",
                                                    subcommands: [List.self, Add.self, Remove.self], defaultSubcommand: List.self)

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "List the rules in priority order.")
        @MainActor func run() async throws {
            let engine = makeEngine()
            printRules(engine)
        }
    }

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a rule (lowest priority).",
            discussion: "Fields: \(RuleField.allCases.map(\.rawValue).joined(separator: ", ")). "
                + "Operators: \(RuleOperator.allCases.map(\.rawValue).joined(separator: ", ")). "
                + "--project inbox (or none) = an explicit \"Sin asignar\" rule.")
        @Option(help: "What to look at (senderDomain, senderEmail, subject…)") var field: String
        @Option(help: "contains, is, startsWith, endsWith") var op: String = "is"
        @Option(help: "The value (acme.com, ana@acme.com, Nubia…)") var value: String
        @Option(help: "Project slug, or inbox/none") var project: String
        @Option(help: "A human name (default: generated)") var name: String?
        @Flag(help: "Add new matching mail by itself (§14.5)") var auto = false

        @MainActor func run() async throws {
            let engine = makeEngine()
            guard let f = RuleField.allCases.first(where: { $0.rawValue.lowercased() == field.lowercased() }) else {
                throw CLIError("Unknown field \(field). Use: \(RuleField.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            guard let o = RuleOperator.allCases.first(where: { $0.rawValue.lowercased() == op.lowercased() }) else {
                throw CLIError("Unknown operator \(op). Use: \(RuleOperator.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            let slug: String? = ["inbox", "none", "-", ""].contains(project.lowercased()) ? nil : project
            if let slug, engine.projects.get(slug) == nil { throw CLIError("No project \(slug).") }
            var rule = RoutingRule(f, o, value, projectSlug: slug, name: name ?? "")
            rule.autoAddMail = auto
            try engine.routing.add(rule)
            print("Added: \(engine.routing.displayName(for: rule, projects: engine.projects.list(), language: engine.config.uiLanguage))")
            printRules(engine)
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a rule by its number in `sb rules`.")
        @Argument(help: "Rule number (1 = first)") var index: Int
        @MainActor func run() async throws {
            let engine = makeEngine()
            let rules = engine.routing.rules
            guard rules.indices.contains(index - 1) else { throw CLIError("No rule #\(index) (there are \(rules.count)).") }
            let rule = rules[index - 1]
            try engine.routing.remove(id: rule.id)
            print("Removed: \(engine.routing.displayName(for: rule, projects: engine.projects.list(), language: engine.config.uiLanguage))")
        }
    }
}

@MainActor private func printRules(_ engine: BrainEngine) {
    let s = engine.routing.settings
    let projects = engine.projects.list()
    let lang = engine.config.uiLanguage
    if s.rules.isEmpty { print(es(engine) ? "Aún no hay reglas." : "No rules yet.") }
    for (i, r) in s.rules.enumerated() {
        let name = engine.routing.displayName(for: r, projects: projects, language: lang)
        let conds = r.conditions.map { "\($0.field.rawValue) \($0.op.rawValue) \"\($0.value)\"" }.joined(separator: " AND ")
        print("\(i + 1). [\(r.enabled ? "on " : "off")] \(name) — \(r.hits) hit(s)\(r.autoAddMail ? " · auto" : "")\n     \(conds) → \(r.projectSlug ?? "inbox")")
    }
    print((es(engine) ? "Lo que no coincide va a: " : "Anything else goes to: ")
          + RoutingStore.projectLabel(s.defaultProjectSlug, projects: projects, language: lang))
}

struct RouteCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "route", abstract: "Show where a mail or a meeting would go.")
    @Option(help: "Sender (mail) or organizer (meeting) address") var from: String?
    @Option(help: "Mail subject") var subject: String?
    @Option(help: "Meeting title (makes it a meeting)") var title: String?
    @Option(help: "Recipient / attendee address (repeatable)") var attendee: [String] = []
    @Option(help: "Body or notes") var text: String = ""
    /// "n veces" counts what a rule really decided: asking where something would go is a preview unless told otherwise.
    @Flag(help: "Count the hit, as if the rule had routed something") var countHit = false
    @Flag(help: .hidden) var dryRun = false   // the default since v0.4 integration; kept so old scripts still run

    @MainActor func run() async throws {
        let engine = makeEngine()
        func addr(_ s: String) -> EmailAddress {
            EmailParser.parseAddresses(s).first ?? EmailAddress(name: nil, email: s.lowercased())
        }
        let subject = RoutingSubject(kind: title != nil ? .meeting : .mail, sender: from.map(addr), recipients: attendee.map(addr),
                                     subject: title ?? subject ?? "", text: text, ownerEmails: engine.vault.ownerEmails())
        let lang = engine.config.uiLanguage
        let projects = engine.projects.list()
        // Exactly what the app decides (§14.2): a rule to a deleted project is skipped, then the default project.
        let preview = engine.routingPreview(subject)
        if countHit, !dryRun, preview.decision != nil { _ = engine.routing.route(subject) }
        engine.routing.flush()
        if let decision = preview.decision {
            print("\(RoutingStore.projectLabel(preview.projectSlug, projects: projects, language: lang)) — "
                  + (es(engine) ? "por la regla «" : "by the rule “")
                  + engine.routing.displayName(for: decision.rule, projects: projects, language: lang) + (es(engine) ? "»" : "”"))
        } else if let def = preview.projectSlug {
            print("\(RoutingStore.projectLabel(def, projects: projects, language: lang)) — " + (es(engine) ? "proyecto por defecto" : "default project"))
        } else {
            print(es(engine) ? "Sin asignar" : "Unassigned")
        }
    }
}
