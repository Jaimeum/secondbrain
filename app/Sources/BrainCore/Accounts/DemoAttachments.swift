import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// v0.7 (CONTRACT §17.1): synthetic attachments of the demo mailbox (`DemoProvider`), real files so the whole path
// (triage → download → save → Archivos) can be seen in snapshots and exercised by `sb attachments selftest`:
// a contract PDF, a 4 KB logo PNG shown inline by the body (a signature), a whiteboard photo, a budget CSV, a quote
// PDF with the studio's logo, and holiday photos with a calendar invitation.

enum DemoAttachments {
    struct Spec {
        enum Content { case pdf(title: String, lines: [String]), logo(seed: UInt32), photo(seed: UInt32), text(String) }
        var id: String
        var name: String
        var mime: String
        var inlineCid: String?
        var content: Content
    }

    /// The attachments of a demo message (empty for most).
    static func specs(messageId: String, lang: Lang) -> [Spec] {
        let l = lang
        switch messageId {
        case "demo-m01":
            return [
                Spec(id: "a1", name: l.t("Propuesta-logistica-Q4.pdf", "Q4-logistics-proposal.pdf"), mime: "application/pdf", inlineCid: nil,
                     content: .pdf(title: l.t("Propuesta de logística Q4 — Acme Logistics", "Q4 logistics proposal — Acme Logistics"),
                                   lines: l.en ? proposalEN : proposalES)),
                Spec(id: "a2", name: "image001.png", mime: "image/png", inlineCid: "image001.png@01db2a7f", content: .logo(seed: 7)),
            ]
        case "demo-m06":
            return [Spec(id: "a1", name: l.t("presupuesto-2027-v1.csv", "budget-2027-v1.csv"), mime: "text/csv", inlineCid: nil,
                         content: .text(l.en ? budgetEN : budgetES))]
        case "demo-m09":
            return [
                Spec(id: "a1", name: l.t("Cotizacion-Estudio-Norte.pdf", "Estudio-Norte-quote.pdf"), mime: "application/pdf", inlineCid: nil,
                     content: .pdf(title: l.t("Cotización — Rediseño app de clientes", "Quote — Customer app redesign"),
                                   lines: l.en ? quoteEN : quoteES)),
                Spec(id: "a2", name: "logo-estudio-norte.png", mime: "image/png", inlineCid: nil, content: .logo(seed: 11)),
            ]
        case "demo-m11":
            return [
                Spec(id: "a1", name: l.t("Contrato-Acme-Logistics-2026.pdf", "Acme-Logistics-contract-2026.pdf"), mime: "application/pdf",
                     inlineCid: nil, content: .pdf(title: l.t("Contrato de servicios logísticos", "Logistics services agreement"),
                                                   lines: l.en ? contractEN : contractES)),
                Spec(id: "a2", name: "image001.png", mime: "image/png", inlineCid: "image001.png@01db2b10", content: .logo(seed: 3)),
                Spec(id: "a3", name: l.t("pizarron-visita-almacen.jpg", "warehouse-visit-whiteboard.jpg"), mime: "image/jpeg",
                     inlineCid: nil, content: .photo(seed: 42)),
            ]
        case "demo-g3":
            return [
                Spec(id: "a1", name: l.t("mercado-oaxaca.jpg", "oaxaca-market.jpg"), mime: "image/jpeg", inlineCid: nil, content: .photo(seed: 5)),
                Spec(id: "a2", name: "invite.ics", mime: "text/calendar", inlineCid: nil,
                     content: .text("BEGIN:VCALENDAR\nVERSION:2.0\nBEGIN:VEVENT\nSUMMARY:Oaxaca\nDTSTART:20261020T180000Z\nEND:VEVENT\nEND:VCALENDAR\n")),
            ]
        default:
            return []
        }
    }

    static func list(messageId: String, lang: Lang) -> [AttachmentInfo] {
        specs(messageId: messageId, lang: lang).map { s in
            AttachmentInfo(id: s.id, name: s.name, mimeType: s.mime, size: data(s).count, isInline: s.inlineCid != nil,
                           contentId: s.inlineCid)
        }
    }

    static func download(messageId: String, id: String, lang: Lang) -> Data? {
        specs(messageId: messageId, lang: lang).first { $0.id == id }.map(data)
    }

    /// The `cid:` ids the demo message's HTML body would reference.
    static func inlineContentIds(messageId: String, lang: Lang) -> [String]? {
        let ids = specs(messageId: messageId, lang: lang).compactMap(\.inlineCid)
        return ids.isEmpty ? nil : ids
    }

    // MARK: Bytes (generated once per spec, deterministic)

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    static func data(_ spec: Spec) -> Data {
        let key = "\(spec.name)|\(spec.id)"
        lock.lock()
        if let d = cache[key] { lock.unlock(); return d }
        lock.unlock()
        let d: Data
        switch spec.content {
        case .pdf(let title, let lines): d = pdf(title: title, lines: lines)
        case .logo(let seed): d = image(width: 40, height: 40, seed: seed, noise: 1.0, type: .png)
        case .photo(let seed): d = image(width: 900, height: 640, seed: seed, noise: 0.35, type: .jpeg)
        case .text(let s): d = Data(s.utf8)
        }
        lock.lock(); cache[key] = d; lock.unlock()
        return d
    }

    private static func pdf(title: String, lines: [String]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        ctx.beginPDFPage(nil)
        func draw(_ text: String, size: CGFloat, y: CGFloat, bold: Bool = false) {
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let attr = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            let line = CTLineCreateWithAttributedString(attr)
            ctx.textPosition = CGPoint(x: 64, y: y)
            CTLineDraw(line, ctx)
        }
        draw(title, size: 18, y: 720, bold: true)
        var y: CGFloat = 684
        for line in lines {
            draw(line, size: 11, y: y)
            y -= 20
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    private static func image(width: Int, height: Int, seed: UInt32, noise: Double, type: UTType) -> Data {
        var state = seed &* 2_654_435_761 &+ 1
        func next() -> UInt8 {
            state = state &* 1_664_525 &+ 1_013_904_223
            return UInt8(truncatingIfNeeded: state >> 24)
        }
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                // A soft gradient (a board, a market) under some grain.
                let gx = Double(x) / Double(max(1, width - 1)), gy = Double(y) / Double(max(1, height - 1))
                let base: (Double, Double, Double) = (40 + 180 * gx, 90 + 120 * gy, 160 + 60 * (1 - gx))
                func channel(_ v: Double) -> UInt8 {
                    let n = (Double(next()) - 128) * noise
                    return UInt8(max(0, min(255, v + n)))
                }
                pixels[i] = channel(base.0)
                pixels[i + 1] = channel(base.1)
                pixels[i + 2] = channel(base.2)
                pixels[i + 3] = 255
            }
        }
        let space = CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return Data() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil) else { return Data() }
        let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.8] : [:]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        CGImageDestinationFinalize(dest)
        return out as Data
    }

    // MARK: Texts

    static let contractES = [
        "Entre Acme Logistics S.A. de C.V. (\"el Proveedor\") y Contoso (\"el Cliente\").",
        "1. Rutas: Monterrey, Querétaro y Puebla.",
        "2. Puebla: dos entregas por semana, volumen mínimo de 40 cajas por envío.",
        "3. Tarifa: se mantiene la tarifa vigente hasta el 31 de marzo de 2027",
        "   si el contrato se firma antes del 15 de noviembre.",
        "4. Vigencia: 12 meses a partir de la firma.",
        "5. Penalización por cancelación con menos de 30 días: 10% del mes en curso.",
        "Firmas: Sofía Herrera (Acme Logistics) · Ana García (Contoso)",
    ]
    static let contractEN = [
        "Between Acme Logistics Inc. (\"the Provider\") and Contoso (\"the Client\").",
        "1. Routes: Monterrey, Querétaro and Puebla.",
        "2. Puebla: two deliveries per week, 40-box minimum per shipment.",
        "3. Rate: the current rate holds until March 31, 2027",
        "   if the agreement is signed before November 15.",
        "4. Term: 12 months from signature.",
        "5. Cancellation with less than 30 days' notice: 10% of the current month.",
        "Signatures: Sofía Herrera (Acme Logistics) · Ana García (Contoso)",
    ]
    static let proposalES = [
        "Rutas nuevas: Monterrey, Querétaro y Puebla (una entrega semanal).",
        "Ajuste de tarifa: +4% a partir de abril.",
        "Si se confirma antes del 15 de noviembre, la tarifa actual se mantiene hasta marzo.",
    ]
    static let proposalEN = [
        "New routes: Monterrey, Querétaro and Puebla (one weekly delivery).",
        "Rate adjustment: +4% starting in April.",
        "If confirmed before November 15, the current rate holds until March.",
    ]
    static let quoteES = [
        "Alcance: rediseño de la app de clientes (pedidos, seguimiento, facturas).",
        "Duración: 6 semanas, dos rondas de cambios incluidas.",
        "Inicio propuesto: 3 de noviembre. Entrega antes de vacaciones.",
        "Total: $480,000 MXN + IVA, 50% al arrancar y 50% a la entrega.",
    ]
    static let quoteEN = [
        "Scope: customer app redesign (orders, tracking, invoices).",
        "Length: 6 weeks, two rounds of changes included.",
        "Proposed start: November 3. Delivery before the holidays.",
        "Total: MXN 480,000 + VAT, 50% at kickoff and 50% on delivery.",
    ]
    static let budgetES = "Área,2026,2027,Cambio\nTecnología,1200000,1296000,+8%\nEventos,400000,380000,-5%\nOperaciones,2100000,2150000,+2%\n"
    static let budgetEN = "Area,2026,2027,Change\nTechnology,1200000,1296000,+8%\nEvents,400000,380000,-5%\nOperations,2100000,2150000,+2%\n"
}
