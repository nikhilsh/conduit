import SwiftUI

extension ConduitUI {
    /// The Conduit brand mark, ANCHORED (round-3 §3): no transform ever
    /// moves or rotates its box. Life is expressed in place only —
    ///   - a slow breathing glow (shadow opacity, ~3.4s full cycle), and
    ///   - a rare eye-blink (~6.8s cadence, 120ms closed).
    ///
    /// The previous implementation breathed via `scaleEffect` +
    /// `repeatForever`, the classic SwiftUI combination where a later
    /// layout change gets captured by the still-repeating animation and
    /// the mark visibly drifts around the header ("the logo flying").
    /// This version never uses `repeatForever` or a transform: each
    /// half-breath is a discrete `withAnimation` toggle from an async
    /// loop, so there is no long-lived animation for layout to leak into.
    ///
    /// Fully static under Reduce Motion (and the loop never starts).
    struct AnimatedBrandMark: View {
        var size: CGFloat = 32

        @State private var glowBright = false
        @State private var eyesClosed = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.neonTheme) private var neon

        /// BRAND.md §3 — glow is the cyan accent.
        private static let cyan = Color(hex: "#22d3ee")
        /// Half of the ~3.4s breathing cycle.
        private static let halfBreath: Double = 1.7

        var body: some View {
            // Glow only reads on a dark canvas with glow enabled — same
            // gate as ConduitMark's own halo, which we take over here so
            // the breath modulates a single shadow.
            let showGlow = neon.glow && neon.dark
            ConduitUI.ConduitMark(size: size, glow: false, eyesClosed: eyesClosed)
                .shadow(
                    color: showGlow
                        ? Self.cyan.opacity(reduceMotion ? 0.53 : (glowBright ? 0.62 : 0.28))
                        : .clear,
                    radius: showGlow ? size * 0.1 : 0
                )
                .task(id: reduceMotion) {
                    guard !reduceMotion else {
                        // Static under Reduce Motion: open eyes, steady glow.
                        eyesClosed = false
                        return
                    }
                    var halfBreaths = 0
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: Self.halfBreath)) {
                            glowBright.toggle()
                        }
                        halfBreaths += 1
                        // Blink every 4th half-breath (~6.8s): the Canvas
                        // redraw is instant, which is exactly what a blink
                        // looks like — lids down for 120ms, back up.
                        if halfBreaths % 4 == 0 {
                            try? await Task.sleep(nanoseconds: 1_580_000_000)
                            guard !Task.isCancelled else { return }
                            eyesClosed = true
                            try? await Task.sleep(nanoseconds: 120_000_000)
                            eyesClosed = false
                        } else {
                            try? await Task.sleep(nanoseconds: 1_700_000_000)
                        }
                    }
                }
                .accessibilityHidden(true)
        }
    }
}
