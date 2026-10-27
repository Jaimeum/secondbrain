import SwiftUI

/// Motion spec A: the app appearing (1.6 s, once per process) over the main window, then a 200 ms crossfade to the
/// UI. Not on vault switches (it sits outside `RootView`'s identity), not in snapshot mode; with Reduce Motion the
/// symbol is static and the overlay leaves with a single 150 ms fade.
struct LaunchOverlay: View {
    /// Once per launch, across windows and language/vault rebuilds.
    @MainActor private static var played = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewState private var visible = LaunchOverlay.shouldPlay
    @ViewState private var halo = 0.0
    @ViewState private var markOpacity = 0.0
    @ViewState private var markBlur: CGFloat = 16
    @ViewState private var markScale: CGFloat = 0.9
    @ViewState private var wordOpacity = 0.0
    @ViewState private var wordOffset: CGFloat = 10
    @ViewState private var overlayOpacity = 1.0

    @MainActor private static var shouldPlay: Bool { !played && DebugSnapshots.directory == nil }

    var body: some View {
        if visible {
            ZStack {
                Brand.color.bg
                Circle()
                    .fill(Brand.color.sage)
                    .frame(width: 220, height: 220)
                    .blur(radius: 40)
                    .opacity(halo)
                VStack(spacing: 18) {
                    BrandMark(size: 96)
                        .opacity(markOpacity)
                        .blur(radius: markBlur)
                        .scaleEffect(markScale)
                    BrandWordmark(size: 26)
                        .opacity(wordOpacity)
                        .offset(y: wordOffset)
                }
            }
            .ignoresSafeArea()
            .opacity(overlayOpacity)
            .accessibilityHidden(true)
            .task { await play() }
        }
    }

    @MainActor private func play() async {
        guard !Self.played else { visible = false; return }
        Self.played = true
        if reduceMotion {
            markOpacity = 1; markBlur = 0; markScale = 1; wordOpacity = 1; wordOffset = 0
            await pause(0.45)
            withAnimation(.easeOut(duration: 0.15)) { overlayOpacity = 0 }
            await pause(0.15)
            visible = false
            return
        }
        // 0.00–0.18 s: the sage halo comes up to 12 %.
        withAnimation(.easeOut(duration: 0.18)) { halo = 0.12 }
        await pause(0.18)
        // 0.18–0.55 s: the symbol resolves: opacity 0→1, blur 16→0, scale 0.90→0.98.
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.37)) {
            markOpacity = 1; markBlur = 0; markScale = 0.98
        }
        await pause(0.90)
        // 1.08–1.40 s: scale 0.98→1.015→1 and the wordmark arrives (fade, 10→0 pt).
        withAnimation(.easeOut(duration: 0.16)) { markScale = 1.015 }
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)) { wordOpacity = 1; wordOffset = 0 }
        await pause(0.16)
        withAnimation(.easeOut(duration: 0.16)) { markScale = 1 }
        await pause(0.16)
        // 1.40–1.60 s: crossfade to the interface.
        withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.2)) { overlayOpacity = 0; halo = 0 }
        await pause(0.2)
        visible = false
    }

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
