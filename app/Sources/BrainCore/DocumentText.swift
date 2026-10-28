import Foundation
import PDFKit

// v0.7 (CONTRACT §17.1): plain text of the office formats Claude's Read can't open, so a saved attachment (or an
// imported file) can be learned from. Word/RTF/ODT through `textutil`; spreadsheets as CSV per sheet; presentations
// as the text of each slide (the OOXML is a zip: read with `unzip`); Pages/Numbers/Keynote through the PDF preview
// they carry, when they carry one. PDFs, images, CSV and plain text need nothing: Claude reads them directly.

public enum DocumentText {
    /// Extensions whose text is extracted next to the original (`<name>.txt`).
    public static let convertible: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "wordml", "xlsx", "xlsm", "pptx",
                                                  "pages", "numbers", "key"]

    /// Whether `name` needs a `<name>.txt` next to it for Claude to read it.
    public static func needsSidecar(_ name: String) -> Bool {
        convertible.contains((name as NSString).pathExtension.lowercased())
    }

    /// The sidecar of an original: `contrato.docx` → `contrato.docx.txt`.
    public static func sidecarURL(for file: URL) -> URL {
        file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".txt")
    }

    /// Whether `name` is the sidecar of a file in the same folder (`x.docx.txt` next to `x.docx`), for listings that
    /// must not show it as a file of its own.
    public static func isSidecar(_ name: String) -> Bool {
        guard name.lowercased().hasSuffix(".txt") else { return false }
        let original = String(name.dropLast(4))
        return needsSidecar(original)
    }

    /// The text of `file`, or nil when it has none we can get. Never throws; slow formats run a short subprocess.
    public static func extract(_ file: URL) -> String? {
        let ext = file.pathExtension.lowercased()
        let text: String?
        switch ext {
        case "doc", "docx", "rtf", "rtfd", "odt", "wordml": text = textutil(file)
        case "xlsx", "xlsm": text = spreadsheet(file)
        case "pptx": text = presentation(file)
        case "pages", "numbers", "key": text = iWorkPreview(file)
        default: text = nil
        }
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Writes `<name>.txt` next to `file` when it is convertible and has text. Returns the sidecar, or nil.
    @discardableResult
    public static func writeSidecar(for file: URL) -> URL? {
        guard needsSidecar(file.lastPathComponent), let text = extract(file) else { return nil }
        let url = sidecarURL(for: file)
        do {
            try (text + "\n").write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            Log.error("document text: could not write \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    // MARK: Word & co.

    static func textutil(_ file: URL) -> String? {
        guard let data = run("/usr/bin/textutil", ["-convert", "txt", "-stdout", file.path]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Spreadsheets (xlsx → CSV per sheet)

    static func spreadsheet(_ file: URL) -> String? {
        let entries = zipEntries(file)
        guard !entries.isEmpty else { return nil }
        let shared = zipEntry(file, "xl/sharedStrings.xml").map(SharedStringsParser.parse) ?? []
        // Sheet names and their files, in workbook order (workbook.xml + its rels).
        var sheets: [(name: String, path: String)] = []
        if let workbook = zipEntry(file, "xl/workbook.xml").flatMap({ String(data: $0, encoding: .utf8) }) {
            let rels = zipEntry(file, "xl/_rels/workbook.xml.rels").flatMap { String(data: $0, encoding: .utf8) } ?? ""
            var targets: [String: String] = [:]
            for m in rels.matches(of: #/<Relationship\b[^>]*>/#) {
                let tag = String(m.output)
                if let id = attribute("Id", in: tag), let target = attribute("Target", in: tag) {
                    targets[id] = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                }
            }
            for m in workbook.matches(of: #/<sheet\b[^>]*>/#) {
                let tag = String(m.output)
                guard let name = attribute("name", in: tag) else { continue }
                let rid = attribute("r:id", in: tag) ?? ""
                if let path = targets[rid] { sheets.append((xmlUnescape(name), path)) }
            }
        }
        if sheets.isEmpty {
            sheets = entries.filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted { naturalNumber($0) < naturalNumber($1) }
                .map { ((($0 as NSString).lastPathComponent as NSString).deletingPathExtension, $0) }
        }
        var out: [String] = []
        for sheet in sheets {
            guard let data = zipEntry(file, sheet.path) else { continue }
            let rows = SheetParser.parse(data, shared: shared)
            guard !rows.isEmpty else { continue }
            out.append("## \(sheet.name)\n\n" + rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\n"))
        }
        return out.isEmpty ? nil : out.joined(separator: "\n\n")
    }

    static func csvField(_ s: String) -> String {
        guard s.contains(",") || s.contains("\"") || s.contains("\n") else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// "B12" → 1 (0-based column of a cell reference).
    static func columnIndex(_ ref: String) -> Int? {
        var n = 0
        var any = false
        for ch in ref.uppercased() {
            guard let a = ch.asciiValue, a >= 65, a <= 90 else { break }
            n = n * 26 + Int(a - 64)
            any = true
        }
        return any ? n - 1 : nil
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inItem = false, inText = false

        static func parse(_ data: Data) -> [String] {
            let p = SharedStringsParser()
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            return p.strings
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch local(name) {
            case "si": inItem = true; current = ""
            case "t": inText = inItem
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "si": strings.append(current); inItem = false
            case "t": inText = false
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var rows: [[String]] = []
        private var row: [Int: String] = [:]
        private var cellRef = "", cellType = "", value = ""
        private var inValue = false, inInline = false
        private var nextColumn = 0

        init(shared: [String]) { self.shared = shared }

        static func parse(_ data: Data, shared: [String]) -> [[String]] {
            let p = SheetParser(shared: shared)
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            // Trailing empty rows go.
            while let last = p.rows.last, last.allSatisfy({ $0.isEmpty }) { p.rows.removeLast() }
            return p.rows
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch local(name) {
            case "row": row = [:]; nextColumn = 0
            case "c":
                cellRef = attributes["r"] ?? ""
                cellType = attributes["t"] ?? ""
                value = ""
            case "v": inValue = true
            case "is": inInline = true
            case "t": if inInline { inValue = true }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch local(name) {
            case "v", "t": inValue = false
            case "is": inInline = false
            case "c":
                var text = value
                if cellType == "s", let i = Int(value.trimmingCharacters(in: .whitespaces)), shared.indices.contains(i) {
                    text = shared[i]
                } else if cellType == "b" {
                    text = value == "1" ? "TRUE" : "FALSE"
                }
                let col = DocumentText.columnIndex(cellRef) ?? nextColumn
                row[col] = text
                nextColumn = col + 1
            case "row":
                let width = (row.keys.max() ?? -1) + 1
                rows.append((0..<width).map { row[$0] ?? "" })
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inValue { value += string } }
    }

    // MARK: Presentations (pptx → text per slide)

    static func presentation(_ file: URL) -> String? {
        let entries = zipEntries(file)
        let slides = entries.filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { naturalNumber($0) < naturalNumber($1) }
        guard !slides.isEmpty else { return nil }
        var out: [String] = []
        for (i, path) in slides.enumerated() {
            guard let data = zipEntry(file, path) else { continue }
            var block = "## \(i + 1)\n\n" + ParagraphParser.parse(data).joined(separator: "\n")
            let number = naturalNumber(path)
            if let notes = zipEntry(file, "ppt/notesSlides/notesSlide\(number).xml") {
                // Speaker notes, minus the slide-number placeholder they repeat.
                let lines = ParagraphParser.parse(notes).filter { Int($0) == nil }
                if !lines.isEmpty { block += "\n\n> " + lines.joined(separator: "\n> ") }
            }
            out.append(block)
        }
        return out.joined(separator: "\n\n")
    }

    /// `<a:p>` paragraphs made of their `<a:t>` runs (non-empty ones).
    private final class ParagraphParser: NSObject, XMLParserDelegate {
        var paragraphs: [String] = []
        private var current = ""
        private var inText = false

        static func parse(_ data: Data) -> [String] {
            let p = ParagraphParser()
            let parser = XMLParser(data: data)
            parser.delegate = p
            parser.parse()
            return p.paragraphs
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            switch qualifiedName ?? name {
            case "a:p": current = ""
            case "a:t": inText = true
            case "a:br": current += " "
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch qualifiedName ?? name {
            case "a:t": inText = false
            case "a:p":
                let t = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { paragraphs.append(t) }
            default: break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { if inText { current += string } }
    }

    // MARK: iWork (the PDF preview inside, when there is one)

    static func iWorkPreview(_ file: URL) -> String? {
        let fm = FileManager.default
        var pdfData: Data?
        if fm.isDirectory(file) {   // an old package format
            pdfData = try? Data(contentsOf: file.appendingPathComponent("QuickLook/Preview.pdf"))
        } else {
            pdfData = zipEntry(file, "QuickLook/Preview.pdf")
        }
        guard let pdfData, let doc = PDFDocument(data: pdfData) else { return nil }
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            if let t = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { pages.append(t) }
        }
        return pages.isEmpty ? nil : pages.joined(separator: "\n\n")
    }

    // MARK: Zip & helpers

    static func zipEntries(_ file: URL) -> [String] {
        guard let data = run("/usr/bin/unzip", ["-Z1", file.path]) else { return [] }
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    static func zipEntry(_ file: URL, _ entry: String) -> Data? {
        guard let data = run("/usr/bin/unzip", ["-p", file.path, entry]), !data.isEmpty else { return nil }
        return data
    }

    /// stdout of a short-lived tool, nil when it fails or runs over 30 s.
    static func run(_ tool: String, _ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        return process.terminationStatus == 0 ? data : nil
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: " \(name)=\"") else { return nil }
        let rest = tag[r.upperBound...]
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        return String(rest[..<end])
    }

    static func xmlUnescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /// The last number in a path ("ppt/slides/slide12.xml" → 12).
    static func naturalNumber(_ path: String) -> Int {
        let digits = (path as NSString).lastPathComponent.filter(\.isNumber)
        return Int(digits) ?? 0
    }
}

/// Element name without its namespace prefix.
private func local(_ name: String) -> String {
    name.split(separator: ":").last.map(String.init) ?? name
}
