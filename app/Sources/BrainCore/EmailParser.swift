import CryptoKit
import Foundation

/// Deterministic parser for emails pasted from Gmail, Outlook, Apple Mail (es/en), forwards and multi-message
/// conversation copies (CONTRACT §11.5). No network, no Claude.
public enum EmailParser {

    // MARK: Public API

    /// The newest message of the paste. With a multi-message paste (a Gmail conversation copy), the earlier
    /// messages are appended to `quotedHistory`; `parseAll` returns them separately.
    public static func parse(_ text: String, ownerEmails: [String] = [], ownerName: String? = nil, now: Date = Date()) -> ParsedEmail {
        let all = parseAll(text, ownerEmails: ownerEmails, ownerName: ownerName, now: now)
        guard var last = all.last else {
            return ParsedEmail(subject: nil, from: nil, date: nil, body: "", quotedHistory: nil, raw: text)
        }
        if all.count > 1 {
            let earlier = all.dropLast().reversed().map { render($0) }.joined(separator: "\n\n")
            last.quotedHistory = [last.quotedHistory, earlier].compactMap { $0 }.joined(separator: "\n\n")
        }
        last.raw = text
        return last
    }

    /// Every message of the paste, oldest first. One element for a normal paste (its history stays quoted).
    public static func parseAll(_ text: String, ownerEmails: [String] = [], ownerName: String? = nil, now: Date = Date()) -> [ParsedEmail] {
        let ordered = ownerEmails.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let owners = Set(ordered)
        let lines = normalize(text).components(separatedBy: "\n")
        let ctx = Context(owners: owners, primaryOwner: ordered.first, ownerName: ownerName, now: now)
        var messages: [ParsedEmail]
        let blocks = gmailBlocks(in: lines, now: now)
        if !blocks.isEmpty {
            let subject = gmailSubject(Array(lines[..<blocks[0].start]))
            messages = []
            for (n, block) in blocks.enumerated() {
                let end = n + 1 < blocks.count ? blocks[n + 1].start : lines.count
                let bodyLines = Array(lines[block.bodyStart..<end])
                // The subject line above the sender blocks wins over one borrowed from quoted/forwarded history.
                var headers = block.headers
                if headers[.subject] == nil, let subject { headers[.subject] = subject }
                let email = message(headers: headers, bodyLines: bodyLines, ctx: ctx)
                messages.append(email)
            }
        } else {
            messages = [singleMessage(lines, ctx: ctx)]
        }
        for i in messages.indices {
            messages[i].raw = messages.count == 1 ? text : render(messages[i])
            if let from = messages[i].from?.email { messages[i].isFromOwner = owners.contains(from) }
        }
        // Conversation copies are oldest first; when every message has a date, trust the dates.
        if messages.count > 1, messages.allSatisfy({ $0.date != nil }) {
            messages.sort { $0.date! < $1.date! }
        }
        return messages
    }

    /// Subject without reply/forward prefixes (`Re:`, `RE:`, `Fwd:`, `FW:`, `RV:`, `AW:`, `WG:`, `TR:`…) and
    /// leading `[tags]`, whitespace collapsed. Case is kept (for display).
    public static func normalizeSubject(_ subject: String) -> String {
        var s = subject.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let prefix = #"^(?i)(?:\[[^\]]{1,40}\]\s*|(?:re|fw|fwd|rv|aw|wg|tr|r|res|enc|sv|vs|antw|rif|i)\s*(?:\[\d+\]|\(\d+\))?\s*[:：]\s*)"#
        while let r = s.range(of: prefix, options: .regularExpression), !r.isEmpty {
            s.removeSubrange(r)
            s = s.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Comparison key: normalized subject, lowercase, without accents.
    public static func subjectKey(_ subject: String) -> String {
        normalizeSubject(subject).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased().replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// `Ana García <ana@acme.com>, "Pérez, Luis" <luis@x.com>; bob@y.com`, `Ana [mailto:ana@acme.com]`.
    public static func parseAddresses(_ text: String) -> [EmailAddress] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false, depth = 0
        for ch in text {
            switch ch {
            case "\"": inQuotes.toggle(); current.append(ch)
            case "<", "[", "(": depth += 1; current.append(ch)
            case ">", "]", ")": depth = max(0, depth - 1); current.append(ch)
            case "," where !inQuotes && depth == 0, ";" where !inQuotes && depth == 0:
                parts.append(current); current = ""
            default: current.append(ch)
            }
        }
        parts.append(current)
        // "García, Ana <ana@x>" (unquoted comma inside a name): glue a name-only piece onto the next piece when that one
        // has an address but no name.
        var merged: [String] = []
        for part in parts.map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
            let lastIsSurname = merged.last.map { !$0.contains("@") && !$0.contains(" ") && !$0.isEmpty } ?? false
            let isFirstNameWithAddress = part.range(of: #"^[^\s<@,]+\s*<[^>]+@[^>]+>$"#, options: .regularExpression) != nil
            if let last = merged.last, (!last.contains("@") && part.hasPrefix("<") && !last.isEmpty) || (lastIsSurname && isFirstNameWithAddress) {
                merged[merged.count - 1] = last + " " + part
            } else {
                merged.append(part)
            }
        }
        return merged.compactMap(parseAddress)
    }

    static func parseAddress(_ raw: String) -> EmailAddress? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        func clean(_ name: String?) -> String? {
            guard var n = name?.trimmingCharacters(in: .whitespaces) else { return nil }
            n = n.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’ ")).trimmingCharacters(in: .whitespaces)
            return n.isEmpty || n.contains("@") && !n.contains(" ") ? nil : n
        }
        func cleanEmail(_ e: String) -> String {
            e.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive)
                .trimmingCharacters(in: CharacterSet(charactersIn: " <>[]()\"'")).lowercased()
        }
        for pattern in [#"^(.*?)\s*<([^<>]+@[^<>]+)>"#, #"^(.*?)\s*\[mailto:([^\]]+)\]"#, #"^(.*?)\s*\(([^()]+@[^()]+)\)"#] {
            if let m = firstMatch(pattern, in: s) {
                let name = clean(m[1])
                let email = cleanEmail(m[2] ?? "")
                return EmailAddress(name: name == email ? nil : name, email: email.isEmpty ? nil : email)
            }
        }
        if let m = firstMatch(#"^<?([A-Za-z0-9._%+'\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})>?$"#, in: s) {
            return EmailAddress(name: nil, email: cleanEmail(m[1] ?? s))
        }
        return EmailAddress(name: clean(s), email: nil)
    }

    // MARK: Dates

    private static let months: [String: Int] = {
        var m: [String: Int] = [:]
        let es = [["ene", "enero"], ["feb", "febrero"], ["mar", "marzo"], ["abr", "abril"], ["may", "mayo"], ["jun", "junio"],
                  ["jul", "julio"], ["ago", "agosto"], ["sep", "sept", "set", "septiembre", "setiembre"], ["oct", "octubre"],
                  ["nov", "noviembre"], ["dic", "diciembre"]]
        let en = [["jan", "january"], ["feb", "february"], ["mar", "march"], ["apr", "april"], ["may"], ["jun", "june"],
                  ["jul", "july"], ["aug", "august"], ["sep", "sept", "september"], ["oct", "october"], ["nov", "november"],
                  ["dec", "december"]]
        for (i, names) in es.enumerated() { for n in names { m[n] = i + 1 } }
        for (i, names) in en.enumerated() { for n in names { m[n] = i + 1 } }
        return m
    }()

    private static let zoneAbbreviations: [String: Int] = [
        "utc": 0, "gmt": 0, "z": 0, "ut": 0, "est": -5, "edt": -4, "cst": -6, "cdt": -5, "mst": -7, "mdt": -6,
        "pst": -8, "pdt": -7, "cet": 1, "cest": 2, "bst": 1, "wet": 0, "west": 1, "art": -3, "brt": -3, "clt": -4,
        "cot": -5, "pet": -5,
    ]

    /// Parses the many date formats mail clients print: Gmail "lun, 26 oct 2026, 10:15 (hace 2 días)", "Mon, Oct 26,
    /// 2026, 10:15 AM", "Monday, October 26, 2026 at 10:15 AM", Outlook "lunes, 26 de octubre de 2026 10:15",
    /// "26/10/2026 10:15", RFC 2822 "Mon, 26 Oct 2026 10:15:00 -0600", ISO 8601, a bare time ("10:15", today).
    /// Explicit offsets/zone names are honoured; otherwise the local time zone. Missing year → the most recent past one.
    /// `dayFirst` resolves "03/04/2026"; default: month first only when the text has AM/PM.
    public static func parseDate(_ input: String, now: Date = Date(), dayFirst: Bool? = nil) -> Date? {
        var s = input.lowercased()
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count < 160 else { return nil }
        let original = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if original.contains("-"), let iso = SBDate.parseISO(original) { return iso.date }
        // Relative "(hace 2 días)" / "(2 days ago)" / "(0 minutes ago)" comments.
        s = s.replacingOccurrences(of: #"\((?:hace|.*\bago\b)[^)]*\)"#, with: " ", options: .regularExpression)

        // Time (removed from the string once found).
        var hour: Int?, minute = 0, second = 0, meridiem: Character?
        var afterTime = ""
        if let r = s.range(of: #"(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([ap])\.?\s?m\b\.?)?"#, options: .regularExpression) {
            let m = firstMatch(#"(\d{1,2}):(\d{2})(?::(\d{2}))?(?:\s*([ap])\.?\s?m\b\.?)?"#, in: String(s[r]))!
            hour = Int(m[1] ?? ""); minute = Int(m[2] ?? "") ?? 0; second = Int(m[3] ?? "") ?? 0
            meridiem = m[4]?.first
            afterTime = String(s[r.upperBound...])
            s.replaceSubrange(r, with: " ")
        }
        if let h = hour {
            guard h <= 23, minute <= 59 else { return nil }
            if meridiem == "p", h < 12 { hour = h + 12 }
            if meridiem == "a", h == 12 { hour = 0 }
        }

        // Time zone: an offset or zone name after the time (or anywhere when no time).
        var zone: TimeZone?
        let zoneScope = hour != nil ? afterTime : s
        let offsetPattern = #"(?:^|\s|\(|gmt|utc)([+-])(\d{1,2})(?::?(\d{2}))?\b(?![-/.]\d)"#
        if let m = firstMatch(offsetPattern, in: zoneScope),
           hour != nil || zoneScope.contains("gmt") || zoneScope.contains("utc") {
            let sign = m[1] == "-" ? -1 : 1
            let h = Int(m[2] ?? "0") ?? 0, mins = Int(m[3] ?? "0") ?? 0
            if h <= 14, mins < 60 { zone = TimeZone(secondsFromGMT: sign * (h * 3600 + mins * 60)) }
        }
        if zone == nil {
            for token in zoneScope.components(separatedBy: CharacterSet.letters.inverted) where !token.isEmpty {
                if let h = zoneAbbreviations[token] { zone = TimeZone(secondsFromGMT: h * 3600); break }
            }
        }
        if zone != nil {
            // Drop the offset so its digits aren't mistaken for a day/year.
            s = s.replacingOccurrences(of: #"(?:gmt|utc)\s*[+-]\d{1,2}(?::?\d{2})?|\s[+-]\d{4}\b|\s[+-]\d{2}:\d{2}\b"#, with: " ",
                                       options: .regularExpression)
        }

        var year: Int?, month: Int?, day: Int?
        // Numeric dates: 2026-10-26, 26/10/2026, 10/26/2026, 26.10.26.
        if let m = firstMatch(#"\b(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})\b"#, in: s) {
            year = Int(m[1]!); month = Int(m[2]!); day = Int(m[3]!)
        } else if let m = firstMatch(#"\b(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})\b"#, in: s) {
            let a = Int(m[1]!)!, b = Int(m[2]!)!
            var y = Int(m[3]!)!
            if y < 100 { y += 2000 }
            let preferDayFirst = dayFirst ?? (meridiem == nil)
            if a > 12 { day = a; month = b } else if b > 12 { month = a; day = b } else if preferDayFirst { day = a; month = b } else { month = a; day = b }
            year = y
        } else {
            // Words: "lun, 26 oct 2026", "October 26, 2026", "26 de octubre de 2026", "mar, 27 oct" (mar = martes here).
            let tokens = s.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty && $0 != "de" && $0 != "del" }
            // Month names next to a day number; "mar" first is the weekday (martes) when another month name follows.
            var candidates: [(index: Int, month: Int, hasDay: Bool)] = []
            for (i, t) in tokens.enumerated() {
                guard let mo = months[t.folding(options: .diacriticInsensitive, locale: nil)] else { continue }
                let neighbours = [i - 1, i + 1].filter { tokens.indices.contains($0) }
                let hasDay = neighbours.contains { j in Int(tokens[j]).map { (1...31).contains($0) && tokens[j].count <= 2 } ?? false }
                candidates.append((i, mo, hasDay))
            }
            if candidates.count > 1 { candidates.removeAll { $0.index == 0 } }
            let chosen = candidates.first { $0.hasDay } ?? candidates.first
            let monthIndex = chosen?.index
            month = chosen?.month
            if let mi = monthIndex {
                for j in [mi + 1, mi - 1] where tokens.indices.contains(j) {
                    if let n = Int(tokens[j]), tokens[j].count <= 2, (1...31).contains(n) { day = n; break }
                }
            }
            year = tokens.compactMap { $0.count == 4 ? Int($0) : nil }.first { (1970...2100).contains($0) }
            if day == nil { month = nil }
            if month == nil {
                var cal = Calendar(identifier: .gregorian)
                cal.timeZone = zone ?? .current
                if tokens.contains(where: { ["ayer", "yesterday"].contains($0) }), let h = hour {
                    let y = cal.date(byAdding: .day, value: -1, to: now)!
                    return compose(cal, cal.dateComponents([.year, .month, .day], from: y), h, minute, second)
                }
                // Gmail shows only the time for today's messages.
                guard let h = hour, tokens.allSatisfy({ !$0.contains(where: \.isNumber) }) else { return nil }
                return compose(cal, cal.dateComponents([.year, .month, .day], from: now), h, minute, second)
            }
        }
        guard let mo = month, let d = day, (1...12).contains(mo), (1...31).contains(d) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = zone ?? .current
        var y = year ?? cal.component(.year, from: now)
        var comps = DateComponents(year: y, month: mo, day: d)
        if year == nil, let candidate = compose(cal, comps, hour ?? 0, minute, second), candidate > now.addingTimeInterval(2 * 86_400) {
            y -= 1
            comps.year = y
        }
        return compose(cal, comps, hour ?? 0, minute, second)
    }

    private static func compose(_ cal: Calendar, _ comps: DateComponents, _ h: Int, _ m: Int, _ s: Int) -> Date? {
        var c = comps
        c.hour = h; c.minute = m; c.second = s
        guard let date = cal.date(from: c), cal.component(.day, from: date) == comps.day else { return nil }
        return date
    }

    // MARK: Structure

    private struct Context {
        let owners: Set<String>
        let primaryOwner: String?   // first address the owner listed: what "para mí" resolves to
        let ownerName: String?
        let now: Date
    }

    private enum Field: String { case from, to, cc, date, subject, other }

    private static let headerNames: [String: Field] = [
        "from": .from, "de": .from, "remitente": .from, "sender": .from,
        "to": .to, "para": .to, "destinatario": .to, "destinatarios": .to,
        "cc": .cc, "copia": .cc, "con copia": .cc,
        "date": .date, "fecha": .date, "sent": .date, "enviado": .date, "enviado el": .date, "enviada": .date,
        "fecha de envío": .date, "sent on": .date,
        "subject": .subject, "asunto": .subject,
        "bcc": .other, "cco": .other, "reply-to": .other, "responder a": .other, "importance": .other, "importancia": .other,
        "attachments": .other, "datos adjuntos": .other, "archivos adjuntos": .other, "adjuntos": .other,
    ]

    private typealias Headers = [Field: String]

    /// `From: x`, `**De:** x`, `Enviado el: x` → (field, value).
    private static func headerLine(_ line: String) -> (Field, String)? {
        guard let m = firstMatch(#"^\s*\**\s*([A-Za-zÁÉÍÓÚáéíóúñÑ\- ]{1,20}?)\s*\**\s*:\s*\**\s*(.*)$"#, in: line),
              let key = m[1]?.lowercased().trimmingCharacters(in: .whitespaces), let field = headerNames[key] else { return nil }
        return (field, (m[2] ?? "").trimmingCharacters(in: .whitespaces))
    }

    /// A run of header lines starting at `start` (blank lines before it skipped). Needs ≥ 2 known headers, one of
    /// them From or Date. Returns the headers and the index of the first line after the block.
    private static func headerBlock(_ lines: [String], at start: Int) -> (headers: Headers, end: Int)? {
        var i = start
        while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).isEmpty { i += 1 }
        var headers: Headers = [:]
        var count = 0
        var last: Field?
        while i < lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces).isEmpty { break }
            if let (field, value) = headerLine(line) {
                if field != .other, headers[field] == nil { headers[field] = value }
                count += 1
                last = field
            } else if let f = last, f == .to || f == .cc || f == .subject,
                      line.first == " " || line.first == "\t" || (f != .subject && line.contains("@")) {
                headers[f, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)   // folded header
            } else {
                break
            }
            i += 1
        }
        guard count >= 2, headers[.from] != nil || headers[.date] != nil else { return nil }
        return (headers, i)
    }

    private struct GmailBlock {
        var start: Int
        var bodyStart: Int
        var headers: Headers
    }

    private static let senderPattern = #"^\s*(.{0,80}?)\s*<([^<>\s]+@[^<>\s]+)>\s*(.*)$"#

    /// Gmail web copies: "Ana García <ana@acme.com>" / date line ("lun, 26 oct 2026, 10:15 (hace 2 días)") /
    /// optional "para mí, Luis" / "to me". Blank lines between them are common.
    private static func gmailBlocks(in lines: [String], now: Date) -> [GmailBlock] {
        var blocks: [GmailBlock] = []
        var i = 0
        func nextNonBlank(_ from: Int, limit: Int = 4) -> Int? {
            var j = from
            while j < lines.count, j < from + limit {
                if !lines[j].trimmingCharacters(in: .whitespaces).isEmpty { return j }
                j += 1
            }
            return nil
        }
        while i < lines.count {
            let line = lines[i]
            guard headerLine(line) == nil, !line.trimmingCharacters(in: .whitespaces).hasPrefix(">"),
                  let m = firstMatch(senderPattern, in: line), !(m[1] ?? "").lowercased().hasSuffix("wrote:") else { i += 1; continue }
            let rest = (m[3] ?? "").trimmingCharacters(in: .whitespaces)
            var dateText: String?
            var cursor = i + 1
            if !rest.isEmpty, parseDate(rest, now: now) != nil {
                dateText = rest
            } else if let j = nextNonBlank(i + 1), lines[j].count < 90, looksLikeDateLine(lines[j]), parseDate(lines[j], now: now) != nil {
                dateText = lines[j]
                cursor = j + 1
            }
            guard let dateText else { i += 1; continue }
            var headers: Headers = [.from: "\(m[1] ?? "") <\(m[2] ?? "")>", .date: dateText]
            if let j = nextNonBlank(cursor), let r = firstMatch(#"^\s*(?:para|to)\s+(.+)$"#, in: lines[j]), lines[j].count < 300 {
                headers[.to] = r[1]
                cursor = j + 1
            }
            blocks.append(GmailBlock(start: i, bodyStart: cursor, headers: headers))
            i = cursor
        }
        return blocks
    }

    private static func looksLikeDateLine(_ line: String) -> Bool {
        let l = line.lowercased()
        return l.contains(":") && l.contains(where: \.isNumber) || l.contains("ago") || l.contains("hace")
    }

    /// The lines above the first Gmail sender: subject plus label chips ("Recibidos", "Inbox ×").
    private static func gmailSubject(_ lines: [String]) -> String? {
        let labels: Set<String> = ["recibidos", "inbox", "bandeja de entrada", "importante", "important", "externo", "external",
                                   "x", "×", "spam", "enviados", "sent", "destacados", "starred", "personal", "trabajo", "work"]
        for line in lines {
            var t = line.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty, !labels.contains(t.lowercased()) else { continue }
            var changed = true
            while changed {
                changed = false
                for label in labels where t.lowercased().hasSuffix(" " + label) {
                    t = String(t.dropLast(label.count + 1)).trimmingCharacters(in: .whitespaces)
                    changed = true
                }
            }
            if let (field, value) = headerLine(t), field == .subject { return value }
            return t.isEmpty ? nil : t
        }
        return nil
    }

    /// A paste without Gmail sender blocks: optional leading subject line / forward marker, optional header block,
    /// then the body.
    private static func singleMessage(_ lines: [String], ctx: Context) -> ParsedEmail {
        var start = 0
        while start < lines.count, lines[start].trimmingCharacters(in: .whitespaces).isEmpty { start += 1 }
        // Pasted from a forward without the forwarder's own headers: "---------- Forwarded message ---------" first.
        if start < lines.count, isForwardMarker(lines[start]), let block = headerBlock(lines, at: start + 1) {
            return message(headers: block.headers, bodyLines: Array(lines[block.end...]), ctx: ctx)
        }
        if let block = headerBlock(lines, at: start) {
            return message(headers: block.headers, bodyLines: Array(lines[block.end...]), ctx: ctx)
        }
        // A subject line, then headers.
        if start < lines.count, let block = headerBlock(lines, at: start + 1) {
            var headers = block.headers
            if headers[.subject] == nil { headers[.subject] = lines[start].trimmingCharacters(in: .whitespaces) }
            return message(headers: headers, bodyLines: Array(lines[block.end...]), ctx: ctx)
        }
        return message(headers: [:], bodyLines: Array(lines[start...]), ctx: ctx)
    }

    private static func message(headers: Headers, bodyLines: [String], ctx: Context) -> ParsedEmail {
        var body = bodyLines
        var quoted: [String] = []
        if let q = quoteStart(body) {
            quoted = Array(body[q...])
            body = Array(body[..<q])
        }
        body = trimNoise(body)
        var bodyText = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var quotedText: String? = quoted.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if quotedText?.isEmpty ?? true { quotedText = nil }

        var headers = headers
        // Nothing new above a forward and no headers of our own: the forwarded message IS the email.
        if headers.isEmpty, bodyText.isEmpty, let first = quoted.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           isForwardMarker(quoted[first]), let block = headerBlock(quoted, at: first + 1) {
            return message(headers: block.headers, bodyLines: Array(quoted[block.end...]), ctx: ctx)
        }
        // No subject of our own: borrow the quoted one (threading needs it; the UI preview lets the user fix it).
        if headers[.subject] == nil, let q = quotedText {
            let qLines = q.components(separatedBy: "\n")
            for i in qLines.indices {
                if let (field, value) = headerLine(qLines[i]), field == .subject, !value.isEmpty { headers[.subject] = value; break }
            }
        }
        if bodyText.isEmpty, quotedText == nil { bodyText = "" }

        var from = headers[.from].flatMap { parseAddresses($0).first }
        if let f = from, f.email == nil, let n = f.name, let mail = firstMatch(#"([A-Za-z0-9._%+'\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,})"#, in: n)?[1] {
            from = EmailAddress(name: n.replacingOccurrences(of: mail, with: "").trimmingCharacters(in: CharacterSet(charactersIn: " <>()[]")), email: mail.lowercased())
        }
        let to = recipients(headers[.to], ctx: ctx)
        let cc = recipients(headers[.cc], ctx: ctx)
        let subject = headers[.subject].map { $0.trimmingCharacters(in: .whitespaces) }.flatMap { $0.isEmpty ? nil : $0 }
        let date = headers[.date].flatMap { parseDate($0, now: ctx.now) }
        return ParsedEmail(subject: subject, from: from, to: to, cc: cc, date: date, body: bodyText,
                           quotedHistory: quotedText, raw: "", isFromOwner: false)
    }

    /// Gmail's "para mí, Luis" / "to me" → the owner's address when known.
    private static func recipients(_ text: String?, ctx: Context) -> [EmailAddress] {
        guard let text, !text.isEmpty else { return [] }
        return parseAddresses(text).map { a in
            guard a.email == nil, let n = a.name?.lowercased(), ["mí", "mi", "me", "yo"].contains(n) else { return a }
            return EmailAddress(name: ctx.ownerName ?? a.name, email: ctx.primaryOwner)
        }
    }

    // MARK: Quoted history

    private static func isForwardMarker(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces).lowercased()
        return t.range(of: #"^-{2,}\s*(forwarded message|mensaje reenviado|original message|mensaje original)\s*-*$"#,
                       options: .regularExpression) != nil
            || t.range(of: #"^(begin forwarded message|inicio del mensaje reenviado|mensaje reenviado)\s*:?$"#,
                       options: .regularExpression) != nil
    }

    /// Index of the first line of quoted/forwarded history, if any.
    static func quoteStart(_ lines: [String]) -> Int? {
        func trimmed(_ i: Int) -> String { lines[i].trimmingCharacters(in: .whitespaces) }
        let wrote = #"(wrote|escribió|escribio|a écrit|schrieb)\s*:\s*$"#
        // Non-blank lines from i to the end, and how many of them start with ">" (suffix sums: linear, not O(n²)
        // on a huge paste that alternates quoted and plain lines).
        var nonBlankFrom = [Int](repeating: 0, count: lines.count + 1)
        var quotedFrom = [Int](repeating: 0, count: lines.count + 1)
        for i in lines.indices.reversed() {
            let t = trimmed(i)
            nonBlankFrom[i] = nonBlankFrom[i + 1] + (t.isEmpty ? 0 : 1)
            quotedFrom[i] = quotedFrom[i + 1] + (t.hasPrefix(">") ? 1 : 0)
        }
        for i in lines.indices {
            let t = trimmed(i)
            guard !t.isEmpty else { continue }
            let lower = t.lowercased()
            if isForwardMarker(t) { return i }
            // "On Mon, Oct 26, 2026 at 10:15 AM Ana <ana@x.com> wrote:" — possibly wrapped over 2-3 lines.
            if lower.range(of: #"^(on|el|em|le|am)\s"#, options: .regularExpression) != nil, t.count < 300 {
                let joined = (i..<min(lines.count, i + 3)).map(trimmed).joined(separator: " ").lowercased()
                if let r = joined.range(of: wrote, options: .regularExpression),
                   joined[..<r.lowerBound].count < 300, lower.contains(where: \.isNumber) || joined.contains("@") { return i }
            }
            // "<ana@x.com> escribió el 26/10/2026 10:15:" — needs an address, a time or a year to not catch prose.
            if lower.range(of: wrote, options: .regularExpression) != nil, t.count < 300,
               lower.contains("@") || lower.range(of: #"\d{1,2}:\d{2}|\b(19|20)\d{2}\b"#, options: .regularExpression) != nil { return i }
            if t.range(of: #"^_{8,}$"#, options: .regularExpression) != nil,
               let j = (i + 1..<lines.count).first(where: { !trimmed($0).isEmpty }), headerLine(lines[j]) != nil { return i }
            // Outlook reply header: "From: …" then "Sent:/Date:/To:/Subject:" within a few lines.
            if let (field, _) = headerLine(t), field == .from,
               (i + 1..<min(lines.count, i + 6)).contains(where: { j in headerLine(lines[j]).map { $0.0 != .from && $0.0 != .other } ?? false }) {
                return i
            }
            if t.hasPrefix(">"), Double(quotedFrom[i]) >= 0.6 * Double(nonBlankFrom[i]) { return i }
        }
        return nil
    }

    /// Drops client chrome around a body: "Responder"/"Reply", collapsed-quote dots, trailing blank lines.
    private static func trimNoise(_ lines: [String]) -> [String] {
        let noise: Set<String> = ["responder", "reenviar", "responder a todos", "reply", "reply all", "forward", "...", "•••", "…",
                                  "mostrar texto citado", "show quoted text", "show trimmed content", "mostrar contenido recortado"]
        var out = lines
        while let last = out.last, last.trimmingCharacters(in: .whitespaces).isEmpty || noise.contains(last.trimmingCharacters(in: .whitespaces).lowercased()) {
            out.removeLast()
        }
        while let first = out.first, first.trimmingCharacters(in: .whitespaces).isEmpty { out.removeFirst() }
        return out
    }

    // MARK: Helpers

    static func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{200B}", with: "").replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\u{200E}", with: "").replacingOccurrences(of: "\u{200F}", with: "")
    }

    /// Plain-text rendering of a parsed message (used for history of multi-message pastes).
    static func render(_ e: ParsedEmail) -> String {
        var lines: [String] = []
        if let f = e.from { lines.append("From: " + format(f)) }
        if let d = e.date { lines.append("Date: " + SBDate.iso(d)) }
        if !e.to.isEmpty { lines.append("To: " + e.to.map(format).joined(separator: ", ")) }
        if !e.cc.isEmpty { lines.append("Cc: " + e.cc.map(format).joined(separator: ", ")) }
        if let s = e.subject { lines.append("Subject: " + s) }
        return (lines + ["", e.body]).joined(separator: "\n")
    }

    /// `Ana García <ana@acme.com>`.
    public static func format(_ a: EmailAddress) -> String {
        switch (a.name, a.email) {
        case let (n?, e?): return "\(n) <\(e)>"
        case let (n?, nil): return n
        case let (nil, e?): return e
        default: return "?"
        }
    }

    /// Whitespace/case-insensitive fingerprint of a body (duplicate detection, quoted-history matching).
    static func bodyFingerprint(_ body: String) -> String {
        let norm = normalizedText(body)
        let digest = SHA256.hash(data: Data(norm.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedText(_ s: String) -> String {
        s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: "\n").map { line -> String in
                var l = line.trimmingCharacters(in: .whitespaces)
                while l.hasPrefix(">") { l = String(l.dropFirst()).trimmingCharacters(in: .whitespaces) }
                return l
            }
            .joined(separator: " ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Capture groups of the first match (index 0 = whole match); nil groups for non-participating ones.
    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> [String?]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: text).map { String(text[$0]) } }
    }
}
