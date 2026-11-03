import AppKit
import BrainCore
import Observation
import Sparkle

// MARK: v0.7.3 auto-updates
//
// Sparkle 2 checks the appcast published with the latest GitHub release (Info.plist SUFeedURL, EdDSA key in
// SUPublicEDKey; both written by scripts/build-app.sh). It downloads in the background, verifies the EdDSA signature
// and that the new app satisfies this app's designated requirement (same "SecondBrain Dev" certificate, so the
// Microphone / Screen Recording permissions carry over), strips the quarantine and, once this process has exited,
// replaces the bundle in place.
//
// Install policy: a found update downloads silently and installs when the app quits, or right away from
// "Reiniciar y actualizar" (Ajustes, menu bar). Never while recording or transcribing: the relaunch is postponed
// until both are over.

@MainActor @Observable
final class UpdateController: NSObject {
    struct Pending {
        let version: String
        let install: () -> Void
    }

    /// The updater is running (a real .app with a feed URL and a public key; not a bare `swift run` or snapshots).
    private(set) var isEnabled = false
    /// Whether "Buscar actualizaciones" can be used right now (no check already in progress).
    private(set) var canCheck = false
    private(set) var lastCheck: Date?
    /// A downloaded update waiting to be installed (on quit, or now via `installNow()`).
    private(set) var pending: Pending?
    /// The last failure of an update cycle ("no update found" is not one), for Ajustes.
    private(set) var lastError: String?
    /// False when Sparkle can't install on its own (e.g. no SUPublicEDKey); the auto-install switch is then disabled.
    private(set) var allowsAutomaticInstall = false

    // Turning these off only affects future cycles: an update already downloaded (`pending`) stays armed to
    // install on quit (Sparkle has no API to unstage it), so `pending` is kept and Ajustes says it still installs.
    var automaticChecks = true {
        didSet {
            guard let updater, updater.automaticallyChecksForUpdates != automaticChecks else { return }
            updater.automaticallyChecksForUpdates = automaticChecks
            logPendingIfSwitchedOff()
        }
    }
    var automaticDownloads = true {
        didSet {
            guard let updater, updater.automaticallyDownloadsUpdates != automaticDownloads else { return }
            updater.automaticallyDownloadsUpdates = automaticDownloads
            logPendingIfSwitchedOff()
        }
    }

    /// The already-downloaded update installs on quit even with the switches off (Ajustes' footer).
    var pendingInstallsDespiteSwitches: Bool {
        UpdatePolicy.pendingInstallsDespiteSwitches(hasPendingUpdate: pending != nil, automaticChecks: automaticChecks,
                                                    automaticDownloads: automaticDownloads)
    }

    private func logPendingIfSwitchedOff() {
        guard pendingInstallsDespiteSwitches, let pending else { return }
        Log.info("updates: automatic updates turned off; \(pending.version) was already downloaded and still installs on quit")
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var postponedRelaunch: Task<Void, Never>?
    @ObservationIgnored private var notifiedVersions = Set<String>()

    private var updater: SPUUpdater? { controller?.updater }

    /// Starts the updater once. A no-op outside a real .app, without a feed or key (a dev build), or in snapshots.
    func start() {
        guard controller == nil else { return }
        let info = Bundle.main.infoDictionary ?? [:]
        guard Bundle.main.bundleURL.pathExtension == "app",
              let feed = info["SUFeedURL"] as? String, !feed.isEmpty,
              let key = info["SUPublicEDKey"] as? String, !key.isEmpty,
              DebugSnapshots.directory == nil else {
            Log.info("updates: disabled (no .app bundle, SUFeedURL or SUPublicEDKey)")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
        self.controller = controller
        let updater = controller.updater
        do {
            // Not `controller.startUpdater()`: on a misconfigured build that one shows a modal alert at launch.
            try updater.start()
        } catch {
            Log.error("updates: could not start Sparkle: \(error.localizedDescription)")
            lastError = error.localizedDescription
            return
        }
        isEnabled = true
        automaticChecks = updater.automaticallyChecksForUpdates
        automaticDownloads = updater.automaticallyDownloadsUpdates
        allowsAutomaticInstall = updater.allowsAutomaticUpdates
        lastCheck = updater.lastUpdateCheckDate
        observations = [
            updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                let value = updater.canCheckForUpdates
                MainActor.assumeIsolated { self?.canCheck = value }
            },
            updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                let value = updater.lastUpdateCheckDate
                MainActor.assumeIsolated { self?.lastCheck = value }
            },
        ]
        Log.info("updates: started (feed \(feed), automatic checks \(automaticChecks), downloads \(automaticDownloads), "
                 + "location \(UpdatePolicy.location(bundlePath: Bundle.main.bundlePath)))")
    }

    /// "Buscar actualizaciones…": Sparkle's own window shows progress and the result.
    func checkForUpdates() {
        guard let controller, canCheck else { return }
        controller.checkForUpdates(nil)
    }

    /// "Reiniciar y actualizar": quits (applicationShouldTerminate still closes a recording), installs and relaunches.
    func installNow() {
        guard AppState.shared.canInstallUpdateNow, let pending else { return }
        Log.info("updates: installing \(pending.version) now")
        pending.install()
    }

    /// The bundle can't be updated where it is, or should be moved first (Ajustes shows a hint).
    var shouldMoveToApplications: Bool {
        UpdatePolicy.location(bundlePath: Bundle.main.bundlePath) != .applications
    }

    private func refreshLastCheck() {
        lastCheck = updater?.lastUpdateCheckDate
    }

    /// Runs `relaunch` once a recording or transcription is over (checked every 5 s on the main actor).
    private func postponeRelaunch(_ relaunch: @escaping () -> Void) {
        postponedRelaunch?.cancel()
        postponedRelaunch = Task { @MainActor in
            while !AppState.shared.canInstallUpdateNow {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
            Log.info("updates: recording/transcription finished, relaunching to install")
            relaunch()
        }
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdateController: SPUUpdaterDelegate {
    /// An update downloaded in the background: keep it for "Reiniciar y actualizar" instead of Sparkle's modal.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        MainActor.assumeIsolated {
            pending = Pending(version: version, install: immediateInstallHandler)
            Log.info("updates: \(version) downloaded, installs on quit")
            if notifiedVersions.insert(version).inserted {
                Notifier.post(title: L("notify.updateTitle"), body: L("notify.updateBody", version), id: "update-\(version)")
            }
        }
        return true
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                             untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        MainActor.assumeIsolated {
            guard !AppState.shared.canInstallUpdateNow else { return false }
            Log.info("updates: relaunch for \(item.displayVersionString) postponed (recording or transcribing)")
            postponeRelaunch(installHandler)
            return true
        }
    }

    /// "No update found" is how a check without news ends: not an error for the UI or the log.
    nonisolated private static func isNoUpdate(_ error: NSError) -> Bool {
        error.domain == SUSparkleErrorDomain && error.code == Int(SUError.noUpdateError.rawValue)
    }

    nonisolated func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let nsError = error as NSError
        let message = nsError.localizedDescription
        let noUpdate = Self.isNoUpdate(nsError)
        MainActor.assumeIsolated {
            refreshLastCheck()
            guard !noUpdate else { lastError = nil; return }
            Log.error("updates: aborted: \(message)")
            lastError = message
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        let nsError = error as NSError?
        let failed = nsError.map { !Self.isNoUpdate($0) } ?? false
        let message = nsError?.localizedDescription
        MainActor.assumeIsolated {
            refreshLastCheck()
            allowsAutomaticInstall = updater.allowsAutomaticUpdates
            if failed, let message {
                Log.error("updates: update cycle failed: \(message)")
                lastError = message
            } else {
                lastError = nil
            }
        }
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdateController: SPUStandardUserDriverDelegate {
    /// Background finds never steal focus from whatever the user is doing (this app lives in the menu bar).
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled find (automatic downloads off) shows Sparkle's window behind the others; say so with a notification.
    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem,
                                                               state: SPUUserUpdateState) {
        guard !state.userInitiated else { return }
        let version = update.displayVersionString
        MainActor.assumeIsolated {
            guard notifiedVersions.insert(version).inserted else { return }
            Notifier.post(title: L("notify.updateAvailableTitle"), body: L("notify.updateAvailableBody", version),
                          id: "update-\(version)")
        }
    }
}
