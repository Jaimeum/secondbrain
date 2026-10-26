import AVFoundation
import Foundation
import PDFKit

// Dates (CONTRACT §11.1): every source has WHEN IT HAPPENED (`eventDate`, raw `date:`) and WHEN IT WAS ADDED
// (`createdAt`, raw `added:`). Raw frontmatter stores both as ISO 8601 with the local UTC offset.

public enum SBDate {
    /// `2026-10-26T15:30:00-06:00` (local offset).
    public static func iso(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    /// Parses what we (or Claude) write in frontmatter: full ISO with offset or `Z`, with or without fractional
    /// seconds, `YYYY-MM-DD HH:mm[:ss]` (local), or a bare `YYYY-MM-DD` (local midnight, `hasTime == false`).
    public static func parseISO(_ raw: String) -> (date: Date, hasTime: Bool)? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2, let f = s.first, f == "\"" || f == "'", s.last == f { s = String(s.dropFirst().dropLast()) }
        guard !s.isEmpty else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let d = full.date(from: s) { return (d, true) }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = full.date(from: s) { return (d, true) }
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: s) { return (d, true) }
        }
        local.dateFormat = "yyyy-MM-dd"
        if s.count == 10, let d = local.date(from: s) { return (d, false) }
        return nil
    }

    /// `YYYY-MM-DD` (local) → local midnight.
    public static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    /// Human date in the UI language: "26 oct 2026, 15:30" / "Oct 26, 2026, 3:30 PM" (local time zone).
    public static func human(_ date: Date, hasTime: Bool = true, language: String) -> String {
        let f = DateFormatter()
        f.timeZone = .current
        if Lang(language).en {
            f.locale = Locale(identifier: "en_US")
            f.setLocalizedDateFormatFromTemplate(hasTime ? "MMMdyyyyjmm" : "MMMdyyyy")
            return f.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        }
        f.locale = Locale(identifier: "es_ES")
        f.dateFormat = hasTime ? "d MMM yyyy, HH:mm" : "d MMM yyyy"
        return f.string(from: date).replacingOccurrences(of: ".", with: "")
    }

    /// True when a date-only value was stored (local midnight exactly).
    static func looksDateOnly(_ date: Date) -> Bool {
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return c.hour == 0 && c.minute == 0 && c.second == 0
    }
}

/// Best guess of when a file's content happened (CONTRACT §11.1).
enum FileDates {
    /// Audio/video: the recording's own `creationDate` metadata (QuickTime/iTunes/ID3) > the file's creation date > now.
    static func mediaEventDate(_ url: URL) async -> Date {
        let asset = AVURLAsset(url: url)
        func date(of item: AVMetadataItem) async -> Date? {
            if let d = try? await item.load(.dateValue), plausible(d) { return d }
            if let s = try? await item.load(.stringValue), let d = SBDate.parseISO(s)?.date ?? EmailParser.parseDate(s), plausible(d) {
                return d
            }
            return nil
        }
        if let item = try? await asset.load(.creationDate), let d = await date(of: item) { return d }
        // `creationDate` misses some containers (an .m4a's iTunes `©day`, ISO `date`, ID3 recording time): look for them.
        let ids: [AVMetadataIdentifier] = [.quickTimeMetadataCreationDate, .commonIdentifierCreationDate, .iTunesMetadataReleaseDate,
                                           .quickTimeUserDataCreationDate, .isoUserDataDate, .id3MetadataRecordingTime,
                                           .id3MetadataDate, .id3MetadataYear]
        if let all = try? await asset.load(.metadata) {
            for id in ids {
                for item in AVMetadataItem.metadataItems(from: all, filteredByIdentifier: id) {
                    if let d = await date(of: item) { return d }
                }
            }
        }
        return fileDate(url) ?? Date()
    }

    /// Documents: the PDF's own creation date > the earlier of the file's creation/modification dates.
    static func documentEventDate(_ url: URL) -> Date? {
        if url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url),
           let d = doc.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date, plausible(d) {
            return d
        }
        return fileDate(url)
    }

    /// Earlier of creation and modification (downloads/copies often keep the original mtime but get a new ctime).
    static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        let dates = [values?.creationDate, values?.contentModificationDate].compactMap { $0 }.filter(plausible)
        return dates.min()
    }

    /// Not in the future, not before 1990 (bogus metadata).
    static func plausible(_ d: Date) -> Bool {
        d <= Date().addingTimeInterval(86_400) && d > Date(timeIntervalSince1970: 631_152_000)
    }
}
