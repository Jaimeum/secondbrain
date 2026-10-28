import AppKit
import BrainCore
import Foundation

// v0.7 (CONTRACT §17.2): real files for the demo vault, so Archivos, the fichas and ⌘K have something to show — saved
// email attachments (a signed contract PDF, a price annex, a beta results sheet, a quote), a photo dropped with
// "Agregar al proyecto" and an uploaded PDF, each with the summary page Claude would have written.
enum DemoFiles {
    /// Adds the files to a vault made by `DemoVault.create` (missing threads or projects are skipped). Returns how many.
    @discardableResult
    static func add(root: URL) throws -> Int {
        let fm = FileManager.default
        var count = 0
        func firstMessage(_ thread: String) -> (stem: String, date: Date)? {
            let names = ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(thread).path)) ?? [])
                .filter { $0.hasSuffix(".md") }.sorted()
            guard let first = names.first else { return nil }
            let stem = (first as NSString).deletingPathExtension
            return FileIndex.stampDate(stem).map { (stem, $0) }
        }
        func attach(_ thread: String, name: String, data: Data, summary: (title: String, text: String, people: [String])?) throws {
            guard let message = firstMessage(thread) else { return }
            let rel = "\(thread)/attachments/\(message.stem)/\(name)"
            let url = root.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            count += 1
            guard let summary, let slug = Scope.projectSlug(ofPath: thread) else { return }
            let key = DemoVault.fmt(message.date, "yyyy-MM-dd") + "-" + slugify((name as NSString).deletingPathExtension, maxLength: 30)
            try page(slug: slug, key: key, title: summary.title, date: message.date, source: rel, text: summary.text, people: summary.people)
        }
        func page(slug: String, key: String, title: String, date: Date, source: String, text: String, people: [String]) throws {
            let peopleList = "[" + people.map { "\"[[\($0)]]\"" }.joined(separator: ", ") + "]"
            let body = """
                ---
                type: source
                source_type: document
                title: "\(title)"
                project: \(slug)
                date: \(DemoVault.fmt(date, "yyyy-MM-dd"))
                language: es
                sources: ["\(source)"]
                people: \(peopleList)
                status: processed
                ---

                # \(title)

                > **En breve:** \(text)

                ## Fuente
                [[\(source)|Archivo original]]
                """
            try DemoVault.write(root, "projects/\(slug)/wiki/sources/\(key).md", body + "\n")
        }

        let atlas = "projects/lanzamiento-atlas"
        let cloud = "projects/migracion-a-la-nube"
        let nubia = "projects/alianza-banco-nubia"
        if fm.fileExists(atPath: root.appendingPathComponent("\(atlas)/raw/emails/contrato-con-acme").path) {
            try attach("\(atlas)/raw/emails/contrato-con-acme", name: "Contrato Atlas firmado.pdf",
                       data: pdf(title: "Contrato de servicios — Atlas", lines: [
                           "Entre Acme S.A. y Dive.", "Vigencia: 12 meses a partir de la firma.",
                           "Pagos: tres, ligados a los hitos del plan de lanzamiento.",
                           "Penalización por retraso: 2 % por semana, tope 10 %."]),
                       summary: ("Contrato de servicios Atlas (firmado)",
                                 "Contrato anual firmado por Acme y Dive: tres pagos por hito y una penalización de 2 % por semana de retraso, con tope de 10 %.",
                                 ["ana-garcia", "elena-castro"]))
            try attach("\(atlas)/raw/emails/contrato-con-acme", name: "Anexo de precios.csv",
                       data: Data("Concepto,Monto\nDiseño,120000\nDesarrollo,380000\nLanzamiento,90000\n".utf8), summary: nil)
        }
        if fm.fileExists(atPath: root.appendingPathComponent("\(atlas)/raw/emails/resultados-de-la-beta-cerrada").path) {
            try attach("\(atlas)/raw/emails/resultados-de-la-beta-cerrada", name: "Resultados beta.csv",
                       data: Data("Métrica,Valor\nUsuarios,240\nRetención 7 días,61 %\nNPS,42\n".utf8),
                       summary: ("Resultados de la beta cerrada (hoja)",
                                 "240 usuarios en la beta, 61 % de retención a 7 días y NPS de 42; el onboarding es el paso con más abandono.",
                                 ["sofia-mendez"]))
            try attach("\(atlas)/raw/emails/resultados-de-la-beta-cerrada", name: "Captura onboarding.png",
                       data: png(width: 900, height: 560, hue: 0.33, label: "Onboarding · paso 2"), summary: nil)
        }
        if fm.fileExists(atPath: root.appendingPathComponent("\(cloud)/raw/emails/cotizacion-del-proveedor-de-nube").path) {
            try attach("\(cloud)/raw/emails/cotizacion-del-proveedor-de-nube", name: "Cotización 2027.pdf",
                       data: pdf(title: "Cotización de servicios de nube 2027", lines: [
                           "Cómputo reservado: 3 años.", "Almacenamiento: 40 TB.", "Soporte empresarial incluido."]),
                       summary: ("Cotización del proveedor de nube 2027",
                                 "Propuesta a 3 años con cómputo reservado y 40 TB de almacenamiento; incluye soporte empresarial.",
                                 ["carlos-vega"]))
        }
        if fm.fileExists(atPath: root.appendingPathComponent("\(nubia)/raw/emails/borrador-del-convenio-con-nubia").path) {
            try attach("\(nubia)/raw/emails/borrador-del-convenio-con-nubia", name: "Convenio Nubia borrador 3.docx",
                       data: Data(repeating: 0x50, count: 38_000), summary: nil)
        }

        // "Agregar al proyecto": a photo of the whiteboard after a visit (raw/assets, with its wrapper and its page).
        if fm.fileExists(atPath: root.appendingPathComponent(atlas).path) {
            let date = Calendar.current.date(byAdding: .day, value: -2, to: Calendar.current.startOfDay(for: Date()))!
                .addingTimeInterval(13 * 3600)
            let stem = DemoVault.fmt(date, "yyyy-MM-dd") + "-pizarron-visita-acme"
            try fm.createDirectory(at: root.appendingPathComponent("\(atlas)/raw/assets"), withIntermediateDirectories: true)
            try png(width: 1200, height: 800, hue: 0.08, label: "Pizarrón · visita a Acme")
                .write(to: root.appendingPathComponent("\(atlas)/raw/assets/\(stem).png"))
            try DemoVault.write(root, "\(atlas)/raw/assets/\(stem).md", """
                ---
                type: image
                source_id: demo-pizarron
                title: "Pizarrón de la visita a Acme"
                project: lanzamiento-atlas
                via: dump
                date: \(SBDate.iso(date))
                added: \(SBDate.iso(date))
                original_file: \(stem).png
                ---

                _(Contenido en el archivo original: `\(stem).png`.)_

                """)
            try page(slug: "lanzamiento-atlas", key: stem, title: "Pizarrón de la visita a Acme", date: date,
                     source: "\(atlas)/raw/assets/\(stem).md",
                     text: "Foto del pizarrón tras la visita: el flujo de pagos queda en dos pasos y Acme pide la demo en su oficina.",
                     people: ["ana-garcia", "luis-torres"])
            count += 1
        }
        // An uploaded PDF (raw/docs with its wrapper).
        if fm.fileExists(atPath: root.appendingPathComponent(cloud).path) {
            let date = Calendar.current.date(byAdding: .day, value: -9, to: Calendar.current.startOfDay(for: Date()))!
                .addingTimeInterval(10 * 3600)
            let stem = DemoVault.fmt(date, "yyyy-MM-dd") + "-runbook-de-corte"
            try fm.createDirectory(at: root.appendingPathComponent("\(cloud)/raw/docs"), withIntermediateDirectories: true)
            try pdf(title: "Runbook de corte", lines: ["1. Congelar cambios 48 h antes.", "2. Respaldo completo.",
                                                       "3. Cambiar DNS.", "4. Validar con clientes piloto."])
                .write(to: root.appendingPathComponent("\(cloud)/raw/docs/\(stem).pdf"))
            try DemoVault.write(root, "\(cloud)/raw/docs/\(stem).md", """
                ---
                type: document
                source_id: demo-runbook
                title: "Runbook de corte"
                project: migracion-a-la-nube
                date: \(SBDate.iso(date))
                added: \(SBDate.iso(date))
                original_file: \(stem).pdf
                ---

                Congelar cambios, respaldo, DNS y validación con clientes piloto.

                """)
            try page(slug: "migracion-a-la-nube", key: stem, title: "Runbook de corte", date: date,
                     source: "\(cloud)/raw/docs/\(stem).md",
                     text: "Los cuatro pasos del corte de noviembre: congelar cambios 48 h antes, respaldo completo, cambio de DNS y validación con clientes piloto.",
                     people: ["luis-torres"])
            count += 1
        }
        return count
    }

    // MARK: Generated content

    /// A one-page PDF with a title and some lines.
    static func pdf(title: String, lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
            .draw(at: CGPoint(x: 56, y: 760))
        for (i, line) in lines.enumerated() {
            NSAttributedString(string: line, attributes: [.font: NSFont.systemFont(ofSize: 13)])
                .draw(at: CGPoint(x: 56, y: 712 - CGFloat(i) * 24))
        }
        NSGraphicsContext.restoreGraphicsState()
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A PNG with a soft gradient, a few shapes and a label (stands in for a photo or a screenshot).
    static func png(width: Int, height: Int, hue: CGFloat, label: String) -> Data {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return Data() }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(starting: NSColor(hue: hue, saturation: 0.25, brightness: 0.95, alpha: 1),
                   ending: NSColor(hue: hue, saturation: 0.45, brightness: 0.7, alpha: 1))?.draw(in: rect, angle: 35)
        var rng = SeededRandom(seed: UInt64(width * 31 + height))
        for _ in 0..<14 {
            let w = CGFloat.random(in: 60...260, using: &rng), h = CGFloat.random(in: 30...120, using: &rng)
            let r = NSRect(x: CGFloat.random(in: 0...CGFloat(width) - w, using: &rng),
                           y: CGFloat.random(in: 0...CGFloat(height) - h, using: &rng), width: w, height: h)
            NSColor(white: 1, alpha: CGFloat.random(in: 0.25...0.6, using: &rng)).setFill()
            NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
        }
        NSAttributedString(string: label, attributes: [.font: NSFont.boldSystemFont(ofSize: CGFloat(height) / 12),
                                                       .foregroundColor: NSColor(white: 0.15, alpha: 0.85)])
            .draw(at: CGPoint(x: CGFloat(width) * 0.06, y: CGFloat(height) * 0.08))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
