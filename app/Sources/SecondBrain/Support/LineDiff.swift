import Foundation

/// Minimal line diff (LCS) for showing what Claude changed in a wiki page.
enum LineDiff {
    enum Kind { case same, added, removed }

    struct Line: Identifiable {
        let id: Int
        let kind: Kind
        let text: String
        let oldNumber: Int?
        let newNumber: Int?
    }

    /// A side-by-side row: left is the old version, right the new one. Either side can be empty.
    struct Row: Identifiable {
        let id: Int
        let left: Line?
        let right: Line?
    }

    static func lines(before: String, after: String) -> [Line] {
        let a = before.components(separatedBy: "\n")
        let b = after.components(separatedBy: "\n")
        let n = a.count, m = b.count

        // Guard against quadratic blow-up on huge files: fall back to "everything replaced".
        if n * m > 4_000_000 {
            var out: [Line] = []
            for (i, t) in a.enumerated() { out.append(Line(id: out.count, kind: .removed, text: t, oldNumber: i + 1, newNumber: nil)) }
            for (j, t) in b.enumerated() { out.append(Line(id: out.count, kind: .added, text: t, oldNumber: nil, newNumber: j + 1)) }
            return out
        }

        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }

        var out: [Line] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, a[i] == b[j] {
                out.append(Line(id: out.count, kind: .same, text: a[i], oldNumber: i + 1, newNumber: j + 1))
                i += 1; j += 1
            } else if j < m, i == n || lcs[i][j + 1] >= lcs[i + 1][j] {
                out.append(Line(id: out.count, kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1))
                j += 1
            } else {
                out.append(Line(id: out.count, kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil))
                i += 1
            }
        }
        return out
    }

    /// Pairs consecutive removed/added runs so modified lines sit next to each other.
    static func rows(_ lines: [Line]) -> [Row] {
        var rows: [Row] = []
        var removed: [Line] = [], added: [Line] = []
        func flush() {
            for k in 0..<max(removed.count, added.count) {
                rows.append(Row(id: rows.count, left: k < removed.count ? removed[k] : nil, right: k < added.count ? added[k] : nil))
            }
            removed.removeAll(); added.removeAll()
        }
        for line in lines {
            switch line.kind {
            case .same:
                flush()
                rows.append(Row(id: rows.count, left: line, right: line))
            case .removed: removed.append(line)
            case .added: added.append(line)
            }
        }
        flush()
        return rows
    }

    /// Collapses long unchanged stretches, keeping `context` lines around each change.
    static func collapsed(_ rows: [Row], context: Int = 3) -> [Row?] {
        let changed = rows.indices.filter { rows[$0].left?.kind != .same || rows[$0].right?.kind != .same }
        guard !changed.isEmpty else { return rows.count > 2 * context ? Array(rows.prefix(context)) + [nil] : rows }
        var keep = Set<Int>()
        for c in changed { for k in max(0, c - context)...min(rows.count - 1, c + context) { keep.insert(k) } }
        var out: [Row?] = []
        var gap = false
        for (idx, row) in rows.enumerated() {
            if keep.contains(idx) { out.append(row); gap = false } else if !gap { out.append(nil); gap = true }
        }
        return out
    }
}
