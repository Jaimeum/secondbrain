import AppKit
import BrainCore
import SwiftTerm
import SwiftUI

/// Embedded terminal running `claude setup-token`. Output is scanned as it arrives and the OAuth token
/// is handed back as soon as it appears, so the user never has to copy it.
struct ClaudeTerminalView: NSViewRepresentable {
    let executable: URL
    var onToken: (String) -> Void
    var onExit: (Int32?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 280))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.processDelegate = context.coordinator
        context.coordinator.view = view

        let coordinator = context.coordinator
        view.setProcessOutputHandler {
            DispatchQueue.main.async { MainActor.assumeIsolated { coordinator.scan() } }
        }

        view.startProcess(executable: executable.path, args: ["setup-token"],
                          environment: Self.environment(),
                          currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ view: LocalProcessTerminalView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: LocalProcessTerminalView, coordinator: Coordinator) {
        if !coordinator.exited { view.terminate() }
    }

    static func environment() -> [String] {
        var env = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let extra = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let existing = (env["PATH"] ?? "").split(separator: ":").map(String.init)
        env["PATH"] = (extra + existing.filter { !extra.contains($0) }).joined(separator: ":")
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        env["HOME"] = home
        return env.map { "\($0.key)=\($0.value)" }
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        var parent: ClaudeTerminalView
        weak var view: LocalProcessTerminalView?
        private(set) var exited = false
        private var deliveredToken: String?

        init(parent: ClaudeTerminalView) { self.parent = parent }

        func scan() {
            guard let view, deliveredToken == nil else { return }
            let text = String(decoding: view.getBufferAsData(), as: UTF8.self)
            guard text.contains("sk-ant-") else { return }
            if let token = Self.findToken(in: text, columns: view.terminalDimensions.cols) {
                deliveredToken = token
                parent.onToken(token)
            }
        }

        /// The terminal wraps long lines, so a ~100 char token can span rows. Rows that fill the full
        /// width are re-joined first; if that still looks truncated, short continuation rows made only of
        /// token characters are joined as well.
        static func findToken(in text: String, columns: Int) -> String? {
            let lines = text.components(separatedBy: "\n")
            var joined = ""
            for line in lines {
                joined += line
                if line.count < columns - 1 { joined += "\n" }
            }
            let first = ClaudeSetup.extractToken(from: joined)
            if let first, first.count >= 80 { return first }

            var merged = ""
            var previous = ""
            for line in joined.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let isContinuation = !trimmed.isEmpty
                    && trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                    && previous.last.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } == true
                    && previous.contains("sk-ant-")
                merged += isContinuation ? trimmed : "\n" + line
                previous = isContinuation ? previous + trimmed : line
            }
            return ClaudeSetup.extractToken(from: merged) ?? first
        }

        func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
        func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func processTerminated(source: TerminalView, exitCode: Int32?) {
            exited = true
            scan()
            parent.onExit(exitCode)
        }
    }
}
