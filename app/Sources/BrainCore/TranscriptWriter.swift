import Foundation

/// Renders a `Transcript` as the raw meeting markdown of CONTRACT §6.
public enum TranscriptWriter {
    /// Pause below which consecutive turns of the same speaker are merged.
    static let mergeGap: Double = 2

    public struct Turn: Equatable, Sendable {
        public var start: Double
        public var end: Double
        public var speaker: String
        public var text: String
    }

    public static func label(for speaker: String, language: String) -> String {
        let lang = Lang(language)
        if speaker == "me" { return lang.meSpeaker() }
        if speaker.hasPrefix("S") {
            let rest = String(speaker.dropFirst())
            if rest == "?" || Int(rest) != nil { return lang.speaker(rest) }
        }
        return speaker
    }

    public static func turns(from segments: [TranscriptSegment]) -> [Turn] {
        var turns: [Turn] = []
        for seg in segments.sorted(by: { $0.start < $1.start }) {
            let text = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if var last = turns.last, last.speaker == seg.speaker, seg.start - last.end < mergeGap {
                last.text += " " + text
                last.end = max(last.end, seg.end)
                turns[turns.count - 1] = last
            } else {
                turns.append(Turn(start: seg.start, end: seg.end, speaker: seg.speaker, text: text))
            }
        }
        return turns
    }

    /// Speakers ordered: me first, then S1, S2… numerically, then anything else (S? last).
    static func orderedSpeakers(_ segments: [TranscriptSegment]) -> [String] {
        let unique = Array(Set(segments.map(\.speaker)))
        func rank(_ s: String) -> (Int, Int, String) {
            if s == "me" { return (0, 0, s) }
            if s.hasPrefix("S"), let n = Int(s.dropFirst()) { return (1, n, s) }
            if s == "S?" { return (3, 0, s) }
            return (2, 0, s)
        }
        return unique.sorted { rank($0) < rank($1) }
    }

    public static func fileName(title: String, startedAt: Date) -> String {
        let slug = slugify(title)
        let stamp = Fmt.local(startedAt, "yyyy-MM-dd-HHmm")
        return slug.isEmpty ? stamp : "\(stamp)-\(slug)"
    }

    /// `date:` = when the meeting happened (`manifest.startedAt`), `added:` = when it was added (CONTRACT §11.1).
    public static func render(transcript: Transcript, manifest: SessionManifest, title: String,
                              projectSlug: String?, language: String, addedAt: Date = Date()) -> String {
        let duration = transcript.durationSeconds > 0
            ? transcript.durationSeconds
            : (manifest.endedAt?.timeIntervalSince(manifest.startedAt) ?? 0)
        let speakers = orderedSpeakers(transcript.segments).map { label(for: $0, language: language) }
        // v0.3 (§12.5): who was invited (calendar), so ingest can map speaker labels to people.
        let attendees = (manifest.attendees ?? []).isEmpty ? "" : "\nattendees: \(YAML.list(manifest.attendees ?? []))"
        var out = """
        ---
        type: transcript
        source_id: \(manifest.id)
        title: \(YAML.scalar(title))
        project: \(YAML.scalar(projectSlug))
        date: \(SBDate.iso(manifest.startedAt))
        added: \(SBDate.iso(addedAt))
        duration: "\(Fmt.clock(duration))"
        language: \(YAML.scalar(transcript.language))
        speakers: \(YAML.list(speakers))\(attendees)
        ---

        # \(title)


        """
        let turns = turns(from: transcript.segments)
        if turns.isEmpty {
            out += Lang(language).t("_(No se detectó voz en la grabación.)_", "_(No speech was detected in the recording.)_") + "\n"
        }
        for turn in turns {
            out += "**[\(Fmt.clock(turn.start))] \(label(for: turn.speaker, language: language)):** \(turn.text)\n\n"
        }
        while out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }

    /// Writes the transcript into `dir` with a collision-free file name and returns its URL.
    @discardableResult
    public static func write(transcript: Transcript, manifest: SessionManifest, title: String,
                             projectSlug: String?, language: String, to dir: URL, addedAt: Date = Date()) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = fm.uniqueURL(in: dir, name: fileName(title: title, startedAt: manifest.startedAt), ext: "md")
        let text = render(transcript: transcript, manifest: manifest, title: title, projectSlug: projectSlug, language: language,
                          addedAt: addedAt)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
