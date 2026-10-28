import BrainCore
import Foundation
import Observation

/// The saved conversations of one scope (CONTRACT §16.3) and the one on screen. Kept by `AppState` for the life of
/// the app, so leaving Preguntar (or a project) and coming back shows the same conversation, and an answer still
/// streaming keeps going and is saved when it ends. Every conversation is saved to `ChatStore` after each question
/// and each answer; a new conversation gets its file with its first question.
@MainActor @Observable
final class Conversations {
    let scope: Scope
    /// The scope's conversations, most recently updated first (the list on the left).
    private(set) var threads: [ChatThread] = []
    private(set) var loaded = false
    /// The conversation on screen (a new, empty one until something is asked or a saved one is opened).
    private(set) var current: ChatModel
    /// The citation inspector's pages (last = shown; earlier ones are Atrás). Empty = closed.
    var inspected: [String] = []

    @ObservationIgnored let store: ChatStore
    /// Conversations opened (or started) this session, by id: reopening one keeps its live state (a streaming answer).
    @ObservationIgnored private var models: [String: ChatModel] = [:]

    init(scope: Scope, store: ChatStore) {
        self.scope = scope
        self.store = store
        current = ChatModel()
        current.onUpdate = { [weak self] in self?.persist($0) }
    }

    /// Reads the list from disk (the first time Preguntar shows, and after a vault switch).
    func reload() async {
        threads = await store.listAsync(scope: scope)
        loaded = true
    }

    /// "Nueva conversación": an empty one (nothing is saved until the first question). Already empty: kept.
    func startNew() {
        guard !current.messages.isEmpty || current.threadId != nil else { return }
        let model = ChatModel()
        model.onUpdate = { [weak self] in self?.persist($0) }
        current = model
    }

    /// Shows a saved conversation. False when it no longer exists (deleted, or another vault's).
    @discardableResult
    func open(id: String) -> Bool {
        if current.threadId == id { return true }
        if let model = models[id] {
            current = model
            return true
        }
        guard let thread = threads.first(where: { $0.id == id }) ?? store.load(id: id, scope: scope) else { return false }
        let model = Self.model(from: thread)
        model.onUpdate = { [weak self] in self?.persist($0) }
        models[id] = model
        current = model
        return true
    }

    func rename(id: String, to title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let model = models[id] ?? (current.threadId == id ? current : nil) { model.title = clean }
        if let i = threads.firstIndex(where: { $0.id == id }) { threads[i].title = clean }
        do { try store.rename(id: id, scope: scope, to: clean) } catch { Log.error("chat rename \(id): \(error)") }
    }

    func delete(id: String) {
        if let model = models.removeValue(forKey: id) {
            model.onUpdate = nil
            model.stop()
        }
        threads.removeAll { $0.id == id }
        do { try store.delete(id: id, scope: scope) } catch { Log.error("chat delete \(id): \(error)") }
        if current.threadId == id {
            current.onUpdate = nil
            current.stop()
            let model = ChatModel()
            model.onUpdate = { [weak self] in self?.persist($0) }
            current = model
        }
    }

    /// An answer was saved as a page: remembered in the conversation ("Guardada · Ver").
    func markSaved(messageId: UUID, path: String, in model: ChatModel) {
        guard let i = model.messages.firstIndex(where: { $0.id == messageId }) else { return }
        model.messages[i].saved = true
        model.messages[i].savedPath = path
        persist(model)
    }

    /// Stops every answer still streaming (vault switch).
    func stopAll() {
        for model in models.values { model.onUpdate = nil; model.stop() }
        current.onUpdate = nil
        current.stop()
    }

    // MARK: Saving

    private func persist(_ model: ChatModel) {
        guard !model.messages.isEmpty else { return }
        let now = Date()
        if model.threadId == nil {
            model.threadId = ChatStore.newId(now)
            model.createdAt = now
            let first = model.messages.first { $0.role == .user }?.text ?? ""
            model.title = ChatStore.title(forQuestion: first)
        }
        guard let id = model.threadId else { return }
        models[id] = model
        let thread = ChatThread(id: id, scope: scope, title: model.title, createdAt: model.createdAt, updatedAt: now,
                                messages: model.messages.map(Self.stored))
        do { try store.save(thread) } catch { Log.error("chat save \(id): \(error)") }
        threads.removeAll { $0.id == id }
        threads.insert(thread, at: 0)
    }

    private static func stored(_ m: ChatMessage) -> ChatThread.Message {
        let failure: String? = switch m.failure {
        case .notConnected: "notConnected"
        case .rateLimited: "rateLimited"
        case .other: "other"
        case nil: nil
        }
        return ChatThread.Message(id: m.id.uuidString, role: m.role == .user ? .user : .assistant, text: m.text,
                                  question: m.role == .assistant ? m.question : nil, failure: failure,
                                  savedPath: m.savedPath)
    }

    static func model(from thread: ChatThread) -> ChatModel {
        let model = ChatModel()
        model.threadId = thread.id
        model.title = thread.title
        model.createdAt = thread.createdAt
        model.messages = thread.messages.map { m in
            var failure: ChatMessage.Failure? = switch m.failure {
            case "notConnected": .notConnected
            case "rateLimited": .rateLimited(nil)
            case nil: nil
            default: .other
            }
            // The app quit while this answer was streaming: it never came.
            if m.role == .assistant, m.text.isEmpty, failure == nil { failure = .other }
            var message = ChatMessage(role: m.role == .user ? .user : .assistant, text: m.text, question: m.question ?? "",
                                      failure: failure, saved: m.savedPath != nil, savedPath: m.savedPath,
                                      projectSlug: thread.scope.projectSlug)
            if let uuid = UUID(uuidString: m.id) { message.id = uuid }
            return message
        }
        return model
    }
}
