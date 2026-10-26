import Foundation

/// Canonical 44-byte PCM WAV header helpers (16-bit LE, mono by default).
enum WAV {
    static let headerSize = 44

    static func header(sampleRate: Int, channels: Int = 1, bitsPerSample: Int = 16, dataBytes: UInt32) -> Data {
        var d = Data(capacity: headerSize)
        func ascii(_ s: String) { d.append(contentsOf: Array(s.utf8)) }
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let blockAlign = channels * bitsPerSample / 8
        ascii("RIFF"); u32(36 &+ dataBytes); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1); u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * blockAlign)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(dataBytes)
        return d
    }

    /// Number of 16-bit mono samples in a WAV written by this module, derived from the file size
    /// (works even when the header was never finalized).
    static func sampleCount(at url: URL) -> Int {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        return max(0, size - headerSize) / 2
    }

    /// Rewrites the RIFF and data sizes from the real file length (crash recovery). Drops a trailing
    /// odd byte. Returns the sample count.
    @discardableResult
    static func repairHeader(at url: URL, sampleRate: Int) throws -> Int {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        let dataBytes = max(0, size - headerSize) & ~1
        try handle.truncate(atOffset: UInt64(headerSize + dataBytes))
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: header(sampleRate: sampleRate, dataBytes: UInt32(dataBytes)))
        return dataBytes / 2
    }
}

/// Streaming writer for one 16 kHz mono Int16 WAV file. The header is refreshed periodically so a
/// crash leaves a nearly valid file; `WAV.repairHeader` fixes the rest.
final class WAVWriter {
    let url: URL
    let sampleRate: Int
    private(set) var sampleCount: Int
    private let handle: FileHandle
    private var samplesSinceHeader = 0
    private var closed = false

    init(url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        guard FileManager.default.createFile(atPath: url.path, contents: WAV.header(sampleRate: sampleRate, dataBytes: 0)) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
        sampleCount = 0
    }

    /// Opens an existing file for appending (after repairing its header).
    init(appendingTo url: URL, sampleRate: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        sampleCount = try WAV.repairHeader(at: url, sampleRate: sampleRate)
        handle = try FileHandle(forUpdating: url)
        try handle.seekToEnd()
    }

    deinit { try? close() }

    func append(_ samples: UnsafeBufferPointer<Int16>) throws {
        guard !samples.isEmpty else { return }
        try handle.write(contentsOf: UnsafeRawBufferPointer(samples))   // arm64/x86 are little-endian
        sampleCount += samples.count
        samplesSinceHeader += samples.count
        if samplesSinceHeader >= sampleRate { try writeHeader() }
    }

    func appendSilence(_ count: Int) throws {
        var remaining = count
        let block = [Int16](repeating: 0, count: min(count, sampleRate))
        while remaining > 0 {
            let n = min(remaining, block.count)
            try block.withUnsafeBufferPointer { try append(UnsafeBufferPointer(rebasing: $0[0..<n])) }
            remaining -= n
        }
    }

    func writeHeader() throws {
        let end = try handle.offset()
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: WAV.header(sampleRate: sampleRate, dataBytes: UInt32(sampleCount * 2)))
        try handle.seek(toOffset: end)
        samplesSinceHeader = 0
    }

    func close() throws {
        guard !closed else { return }
        closed = true
        try writeHeader()
        try handle.synchronize()
        try handle.close()
    }
}
