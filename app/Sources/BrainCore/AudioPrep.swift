import AVFoundation
import Foundation
import UniformTypeIdentifiers

public enum AudioPrepError: Error, LocalizedError {
    case noAudio(String)
    case unreadable(String)

    public var errorDescription: String? {
        let lang = Lang(AppConfig.load().uiLanguage)
        switch self {
        case .noAudio(let name): return lang.t("«\(name)» no tiene audio que pueda transcribir.",
                                               "“\(name)” has no audio I can transcribe.")
        case .unreadable(let name): return lang.t("No pude leer el audio de «\(name)».", "I couldn't read the audio of “\(name)”.")
        }
    }
}

/// Converts audio/video files to the recorder's on-disk format: 16 kHz mono Int16 WAV chunks (CONTRACT §3).
/// Used by media imports (`BrainEngine.importFile` → transcribe job) and `sb simulate`. Everything here is
/// nonisolated and blocking-friendly: call it from a background task.
public enum AudioPrep {
    /// Extensions always treated as recordings to transcribe.
    public static let mediaExtensions: Set<String> = [
        "m4a", "mp3", "wav", "wave", "aiff", "aif", "aifc", "aac", "flac", "caf", "m4b", "amr", "3gp", "3g2",
        "mp4", "mov", "m4v", "qt",
    ]
    /// Extensions that are never probed as media (documents the importer handles).
    private static let documentExtensions: Set<String> = [
        "md", "markdown", "txt", "text", "csv", "json", "yaml", "yml", "pdf", "rtf", "rtfd", "doc", "docx", "odt",
        "html", "htm", "webarchive", "pages", "key", "numbers", "xlsx", "xls", "pptx", "ppt", "zip",
    ]

    /// True when the file should become a meeting (transcribed) rather than a document: a known audio/video
    /// extension or UTType, or any other file Core Audio can open as audio.
    public static func isMedia(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if mediaExtensions.contains(ext) { return true }
        if documentExtensions.contains(ext) { return false }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .audiovisualContent) { return true }
        guard !FileManager.default.isDirectory(url) else { return false }
        if let file = try? AVAudioFile(forReading: url), file.length > 0 { return true }
        return false
    }

    public struct Converted: Sendable {
        public var files: [String]
        public var samples: Int
        public var sampleRate: Int
        public var duration: Double { Double(samples) / Double(sampleRate) }
    }

    /// Streams `url` (any container AVFoundation reads: m4a, mp3, wav, mp4, mov…; all audio tracks mixed)
    /// into `dir/<prefix>_000.wav`, `_001.wav`… of `chunkSeconds` each. At least one file is written.
    /// On failure the partial chunks are removed.
    public static func convertToChunks(_ url: URL, prefix: String = "system", chunkSeconds: Int = 300,
                                       sampleRate: Int = 16_000, dir: URL,
                                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> Converted {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let writer = ChunkWriter(dir: dir, prefix: prefix, chunkSamples: max(1, chunkSeconds * sampleRate), sampleRate: sampleRate)
        do {
            try await read(url, sampleRate: sampleRate, progress: progress) { try writer.append($0) }
            let files = try writer.finish()
            return Converted(files: files, samples: writer.totalSamples, sampleRate: sampleRate)
        } catch {
            writer.abort()
            throw error
        }
    }

    /// Whole file as 16 kHz (or `sampleRate`) mono Int16 samples. Prefer `convertToChunks` for long files.
    public static func loadMono16k(_ url: URL, sampleRate: Int = 16_000) async throws -> [Int16] {
        var samples: [Int16] = []
        try await read(url, sampleRate: sampleRate, progress: nil) { samples.append(contentsOf: $0) }
        return samples
    }

    /// Feeds mono Int16 samples to `sink`, via AVAssetReader (works for video containers) and falling back to
    /// AVAudioFile + AVAudioConverter for audio files AVAsset can't open.
    static func read(_ url: URL, sampleRate: Int, progress: (@Sendable (Double) -> Void)?,
                     sink: (UnsafeBufferPointer<Int16>) throws -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        if tracks.isEmpty {
            if (try? AVAudioFile(forReading: url)) != nil {
                try readWithAudioFile(url, sampleRate: sampleRate, progress: progress, sink: sink)
                return
            }
            let hasVideo = !((try? await asset.loadTracks(withMediaType: .video)) ?? []).isEmpty
            throw hasVideo || isMedia(url) ? AudioPrepError.noAudio(url.lastPathComponent)
                                           : AudioPrepError.unreadable(url.lastPathComponent)
        }
        let duration = (try? await asset.load(.duration)).map { CMTimeGetSeconds($0) } ?? 0
        let reader: AVAssetReader
        do { reader = try AVAssetReader(asset: asset) } catch { throw AudioPrepError.unreadable(url.lastPathComponent) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioPrepError.unreadable(url.lastPathComponent) }
        reader.add(output)
        guard reader.startReading() else {
            if (try? AVAudioFile(forReading: url)) != nil {
                try readWithAudioFile(url, sampleRate: sampleRate, progress: progress, sink: sink)
                return
            }
            throw reader.error ?? AudioPrepError.unreadable(url.lastPathComponent)
        }
        var total = 0
        var lastReport = -1.0
        var scratch: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / 2
            guard count > 0 else { continue }
            if scratch.count < count { scratch = [Int16](repeating: 0, count: count) }
            let status = scratch.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 2, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw AudioPrepError.unreadable(url.lastPathComponent) }
            try scratch.withUnsafeBufferPointer { try sink(UnsafeBufferPointer(rebasing: $0[0..<count])) }
            total += count
            if let progress, duration > 0 {
                let fraction = min(1, Double(total) / Double(sampleRate) / duration)
                if fraction - lastReport >= 0.02 {
                    lastReport = fraction
                    progress(fraction)
                }
            }
        }
        if reader.status == .failed { throw reader.error ?? AudioPrepError.unreadable(url.lastPathComponent) }
        progress?(1)
    }

    private static func readWithAudioFile(_ url: URL, sampleRate: Int, progress: (@Sendable (Double) -> Void)?,
                                          sink: (UnsafeBufferPointer<Int16>) throws -> Void) throws {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65_536) else {
            throw AudioPrepError.unreadable(url.lastPathComponent)
        }
        converter.downmix = true
        var finished = false
        var readFrames: AVAudioFramePosition = 0
        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 65_536) else { break }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, inputStatus in
                if finished {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuffer, frameCount: 65_536) } catch { inBuffer.frameLength = 0 }
                if inBuffer.frameLength == 0 {
                    finished = true
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                readFrames += AVAudioFramePosition(inBuffer.frameLength)
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if let error { throw error }
            if let data = out.int16ChannelData, out.frameLength > 0 {
                try sink(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            }
            if file.length > 0 { progress?(min(1, Double(readFrames) / Double(file.length))) }
            if status == .endOfStream || status == .error { break }
        }
    }

    /// Writes `prefix_000.wav`, `prefix_001.wav`… each `chunkSeconds` long (the last may be shorter).
    public static func writeChunks(_ samples: [Int16], prefix: String, chunkSeconds: Int, sampleRate: Int, dir: URL) throws -> [String] {
        let writer = ChunkWriter(dir: dir, prefix: prefix, chunkSamples: max(1, chunkSeconds * sampleRate), sampleRate: sampleRate)
        do {
            try samples.withUnsafeBufferPointer { try writer.append($0) }
            return try writer.finish()
        } catch {
            writer.abort()
            throw error
        }
    }

    public static func writeWAV(_ samples: ArraySlice<Int16>, sampleRate: Int, to url: URL) throws {
        var data = wavHeader(sampleCount: samples.count, sampleRate: sampleRate)
        samples.withUnsafeBufferPointer { data.append(contentsOf: UnsafeRawBufferPointer($0)) }   // host is little-endian
        try data.write(to: url, options: .atomic)
    }

    static func wavHeader(sampleCount: Int, sampleRate: Int) -> Data {
        let dataSize = UInt32(sampleCount * 2)
        var header = Data()
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { header.append(contentsOf: $0) } }
        header.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36) + dataSize)
        header.append(contentsOf: Array("WAVE".utf8))
        header.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(sampleRate)); put(UInt32(sampleRate * 2)); put(UInt16(2)); put(UInt16(16))
        header.append(contentsOf: Array("data".utf8)); put(dataSize)
        return header
    }
}

/// Streams samples into consecutive WAV files, fixing each header when the chunk closes.
private final class ChunkWriter {
    let dir: URL
    let prefix: String
    let chunkSamples: Int
    let sampleRate: Int
    private(set) var files: [String] = []
    private(set) var totalSamples = 0
    private var handle: FileHandle?
    private var inChunk = 0

    init(dir: URL, prefix: String, chunkSamples: Int, sampleRate: Int) {
        self.dir = dir; self.prefix = prefix; self.chunkSamples = chunkSamples; self.sampleRate = sampleRate
    }

    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        var offset = 0
        while offset < samples.count {
            if handle == nil || inChunk == chunkSamples { try openNext() }
            let n = min(samples.count - offset, chunkSamples - inChunk)
            let slice = UnsafeBufferPointer(rebasing: samples[offset..<(offset + n)])
            try handle?.write(contentsOf: UnsafeRawBufferPointer(slice))
            inChunk += n
            totalSamples += n
            offset += n
        }
    }

    func finish() throws -> [String] {
        if handle == nil { try openNext() }   // every track has at least one (maybe empty) file
        try closeCurrent()
        return files
    }

    func abort() {
        try? handle?.close()
        handle = nil
        for name in files { try? FileManager.default.removeItem(at: dir.appendingPathComponent(name)) }
    }

    private func openNext() throws {
        try closeCurrent()
        let name = String(format: "%@_%03d.wav", prefix, files.count)
        let url = dir.appendingPathComponent(name)
        try AudioPrep.wavHeader(sampleCount: 0, sampleRate: sampleRate).write(to: url)
        files.append(name)
        handle = try FileHandle(forWritingTo: url)
        try handle?.seekToEnd()
        inChunk = 0
    }

    private func closeCurrent() throws {
        guard let h = handle else { return }
        let header = AudioPrep.wavHeader(sampleCount: inChunk, sampleRate: sampleRate)
        try h.seek(toOffset: 0)
        try h.write(contentsOf: header)
        try h.close()
        handle = nil
    }
}
