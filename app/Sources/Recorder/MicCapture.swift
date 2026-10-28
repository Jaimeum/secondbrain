import AVFAudio
import CoreAudio
import Foundation
import os

/// Microphone capture through a plain AVAudioEngine input tap. Deliberately no voice processing:
/// enabling it reconfigures the shared built-in mic (its hardware DSP mode and channel layout), which
/// makes coreaudiod restart every other app's capture, and a meeting app (Discord, Zoom, Meet,
/// Teams) can fail that restart and stay silent for the remote side until the user rejoins.
/// The price is giving up echo cancellation: with speakers (not headphones) the remote side leaks
/// into the mic track, and `TranscriptMerge.removeEcho` is the only thing that drops it.
/// Restarts itself when the default input device changes or the engine stops, within the limits of
/// `MicRestartPolicy`. It never gives up for good while active: past the restart budget it waits for
/// the window to free up, and after failed retries it tries again every `recheckInterval`.
/// `onFailure` reports the mic going silent, `onRecovery` it coming back.
final class MicCapture: @unchecked Sendable {
    /// Called on the audio render thread with a buffer that is only valid during the call.
    typealias Handler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    /// Called on the main queue when the mic stopped and can't be restarted for now. Set before `start()`.
    var onFailure: ((Error) -> Void)?
    /// Called on the main queue when the mic runs again after `onFailure`. Set before `start()`.
    var onRecovery: (() -> Void)?

    private let handler: Handler
    private let log = Logger(subsystem: "app.secondbrain.mac", category: "Recorder")
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var device: AudioDeviceID?
    private var policy = MicRestartPolicy()
    private var pending: DispatchWorkItem?   // debounced check, deferred check or scheduled retry, main queue
    private var burstStart: TimeInterval?    // first change of the burst the pending check collapses
    private var active = false
    private var lost = false                 // onFailure reported, onRecovery not yet

    init(handler: @escaping Handler) { self.handler = handler }

    deinit { stop() }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard AVAudioApplication.shared.recordPermission != .denied else { throw RecorderError.microphoneUnavailable }
        try startEngine()
        active = true
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        active = false
        pending?.cancel()
        pending = nil
        burstStart = nil
        teardown()
    }

    private func startEngine() throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { teardown(); throw RecorderError.microphoneUnavailable }
        let handler = self.handler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in handler(buffer, time) }
        engine.prepare()
        do { try engine.start() } catch { teardown(); throw error }
        device = Self.defaultInputDevice()

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.configurationChanged() }
    }

    /// Changes arrive in bursts (often caused by other apps); collapse them into one check, but never
    /// push it more than `maxDebounceWait` past the first change: the engine has usually stopped already.
    private func configurationChanged() {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let now = AudioMath.hostSeconds()
        let first = burstStart ?? now
        burstStart = first
        schedule(after: MicRestartPolicy.debounceDelay(now: now, burstStart: first)) { $0.checkAfterChange() }
    }

    private func checkAfterChange() {
        lock.lock(); defer { lock.unlock() }
        burstStart = nil
        guard active else { return }
        let current = Self.defaultInputDevice()
        let running = engine?.isRunning ?? false
        guard MicRestartPolicy.needsRestart(deviceChanged: current != device, engineRunning: running) else {
            log.debug("Audio configuration changed; microphone still running on the same device")
            return
        }
        let now = AudioMath.hostSeconds()
        guard policy.admit(at: now) else {
            // Back off instead of giving up: whatever is churning the device gets a quiet window, and
            // the mic comes back as soon as the budget allows.
            let wait = policy.wait(at: now)
            let reason = "too many restarts in a short time; retrying in \(Int(wait.rounded(.up))) s"
            if running { log.notice("Microphone restart deferred: \(reason, privacy: .public)") }
            else { reportLost(RecorderError.microphoneUnavailable, reason) }
            schedule(after: wait) { $0.checkAfterChange() }
            return
        }
        log.notice("Audio configuration changed (device changed: \(current != self.device), running: \(running)); restarting microphone")
        attemptRestart(retry: 0)
    }

    /// Lock held.
    private func attemptRestart(retry: Int) {
        teardown()
        do {
            try startEngine()
            log.notice("Microphone restarted")
            if lost {
                lost = false
                let onRecovery = self.onRecovery
                DispatchQueue.main.async { onRecovery?() }
            }
        } catch {
            guard retry < MicRestartPolicy.retryDelays.count else {
                // Out of quick retries: report it, then keep trying slowly so a mic that settles or is
                // plugged in later comes back. These periodic attempts don't spend the restart budget.
                reportLost(error, "restart failed: \(error.localizedDescription); retrying every \(Int(MicRestartPolicy.recheckInterval)) s")
                schedule(after: MicRestartPolicy.recheckInterval) { $0.retryRestart(retry) }
                return
            }
            log.error("Microphone restart failed, retrying: \(error.localizedDescription, privacy: .public)")
            schedule(after: MicRestartPolicy.retryDelays[retry]) { $0.retryRestart(retry + 1) }
        }
    }

    private func retryRestart(_ retry: Int) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        attemptRestart(retry: retry)
    }

    /// Lock held. Logs every time, reports to `onFailure` once per outage.
    private func reportLost(_ error: Error, _ reason: String) {
        log.error("Microphone lost: \(reason, privacy: .public)")
        guard !lost else { return }
        lost = true
        let onFailure = self.onFailure
        DispatchQueue.main.async { onFailure?(error) }
    }

    /// Lock held. Replaces any pending check or retry.
    private func schedule(after delay: TimeInterval, _ body: @escaping (MicCapture) -> Void) {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in if let self { body(self) } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }
}

/// When the mic restarts after an audio configuration change: after a quiet `debounce` (but at most
/// `maxDebounceWait` after the first change of a burst), only if the default input device changed or
/// the engine stopped, at most `limit` times per `window` seconds (further restarts wait for the
/// window), and a failed restart is retried after each of `retryDelays`, then every `recheckInterval`.
public struct MicRestartPolicy: Sendable {
    public static let debounce: TimeInterval = 0.5
    public static let maxDebounceWait: TimeInterval = 2
    public static let retryDelays: [TimeInterval] = [1, 2]
    public static let recheckInterval: TimeInterval = 30

    public let limit: Int
    public let window: TimeInterval
    private var history: [TimeInterval] = []

    public init(limit: Int = 5, window: TimeInterval = 60) {
        self.limit = limit
        self.window = window
    }

    public static func needsRestart(deviceChanged: Bool, engineRunning: Bool) -> Bool {
        deviceChanged || !engineRunning
    }

    /// Delay of the debounced check for a change at `now` in a burst that began at `burstStart`.
    public static func debounceDelay(now: TimeInterval, burstStart: TimeInterval) -> TimeInterval {
        max(0, min(debounce, burstStart + maxDebounceWait - now))
    }

    /// Counts a restart at `now` (seconds, any monotonic clock) if the budget allows it.
    public mutating func admit(at now: TimeInterval) -> Bool {
        history.removeAll { now - $0 >= window }
        guard history.count < limit else { return false }
        history.append(now)
        return true
    }

    /// Seconds from `now` until `admit` would allow another restart (0 if it would now).
    public func wait(at now: TimeInterval) -> TimeInterval {
        let live = history.filter { now - $0 < window }
        guard live.count >= limit, let oldest = live.min() else { return 0 }
        return max(0, oldest + window - now)
    }
}
