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
                        messages[index].steps.append(Self.describeStep(name: name, detail: detail, vault: engine.vault))
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

    /// "Leyendo «Comité de la alianza»…": the page's title (vault) or a readable name, never a file name.
    static func describeStep(name: String, detail: String, vault: VaultStore? = nil) -> String {
        switch name {
        case "Read":
            guard let raw = detail.split(separator: " ").last.map(String.init), raw.hasSuffix(".md") || raw.contains("/") else {
                return L("chat.step.reading")
            }
            return L("chat.step.readingFile", pageName(raw, vault: vault))
        case "Grep", "Glob": return L("chat.step.searching")
        default: return L("chat.step.thinking")
        }
    }

    private static func pageName(_ path: String, vault: VaultStore?) -> String {
        if let vault, path.hasSuffix(".md") {
            let root = vault.root.standardizedFileURL.path + "/"
            let rel = path.hasPrefix(root) ? String(path.dropFirst(root.count)) : path
            if !rel.hasPrefix("/"), FileManager.default.fileExists(atPath: vault.url(for: rel).path) {
                return "«" + vault.title(of: rel) + "»"
            }
        }
        return "«" + WikiGrouping.humanize(path) + "»"
    }
}

/// "Preguntar": ask the wiki questions, answers cite pages with clickable [[links]].
struct ChatView: View {
    @Environment(AppState.self) private var state
    @Bindable var model: ChatModel
    let projectSlug: String?
    var onOpenPage: (String) -> Void

    @ViewState private var showReconnect = false

    private var effectiveScope: String? { model.wholeBrain ? nil : projectSlug }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Brand.color.line).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Brand.spacing.l) {
                        if model.messages.isEmpty { suggestions }
                        ForEach(model.messages) { message in
                            MessageView(message: message, baseRelPath: basePath, onOpenPage: onOpenPage,
                                        onSave: { save(message) }, onReconnect: { showReconnect = true })
                                .id(message.id)
                        }
                    }
                    .padding(Brand.spacing.content)
                    .frame(maxWidth: 820)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: model.messages.last?.text) {
                    if let last = model.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            Rectangle().fill(Brand.color.line).frame(height: 1)
            inputBar
        }
        .background(Brand.color.surface)
        .sheet(isPresented: $showReconnect) {
            ReconnectClaudeSheet()
        }
        .onAppear(perform: sendPendingQuestion)
        .onChange(of: state.pendingQuestion) { sendPendingQuestion() }
    }

    /// A question typed in the search palette (⌘K): asked as soon as this view shows.
    private func sendPendingQuestion() {
        guard let question = state.pendingQuestion?.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        state.pendingQuestion = nil
        guard !question.isEmpty else { return }
        if model.isAsking { model.stop() }
        model.draft = question
        model.ask(engine: state.engine, projectSlug: effectiveScope)
    }

    private var basePath: String {
        effectiveScope.map { "projects/\($0)/wiki/index.md" } ?? "index.md"
    }

    private var topBar: some View {
        HStack(spacing: Brand.spacing.m) {
            if projectSlug != nil {
                BrandSegmentedControl(options: [(false, L("chat.scopeProject")), (true, L("chat.scopeBrain"))],
                                      selection: $model.wholeBrain)
                    .frame(maxWidth: 280)
            }
            Spacer(minLength: Brand.spacing.s)
            if !model.messages.isEmpty {
                Button { model.clear() } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(Brand.color.text2)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(L("chat.clear"))
                .accessibilityLabel(Text(L("chat.clear")))
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .frame(height: 44)
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: Brand.spacing.m) {
            Text(L("chat.emptyTitle"))
                .font(Brand.title)
                .foregroundStyle(Brand.color.text)
            Text(L("chat.emptyMessage"))
                .font(Brand.body)
                .foregroundStyle(Brand.color.text2)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(["chat.suggestion1", "chat.suggestion2", "chat.suggestion3"], id: \.self) { key in
                Button {
                    model.draft = L(key)
                    model.ask(engine: state.engine, projectSlug: effectiveScope)
                } label: {
                    HStack(spacing: Brand.spacing.s) {
                        Image(systemName: "sparkle").foregroundStyle(Brand.color.accent)
                        Text(L(key)).foregroundStyle(Brand.color.text).multilineTextAlignment(.leading)
                    }
                    .font(Brand.body)
                    .padding(.horizontal, Brand.spacing.m)
                    .padding(.vertical, Brand.spacing.s)
                    .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous).strokeBorder(Brand.color.line))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, Brand.spacing.xxl)
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: Brand.spacing.s) {
            TextField(L("chat.placeholder"), text: $model.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Brand.body)
                .lineLimit(1...6)
                .padding(.horizontal, Brand.spacing.m)
                .padding(.vertical, 9)
                .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.line))
                .onSubmit { model.ask(engine: state.engine, projectSlug: effectiveScope) }
            if model.isAsking {
                Button { model.stop() } label: {
                    Image(systemName: "stop.circle.fill").font(Brand.font(26))
                        .foregroundStyle(Brand.color.text2)
                }
                .buttonStyle(.plain)
                .help(L("chat.stop"))
            } else {
                Button { model.ask(engine: state.engine, projectSlug: effectiveScope) } label: {
                    Image(systemName: "arrow.up.circle.fill").font(Brand.font(26))
                        .foregroundStyle(Brand.color.accent)
                }
                .buttonStyle(.plain)
                .disabled(model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
                .help(L("chat.send"))
            }
        }
        .padding(.horizontal, Brand.spacing.l)
        .padding(.vertical, Brand.spacing.m)
    }

    private func save(_ message: ChatMessage) {
        state.engine.saveAnswer(question: message.question, answer: message.text, projectSlug: effectiveScope)
        if let i = model.messages.firstIndex(where: { $0.id == message.id }) { model.messages[i].saved = true }
    }
}

struct MessageView: View {   // v0.3: also used by MeetingPrepView
    @Environment(AppState.self) private var state
    let message: ChatMessage
    let baseRelPath: String
    var onOpenPage: (String) -> Void
    var onSave: () -> Void
    var onReconnect: () -> Void

    /// Citations that point at emails get an envelope symbol so it's clear the answer comes from a mail.
    @ViewState private var emailTargets: Set<String> = []

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .font(Brand.body)
                    .foregroundStyle(Brand.color.text)
                    .textSelection(.enabled)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Brand.color.accentSoft, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
            }
        case .assistant:
            VStack(alignment: .leading, spacing: Brand.spacing.m) {
                if message.isStreaming || (message.text.isEmpty && message.failure == nil) {
                    BrandLoader(size: 16, text: message.steps.last ?? L("chat.thinking"))
                        .animation(Brand.motion.fast, value: message.steps.count)
                }
                if !message.text.isEmpty {
                    MarkdownText(markdown: message.text, emailTargets: emailTargets)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == "sbwiki" else { return .systemAction }
                            let target = url.absoluteString.replacingOccurrences(of: "sbwiki://link/", with: "")
                                .removingPercentEncoding ?? ""
                            // Resolving walks the vault: do it off the main thread.
                            let vault = state.engine.vault
                            let base = baseRelPath
                            Task {
                                if let path = await vault.resolveWikilinksAsync([target], from: base)[target] {
                                    onOpenPage(path)
                                }
                            }
                            return .handled
                        })
                }
                if let failure = message.failure { failureView(failure) }
                if !message.isStreaming, message.failure == nil, !message.text.isEmpty {
                    HStack(spacing: Brand.spacing.s) {
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
                    .buttonStyle(.brandSecondary)
                    .controlSize(.small)
                }
            }
            .padding(Brand.spacing.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Brand.color.card, in: RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Brand.radius.card, style: .continuous).strokeBorder(Brand.color.line))
            .task(id: message.isStreaming) { await findEmailCitations() }
        }
    }

    private func findEmailCitations() async {
        guard !message.isStreaming, !message.text.isEmpty else { return }
        let targets = WikiWebView.Coordinator.wikilinkTargets(in: message.text)
        guard !targets.isEmpty else { return }
        let resolved = await state.engine.vault.resolveWikilinksAsync(targets, from: baseRelPath)
        emailTargets = Set(resolved.filter { $0.value.contains("/emails/") }.keys)
    }

    @ViewBuilder private func failureView(_ failure: ChatMessage.Failure) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.bubble").foregroundStyle(Brand.color.warning)
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
        .font(Brand.body)
        .foregroundStyle(Brand.color.text)
        .padding(Brand.spacing.m)
        .background(Brand.color.warningSoft, in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
    }
}

/// Lightweight block markdown: headings, bullets, numbered lists, quotes, and inline styling.
/// `[[wikilinks]]` become `sbwiki://link/<target>` links resolved on click.
struct MarkdownText: View {
    let markdown: String
    /// Wikilink targets that resolve to emails: shown with an envelope symbol.
    var emailTargets: Set<String> = []

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
            inline(text).font(level <= 1 ? Brand.title : level == 2 ? Brand.section : Brand.callout)
                .padding(.top, 6)
        case .bullet(let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(Brand.color.text2)
                inline(text)
            }
            .padding(.leading, CGFloat(indent) * 16)
        case .numbered(let n, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(n).").foregroundStyle(Brand.color.text2).monospacedDigit()
                inline(text)
            }
        case .quote(let text):
            inline(text)
                .padding(.leading, 10)
                .overlay(alignment: .leading) { Rectangle().fill(Brand.color.sage).frame(width: 3) }
        case .paragraph(let text):
            inline(text)
        case .code(let text):
            Text(text)
                .font(Brand.mono)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Brand.color.cardAlt.opacity(0.6), in: RoundedRectangle(cornerRadius: Brand.radius.control, style: .continuous))
        }
    }

    private static let wikilink = #/\[\[([^\[\]\|\n]+?)(?:\|([^\[\]\n]+))?\]\]/#

    /// Inline markdown with `[[wikilinks]]` as links; citations of emails get an envelope SF Symbol before them.
    private func inline(_ text: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        func parse(_ s: String) -> Text {
            (try? AttributedString(markdown: s, options: options)).map { Text($0) } ?? Text(s)
        }
        let matches = text.matches(of: Self.wikilink)
        guard matches.contains(where: { Self.isEmail($0.output.1, emailTargets) }) else {
            return parse(Self.linkifyWikilinks(text, emailTargets: emailTargets))
        }
        // Split around email citations so the symbol can sit inside the text (markdown can't carry images).
        var result = Text("")
        var cursor = text.startIndex
        for match in matches where Self.isEmail(match.output.1, emailTargets) {
            let before = String(text[cursor..<match.range.lowerBound])
            if !before.isEmpty { result = result + parse(Self.linkifyWikilinks(before, emailTargets: emailTargets)) }
            result = result + Text(Image(systemName: "envelope")).foregroundStyle(Brand.color.text2) + Text(" ")
                + parse(Self.linkifyWikilinks(String(text[match.range]), emailTargets: emailTargets))
            cursor = match.range.upperBound
        }
        let rest = String(text[cursor...])
        if !rest.isEmpty { result = result + parse(Self.linkifyWikilinks(rest, emailTargets: emailTargets)) }
        return result
    }

    private static func isEmail(_ rawTarget: Substring, _ emailTargets: Set<String>) -> Bool {
        let raw = String(rawTarget).trimmingCharacters(in: .whitespaces)
        let target = raw.split(separator: "#").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw
        return emailTargets.contains(target) || emailTargets.contains(raw) || target.contains("emails/")
    }

    /// `[[target|label]]` → `[label](sbwiki://link/target)` (resolved on click). The envelope for email citations is
    /// added by `inline`; `emailTargets` stays for source compatibility.
    static func linkifyWikilinks(_ text: String, emailTargets: Set<String> = []) -> String {
        text.replacing(wikilink) { match in
            let target = String(match.1).split(separator: "#").first.map(String.init) ?? String(match.1)
            let label = match.2.map(String.init) ?? target
            let encoded = target.trimmingCharacters(in: .whitespaces)
                .addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? target
            return "[\(label)](sbwiki://link/\(encoded))"
        }
    }
}
