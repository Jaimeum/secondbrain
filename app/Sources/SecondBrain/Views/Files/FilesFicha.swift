import BrainCore
import Foundation

/// v0.7 (CONTRACT §17.2): the "Archivos" section of a ficha (a thread's attachments, what a person sent or is named in,
/// a company's people's files, a document page's own file), written as markdown after the other automatic sections.
/// Rows link with `sbwiki://page/@file/<path>`; `EntityView.follow` hands those to `FilesModel.reveal`.
enum FilesFicha {
    static let prefix = "@file/"

    /// The file path of a `@file/…` link target, else nil.
    static func filePath(fromLink target: String) -> String? {
        target.hasPrefix(prefix) ? String(target.dropFirst(prefix.count)) : nil
    }

    /// The files `path` lists, newest first (none for navigation pages and project overviews).
    @MainActor static func files(for path: String, snapshot: EntityIndex.Snapshot) -> [FileEntry] {
        FileIndex.files(for: path, in: FilesModel.shared.entries, snapshot: snapshot)
    }

    /// `## Archivos` + one row per file; "" when there are none or the page already has such a heading.
    static func section(_ files: [FileEntry], pageHeadings: [String]) -> String {
        guard !files.isEmpty else { return "" }
        let have = Set(pageHeadings.map(EntityMarkdown.normalized))
        guard have.isDisjoint(with: ["archivos", "files"]) else { return "" }
        var out = ["", "## \(L("entity.section.files"))", ""]
        for file in files.prefix(40) {
            let link = "[\(escape(file.name))](sbwiki://page/\(percent(prefix + file.path)))"
            var parts = [link, escape(FilesView.originLine(file)), day(file.date)]
            parts.insert(FilesView.label(file.type), at: 1)
            out.append("- " + parts.joined(separator: " · "))
        }
        if files.count > 40 { out.append("- …") }
        out.append("")
        return out.joined(separator: "\n")
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\[]*_`<>#|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    private static func percent(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? s
    }
}
