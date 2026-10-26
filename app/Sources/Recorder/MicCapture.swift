import AVFAudio
import Foundation
import os

/// Microphone capture through AVAudioEngine with Apple's voice processing (echo cancellation), so
/// the remote side playing through the speakers doesn't bleed into the mic track. Falls back to the
/// raw input if voice processing can't be enabled. Restarts itself when the input device changes.
final class MicCapture: @unchecked Sendable {
    /// Called on the audio render thread with a buffer that is only valid during the call.
    typealias Handler = (AVAudioPCMBuffer, AVAudioTime) -> Void

    private let handler: Handler
    private let log = Logger(subsystem: "app.secondbrain.mac", category: "Recorder")
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private(set) var usesVoiceProcessing = false

    init(handler: @escaping Handler) { self.handler = handler }

    deinit { stop() }

    func start() throws {
        lock.lock(); defer { lock.unlock() }
        guard AVAudioApplication.shared.recordPermission != .denied else { throw RecorderError.microphoneUnavailable }
        do {
            try startEngine(voiceProcessing: true)
        } catch {
            log.warning("Voice processing unavailable (\(error.localizedDescription, privacy: .public)); using raw mic")
            teardown()
            try startEngine(voiceProcessing: false)
        }
    }

    func stop() {
        lock.lock(); defer { lock.unlock() }
        teardown()
    }

    private func startEngine(voiceProcessing: Bool) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        if voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            _ = engine.mainMixerNode   // voice processing needs the output half of the IO unit configured
        }
        usesVoiceProcessing = voiceProcessing

        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.microphoneUnavailable }
        let handler = self.handler
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, time in handler(buffer, time) }
        engine.prepare()
        try engine.start()

        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.restartAfterDeviceChange() }
    }

    private func restartAfterDeviceChange() {
        lock.lock()
        guard engine != nil else { lock.unlock(); return }
        teardown()
        lock.unlock()
        log.info("Audio configuration changed; restarting microphone")
        do { try start() } catch {
            log.error("Microphone restart failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func teardown() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if usesVoiceProcessing { try? engine.inputNode.setVoiceProcessingEnabled(false) }
    }
}
