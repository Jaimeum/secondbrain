import Foundation

// TEMPORARY skeleton of the v0.2 public API (docs/CONTRACT.md §11) so every target compiles from
// day one. The core engineer moves these into real files (same signatures) and deletes this file;
// the Exporter part belongs to the export engineer (Exporter.swift).

public extension BrainEngine {
    // Emails
    func parseEmail(_ pasted: String) -> ParsedEmail { fatalError("TODO") }
    func emailThreads(projectSlug: String?) -> [EmailThread] { fatalError("TODO") }
    func matchThreads(for email: ParsedEmail) -> [ThreadMatch] { fatalError("TODO") }
    /// threadKey nil = new thread. projectSlug ignored when the thread already lives in a project.
    @discardableResult
    func addEmail(_ email: ParsedEmail, threadKey: String?, projectSlug: String?) throws -> SourceRecord { fatalError("TODO") }
    func emails(inThread key: String) -> [SourceRecord] { fatalError("TODO") }

    // Templates
    func templates(scope: TemplateScope?) -> [TemplateInfo] { fatalError("TODO") }
    @discardableResult func saveTemplate(_ t: TemplateInfo) throws -> TemplateInfo { fatalError("TODO") }
    func deleteTemplate(id: String) throws { fatalError("TODO") }
    func makeTemplate(fromDescription text: String, name: String) { fatalError("TODO") }   // job .makeTemplate
    func setTemplate(sourceId: String, templateId: String?) { fatalError("TODO") }
    func setDefaultTemplate(projectSlug: String, templateId: String?) throws { fatalError("TODO") }
    func reformat(sourceId: String, templateId: String) { fatalError("TODO") }              // job .reformat

    // Dates / timeline
    func setEventDate(sourceId: String, date: Date) throws { fatalError("TODO") }
    func timeline(projectSlug: String?) async -> [TimelineEntry] { fatalError("TODO") }

    // Tasks
    func tasks(projectSlug: String?) async -> [TaskItem] { fatalError("TODO") }
    func setTask(_ task: TaskItem, done: Bool) throws { fatalError("TODO") }
    func tasks(forSourceId id: String) async -> [TaskItem] { fatalError("TODO") }

    // Export (assembles markdown via the engine, renders via Exporter)
    func exportDocument(sourceId: String, options: ExportOptions) async throws -> (title: String, markdown: String) { fatalError("TODO") }
    func exportDocument(pagePath: String, options: ExportOptions) async throws -> (title: String, markdown: String) { fatalError("TODO") }
    func exportTasks(_ tasks: [TaskItem], title: String) -> String { fatalError("TODO") }
}

public extension VaultStore {
    func ownerEmails() -> [String] { fatalError("TODO") }
    func setOwnerEmails(_ emails: [String]) throws { fatalError("TODO") }
}

public enum Exporter {
    /// Renders markdown (wiki flavour: frontmatter, [[wikilinks]], callouts, checkboxes, tables) to a file.
    @MainActor public static func export(markdown: String, title: String, format: ExportFormat,
                                         options: ExportOptions, to url: URL) throws { fatalError("TODO") }
    /// Rich text + plain text for the clipboard.
    @MainActor public static func copyToPasteboard(markdown: String, options: ExportOptions) { fatalError("TODO") }
    public static func plainText(markdown: String, options: ExportOptions) -> String { fatalError("TODO") }
}
