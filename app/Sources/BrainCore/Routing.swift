import Foundation
import Observation

// v0.4 routing rules (CONTRACT §14): one account receives mail and meetings of every project; rules say which
// project each one belongs to. They live in the vault (`.secondbrain/routing.json`) so they travel with the brain.

// MARK: - Types

public enum RuleField: String, Codable, CaseIterable, Sendable {
    case senderEmail, senderDomain, senderName, recipient /* to/cc, email o dominio */, subject,
         attendeeEmail, attendeeDomain, organizerEmail, title /* reunión */, anyText /* asunto+título+cuerpo/notas */
}

public enum RuleOperator: String, Codable, CaseIterable, Sendable { case contains, `is`, startsWith, endsWith }

public struct RuleCondition: Codable, Hashable, Sendable {
    public var field: RuleField
    public var op: RuleOperator
    public var value: String
    public init(field: RuleField, op: RuleOperator, value: String) {
        self.field = field; self.op = op; self.value = value
    }
}

public struct RoutingRule: Codable, Identifiable, Hashable, Sendable {
    public var id: String                    // uuid
    public var name: String                  // human; empty = generated ("De @acme.com → 🚀 Acme")
    public var enabled: Bool
    public var conditions: [RuleCondition]   // ALL must hold (AND); one rule per "or"
    public var projectSlug: String?          // nil = explicit "Sin asignar" (e.g. newsletters)
    public var autoAddMail: Bool             // §14.5: add new matching mail by itself (default false)
    public var createdAt: Date
    public var hits: Int                     // times it decided something
    public var lastHitAt: Date?

    public init(id: String = UUID().uuidString, name: String = "", enabled: Bool = true, conditions: [RuleCondition],
                projectSlug: String?, autoAddMail: Bool = false, createdAt: Date = Date(), hits: Int = 0, lastHitAt: Date? = nil) {
        self.id = id; self.name = name; self.enabled = enabled; self.conditions = conditions; self.projectSlug = projectSlug
        self.autoAddMail = autoAddMail; self.createdAt = createdAt; self.hits = hits; self.lastHitAt = lastHitAt
    }

    /// Convenience: a one-condition rule.
    public init(_ field: RuleField, _ op: RuleOperator, _ value: String, projectSlug: String?, name: String = "") {
        self.init(name: name, conditions: [RuleCondition(field: field, op: op, value: value)], projectSlug: projectSlug)
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        conditions = try c.decodeIfPresent([RuleCondition].self, forKey: .conditions) ?? []
        projectSlug = try c.decodeIfPresent(String.self, forKey: .projectSlug)
        autoAddMail = try c.decodeIfPresent(Bool.self, forKey: .autoAddMail) ?? false
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        hits = try c.decodeIfPresent(Int.self, forKey: .hits) ?? 0
        lastHitAt = try c.decodeIfPresent(Date.self, forKey: .lastHitAt)
    }

    /// Same conditions (normalized, order ignored) as `other`: §14.3 doesn't offer a rule that already exists.
    public func hasSameConditions(as other: RoutingRule) -> Bool {
        Set(conditions.map(RuleMatcher.normalized)) == Set(other.conditions.map(RuleMatcher.normalized))
    }
}

public struct RoutingSettings: Codable, Equatable, Sendable {
    public var rules: [RoutingRule]              // order = priority; the first one that matches wins
    public var defaultProjectSlug: String?       // nil = Sin asignar
    public var mailSyncCursors: [String: Date]   // accountId → last mail checked by auto-add
    public var autoImportEnabled: Bool           // §14.5 global switch "Revisar el correo cada 15 min" (default on)

    public init(rules: [RoutingRule] = [], defaultProjectSlug: String? = nil, mailSyncCursors: [String: Date] = [:],
                autoImportEnabled: Bool = true) {
        self.rules = rules; self.defaultProjectSlug = defaultProjectSlug; self.mailSyncCursors = mailSyncCursors
        self.autoImportEnabled = autoImportEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // One unreadable rule (a field from a newer version) must not lose the others.
        rules = (try c.decodeIfPresent([Lossy<RoutingRule>].self, forKey: .rules) ?? []).compactMap(\.value)
        defaultProjectSlug = try c.decodeIfPresent(String.self, forKey: .defaultProjectSlug)
        mailSyncCursors = (try? c.decodeIfPresent([String: Date].self, forKey: .mailSyncCursors)) ?? [:]
        autoImportEnabled = (try? c.decodeIfPresent(Bool.self, forKey: .autoImportEnabled)) ?? true
    }

    private struct Lossy<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }
}

/// What gets evaluated, mail (connected or pasted) or a meeting.
public struct RoutingSubject: Sendable, Equatable {
    public enum Kind: Sendable { case mail, meeting }
    public var kind: Kind
    public var sender: EmailAddress?        // mail: from · meeting: organizer
    public var recipients: [EmailAddress]   // to+cc · attendees
    public var subject: String              // subject · title
    public var text: String                 // body/snippet · notes (may be empty)
    /// The vault owner's addresses: `attendee*` fields skip them, `suggestedRule` never proposes them.
    public var ownerEmails: [String]

    public init(kind: Kind, sender: EmailAddress?, recipients: [EmailAddress], subject: String, text: String,
                ownerEmails: [String] = []) {
        self.kind = kind; self.sender = sender; self.recipients = recipients; self.subject = subject; self.text = text
        self.ownerEmails = ownerEmails.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
    }

    /// A connected account's message (list row: to only, the snippet as text).
    public static func mail(_ m: MailMessageSummary, ownerEmails: [String] = []) -> RoutingSubject {
        RoutingSubject(kind: .mail, sender: m.from, recipients: m.to, subject: m.subject, text: m.snippet, ownerEmails: ownerEmails)
    }

    /// A pasted or imported email (to+cc, the new text as text). A message marked `isFromOwner` adds its sender to the
    /// owner's addresses.
    public static func mail(_ p: ParsedEmail, ownerEmails: [String] = []) -> RoutingSubject {
        var owners = ownerEmails
        if p.isFromOwner, let e = p.from?.email { owners.append(e) }
        return RoutingSubject(kind: .mail, sender: p.from, recipients: p.to + p.cc, subject: p.subject ?? "", text: p.body,
                              ownerEmails: owners)
    }

    /// A calendar event (organizer as sender, attendees as recipients, title as subject, notes as text).
    public static func meeting(_ e: CalendarEvent, ownerEmails: [String] = []) -> RoutingSubject {
        RoutingSubject(kind: .meeting, sender: e.organizer, recipients: e.attendees, subject: e.title, text: e.notes ?? "",
                       ownerEmails: ownerEmails)
    }

    func isOwner(_ a: EmailAddress) -> Bool {
        guard let e = a.email?.lowercased() else { return false }
        return ownerEmails.contains(e)
    }
}

public struct RoutingDecision: Equatable, Sendable {
    public var rule: RoutingRule
    public var projectSlug: String?
    public init(rule: RoutingRule, projectSlug: String?) { self.rule = rule; self.projectSlug = projectSlug }
}

public enum RoutingError: LocalizedError {
    case ruleNotFound(String)
    case emptyRule

    public var errorDescription: String? {
        switch self {
        case .ruleNotFound(let id): return "Routing rule not found: \(id)"
        case .emptyRule: return "A rule needs at least one condition with a value."
        }
    }
}

// MARK: - Matching

/// Pure rule evaluation (no state). Fields are kind-agnostic: on a meeting `sender*` is the organizer and `subject`
/// the title; on a mail `organizerEmail` is the sender and `title` the subject. `attendee*` look at the recipients
/// minus the owner; `recipient` at all of them (an alias of the owner, `acme@me.com`, is a valid rule).
public enum RuleMatcher {
    /// All conditions hold (AND). A rule without conditions, or a condition with an empty value, never matches.
    /// `enabled` is not checked here (the editor's "Probar" tests a disabled rule too): see `firstMatch`.
    public static func matches(_ rule: RoutingRule, _ s: RoutingSubject) -> Bool {
        !rule.conditions.isEmpty && rule.conditions.allSatisfy { matches($0, s) }
    }

    /// The first enabled rule that matches (list order = priority).
    public static func firstMatch(_ rules: [RoutingRule], _ s: RoutingSubject) -> RoutingRule? {
        rules.first { $0.enabled && matches($0, s) }
    }

    public static func matches(_ c: RuleCondition, _ s: RoutingSubject) -> Bool {
        let v = fold(c.value)
        guard !v.isEmpty else { return false }
        switch c.field {
        case .senderEmail, .organizerEmail:
            return s.sender.map { address($0, c.op, v) } ?? false
        case .senderDomain:
            return s.sender.flatMap(domain).map { domainMatch($0, c.op, v) } ?? false
        case .senderName:
            return s.sender?.name.map { compare(fold($0), c.op, v) } ?? false
        case .recipient:
            return s.recipients.contains { address($0, c.op, v) }
        case .attendeeEmail:
            return s.recipients.contains { !s.isOwner($0) && address($0, c.op, v) }
        case .attendeeDomain:
            return s.recipients.contains { a in !s.isOwner(a) && (domain(a).map { domainMatch($0, c.op, v) } ?? false) }
        case .subject, .title:
            return compare(fold(s.subject), c.op, v)
        case .anyText:
            return [s.subject, s.text].contains { compare(fold($0), c.op, v) }
        }
    }

    /// Case- and accent-insensitive, trimmed ("Ñandú " → "nandu").
    public static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The condition as compared (folded value): used to spot equivalent rules.
    static func normalized(_ c: RuleCondition) -> RuleCondition {
        RuleCondition(field: c.field, op: c.op, value: fold(c.value))
    }

    /// Domain of an address, lowercased ("ana@Mail.Acme.com" → "mail.acme.com").
    public static func domain(_ a: EmailAddress) -> String? {
        guard let e = a.email, let at = e.lastIndex(of: "@") else { return nil }
        let d = fold(String(e[e.index(after: at)...]))
        return d.isEmpty ? nil : d
    }

    /// "@acme.com", "*.acme.com", "ana@acme.com", "acme.com." → "acme.com".
    static func bareDomain(_ v: String) -> String {
        var d = v
        if let at = d.lastIndex(of: "@") { d = String(d[d.index(after: at)...]) }
        if d.hasPrefix("*.") { d.removeFirst(2) }
        while d.hasPrefix(".") { d.removeFirst() }
        while d.hasSuffix(".") { d.removeLast() }
        return d
    }

    /// `is acme.com` accepts acme.com and any subdomain (mail.acme.com), never notacme.com.
    static func domainMatch(_ d: String, _ op: RuleOperator, _ v: String) -> Bool {
        let bare = bareDomain(v)
        guard !bare.isEmpty else { return false }
        switch op {
        case .is: return d == bare || d.hasSuffix("." + bare)
        case .contains: return d.contains(bare)
        case .startsWith: return d.hasPrefix(bare)
        case .endsWith: return d.hasSuffix(bare)
        }
    }

    /// An address field: `is` with a domain ("acme.com", "@acme.com") compares domains; otherwise the email itself.
    static func address(_ a: EmailAddress, _ op: RuleOperator, _ v: String) -> Bool {
        guard let e = a.email.map(fold), !e.isEmpty else { return false }
        let isEmailValue = (v.firstIndex(of: "@").map { $0 != v.startIndex }) ?? false
        if op == .is, !isEmailValue { return domain(a).map { domainMatch($0, .is, v) } ?? false }
        return compare(e, op, v)
    }

    static func compare(_ x: String, _ op: RuleOperator, _ v: String) -> Bool {
        switch op {
        case .contains: return x.contains(v)
        case .is: return x == v
        case .startsWith: return x.hasPrefix(v)
        case .endsWith: return x.hasSuffix(v)
        }
    }
}

// MARK: - Store

/// The vault's rules (`vault/.secondbrain/routing.json`, written atomically). Every write starts from what is on disk
/// (another process — `sb rules add`, the app — may have changed it) and keeps the larger hit count of each rule.
@MainActor @Observable public final class RoutingStore {
    public private(set) var settings: RoutingSettings
    @ObservationIgnored public private(set) var fileURL: URL
    @ObservationIgnored private var lastWrite = Date.distantPast
    @ObservationIgnored private var pendingWrite: Task<Void, Never>?

    /// `<vault>/.secondbrain/routing.json`.
    public nonisolated static func fileURL(vaultRoot: URL) -> URL {
        vaultRoot.appendingPathComponent(".secondbrain/routing.json")
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
        settings = Self.read(fileURL, backupCorrupt: true) ?? RoutingSettings()
    }

    /// Switches to another file (or re-reads the same one). Pending hit counts are written to the old file first.
    public func reload(fileURL: URL) {
        flush()
        self.fileURL = fileURL
        settings = Self.read(fileURL, backupCorrupt: true) ?? RoutingSettings()
    }

    public var rules: [RoutingRule] { settings.rules }
    public func rule(id: String) -> RoutingRule? { settings.rules.first { $0.id == id } }

    /// Appends a rule (lowest priority). Throws `RoutingError.emptyRule` without a usable condition.
    public func add(_ rule: RoutingRule) throws {
        guard rule.conditions.contains(where: { !RuleMatcher.fold($0.value).isEmpty }) else { throw RoutingError.emptyRule }
        try mutate { $0.rules.append(rule) }
    }

    /// Replaces the rule with the same id (hit count and last hit: the larger/later of the stored and given ones).
    public func update(_ rule: RoutingRule) throws {
        guard rule.conditions.contains(where: { !RuleMatcher.fold($0.value).isEmpty }) else { throw RoutingError.emptyRule }
        try mutate { s in
            guard let i = s.rules.firstIndex(where: { $0.id == rule.id }) else { throw RoutingError.ruleNotFound(rule.id) }
            var next = rule
            next.hits = max(rule.hits, s.rules[i].hits)   // the editor's copy may predate later hits
            if let last = s.rules[i].lastHitAt, last > (rule.lastHitAt ?? .distantPast) { next.lastHitAt = last }
            s.rules[i] = next
        }
    }

    public func remove(id: String) throws {
        try mutate { $0.rules.removeAll { $0.id == id } }
    }

    /// Reorders like SwiftUI's `onMove` (offsets of `settings.rules` as shown).
    public func move(fromOffsets: IndexSet, toOffset: Int) throws {
        try mutate(fromDisk: false) { s in
            let moving = fromOffsets.filter { s.rules.indices.contains($0) }.map { s.rules[$0] }
            let before = fromOffsets.filter { $0 < toOffset }.count
            for i in fromOffsets.sorted(by: >) where s.rules.indices.contains(i) { s.rules.remove(at: i) }
            let at = max(0, min(s.rules.count, toOffset - before))
            s.rules.insert(contentsOf: moving, at: at)
        }
    }

    public func setDefaultProject(_ slug: String?) throws {
        try mutate { $0.defaultProjectSlug = slug.flatMap { $0.isEmpty ? nil : $0 } }
    }

    /// §14.5: the global "Revisar el correo cada 15 min" switch (Ajustes → Reglas).
    public func setAutoImportEnabled(_ on: Bool) throws {
        try mutate { $0.autoImportEnabled = on }
    }

    /// §14.5: where auto-add stopped for an account (nil forgets it).
    public func setMailSyncCursor(_ date: Date?, for accountId: String) throws {
        try mutate { $0.mailSyncCursors[accountId] = date }
    }

    /// The first enabled rule that matches, without recording a hit (previews, preselection, "Probar").
    public func match(_ subject: RoutingSubject) -> RoutingDecision? {
        RuleMatcher.firstMatch(settings.rules, subject).map { RoutingDecision(rule: $0, projectSlug: $0.projectSlug) }
    }

    /// The first enabled rule that matches; records the hit (`hits`, `lastHitAt`; written at most once per second).
    public func route(_ subject: RoutingSubject) -> RoutingDecision? {
        guard var decision = match(subject), let i = settings.rules.firstIndex(where: { $0.id == decision.rule.id }) else { return nil }
        settings.rules[i].hits += 1
        settings.rules[i].lastHitAt = Date()
        decision.rule = settings.rules[i]
        scheduleHitWrite()
        return decision
    }

    /// The rule's decision (even an explicit "Sin asignar") ?? the default project. `recordHit: false` for previews.
    public func resolvedProject(_ subject: RoutingSubject, recordHit: Bool = true) -> String? {
        if let d = recordHit ? route(subject) : match(subject) { return d.projectSlug }
        return settings.defaultProjectSlug
    }

    /// A rule with the same conditions already exists (§14.3: then nothing is offered).
    public func hasEquivalentRule(_ rule: RoutingRule) -> Bool {
        settings.rules.contains { $0.id != rule.id && $0.hasSameConditions(as: rule) }
    }

    /// Writes pending hit counts now (the CLI calls it before exiting).
    public func flush() {
        guard pendingWrite != nil else { return }
        pendingWrite?.cancel()
        pendingWrite = nil
        writeHits()
    }

    /// The rule's name, or the generated one ("De @acme.com → 🚀 Acme") when it has none.
    public func displayName(for rule: RoutingRule, projects: [Project], language: String) -> String {
        Self.displayName(for: rule, projects: projects, language: language)
    }

    public nonisolated static func displayName(for rule: RoutingRule, projects: [Project], language: String) -> String {
        let name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        return generatedName(conditions: rule.conditions, projectLabel: projectLabel(rule.projectSlug, projects: projects, language: language),
                             language: language)
    }

    /// "🚀 Acme", the slug when the project is gone, "Sin asignar" / "Unassigned" for nil.
    public nonisolated static func projectLabel(_ slug: String?, projects: [Project], language: String) -> String {
        guard let slug else { return Lang(language).t("Sin asignar", "Unassigned") }
        guard let p = projects.first(where: { $0.slug == slug }) else { return slug }
        return p.emoji.isEmpty ? p.name : "\(p.emoji) \(p.name)"
    }

    /// "De @acme.com → 🚀 Acme", "El asunto contiene «Nubia» y de ana@x.com → 🤝 Alianza".
    public nonisolated static func generatedName(conditions: [RuleCondition], projectLabel: String, language: String) -> String {
        let l = Lang(language)
        let parts = conditions.enumerated().map { i, c in phrase(c, l, first: i == 0) }
        let lhs = parts.isEmpty ? l.t("Sin condiciones", "No conditions") : parts.joined(separator: l.t(" y ", " and "))
        return "\(lhs) → \(projectLabel)"
    }

    nonisolated static func phrase(_ c: RuleCondition, _ l: Lang, first: Bool) -> String {
        let v = c.value.trimmingCharacters(in: .whitespacesAndNewlines)
        let domain = RuleMatcher.bareDomain(v)
        let isEmail = (v.firstIndex(of: "@").map { $0 != v.startIndex }) ?? false
        func cap(_ s: String) -> String { first ? s.prefix(1).uppercased() + s.dropFirst() : s }
        if c.op == .is {
            switch c.field {
            case .senderDomain: return cap(l.t("de @\(domain)", "from @\(domain)"))
            case .senderEmail: return cap(l.t("de ", "from ") + (isEmail ? v : "@\(domain)"))
            case .organizerEmail: return cap(l.t("organiza ", "organized by ") + (isEmail ? v : "@\(domain)"))
            case .attendeeDomain: return cap(l.t("con @\(domain)", "with @\(domain)"))
            case .attendeeEmail: return cap(l.t("con ", "with ") + (isEmail ? v : "@\(domain)"))
            case .recipient: return cap(l.t("para ", "to ") + (isEmail ? v : "@\(domain)"))
            default: break
            }
        }
        let field: String
        switch c.field {
        case .senderEmail: field = l.t("el remitente", "the sender")
        case .senderDomain: field = l.t("el dominio del remitente", "the sender's domain")
        case .senderName: field = l.t("el nombre del remitente", "the sender's name")
        case .recipient: field = l.t("un destinatario", "a recipient")
        case .subject: field = l.t("el asunto", "the subject")
        case .attendeeEmail: field = l.t("un asistente", "an attendee")
        case .attendeeDomain: field = l.t("el dominio de un asistente", "an attendee's domain")
        case .organizerEmail: field = l.t("el organizador", "the organizer")
        case .title: field = l.t("el título", "the title")
        case .anyText: field = l.t("cualquier texto", "any text")
        }
        let op: String
        switch c.op {
        case .contains: op = l.t("contiene", "contains")
        case .is: op = l.t("es", "is")
        case .startsWith: op = l.t("empieza con", "starts with")
        case .endsWith: op = l.t("termina con", "ends with")
        }
        return cap("\(field) \(op) «\(v)»")
    }

    // MARK: Suggestion (§14.3)

    /// Webmail domains: a rule by domain would catch strangers, so the rule uses the address.
    public nonisolated static let publicMailProviders: Set<String> = [
        "gmail", "googlemail", "outlook", "hotmail", "live", "msn", "passport", "yahoo", "ymail", "rocketmail", "icloud", "me",
        "mac", "proton", "protonmail", "pm", "aol", "gmx", "zoho", "zohomail", "yandex", "mail", "hey", "tutanota", "tuta",
        "fastmail", "inbox", "prodigy", "terra", "qq", "163", "126", "naver", "web", "t-online", "orange", "free", "laposte",
        "libero", "wanadoo", "bol", "uol", "att", "comcast", "verizon", "sbcglobal", "bellsouth", "cox", "earthlink",
    ]

    /// gmail.com, yahoo.com.mx, hotmail.es, proton.me, me.com… (provider label + a country/generic suffix).
    public nonisolated static func isPublicDomain(_ domain: String) -> Bool {
        let labels = RuleMatcher.fold(domain).split(separator: ".").map(String.init)
        guard labels.count >= 2, labels.count <= 4, publicMailProviders.contains(labels[0]) else { return false }
        // The rest must look like a public suffix (com, es, com.mx, co.uk, me, net…), not a company's subdomain.
        return labels.dropFirst().allSatisfy { $0.count <= 3 }
    }

    /// The rule §14.3 offers after a manual assignment, or nil when there is nothing sensible to propose.
    /// Mail: corporate sender domain → `senderDomain is`; public domain → `senderEmail is`; sent by the owner → the
    /// first other recipient (domain or address), or nil. Meeting: `organizerEmail is`; organized by the owner (or no
    /// organizer) → first other attendee (`attendeeDomain is`, or `attendeeEmail is` for a public domain), or nil.
    /// `projectName` ("🚀 Acme") fills `name` in `language`; without it the name stays empty (generated on display).
    public nonisolated static func suggestedRule(for subject: RoutingSubject, projectSlug: String?, language: String,
                                                 projectName: String? = nil) -> RoutingRule? {
        func byAddress(_ a: EmailAddress, domainField: RuleField, emailField: RuleField) -> RuleCondition? {
            guard let email = a.email?.lowercased(), email.contains("@") else { return nil }
            guard let d = RuleMatcher.domain(a), !isPublicDomain(d) else { return RuleCondition(field: emailField, op: .is, value: email) }
            return RuleCondition(field: domainField, op: .is, value: d)
        }
        let others = subject.recipients.filter { !subject.isOwner($0) && $0.email != nil }
        var condition: RuleCondition?
        switch subject.kind {
        case .mail:
            if let s = subject.sender, s.email != nil, !subject.isOwner(s) {
                condition = byAddress(s, domainField: .senderDomain, emailField: .senderEmail)
            } else if let r = others.first {
                condition = byAddress(r, domainField: .recipient, emailField: .recipient)
            }
        case .meeting:
            if let o = subject.sender, let e = o.email?.lowercased(), !subject.isOwner(o) {
                condition = RuleCondition(field: .organizerEmail, op: .is, value: e)
            } else if let a = others.first {
                condition = byAddress(a, domainField: .attendeeDomain, emailField: .attendeeEmail)
            }
        }
        guard let condition else { return nil }
        let name = projectName.map { generatedName(conditions: [condition], projectLabel: $0, language: language) } ?? ""
        return RoutingRule(name: name, conditions: [condition], projectSlug: projectSlug)
    }

    // MARK: Persistence

    private func mutate(fromDisk: Bool = true, _ body: (inout RoutingSettings) throws -> Void) throws {
        var next = fromDisk ? Self.merged(disk: Self.read(fileURL, backupCorrupt: false), memory: settings) : settings
        try body(&next)
        try Self.write(next, to: fileURL)
        settings = next
        lastWrite = Date()
    }

    private func scheduleHitWrite() {
        let wait = 1 - Date().timeIntervalSince(lastWrite)
        if wait <= 0, pendingWrite == nil {
            writeHits()
            return
        }
        guard pendingWrite == nil else { return }
        pendingWrite = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, wait)))
            guard !Task.isCancelled, let self else { return }
            self.pendingWrite = nil
            self.writeHits()
        }
    }

    private func writeHits() {
        let next = Self.merged(disk: Self.read(fileURL, backupCorrupt: false), memory: settings)
        do {
            try Self.write(next, to: fileURL)
            settings = next
        } catch {
            Log.error("routing: could not save hit counts: \(error)")
        }
        lastWrite = Date()
    }

    /// Disk wins (rules, order, default, cursors), except hit counts: the larger of both.
    private static func merged(disk: RoutingSettings?, memory: RoutingSettings) -> RoutingSettings {
        guard var out = disk else { return memory }
        for i in out.rules.indices {
            guard let mine = memory.rules.first(where: { $0.id == out.rules[i].id }) else { continue }
            out.rules[i].hits = max(out.rules[i].hits, mine.hits)
            if let m = mine.lastHitAt, m > (out.rules[i].lastHitAt ?? .distantPast) { out.rules[i].lastHitAt = m }
        }
        return out
    }

    /// nil when the file is missing or unreadable. An unreadable file is copied aside once (`routing.corrupt.json`)
    /// so the next save doesn't silently lose the user's rules.
    private nonisolated static func read(_ url: URL, backupCorrupt: Bool) -> RoutingSettings? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder.sb.decode(RoutingSettings.self, from: data)
        } catch {
            Log.error("routing: unreadable \(url.lastPathComponent): \(error)")
            if backupCorrupt {
                let backup = url.deletingLastPathComponent().appendingPathComponent("routing.corrupt.json")
                try? FileManager.default.removeItem(at: backup)
                try? FileManager.default.copyItem(at: url, to: backup)
            }
            return nil
        }
    }

    private nonisolated static func write(_ s: RoutingSettings, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder.sb.encode(s).write(to: url, options: .atomic)
    }
}
