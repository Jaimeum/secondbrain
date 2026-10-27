import BrainCore
import Foundation
import Observation

/// "Agregar solos" (CONTRACT §14.5): every 15 minutes and when Correo opens, new mail that falls on a rule with
/// "Agregar solos los correos nuevos" is added by itself (`BrainEngine.runMailAutoImport`), with one local notification
/// per cycle ("Agregué 3 correos a 🚀 Acme"). Does nothing without mail accounts, without such rules, with the switch
/// off (Ajustes → Reglas, stored in the vault's routing.json), while rendering debug snapshots (never, not even when
/// asked: a snapshot must not write mail nor queue Claude jobs) or with the demo accounts (`SB_DEMO_ACCOUNTS=1`) unless
/// `SB_DEMO_AUTO_IMPORT=1` asks for it. Account errors are silent here: Correo already shows "Vuelve a conectar".
@MainActor @Observable
final class MailAutoImporter {
    static let shared = MailAutoImporter()
    static let interval: TimeInterval = 15 * 60
    /// Opening Correo again right away doesn't list the mail again.
    static let minimumGap: TimeInterval = 60

    private(set) var isRunning = false
    private(set) var lastRun: Date?
    private(set) var lastReport: MailAutoImportReport?

    @ObservationIgnored private weak var state: AppState?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var cycle: Task<Void, Never>?

    // MARK: Switch (for the Rules screen)

    /// "Revisar el correo cada 15 min".
    var isEnabled: Bool { state?.engine.routing.settings.autoImportEnabled ?? true }

    func setEnabled(_ on: Bool) throws {
        try state?.engine.routing.setAutoImportEnabled(on)
        if on { runNow(force: true) }
    }

    /// There is something to do: the switch is on, a rule adds by itself and an account has mail.
    var hasWork: Bool {
        guard let engine = state?.engine else { return false }
        return engine.routing.settings.autoImportEnabled && !engine.routing.autoAddRules.isEmpty && !engine.accounts.mailAccounts.isEmpty
    }

    // MARK: Lifecycle

    /// Snapshots never run a cycle; demo accounts only with `SB_DEMO_AUTO_IMPORT=1`.
    static func isAllowed(isDemo: Bool, snapshot: Bool? = nil,
                          environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard !(snapshot ?? (DebugSnapshots.directory != nil)) else { return false }
        return !isDemo || environment["SB_DEMO_AUTO_IMPORT"] == "1"
    }

    private var allowed: Bool { Self.isAllowed(isDemo: state?.engine.accounts.isDemo ?? false) }

    /// From `AppState.startEngine`: a cycle shortly after launch, then every 15 minutes.
    func start(state: AppState) {
        self.state = state
        guard loop == nil, allowed else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))   // let the app (and the accounts) settle first
            while !Task.isCancelled {
                self?.runNow()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        cycle?.cancel()
    }

    /// One cycle now (opening Correo, the switch turned on). Skipped while one runs or right after the last one.
    func runNow(force: Bool = false) {
        guard let state, cycle == nil, allowed, hasWork else { return }
        if !force, let lastRun, Date().timeIntervalSince(lastRun) < Self.minimumGap { return }
        let engine = state.engine
        isRunning = true
        cycle = Task { [weak self] in
            let report = await engine.runMailAutoImport()
            guard let self else { return }
            self.cycle = nil
            self.isRunning = false
            self.lastRun = Date()
            self.lastReport = report
            guard report.total > 0 else { return }
            state.bumpVault()
            Notifier.post(title: L("rules.auto.title"), body: Self.message(report, state: state))
        }
    }

    /// "Agregué 3 correos a 🚀 Acme" · "Agregué 5 correos: 3 a 🚀 Acme y 2 a 🤝 Alianza" (+ "El resto, en un rato.").
    static func message(_ report: MailAutoImportReport, state: AppState) -> String {
        var text: String
        if report.added.count == 1, let entry = report.added.first {
            let name = state.projectName(entry.projectSlug)
            text = entry.count == 1 ? L("rules.auto.one", name) : L("rules.auto.many", entry.count, name)
        } else {
            let parts = report.added.map { L("rules.auto.part", $0.count, state.projectName($0.projectSlug)) }
            text = L("rules.auto.mixed", report.total, ListFormatter.localizedString(byJoining: parts))
        }
        if report.reachedCap { text += " " + L("rules.auto.more") }
        return text
    }
}
