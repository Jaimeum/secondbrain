import Foundation
import BrainCore

/// A transcribed span before cleaning, with the signals needed to judge it.
public struct RawSegment: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var track: String          // "system" | "mic"
    public var speaker: String        // "S1"... | "S?" | "me"
    public var language: String?
    public var avgLogprob: Double
    public var noSpeechProb: Double
    public var compressionRatio: Double
    public var rms: Double            // RMS of the track audio over [start, end]

    public init(start: Double, end: Double, text: String, track: String, speaker: String, language: String? = nil,
                avgLogprob: Double = 0, noSpeechProb: Double = 0, compressionRatio: Double = 1, rms: Double = 1) {
        self.start = start; self.end = end; self.text = text; self.track = track; self.speaker = speaker
        self.language = language; self.avgLogprob = avgLogprob; self.noSpeechProb = noSpeechProb
        self.compressionRatio = compressionRatio; self.rms = rms
    }

    public var duration: Double { max(0, end - start) }
}

/// Pure post-processing: hallucination filtering, echo removal, speaker labelling and merging.
public enum TranscriptMerge {
    /// Below this RMS the audio is effectively silent (≈ -54 dBFS).
    public static let silenceRMS = 0.002
    /// Above this RMS a span clearly carries a voice (≈ -40 dBFS).
    public static let speechRMS = 0.01
    /// Echo threshold from CONTRACT §5.1.
    public static let echoSimilarity = 0.6
    /// A mic segment quieter than this, and than `echoResidualRatio` × the system speech it overlaps,
    /// is echo-cancellation residue rather than the owner talking.
    public static let echoResidualRMS = 0.03
    public static let echoResidualRatio = 0.12

    // MARK: Text normalisation

    /// Lowercased, accent-folded words without punctuation.
    public static func tokens(_ text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    public static func normalized(_ text: String) -> String { tokens(text).joined(separator: " ") }

    /// Collapses whitespace and strips Whisper special tokens like `<|es|>` or `[BLANK_AUDIO]`.
    public static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|Music|música|Música|SILENCE|silencio)\]"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Similarity

    public static func jaccard(_ a: [String], _ b: [String]) -> Double {
        let sa = Set(a), sb = Set(b)
        guard !sa.isEmpty || !sb.isEmpty else { return 1 }
        return Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
    }

    /// 1 - levenshtein / maxLength over characters of the normalized strings.
    public static func levenshteinRatio(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty && y.isEmpty { return 1 }
        if x.isEmpty || y.isEmpty { return 0 }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }

    /// Share of `part`'s words found in `whole` (only meaningful for 3+ words).
    public static func containment(_ part: [String], in whole: [String]) -> Double {
        guard part.count >= 3 else { return 0 }
        var bag = [String: Int]()
        for w in whole { bag[w, default: 0] += 1 }
        var hits = 0
        for w in part where (bag[w] ?? 0) > 0 { hits += 1; bag[w]! -= 1 }
        return Double(hits) / Double(part.count)
    }

    public static func similarity(_ a: String, _ b: String) -> Double {
        let ta = tokens(a), tb = tokens(b)
        return max(jaccard(ta, tb),
                   levenshteinRatio(ta.joined(separator: " "), tb.joined(separator: " ")),
                   containment(ta, in: tb))
    }

    // MARK: Hallucinations

    /// Phrases Whisper emits on silence/noise. Matched against the normalized text.
    static let alwaysHallucination = [
        "amara org", "subtitulos realizados por", "subtitulos por la comunidad", "subtitulado por",
        "transcripcion realizada por", "sottotitoli creati dalla comunita", "untertitel der amara",
        "subtitles by the amara", "www mooji org",
    ]
    static let suspiciousPhrases: Set<String> = [
        "gracias", "gracias por ver", "gracias por ver el video", "gracias por su atencion", "muchas gracias",
        "suscribete", "suscribete al canal", "no olvides suscribirte", "hasta la proxima", "adios",
        "thank you", "thanks for watching", "thank you for watching", "thank you so much", "please subscribe",
        "bye", "you", "so", "oh", "uh", "um", "mm", "hmm", "ah", "eh", "okay", "ok",
        "music", "musica", "silence", "silencio", "applause", "risas",
    ]

    /// Removes runaway n-gram loops ("y y y y y", "no sé no sé no sé no sé"), keeping one copy.
    public static func collapseLoops(_ text: String, minRepeats: Int = 3) -> String {
        var words = text.split(separator: " ").map(String.init)
        guard words.count >= minRepeats else { return text }
        let key = { (w: String) in normalized(w) }
        var changed = true
        while changed {
            changed = false
            outer: for n in 1...min(6, words.count / minRepeats) {
                var i = 0
                while i + n * minRepeats <= words.count {
                    let gram = words[i..<i + n].map(key)
                    var reps = 1
                    while i + (reps + 1) * n <= words.count, words[i + reps * n..<i + (reps + 1) * n].map(key) == gram { reps += 1 }
                    if reps >= minRepeats {
                        words.removeSubrange(i + n..<i + reps * n)
                        changed = true
                        break outer
                    }
                    i += 1
                }
            }
        }
        return words.joined(separator: " ")
    }

    public static func isHallucination(_ s: RawSegment) -> Bool {
        let norm = normalized(s.text)
        if norm.isEmpty { return true }
        if s.rms < silenceRMS { return true }
        if alwaysHallucination.contains(where: { norm.contains($0) }) { return true }
        let lowConfidence = s.avgLogprob < -0.8 || s.noSpeechProb > 0.5 || s.rms < silenceRMS * 5
        if suspiciousPhrases.contains(norm) && lowConfidence { return true }
        // Whisper's own "no speech" rule.
        if s.noSpeechProb > 0.6 && s.avgLogprob < -1.0 { return true }
        // Highly repetitive output that we could not salvage.
        if s.compressionRatio > 2.4 && s.avgLogprob < -1.0 { return true }
        return false
    }

    // MARK: Echo

    /// Drops mic segments that repeat what the system track was playing at the same time.
    /// An echo is the same audio at (almost) the same instant, so at least `minCoverage` of the mic
    /// segment must overlap system speech; a reply that merely reuses the question's words a moment
    /// later ("¿puedes preparar el análisis?" → "Claro, preparo el análisis") is kept.
    public static func removeEcho(mic: [RawSegment], system: [RawSegment], tolerance: Double = 0.3,
                                  minCoverage: Double = 0.5,
                                  threshold: Double = echoSimilarity) -> [RawSegment] {
        mic.filter { m in
            let overlapping = system.filter { $0.start < m.end + tolerance && $0.end > m.start - tolerance }
            guard !overlapping.isEmpty else { return true }
            let covered = coveredDuration(of: m, by: overlapping, tolerance: tolerance)
            guard covered >= minCoverage * max(m.end - m.start, 0.01) else { return true }
            // What leaks past the mic's echo cancellation is faint and often transcribes as different
            // words (or another language) than the system track: drop it on energy alone.
            let loudest = overlapping.map(\.rms).max() ?? 0
            if m.rms < echoResidualRMS, m.rms < echoResidualRatio * loudest { return false }
            if overlapping.contains(where: { similarity(m.text, $0.text) >= threshold }) { return false }
            let joined = overlapping.map(\.text).joined(separator: " ")
            return similarity(m.text, joined) < threshold
        }
    }

    /// Seconds of `m` covered by the union of `others` (each widened by `tolerance` for playback latency).
    static func coveredDuration(of m: RawSegment, by others: [RawSegment], tolerance: Double) -> Double {
        let spans = others
            .map { (max($0.start - tolerance, m.start), min($0.end + tolerance, m.end)) }
            .filter { $0.0 < $0.1 }
            .sorted { $0.0 < $1.0 }
        var total = 0.0, cursor = m.start
        for (s, e) in spans where e > cursor {
            total += e - max(s, cursor)
            cursor = e
        }
        return total
    }

    // MARK: Speakers

    /// Splits a run of words by speaker change. `nil` speakers inherit from the neighbour.
    public static func splitBySpeaker<W>(_ words: [W], speaker: (W) -> Int?) -> [(speaker: Int?, words: [W])] {
        guard !words.isEmpty else { return [] }
        var ids = words.map(speaker)
        var last: Int? = nil
        for i in ids.indices { if let id = ids[i] { last = id } else { ids[i] = last } }
        var next: Int? = nil
        for i in ids.indices.reversed() { if let id = ids[i] { next = id } else { ids[i] = next } }
        var runs: [(speaker: Int?, words: [W])] = []
        for (w, id) in zip(words, ids) {
            if let lastRun = runs.last, lastRun.speaker == id {
                runs[runs.count - 1].words.append(w)
            } else {
                runs.append((id, [w]))
            }
        }
        return runs
    }

    /// Folds runs of fewer than `minWords` words into a neighbouring run: inside one Whisper segment
    /// such blips are almost always diarization jitter at turn edges.
    public static func absorbShortRuns<W>(_ runs: [(speaker: Int?, words: [W])], minWords: Int = 3) -> [(speaker: Int?, words: [W])] {
        guard runs.count > 1 else { return runs }
        var out: [(speaker: Int?, words: [W])] = []
        var pending: [W] = []
        for run in runs {
            if run.words.count < minWords {
                if out.isEmpty { pending += run.words } else { out[out.count - 1].words += run.words }
            } else if let last = out.last, last.speaker == run.speaker {
                out[out.count - 1].words += run.words
            } else {
                out.append((run.speaker, pending + run.words))
                pending = []
            }
        }
        if out.isEmpty { return [(runs[0].speaker, pending)] }
        if !pending.isEmpty { out[0].words = pending + out[0].words }
        return out
    }

    /// Maps raw diarizer ids to "S1", "S2", ... in order of first appearance (segments sorted by start).
    public static func labelSpeakers(_ ids: [Int?]) -> [String] {
        var map = [Int: String]()
        return ids.map { id in
            guard let id else { return "S?" }
            if let label = map[id] { return label }
            let label = "S\(map.count + 1)"
            map[id] = label
            return label
        }
    }

    /// System segments carry the raw diarizer id as their speaker until here; relabel the survivors
    /// "S1", "S2", ... by first appearance. Must run on the final, sorted list.
    public static func relabelSystemSpeakers(_ segments: [RawSegment]) -> [RawSegment] {
        let system = segments.indices.filter { segments[$0].track == "system" }
        let labels = labelSpeakers(system.map { Int(segments[$0].speaker) })
        var out = segments
        for (i, label) in zip(system, labels) { out[i].speaker = label }
        return out
    }

    // MARK: Language

    /// Languages the meeting is really spoken in: those covering ≥ `minShare` of the speech in
    /// windows with enough speech (≥ `minSeconds`) for reliable detection. Empty if there are none.
    public static func meetingLanguages(_ windows: [(language: String?, seconds: Double)],
                                        minSeconds: Double = 3, minShare: Double = 0.1) -> Set<String> {
        var totals = [String: Double]()
        for w in windows where w.seconds >= minSeconds {
            if let l = w.language { totals[l, default: 0] += w.seconds }
        }
        let sum = totals.values.reduce(0, +)
        guard sum > 0 else { return [] }
        return Set(totals.filter { $0.value / sum >= minShare }.keys)
    }

    public static func dominantLanguage(_ segments: [RawSegment]) -> String? {
        var totals = [String: Double]()
        for s in segments {
            guard let lang = s.language, !lang.isEmpty else { continue }
            totals[lang, default: 0] += max(s.duration, 0.01)
        }
        return totals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    // MARK: Final merge

    /// Cleans, filters, removes echo and returns segments sorted by start.
    public static func merge(system: [RawSegment], mic: [RawSegment]) -> [RawSegment] {
        func prepare(_ list: [RawSegment]) -> [RawSegment] {
            list.compactMap { s in
                var s = s
                s.text = collapseLoops(clean(s.text))
                return isHallucination(s) ? nil : s
            }
        }
        let sys = prepare(system)
        let me = removeEcho(mic: prepare(mic), system: sys)
        return (sys + me).sorted { ($0.start, $0.track == "mic" ? 1 : 0) < ($1.start, $1.track == "mic" ? 1 : 0) }
    }

    public static func transcript(from merged: [RawSegment], durationSeconds: Double) -> Transcript {
        Transcript(
            language: dominantLanguage(merged),
            durationSeconds: durationSeconds,
            segments: merged.map {
                TranscriptSegment(start: $0.start, end: $0.end, speaker: $0.speaker, track: $0.track, text: $0.text)
            }
        )
    }
}
