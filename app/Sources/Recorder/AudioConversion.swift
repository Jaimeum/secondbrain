import AVFAudio
import CoreMedia
import Darwin

/// Converts arbitrary PCM buffers to 16 kHz mono Int16. Stateful (the sample-rate converter keeps
/// history between calls), so use one instance per track from a single queue.
final class MonoResampler {
    enum Mix { case average, firstChannel }

    let sampleRate: Double
    private let mix: Mix
    private let outFormat: AVAudioFormat
    private var floatConverter: AVAudioConverter?   // non-Float32 input → Float32
    private var resampler: AVAudioConverter?         // mono Float32 @ source rate → Int16 @ 16 kHz

    init(mix: Mix, sampleRate: Int = 16000) {
        self.mix = mix
        self.sampleRate = Double(sampleRate)
        outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: Double(sampleRate), channels: 1, interleaved: true)!
    }

    func process(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        guard buffer.frameLength > 0, let mono = monoFloat(buffer) else { return [] }
        if resampler?.inputFormat != mono.format {
            resampler = AVAudioConverter(from: mono.format, to: outFormat)
            resampler?.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        }
        guard let resampler else { return [] }
        let capacity = AVAudioFrameCount((Double(mono.frameLength) * sampleRate / mono.format.sampleRate).rounded(.up)) + 256
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        let status = resampler.convert(to: out, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow   // not .endOfStream: keep the converter's state
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return mono
        }
        guard status != .error, let data = out.int16ChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
    }

    private func monoFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        var source = buffer
        if buffer.format.commonFormat != .pcmFormatFloat32 {
            guard let converted = toFloat(buffer) else { return nil }
            source = converted
        }
        let channels = Int(source.format.channelCount)
        let frames = Int(source.frameLength)
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: source.format.sampleRate, channels: 1, interleaved: false),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: AVAudioFrameCount(frames)),
              let src = source.floatChannelData, let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = AVAudioFrameCount(frames)

        let interleaved = source.format.isInterleaved
        let stride = interleaved ? channels : 1
        func sample(_ channel: Int, _ i: Int) -> Float {
            interleaved ? src[0][i * stride + channel] : src[channel][i]
        }
        let used = mix == .average ? channels : 1
        let scale = 1 / Float(used)
        for i in 0..<frames {
            var acc: Float = 0
            for c in 0..<used { acc += sample(c, i) }
            dst[i] = acc * scale
        }
        return mono
    }

    private func toFloat(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: buffer.format.sampleRate,
                                          channels: buffer.format.channelCount, interleaved: false) else { return nil }
        if floatConverter?.inputFormat != buffer.format { floatConverter = AVAudioConverter(from: buffer.format, to: target) }
        guard let floatConverter, let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: buffer.frameLength) else { return nil }
        do { try floatConverter.convert(to: out, from: buffer) } catch { return nil }
        return out
    }
}

enum AudioMath {
    /// RMS mapped to a 0...1 meter value on a -55...0 dBFS scale.
    static func level(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples { let v = Double(s); sum += v * v }
        let rms = (sum / Double(samples.count)).squareRoot() / 32768
        guard rms > 0 else { return 0 }
        let db = 20 * log10(rms)
        return Float(min(1, max(0, (db + 55) / 55)))
    }

    /// Current host time in seconds (same clock as CMSampleBuffer PTS from ScreenCaptureKit and
    /// AVAudioTime.hostTime from AVAudioEngine).
    static func hostSeconds() -> Double { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

extension CMSampleBuffer {
    /// Copies the audio of a ScreenCaptureKit sample buffer into an AVAudioPCMBuffer.
    func pcmBuffer() -> AVAudioPCMBuffer? {
        guard let description = formatDescription,
              CMFormatDescriptionGetMediaType(description) == kCMMediaType_Audio else { return nil }
        let format = AVAudioFormat(cmAudioFormatDescription: description)
        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(self, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
        return status == noErr ? buffer : nil
    }
}

extension AVAudioPCMBuffer {
    func copy() -> AVAudioPCMBuffer? {
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        out.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: audioBufferList))
        let dst = UnsafeMutableAudioBufferListPointer(out.mutableAudioBufferList)
        for (s, d) in zip(src, dst) {
            guard let sData = s.mData, let dData = d.mData else { continue }
            memcpy(dData, sData, Int(min(s.mDataByteSize, d.mDataByteSize)))
        }
        return out
    }
}
