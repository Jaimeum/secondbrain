import BrainCore
import Foundation

/// v0.7 (§17.8): the demo vault's "Contrato con Acme" becomes a long thread from a connected account — four emails,
/// one of them the owner's reply ("Tú") — with each message's `external_id`/`web_link` and a `_thread.json` carrying
/// the provider's conversation id, so the conversation view, "Abrir en Outlook" and thread following have something
/// real to show. Runs after `DemoFiles.add`; a vault without that thread is left as is.
enum DemoThreads {
    static let account = "microsoft:jaime.ruiz@ejemplo.com"
    static let conversationId = "demo-conv-contrato-acme"

    static func enrich(root: URL) throws {
        let fm = FileManager.default
        let rel = "projects/lanzamiento-atlas/raw/emails/contrato-con-acme"
        let folder = root.appendingPathComponent(rel)
        let existing = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        guard existing.count >= 2, !fm.fileExists(atPath: folder.appendingPathComponent("_thread.json").path) else { return }

        func field(_ name: String, _ text: String) -> String? {
            text.components(separatedBy: "\n").first { $0.hasPrefix(name + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
                .map { $0.hasPrefix("\"") && $0.hasSuffix("\"") && $0.count >= 2 ? String($0.dropFirst().dropLast()) : $0 }
        }
        func address(_ raw: String) -> [String: String] {
            guard let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">") else { return ["email": raw] }
            return ["name": raw[..<open].trimmingCharacters(in: .whitespaces),
                    "email": String(raw[raw.index(after: open)..<close])]
        }
        let iso = ISO8601DateFormatter()
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyy-MM-dd-HHmm"

        // The last saved message's date: the two new ones follow it.
        let lastText = try String(contentsOf: folder.appendingPathComponent(existing.last!), encoding: .utf8)
        let last = field("date", lastText).flatMap { SBDate.parseISO($0)?.date } ?? Date().addingTimeInterval(-70 * 86_400)
        let ana = "Ana García <ana.garcia@ejemplo.com>", jaime = "Jaime Ruiz <jaime.ruiz@ejemplo.com>"
        let d3 = last.addingTimeInterval(20 * 3600), d4 = d3.addingTimeInterval(25 * 3600)
        let added: [(file: String, from: String, to: String, date: Date, text: String)] = [
            ("\(stamp.string(from: d3))-jaime-ruiz.md", jaime, ana, d3,
             "Ana, gracias. Lo revisé con Elena: estamos de acuerdo con la cláusula de penalización si bajamos el tope al 5 %.\n\nTe confirmo el viernes con la firma del director.\n\nJaime\n\n## Historial citado\n\n> Gracias, lo reviso y te confirmo."),
            ("\(stamp.string(from: d4))-ana-garcia.md", ana, jaime, d4,
             "Perfecto, Jaime. Ajusté el tope al 5 % en la versión 3 del contrato.\n\nQuedan abiertos:\n- Fecha de inicio del servicio (proponemos el 1 de septiembre).\n- Quién firma por parte de ustedes.\n- Facturación mensual o trimestral.\n\nSi te parece, lo cerramos en la llamada del jueves.\n\nSaludos,\nAna\n\n## Historial citado\n\n> Ana, gracias. Lo revisé con Elena…"),
        ]
        for m in added {
            let text = "---\ntype: email\nsubject: \"Re: Contrato con Acme\"\nfrom: \"\(m.from)\"\nto: [\"\(m.to)\"]\ndate: \(SBDate.iso(m.date))\n---\n\n\(m.text)\n"
            try text.write(to: folder.appendingPathComponent(m.file), atomically: true, encoding: .utf8)
        }

        // Every message gets its provider id and link (raw front matter and `_thread.json`).
        var messages: [[String: Any]] = []
        var participants: [[String: String]] = []
        for (i, file) in (existing + added.map(\.file)).enumerated() {
            let url = folder.appendingPathComponent(file)
            var text = try String(contentsOf: url, encoding: .utf8)
            let id = "demo-acme-\(i + 1)"
            let link = "https://outlook.office.com/mail/inbox/id/\(id)"
            if !text.contains("\nexternal_id:"), let end = text.range(of: "\n---\n", range: text.index(text.startIndex, offsetBy: 3)..<text.endIndex) {
                text.insert(contentsOf: "\nexternal_id: \"microsoft:\(id)\"\nweb_link: \"\(link)\"", at: end.lowerBound)
                try text.write(to: url, atomically: true, encoding: .utf8)
            }
            let from = field("from", text).map(address) ?? [:]
            if !participants.contains(where: { $0["email"] == from["email"] }) { participants.append(from) }
            var m: [String: Any] = ["file": file, "from": from, "externalId": "microsoft:\(id)", "webLink": link,
                                    "isFromOwner": from["email"] == "jaime.ruiz@ejemplo.com"]
            if let d = field("date", text).flatMap({ SBDate.parseISO($0)?.date }) { m["date"] = iso.string(from: d) }
            messages.append(m)
        }
        let meta: [String: Any] = ["key": "contrato-con-acme", "subject": "Contrato con Acme", "participants": participants,
                                   "messages": messages, "createdAt": iso.string(from: Date()),
                                   "providerThreadIds": [account: conversationId]]
        let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: folder.appendingPathComponent("_thread.json"))

        // The thread page counts the four emails, ends on the last one and lists them in its chronology.
        let page = root.appendingPathComponent("projects/lanzamiento-atlas/wiki/emails/contrato-con-acme.md")
        if var text = try? String(contentsOf: page, encoding: .utf8) {
            let ymd = DateFormatter()
            ymd.locale = Locale(identifier: "en_US_POSIX")
            ymd.dateFormat = "yyyy-MM-dd"
            let hm = DateFormatter()
            hm.locale = Locale(identifier: "en_US_POSIX")
            hm.dateFormat = "yyyy-MM-dd HH:mm"
            text = text.replacingOccurrences(of: "\nmessages: 2\n", with: "\nmessages: 4\n")
                .replacingOccurrences(of: "· 2 correos ·", with: "· 4 correos ·")
                .replacingOccurrences(of: " al \(ymd.string(from: last)) ·", with: " al \(ymd.string(from: d4)) ·")
                .replacingOccurrences(of: "\nlast_message: \"\(SBDate.iso(last))\"", with: "\nlast_message: \"\(SBDate.iso(d4))\"")
                .replacingOccurrences(of: "\nupdated: \(ymd.string(from: last))\n", with: "\nupdated: \(ymd.string(from: d4))\n")
            let stems = added.map { ($0.file as NSString).deletingPathExtension }
            let lines = [
                "- **\(hm.string(from: d3))** · [[people/jaime-ruiz|Jaime Ruiz]] (tú) → [[people/ana-garcia|Ana García]]: acepta la penalización con tope al 5 % y promete confirmar el viernes con la firma del director ([[\(stems[0])]])",
                "- **\(hm.string(from: d4))** · [[people/ana-garcia|Ana García]] → [[people/jaime-ruiz|Jaime Ruiz]]: versión 3 con el tope al 5 %; quedan abiertos inicio, firmante y facturación ([[\(stems[1])]])",
            ]
            if let range = text.range(of: "\n## Cronología\n") {
                // After the last line of the chronology (the first blank line after its heading).
                let after = text[range.upperBound...]
                if let end = after.range(of: "\n\n") {
                    text.insert(contentsOf: "\n" + lines.joined(separator: "\n"), at: end.lowerBound)
                }
            }
            try text.write(to: page, atomically: true, encoding: .utf8)
        }
    }

    /// The other demo threads (two emails each, as if pasted: no provider ids) get their `_thread.json` too, so they are
    /// one row with their count in Inicio and Contenido and their ficha shows the conversation.
    static func describeOthers(root: URL) throws {
        let fm = FileManager.default
        let iso = ISO8601DateFormatter()
        let projects = root.appendingPathComponent("projects")
        for project in (try? fm.contentsOfDirectory(atPath: projects.path)) ?? [] {
            let emails = projects.appendingPathComponent(project).appendingPathComponent("raw/emails")
            for thread in (try? fm.contentsOfDirectory(atPath: emails.path)) ?? [] where !thread.hasPrefix(".") {
                let folder = emails.appendingPathComponent(thread)
                guard !fm.fileExists(atPath: folder.appendingPathComponent("_thread.json").path) else { continue }
                let files = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
                guard !files.isEmpty else { continue }
                var messages: [[String: Any]] = []
                var participants: [[String: String]] = []
                var subject = ""
                for file in files {
                    let text = try String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)
                    func field(_ name: String) -> String? {
                        text.components(separatedBy: "\n").first { $0.hasPrefix(name + ":") }
                            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: CharacterSet(charactersIn: " \"[]")) }
                    }
                    var from: [String: String] = [:]
                    for raw in [field("from"), field("to")].compactMap({ $0 }) {
                        guard let open = raw.firstIndex(of: "<"), let close = raw.firstIndex(of: ">") else { continue }
                        let a = ["name": raw[..<open].trimmingCharacters(in: .whitespaces), "email": String(raw[raw.index(after: open)..<close])]
                        if from.isEmpty, raw == field("from") { from = a }
                        if !participants.contains(where: { $0["email"] == a["email"] }) { participants.append(a) }
                    }
                    if subject.isEmpty, let s = field("subject") { subject = s.replacingOccurrences(of: "Re: ", with: "") }
                    var m: [String: Any] = ["file": file, "from": from, "isFromOwner": from["email"] == "jaime.ruiz@ejemplo.com"]
                    if let d = field("date").flatMap({ SBDate.parseISO($0)?.date }) { m["date"] = iso.string(from: d) }
                    messages.append(m)
                }
                let meta: [String: Any] = ["key": thread, "subject": subject, "participants": participants, "messages": messages,
                                           "createdAt": iso.string(from: Date())]
                let data = try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
                try data.write(to: folder.appendingPathComponent("_thread.json"))
            }
        }
    }
}
