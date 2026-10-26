import BrainCore
import Foundation
import os

extension Recorder {
    /// Finds sessions left without `endedAt` (the app crashed or was killed while recording),
    /// repairs their WAV headers, evens out the track lengths, sets `endedAt`, saves and returns
    /// them so the app can queue them for transcription. Sessions recording in this process are skipped.
    nonisolated public static func recoverInterruptedSessions(in sessionsDir: URL) -> [SessionManifest] {
        let fm = FileManager.default
        let log = Logger(subsystem: "app.secondbrain.mac", category: "Recorder")
        guard let dirs = try? fm.contentsOfDirectory(at: sessionsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var recovered: [SessionManifest] = []
        for dir in dirs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard var manifest = try? SessionManifest.load(from: dir), manifest.endedAt == nil,
                  !ActiveSessions.contains(manifest.id) else { continue }
            do {
                try recover(&manifest, in: dir)
                try manifest.save(to: dir)
                recovered.append(manifest)
                log.info("Recovered interrupted session \(manifest.id, privacy: .public)")
            } catch {
                log.error("Recovering \(manifest.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        return recovered
    }

    nonisolated static func recover(_ manifest: inout SessionManifest, in dir: URL) throws {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let rate = manifest.sampleRate
        let chunkSamples = rate * manifest.chunkSeconds
        var lengths: [String: Int] = [:]

        // Trust the files on disk over the manifest: a chunk may have been created right before the crash.
        for track in manifest.tracks.keys {
            let pattern = try NSRegularExpression(pattern: "^\(track)_\\d{3}\\.wav$")
            let names = files.filter { pattern.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }.sorted()
            var total = 0
            for name in names { total += try WAV.repairHeader(at: dir.appendingPathComponent(name), sampleRate: rate) }
            manifest.tracks[track] = names
            lengths[track] = total
        }

        // Tracks are zero-filled with a small lag while recording; pad the shorter ones so all end together.
        let longest = lengths.values.max() ?? 0
        for (track, length) in lengths where length < longest {
            var names = manifest.tracks[track] ?? []
            var missing = longest - length
            var writer: WAVWriter? = try names.last.map { try WAVWriter(appendingTo: dir.appendingPathComponent($0), sampleRate: rate) }
            while missing > 0 {
                if writer == nil || writer!.sampleCount >= chunkSamples {
                    try writer?.close()
                    let name = ChunkedTrackWriter.fileName(track: track, index: names.count)
                    writer = try WAVWriter(url: dir.appendingPathComponent(name), sampleRate: rate)
                    names.append(name)
                }
                let n = min(missing, chunkSamples - writer!.sampleCount)
                try writer!.appendSilence(n)
                missing -= n
            }
            try writer?.close()
            manifest.tracks[track] = names
        }

        manifest.endedAt = manifest.startedAt.addingTimeInterval(Double(longest) / Double(rate))
    }
}
