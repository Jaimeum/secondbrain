import SwiftUI

/// The gradient symbol (never tinted). `size` is the symbol's side in points; the image is picked at 128/256/512 px.
struct BrandMark: View {
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = BrandAssets.mark(points: size) {
                Image(nsImage: image).resizable().interpolation(.high).antialiased(true)
            } else {
                Circle().fill(Brand.color.sage)   // assets missing: a calm placeholder, never a crash
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(Text(verbatim: "secondbrain"))
    }
}

/// `secondbrain` in Inter Medium, tracking −0.03 em. Always lowercase (never localized, never capitalized).
struct BrandWordmark: View {
    var size: CGFloat = 15

    var body: some View {
        Text(verbatim: "secondbrain")
            .font(Brand.font(size, .medium))
            .tracking(Brand.wordmarkTracking(size))
            .textCase(nil)
            .foregroundStyle(Brand.color.text)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Mark + wordmark side by side (sidebar header, menu bar popover). `size` = mark side; wordmark at 0.75×.
struct BrandLogo: View {
    var size: CGFloat = 20

    var body: some View {
        HStack(spacing: size * 0.4) {
            BrandMark(size: size)
            BrandWordmark(size: (size * 0.75).rounded())
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "secondbrain"))
    }
}

/// Long-running work (motion spec B): the symbol breathing in opacity 0.55 → 1 → 0.55 over 2 s (time-based, fixed
/// scale), optionally with a real status text ("Transcribiendo… 42 %"). Reduce Motion: static symbol.
struct BrandLoader: View {
    var size: CGFloat = 24
    var text: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: Brand.spacing.s) {
            if reduceMotion {
                BrandMark(size: size)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    BrandMark(size: size).opacity(Self.breath(at: context.date))
                }
                .frame(width: size, height: size)
            }
            if let text {
                Text(text)
                    .font(Brand.caption)
                    .foregroundStyle(Brand.color.text2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(text ?? L("status.ingesting")))
    }

    /// 0.55…1 on a 2 s cosine, synced to wall-clock time (not frames).
    static func breath(at date: Date) -> Double {
        let phase = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
        return 0.775 + 0.225 * cos(phase * 2 * .pi)
    }
}

/// The `record` dot while recording: beats in opacity only (0.35 → 1, 1 s), never in scale or position.
struct BrandRecordingDot: View {
    var size: CGFloat = 8
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if reduceMotion {
                Circle().fill(Brand.color.record)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
                    Circle().fill(Brand.color.record).opacity(0.675 + 0.325 * cos(phase * 2 * .pi))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Saved / learned (motion spec C): scale 1 → 1.04 → 1 in 650 ms whenever `trigger` changes. No-op with Reduce Motion.
struct BrandPulseModifier<Trigger: Equatable>: ViewModifier {
    let trigger: Trigger
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        if reduceMotion {
            content
        } else {
            content.keyframeAnimator(initialValue: 1.0, trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                CubicKeyframe(1.04, duration: 0.18)
                CubicKeyframe(1.0, duration: 0.30)
                LinearKeyframe(1.0, duration: 0.17)
            }
        }
    }
}

extension View {
    /// Motion spec C: a calm 650 ms pulse each time `trigger` changes (e.g. an ingest counter).
    func brandPulse<T: Equatable>(trigger: T) -> some View {
        modifier(BrandPulseModifier(trigger: trigger))
    }
}
