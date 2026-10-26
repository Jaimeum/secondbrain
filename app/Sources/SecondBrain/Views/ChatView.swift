import AppKit
import BrainCore
import Observation
import SwiftUI

struct ChatMessage: Identifiable {
    enum Role { case user, assistant }
    enum Failure: Equatable { case notConnected, rateLimited(Date?), other }

    let id = UUID()
    let role: Role
    var text: String
    var question = ""
    var steps: [String] = []
    var isStreaming = false
    var failure: Failure?
    var saved = false
}

@MainActor @Observable
final class ChatModel {
    var messages: [ChatMessage] = []
    var wholeBrain = false
    var draft = ""
    private(set) var isAsking = false
    @ObservationIgnored private var task: Task<Void, Never>?

    func ask(engine: BrainEngine, projectSlug: String?) {
        let question = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isAsking else { return }
        draft = ""
        messages.append(ChatMessage(role: .user, text: question))
        messages.append(ChatMessage(role: .assistant, text: "", question: question, isStreaming: true))
        let index = messages.count - 1
        isAsking = true

        task = Task {
            do {
                for try await event in engine.ask(question, projectSlug: projectSlug) {
                    // Stopped or cleared meanwhile: `index` may no longer point at this answer.
                    guard !Task.isCancelled, messages.indices.contains(index) else { return }
                    switch event {
                    case .text(let chunk):
                        // Claude sends whole message blocks; keep consecutive ones apart.
                        let current = messages[index].text
                        let separator = current.isEmpty || current.hasSuffix("\n") ? "" : "\n\n"
                        messages[index].text = current + separator + chunk
                    case .tool(let name, let detail):
                        messages[index].steps.append(Self.describeStep(name: name, detail: detail))
                    case .done(let result, let isError):
                        if isError {
                            messages[index].failure = .other
                        } else if !result.isEmpty {
                            messages[index].text = result
                        }
                    }
                }
            } catch let error as ClaudeError {
                guard !Task.isCancelled, messages.indices.contains(index) else { return }
                switch error {
                case .notInstalled, .notAuthenticated: messages[index].failure = .notConnected
                case .rateLimited(let reset): messages[index].failure = .rateLimited(reset)
                case .failed: messages[index].failure = .other
                }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, messages.indices.contains(index) else { return }
                messages[index].failure = .other
            }
            guard !Task.isCancelled, messages.indices.contains(index) else { return }
            messages[index].isStreaming = false
            isAsking = false
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isAsking = false
        if let last = messages.indices.last { messages[last].isStreaming = false }
    }

    func clear() {
        stop()
        messages.removeAll()
    }

    static func describeStep(name: String, detail: String) -> String {
        let file = detail.split(separator: " ").last.map { (String($0) as NSString).lastPathComponent } ?? ""
        switch name {
        case "Read": return file.isEmpty ? L("chat.step.reading") : L("chat.step.readingFile", file)
        case "Grep", "Glob": return L("chat.step.searching")
        default: return detail.isEmpty ? name : detail
        }
    }
}

/// "Preguntar": ask the wiki questions, answers cite pages with clickable [[links]].
struct ChatView: View {
    @Environment(AppState.self) private var state
    @Bindable var model: ChatModel
    let projectSlug: String?
    var onOpenPage: (String) -> Void

    @ViewState private var lintQueued = false
    @ViewState private var showReconnect = false

    private var effectiveScope: String? { model.wholeBrain ? nil : projectSlug }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.messages.isEmpty { suggestions }
                        ForEach(model.messages) { message in
                            MessageView(message: message, baseRelPath: basePath, onOpenPage: onOpenPage,
                                        onSave: { save(message) }, onReconnect: { showReconnect = true })
                                .id(message.id)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Divider()
            inputBar
        }
        .sheet(isPresented: $showReconnect) {
            ReconnectClaudeSheet()
        }
    }

    private var basePath: String {
        effectiveScope.map { "projects/\($0)/wiki/index.md" } ?? "index.md"
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if projectSlug != nil {
                Picker("", selection: $model.wholeBrain) {
                    Text(L("chat.scopeProject")).tag(false)
                    Text(L("chat.scopeBrain")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            Spacer()
            if lintQueued {
                Label(L("chat.lintQueued"), systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.green)
            }
            Button {
                state.engine.lint(projectSlug: effectiveScope)
                lintQueued = true
            } label: {
                Label(L("chat.lint"), systemImage: "stethoscope")
            }
            .help(L("chat.lintHelp"))
            if !model.messages.isEmpty {
                Button { model.clear() } label: { Label(L("chat.clear"), systemImage: "trash") }
                    .labelStyle(.iconOnly)
                    .help(L("chat.clear"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("chat.emptyTitle")).font(.title3.weight(.semibold))
            Text(L("chat.emptyMessage")).foregroundStyle(.secondary)
            ForEach(["chat.suggestion1", "chat.suggestion2", "chat.suggestion3"], id: \.self) { key in
                Button {
                    model.draft = L(key)
                    model.ask(engine: state.engine, projectSlug: effectiveScope)
                } label: {
                    Label(L(key), systemImage: "sparkle")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 30)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField(L("chat.placeholder"), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1...6)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12))
                .onSubmit { model.ask(engine: state.engine, projectSlug: effectiveScope) }
            if model.isAsking {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .help(L("chat.stop"))
            } else {
                Button { model.ask(engine: state.engine, projectSlug: effectiveScope) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 26))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(14)
    }

    private func save(_ message: ChatMessage) {
        state.engine.saveAnswer(question: message.question, answer: message.text, projectSlug: effectiveScope)
        if let i = model.messages.firstIndex(where: { $0.id == message.id }) { model.messages[i].saved = true }
    }
}

private struct MessageView: View {
    @Environment(AppState.self) private var state
    let message: ChatMessage
    let baseRelPath: String
    var onOpenPage: (String) -> Void
    var onSave: () -> Void
    var onReconnect: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 10) {
                if message.isStreaming || (message.text.isEmpty && message.failure == nil) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(message.steps.last ?? L("chat.thinking"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .animation(.default, value: message.steps.count)
                    }
                }
                if !message.text.isEmpty {
                    MarkdownText(markdown: message.text)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "sbwiki" else { return .systemAction }
                            let target = url.absoluteString.replacingOccurrences(of: "sbwiki://link/", with: "")
                                .removingPercentEncoding ?? ""
                            if let path = state.engine.vault.resolveWikilink(target, from: baseRelPath) {
                                onOpenPage(path)
                            }
                            return .handled
                        })
                }
                if let failure = message.failure { failureView(failure) }
                if !message.isStreaming, message.failure == nil, !message.text.isEmpty {
                    HStack {
                        Button(action: onSave) {
                            Label(message.saved ? L("chat.saved") : L("chat.saveToWiki"),
                                  systemImage: message.saved ? "checkmark" : "square.and.arrow.down")
                        }
                        .disabled(message.saved)
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(message.text, forType: .string)
                        } label: {
                            Label(L("chat.copy"), systemImage: "doc.on.doc")
                        }
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder private func failureView(_ failure: ChatMessage.Failure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(.orange)
            switch failure {
            case .notConnected:
                Text(L("chat.errorNotConnected"))
                Button(L("chat.reconnect"), action: onReconnect)
            case .rateLimited(let reset):
                Text(reset.map { L("chat.errorRateLimitedUntil", Fmt.time($0)) } ?? L("chat.errorRateLimited"))
            case .other:
                Text(L("chat.errorOther"))
            }
        }
        .font(.callout)
        .padding(12)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// Lightweight block markdown: headings, bullets, numbered lists, quotes, and inline styling.
/// `[[wikilinks]]` become `sbwiki://link/<target>` links resolved on click.
struct MarkdownText: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    private enum Block { case heading(Int, String), bullet(String, Int), numbered(String, String), quote(String), paragraph(String), code(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var code: [String]? = nil
        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code!.append(raw); continue }
            if line.isEmpty { flush(); continue }
            let indent = (raw.prefix { $0 == " " }.count) / 2
            if let m = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                flush(); out.append(.heading(m.1.count, String(m.2)))
            } else if let m = line.firstMatch(of: #/^[-*+]\s+(.*)$/#) {
                flush(); out.append(.bullet(String(m.1), indent))
            } else if let m = line.firstMatch(of: #/^(\d+)[.)]\s+(.*)$/#) {
                flush(); out.append(.numbered(String(m.1), String(m.2)))
            } else if let m = line.firstMatch(of: #/^>\s?(.*)$/#) {
                flush(); out.append(.quote(String(m.1)))
            } else {
                paragraph.append(line)
            }
        }
        if let c = code { out.append(.code(c.joined(separator: "\n"))) }
        flush()
        return out
    }

    @ViewBuilder private func blockView(_ block: Block) -> some View {
        switch block {
        case .heading(let level, let text):
            inline(text).font(level <= 1 ? .title2.bold() : level == 2 ? .title3.bold() : .headline)
                .padding(.top, 6)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(.secondary).monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            inline(text)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor.opacity(0.5)).frame(width: 3) }
        case .paragraph(let text):
            inline(text)
        case .code(let text):
            Text(text)
                .font(.system(.callout, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func inline(_ text: String) -> Text {
        let linked = Self.linkifyWikilinks(text)
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: linked, options: options) {
            return Text(attributed)
        }
        return Text(text)
    }

    static func linkifyWikilinks(_ text: String) -> String {
        text.replacing(#/\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]+))?\]\]/#) { match in
            let target = String(match.1).split(separator: "#").first.map(String.init) ?? String(match.1)
            let label = match.2.map(String.init) ?? target
            let encoded = target.trimmingCharacters(in: .whitespaces)
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? target
            return "[\(label)](sbwiki://link/\(encoded))"
        }
    }
}
