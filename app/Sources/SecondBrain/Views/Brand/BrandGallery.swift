import AppKit
import SwiftUI

/// Development only: every brand token and component on one page. Rendered to `brand-light.png` / `brand-dark.png`
/// when `SB_SNAPSHOT_DIR` is set and `SB_SNAPSHOT_ONLY=brand` (same harness as `DebugSnapshots`).
struct BrandGallery: View {
    private let swatches: [(String, Color)] = [
        ("bg", Brand.color.bg), ("surface", Brand.color.surface), ("card", Brand.color.card),
        ("cardAlt", Brand.color.cardAlt), ("line", Brand.color.line), ("text", Brand.color.text),
        ("text2", Brand.color.text2), ("text3", Brand.color.text3), ("accent", Brand.color.accent),
        ("onAccent", Brand.color.onAccent), ("accentSoft", Brand.color.accentSoft), ("sage", Brand.color.sage),
        ("record", Brand.color.record), ("recordSoft", Brand.color.recordSoft), ("warning", Brand.color.warning),
        ("warningSoft", Brand.color.warningSoft), ("danger", Brand.color.danger), ("success", Brand.color.success),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 24) {
                BrandLogo()
                BrandLogo(size: 32)
                BrandLoader(size: 24, text: "Transcribiendo… 42 %")
                BrandRecordingDot()
                Image(nsImage: BrandMenuBarIcon.idle)
                Image(nsImage: BrandMenuBarIcon.recording)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Título de página 20").font(Brand.title)
                Text("Sección 15 semibold").font(Brand.section)
                Text("Cuerpo 13 — Solo leo. Nunca envío, borro ni cambio nada.")
                Text("Callout 13 medium").font(Brand.callout)
                Text("Caption 11 · hace 3 min").font(Brand.caption).foregroundStyle(Brand.color.text2)
                Text("~/Documents/SecondBrain").font(Brand.mono).foregroundStyle(Brand.color.text2)
            }
            HStack(spacing: 8) {
                Button("Grabar") {}.buttonStyle(.brandRecord)
                Button("Guardar en Kickoff") {}.buttonStyle(.brandPrimary)
                Button("Cancelar") {}.buttonStyle(.brandSecondary)
                Button("Grande") {}.buttonStyle(.brandPrimary).controlSize(.large)
                Button("Desactivado") {}.buttonStyle(.brandPrimary).disabled(true)
            }
            HStack(spacing: 6) {
                BrandChip(text: "Reunión · 26 oct", symbol: "calendar")
                BrandChip(text: "Kickoff", symbol: "circle.fill", tint: Brand.projectColor(slug: "kickoff"))
                BrandChip(text: "Activo", active: true)
                ForEach(Brand.projectPalette.indices, id: \.self) { i in
                    Circle().fill(Brand.projectPalette[i]).frame(width: 14, height: 14)
                }
            }
            BrandCard {
                VStack(alignment: .leading, spacing: 8) {
                    BrandSectionHeader(title: "Por ordenar", count: 3) {
                        Button("Ver todo →") {}.buttonStyle(.borderless)
                    }
                    Text("Una tarjeta: card, borde line 1 px, radio 12.").foregroundStyle(Brand.color.text2)
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 6) {
                ForEach(swatches, id: \.0) { name, color in
                    VStack(spacing: 2) {
                        RoundedRectangle(cornerRadius: Brand.radius.control).fill(color)
                            .overlay(RoundedRectangle(cornerRadius: Brand.radius.control).strokeBorder(Brand.color.line))
                            .frame(height: 26)
                        Text(name).font(Brand.caption).foregroundStyle(Brand.color.text2)
                    }
                }
            }
            HStack {
                EmptyStateView(symbol: "brand", title: "Tu conocimiento, en un lugar.", message: "Mensaje en text2.")
                    .frame(height: 170)
            }
        }
        .padding(Brand.spacing.content)
        .frame(width: 760, alignment: .topLeading)
        .background(Brand.color.surface)
        .foregroundStyle(Brand.color.text)
        .brandEnvironment()
    }

    @MainActor static func renderIfRequested() {
        guard let dir = DebugSnapshots.directory, ProcessInfo.processInfo.environment["SB_SNAPSHOT_ONLY"] == "brand"
        else { return }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for dark in [false, true] {
            let host = NSHostingView(rootView: BrandGallery())
            host.frame = CGRect(origin: .zero, size: host.fittingSize)
            let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: host.fittingSize),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: dir.appendingPathComponent("brand-\(dark ? "dark" : "light").png"))
            window.contentView = nil
        }
    }
}
