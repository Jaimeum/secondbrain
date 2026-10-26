import Foundation

/// Page templates ("formatos") in `vault/templates/<id>.md` (CONTRACT §11.3).
public extension VaultStore {
    static let templatesDir = "templates"
    static let emailTemplateId = "correo-hilo"

    func templates() -> [TemplateInfo] {
        let fm = FileManager.default
        let dir = url(for: Self.templatesDir)
        let files = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") && !$0.hasPrefix(".") }
        let order = ["estandar", "ejecutivo", "detallado", "solo-acuerdos", "cliente-ventas", "uno-a-uno", "standup",
                     "entrevista", "correo-hilo"]
        return files.compactMap { template(id: String($0.dropLast(3))) }
            .sorted { a, b in
                let ra = order.firstIndex(of: a.id) ?? (a.isBuiltIn ? 50 : 100)
                let rb = order.firstIndex(of: b.id) ?? (b.isBuiltIn ? 50 : 100)
                return (ra, a.name.lowercased()) < (rb, b.name.lowercased())
            }
    }

    func template(id: String) -> TemplateInfo? {
        guard !id.isEmpty, !id.contains("/"), let text = try? read("\(Self.templatesDir)/\(id).md") else { return nil }
        let parts = Frontmatter.split(text)
        let scope = Frontmatter.field("scope", in: text).flatMap(TemplateScope.init(rawValue:)) ?? .any
        return TemplateInfo(id: id, name: Frontmatter.field("name", in: text) ?? id,
                            description: Frontmatter.field("description", in: text) ?? "",
                            scope: scope, isBuiltIn: Frontmatter.field("builtin", in: text)?.lowercased() == "true",
                            body: parts.body)
    }

    /// Writes a user template (never builtin) and returns it.
    @discardableResult
    func writeTemplate(_ t: TemplateInfo) throws -> TemplateInfo {
        var t = t
        t.isBuiltIn = false
        let text = """
        ---
        type: template
        name: \(YAML.quoted(t.name))
        description: \(YAML.quoted(t.description))
        scope: \(t.scope.rawValue)
        builtin: false
        ---

        \(t.body.trimmingCharacters(in: .whitespacesAndNewlines))

        """
        let dir = url(for: Self.templatesDir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("\(t.id).md"), atomically: true, encoding: .utf8)
        return t
    }
}

public extension BrainEngine {
    /// Templates for a kind of source (`.meeting` also lists `.any`; nil = all), built-in presets first.
    func templates(scope: TemplateScope?) -> [TemplateInfo] {
        let all = vault.templates()
        guard let scope, scope != .any else { return all }
        return all.filter { $0.scope == scope || $0.scope == .any }
    }

    /// Saves a template. Editing a built-in one creates (or updates) the user's copy `<id>-mio`; a new template
    /// (empty id or unknown id) gets an id from its name.
    @discardableResult
    func saveTemplate(_ t: TemplateInfo) throws -> TemplateInfo {
        var t = t
        t.name = t.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.name.isEmpty else { throw EngineError.invalidTemplate(lang.t("El formato necesita un nombre.", "The format needs a name.")) }
        let existing = vault.template(id: t.id)
        if t.isBuiltIn || existing?.isBuiltIn == true {
            let base = t.id.isEmpty ? (slugify(t.name).isEmpty ? "formato" : slugify(t.name)) : t.id
            t.id = base.hasSuffix("-mio") ? base : base + "-mio"
            if vault.template(id: t.id)?.isBuiltIn == true { t.id = uniqueTemplateId(base + "-mio") }
            if existing?.isBuiltIn == true, t.name == existing?.name { t.name += lang.t(" (mío)", " (mine)") }
        } else if t.id.isEmpty || existing == nil {
            let base = t.id.isEmpty ? (slugify(t.name).isEmpty ? "formato" : slugify(t.name)) : slugify(t.id)
            t.id = uniqueTemplateId(base)
        }
        let saved = try vault.writeTemplate(t)
        Log.info("template saved: \(saved.id)")
        return saved
    }

    /// Deletes a user template (built-in presets can't be deleted). Projects/sources that used it fall back to the default.
    func deleteTemplate(id: String) throws {
        guard let t = vault.template(id: id) else { throw EngineError.invalidTemplate(lang.t("No encontré ese formato.", "Format not found.")) }
        guard !t.isBuiltIn else {
            throw EngineError.invalidTemplate(lang.t("Los formatos incluidos no se pueden borrar.", "Built-in formats can't be deleted."))
        }
        try FileManager.default.removeItem(at: vault.url(for: "\(VaultStore.templatesDir)/\(id).md"))
        for var p in projects.list() where p.defaultTemplate == id {
            p.defaultTemplate = nil
            try? projects.update(p)
        }
        for var src in sources where src.templateId == id {
            src.templateId = nil
            upsert(&src)
        }
        Log.info("template deleted: \(id)")
    }

    /// Asks Claude to write `templates/<id>.md` from a description (job `.makeTemplate`).
    func makeTemplate(fromDescription text: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = uniqueTemplateId(slugify(clean).isEmpty ? "formato" : slugify(clean))
        enqueue(Job(kind: .makeTemplate, payload: ["name": clean, "id": id, "description": text]))
    }

    /// The template a source should use (nil = clear, use the default).
    func setTemplate(sourceId: String, templateId: String?) {
        guard var src = source(sourceId) else { return }
        src.templateId = templateId?.isEmpty == true ? nil : templateId
        upsert(&src)
    }

    func setDefaultTemplate(projectSlug: String, templateId: String?) throws {
        guard var p = projects.get(projectSlug) else { throw ProjectError.notFound(projectSlug) }
        p.defaultTemplate = templateId?.isEmpty == true ? nil : templateId
        try projects.update(p)
    }

    /// Rewrites only this source's wiki page with another template (job `.reformat`, undoable).
    func reformat(sourceId: String, templateId: String) {
        guard let src = source(sourceId) else { return }
        enqueue(Job(kind: .reformat, sourceId: sourceId, projectSlug: src.projectSlug, payload: ["templateId": templateId]))
    }

    /// Template for a source (CONTRACT §11.3): `source.templateId` > `project.defaultTemplate` (when it fits the
    /// kind) > `estandar` / `correo-hilo`. Documents/notes/urls only use one when chosen explicitly. Missing
    /// files are skipped (nil = let Claude use its built-in default).
    internal func templateId(for src: SourceRecord) -> String? {
        let scope: TemplateScope? = src.kind == .meeting ? .meeting : src.kind == .email ? .email : nil
        func fits(_ id: String?) -> String? {
            guard let id, let t = vault.template(id: id) else { return nil }
            guard let scope else { return t.id }
            // A project's meeting format ("any" included) shouldn't reshape email threads: emails only take
            // a project default that was made for emails.
            if scope == .email { return t.scope == .email ? t.id : nil }
            return t.scope == scope || t.scope == .any ? t.id : nil
        }
        if let chosen = src.templateId, vault.template(id: chosen) != nil { return chosen }
        guard let scope else { return nil }
        if let slug = src.projectSlug, let id = fits(projects.get(slug)?.defaultTemplate) { return id }
        let fallback = scope == .email ? VaultStore.emailTemplateId : TemplateInfo.standardId
        return vault.template(id: fallback) != nil ? fallback : nil
    }

    /// `<raw> | template=templates/<id>.md` (or just the raw path).
    internal func claudeArguments(raw: String, templateId: String?) -> String {
        guard let templateId else { return raw }
        return "\(raw) | template=\(VaultStore.templatesDir)/\(templateId).md"
    }

    private func uniqueTemplateId(_ base: String) -> String {
        var id = base, n = 2
        while FileManager.default.fileExists(atPath: vault.url(for: "\(VaultStore.templatesDir)/\(id).md").path) {
            id = "\(base)-\(n)"
            n += 1
        }
        return id
    }
}
