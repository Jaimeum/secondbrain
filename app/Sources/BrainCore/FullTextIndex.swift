import Foundation

// ⌘K full text (CONTRACT §16.7): an in-memory inverted index of every wiki page of the vault (never raw/, _inbox/,
// templates or navigation pages), accent- and case-insensitive. `refresh` re-reads only the files whose size or
// modification date changed since the last pass, so a vault revision costs one directory walk plus the pages that
// changed. Queries match every word of the query (the last ones also by prefix) in the title or the body; titles weigh
// more than the body; a body hit comes with a ±60-character snippet with the matches marked.

/// What a page is, by its folder (the ⌘K group it goes to).
public enum SearchPageKind: String, Sendable, Hashable, CaseIterable {
    case person, org, topic, decision, meeting, emailThread, note, question, repo   // v0.7 (§17.4)
    /// A page at the root of a project's wiki (overview, timeline…).
    case project
}

/// One indexed page, without its text.
public struct SearchPageInfo: Sendable, Hashable {
    public let path: String
    public let title: String
    public let kind: SearchPageKind
    public let projectSlug: String?
    /// Front-matter `event_date`/`date`, else the date in the file name ("2026-10-26-0900-…").
    public let date: Date?
}

/// A piece of a snippet; `bold` = it matched the query.
public struct SnippetPart: Sendable, Hashable {
    public let text: String
    public let bold: Bool
    public init(_ text: String, bold: Bool) { self.text = text; self.bold = bold }
}

public struct FullTextHit: Sendable, Hashable {
    public let path: String
    /// `titleBoost` + the title's match (1…3) when the title holds the query; else the body's (0…`maxBodyScore`].
    public let score: Double
    public let titleMatch: Bool
    /// Where the earliest query word starts in the page's plain text (scalar offset), nil when only the title matched.
    public let bodyOffset: Int?
}

public final class FullTextIndex: @unchecked Sendable {
    public static let titleBoost = 3.0
    public static let maxBodyScore = 1.5
    /// Characters of context on each side of the match in a snippet.
    public static let snippetContext = 60
    /// A query word expands to at most this many indexed words that start with it.
    static let maxPrefixTerms = 300

    struct Doc {
        var info: SearchPageInfo
        var foldedTitle: String
        /// Body without front-matter or markdown marks, on one line (snippets are cut from it).
        var plain: String
        /// Word → its first offset in `plain` (unicode scalars).
        var bodyTerms: [String: Int32]
        var titleTerms: Set<String>
        var signature: String
    }

    private let lock = NSLock()
    /// Serializes refreshes (a second one waits; it then finds nothing new to read).
    private let refreshLock = NSLock()
    private var docs: [Int32: Doc] = [:]
    private var idByPath: [String: Int32] = [:]
    private var postings: [String: [Int32]] = [:]
    private var sortedTerms: [String] = []
    private var termsDirty = false
    private var nextId: Int32 = 0

    public init() {}

    public var count: Int { lock.withLock { docs.count } }

    public func pages() -> [SearchPageInfo] {
        lock.withLock { docs.values.map(\.info) }
    }

    public func page(_ path: String) -> SearchPageInfo? {
        lock.withLock { idByPath[path].flatMap { docs[$0]?.info } }
    }

    /// Forgets everything (another vault).
    public func reset() {
        lock.withLock {
            docs = [:]; idByPath = [:]; postings = [:]; sortedTerms = []; termsDirty = false; nextId = 0
        }
    }

    // MARK: Building

    /// Brings the index up to date with the vault at `root`: new and changed pages are (re)read, deleted ones dropped.
    @discardableResult
    public func refresh(root: URL) -> (updated: Int, removed: Int) {
        refreshLock.lock()
        defer { refreshLock.unlock() }
        let found = Self.wikiFiles(root: root)
        let known: [String: String] = lock.withLock {
            Dictionary(uniqueKeysWithValues: idByPath.compactMap { path, id in docs[id].map { (path, $0.signature) } })
        }
        var parsed: [Doc] = []
        for (path, signature) in found where known[path] != signature {
            guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { continue }
            parsed.append(Self.makeDoc(path: path, text: text, signature: signature))
        }
        let gone = Set(known.keys).subtracting(found.keys)
        guard !parsed.isEmpty || !gone.isEmpty else { return (0, 0) }
        lock.withLock {
            for path in gone { removeLocked(path) }
            for doc in parsed { insertLocked(doc) }
        }
        return (parsed.count, gone.count)
    }

    /// Indexes one page from text (tests; the app always goes through `refresh`).
    public func upsert(path: String, text: String) {
        let doc = Self.makeDoc(path: path, text: text, signature: UUID().uuidString)
        lock.withLock { insertLocked(doc) }
    }

    public func remove(path: String) {
        lock.withLock { removeLocked(path) }
    }

    private func insertLocked(_ doc: Doc) {
        removeLocked(doc.info.path)
        let id = nextId
        nextId += 1
        docs[id] = doc
        idByPath[doc.info.path] = id
        for term in Set(doc.bodyTerms.keys).union(doc.titleTerms) {
            if postings[term] == nil { termsDirty = true }
            postings[term, default: []].append(id)
        }
    }

    private func removeLocked(_ path: String) {
        guard let id = idByPath.removeValue(forKey: path), let doc = docs.removeValue(forKey: id) else { return }
        for term in Set(doc.bodyTerms.keys).union(doc.titleTerms) {
            guard var list = postings[term] else { continue }
            list.removeAll { $0 == id }
            if list.isEmpty {
                postings[term] = nil
                termsDirty = true
            } else {
                postings[term] = list
            }
        }
    }

    /// Wiki pages (vault-relative path → "size-mtime"): root pages, people/, orgs/, questions/ and every project's
    /// wiki/, minus schemas and navigation pages (index, log, health) and tasks.md (its tasks have their own rows).
    static func wikiFiles(root: URL) -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        func add(_ url: URL, _ rel: String) {
            guard isIndexed(rel), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { return }
            let stamp = values.contentModificationDate?.timeIntervalSinceReferenceDate ?? 0
            out[rel] = "\(values.fileSize ?? 0)-\(stamp)"
        }
        func walk(_ rel: String) {
            let base = root.appendingPathComponent(rel)
            guard let walker = fm.enumerator(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
            let prefix = base.standardizedFileURL.path + "/"
            for case let url as URL in walker where url.pathExtension.lowercased() == "md" {
                let full = url.standardizedFileURL.path
                guard full.hasPrefix(prefix) else { continue }
                add(url, rel + "/" + full.dropFirst(prefix.count))
            }
        }
        for name in (try? fm.contentsOfDirectory(atPath: root.path)) ?? [] where name.lowercased().hasSuffix(".md") {
            add(root.appendingPathComponent(name), name)
        }
        for folder in ["people", "orgs", "questions"] { walk(folder) }
        let projects = root.appendingPathComponent("projects")
        for slug in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] where !slug.hasPrefix(".") {
            walk("projects/\(slug)/wiki")
        }
        return out
    }

    public static func isIndexed(_ rel: String) -> Bool {
        guard rel.lowercased().hasSuffix(".md"), !rel.contains("/raw/"), !rel.hasPrefix("_inbox/") else { return false }
        let name = (rel as NSString).lastPathComponent
        if name.hasPrefix("CLAUDE") || name == "README.md" { return false }
        return !["index.md", "log.md", "health.md", "tasks.md"].contains(name)
    }

    public static func kind(of path: String) -> SearchPageKind {
        let parts = path.split(separator: "/").map(String.init)
        switch parts.first {
        case "people": return .person
        case "orgs": return .org
        case "questions": return .question
        case "projects":
            guard parts.count >= 4, parts[2] == "wiki" else { return .note }
            if parts.count == 4 { return .project }
            switch parts[3] {
            case "meetings": return .meeting
            case "emails": return .emailThread
            case "sources": return .note
            case "decisions": return .decision
            case "questions": return .question
            case "repos": return .repo
            default: return .topic
            }
        default:
            return .note   // facts.md and other pages at the root of the vault
        }
    }

    static func makeDoc(path: String, text: String, signature: String) -> Doc {
        let parts = Frontmatter.split(text)
        let fallback = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var title: String?
        for line in parts.body.split(separator: "\n", omittingEmptySubsequences: true) where line.hasPrefix("# ") {
            let t = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { title = t; break }
        }
        let resolvedTitle = title ?? Frontmatter.field("title", in: text) ?? fallback
        var date: Date?
        if let raw = Frontmatter.field("event_date", in: text) ?? Frontmatter.field("date", in: text) {
            date = SBDate.parseISO(raw)?.date
        }
        let plain = plainText(parts.body)
        var bodyTerms: [String: Int32] = [:]
        for token in tokens(plain) where bodyTerms[token.term] == nil { bodyTerms[token.term] = Int32(token.start) }
        let info = SearchPageInfo(path: path, title: resolvedTitle, kind: kind(of: path),
                                  projectSlug: VaultStore.projectSlug(of: path), date: date ?? fileDate(path))
        return Doc(info: info, foldedTitle: fold(resolvedTitle), plain: plain, bodyTerms: bodyTerms,
                   titleTerms: Set(tokens(resolvedTitle).map(\.term)), signature: signature)
    }

    /// "2026-10-26-0900-comite.md" → 26 oct 2026 09:00 (meeting and email pages are named by date).
    public static func fileDate(_ path: String) -> Date? {
        let name = (path as NSString).lastPathComponent
        let parts = name.split(separator: "-", maxSplits: 4, omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0].count == 4, parts[1].count == 2, parts[2].prefix(2).count == 2,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2].prefix(2)),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        var comps = DateComponents(year: y, month: m, day: d)
        if parts.count >= 4, parts[3].count == 4, let hm = Int(parts[3]) {
            comps.hour = hm / 100
            comps.minute = hm % 100
        }
        return Calendar.current.date(from: comps)
    }

    // MARK: Text

    private static let aliasLink = try! NSRegularExpression(pattern: #"\[\[[^\]\|\n]*\|([^\]\n]*)\]\]"#)
    private static let plainLink = try! NSRegularExpression(pattern: #"\[\[([^\]\n#]*)(?:#[^\]\n]*)?\]\]"#)
    private static let mdLink = try! NSRegularExpression(pattern: #"!?\[([^\]\n]*)\]\([^)\n]*\)"#)

    /// The body as one line of readable text: links become their label, markdown marks and line structure go.
    public static func plainText(_ body: String) -> String {
        var text = body
        for (regex, template) in [(aliasLink, "$1"), (plainLink, "$1"), (mdLink, "$1")] where text.contains("[") {
            let ns = text as NSString
            text = regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: template)
        }
        var out = String.UnicodeScalarView()
        out.reserveCapacity(text.unicodeScalars.count)
        var lastWasSpace = true
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var s = Substring(line).drop { $0 == " " || $0 == "\t" }
            // Block marks at the start of a line: headings, quotes, list bullets, checkboxes.
            while let first = s.first, first == "#" || first == ">" { s = s.dropFirst().drop { $0 == " " } }
            if s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ") { s = s.dropFirst(2) }
            if s.hasPrefix("[ ] ") || s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { s = s.dropFirst(4) }
            if s.allSatisfy({ $0 == "-" || $0 == "|" || $0 == ":" || $0 == " " || $0 == "=" }) { continue }   // rules, table separators
            for scalar in s.unicodeScalars {
                switch scalar {
                case "*", "`", "\r": continue
                case "|", "\t", " ":
                    if !lastWasSpace { out.append(" "); lastWasSpace = true }
                default:
                    out.append(scalar)
                    lastWasSpace = false
                }
            }
            if !lastWasSpace { out.append(" "); lastWasSpace = true }
        }
        var result = String(out)
        if result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Lowercase, without accents (á → a, Ñ → n); combining marks are dropped (nil).
    private static let foldTable: [Unicode.Scalar?] = (0x80..<0x2000).map { value in
        guard let scalar = Unicode.Scalar(value) else { return nil }
        let folded = String(scalar).folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased().unicodeScalars
        if folded.isEmpty { return nil }
        return folded.count == 1 ? folded.first : (scalar.properties.lowercaseMapping.unicodeScalars.first ?? scalar)
    }

    static func foldScalar(_ s: Unicode.Scalar) -> Unicode.Scalar? {
        let v = s.value
        if v < 0x80 { return v >= 0x41 && v <= 0x5A ? Unicode.Scalar(v + 32)! : s }
        if v < 0x2000 { return foldTable[Int(v) - 0x80] }
        if s.properties.generalCategory == .nonspacingMark { return nil }
        let lower = s.properties.lowercaseMapping.unicodeScalars
        return lower.count == 1 ? lower.first : s
    }

    static func isWordScalar(_ s: Unicode.Scalar) -> Bool {
        let v = s.value
        if v < 0x80 { return (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39) }
        return s.properties.isAlphabetic || s.properties.numericType != nil
    }

    /// Folded words with their range in `text` (unicode-scalar offsets, end exclusive).
    public static func tokens(_ text: String) -> [(term: String, start: Int, end: Int)] {
        var out: [(term: String, start: Int, end: Int)] = []
        var current = String.UnicodeScalarView()
        var start = 0, offset = 0
        func flush() {
            if !current.isEmpty { out.append((String(current), start, offset)); current = String.UnicodeScalarView() }
        }
        for scalar in text.unicodeScalars {
            if let folded = foldScalar(scalar) {
                if isWordScalar(folded) {
                    if current.isEmpty { start = offset }
                    current.append(folded)
                } else {
                    flush()
                }
            }
            offset += 1
        }
        flush()
        return out
    }

    /// The same folding as the index, for whole strings (titles).
    public static func fold(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars { if let f = foldScalar(scalar) { out.append(f) } }
        return String(out)
    }

    /// The words of a query, folded; each one also matches by prefix when it has 2+ characters.
    public static func queryWords(_ query: String) -> [String] {
        var seen = Set<String>()
        return tokens(query).map(\.term).filter { seen.insert($0).inserted }
    }

    // MARK: Ranking

    /// How well a folded title holds a folded query: 3 prefix, 2 start of a word, 1 contains (or every word of the
    /// query appears), 0 no match.
    public static func titleScore(_ key: String, query q: String) -> Double {
        guard !q.isEmpty else { return 0 }
        if key.hasPrefix(q) { return 3 }
        if let range = key.range(of: q) {
            // hasPrefix and range(of:) can disagree on unusual input (emoji sequences, enclosing marks).
            guard range.lowerBound > key.startIndex else { return 3 }
            let before = key[key.index(before: range.lowerBound)]
            return before.isLetter || before.isNumber ? 1 : 2
        }
        let words = q.split(separator: " ")
        guard words.count > 1, words.allSatisfy({ key.contains($0) }) else { return 0 }
        return 1
    }

    // MARK: Querying

    /// Indexed words a query word stands for: itself, plus (2+ characters) the words that start with it.
    private func expandLocked(_ word: String) -> [String] {
        guard word.count >= 2 else { return postings[word] == nil ? [] : [word] }
        if termsDirty {
            sortedTerms = postings.keys.sorted()
            termsDirty = false
        }
        var low = 0, high = sortedTerms.count
        while low < high {
            let mid = (low + high) / 2
            if sortedTerms[mid] < word { low = mid + 1 } else { high = mid }
        }
        var out: [String] = []
        var i = low
        while i < sortedTerms.count, sortedTerms[i].hasPrefix(word), out.count < Self.maxPrefixTerms {
            out.append(sortedTerms[i])
            i += 1
        }
        return out
    }

    /// Pages holding every word of the query (title or body), best first. `limit` caps the list after sorting.
    public func search(_ query: String, limit: Int = .max) -> [FullTextHit] {
        let words = Self.queryWords(query)
        guard !words.isEmpty else { return [] }
        let foldedQuery = Self.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return lock.withLock { () -> [FullTextHit] in
            // Per word: the pages that have it (via any of its expansions) and whether that was the exact word.
            var perWord: [[Int32: Bool]] = []
            let expansions = words.map { expandLocked($0) }
            for (word, terms) in zip(words, expansions) {
                var found: [Int32: Bool] = [:]
                for term in terms {
                    let exact = term == word
                    for id in postings[term] ?? [] where found[id] != true { found[id] = exact }
                }
                if found.isEmpty { return [] }
                perWord.append(found)
            }
            let order = perWord.indices.sorted { perWord[$0].count < perWord[$1].count }
            var candidates = Set(perWord[order[0]].keys)
            for i in order.dropFirst() {
                candidates = candidates.filter { perWord[i][$0] != nil }
                if candidates.isEmpty { return [] }
            }
            var hits: [FullTextHit] = []
            hits.reserveCapacity(candidates.count)
            for id in candidates {
                guard let doc = docs[id] else { continue }
                let title = Self.titleScore(doc.foldedTitle, query: foldedQuery)
                    // Every word in the title, in any order or with other words between them.
                    .nonZeroOr(words.allSatisfy { w in doc.titleTerms.contains { $0.hasPrefix(w) } } ? 1 : 0)
                var offset: Int32?
                var inBody = 0, exactWords = 0
                for (i, word) in words.enumerated() {
                    if perWord[i][id] == true { exactWords += 1 }
                    var best: Int32?
                    if let o = doc.bodyTerms[word] { best = o }
                    if best == nil || word.count >= 2 {
                        for term in expansions[i] where term != word {
                            if let o = doc.bodyTerms[term], best.map({ o < $0 }) ?? true { best = o }
                        }
                    }
                    if let best {
                        inBody += 1
                        offset = offset.map { min($0, best) } ?? best
                    }
                }
                let score: Double
                if title > 0 {
                    score = Self.titleBoost + title
                } else {
                    // All in the body ranks over part in the title and part in the body; whole words over prefixes.
                    let n = Double(words.count)
                    score = 0.5 + 0.5 * Double(inBody) / n + 0.5 * Double(exactWords) / n
                }
                hits.append(FullTextHit(path: doc.info.path, score: score, titleMatch: title > 0,
                                        bodyOffset: offset.map(Int.init)))
            }
            hits.sort { $0.score != $1.score ? $0.score > $1.score : $0.path < $1.path }
            return limit < hits.count ? Array(hits.prefix(limit)) : hits
        }
    }

    /// ±`snippetContext` characters of the page around its first match, cut at word boundaries, with every word that
    /// matches the query in bold. nil when the body doesn't hold the query.
    public func snippet(path: String, query: String) -> [SnippetPart]? {
        let words = Self.queryWords(query)
        guard !words.isEmpty else { return nil }
        let plain: String? = lock.withLock { idByPath[path].flatMap { docs[$0]?.plain } }
        guard let plain else { return nil }
        let scalars = Array(plain.unicodeScalars)
        func matches(_ term: String) -> Bool { words.contains { term == $0 || ($0.count >= 2 && term.hasPrefix($0)) } }
        let all = Self.tokens(plain)
        guard let first = all.first(where: { matches($0.term) }) else { return nil }
        var lower = max(0, first.start - Self.snippetContext)
        var upper = min(scalars.count, first.end + Self.snippetContext)
        // Whole words only: move in to the nearest space (not past the match).
        if lower > 0, let space = scalars[lower..<first.start].firstIndex(of: " ") { lower = space + 1 }
        if upper < scalars.count, let space = scalars[first.end..<upper].lastIndex(of: " ") { upper = space }
        var parts: [SnippetPart] = []
        var cursor = lower
        func text(_ a: Int, _ b: Int) -> String {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[a..<b])
            return String(v)
        }
        for token in all where token.start >= lower && token.end <= upper && matches(token.term) {
            if token.start > cursor { parts.append(SnippetPart(text(cursor, token.start), bold: false)) }
            parts.append(SnippetPart(text(token.start, token.end), bold: true))
            cursor = token.end
        }
        if cursor < upper { parts.append(SnippetPart(text(cursor, upper), bold: false)) }
        if lower > 0 { parts.insert(SnippetPart("…", bold: false), at: 0) }
        if upper < scalars.count { parts.append(SnippetPart("…", bold: false)) }
        return parts
    }
}

private extension Double {
    func nonZeroOr(_ other: Double) -> Double { self > 0 ? self : other }
}
