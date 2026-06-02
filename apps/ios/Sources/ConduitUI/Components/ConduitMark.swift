import SwiftUI

extension ConduitUI {
    /// The Conduit brand mark — the "terminal daemon": a rounded-square head
    /// with a cyan→green neon outline, top/bottom connector pills, `>` `<`
    /// squint eyes and a small smile. Vector reimplementation of the
    /// `ConduitMark` reference in the design handoff (BRAND.md §2), drawn on a
    /// 32×32 grid and scaled to `size`.
    ///
    /// - `color`: when set, the outline + pills render in this flat tint
    ///   (used for agent-tinted session avatars). When `nil`, the signature
    ///   cyan→green gradient is used.
    /// - `glow`: soft same-color outer glow (BRAND.md §3). On by default.
    struct ConduitMark: View {
        var size: CGFloat = 28
        var color: Color? = nil
        var glow: Bool = true

        // Theme-aware like the design `ConduitMark`: on a light canvas the pastel
        // cyan→green washes out and the near-white eyes vanish ("logo not
        // rendering well"), so light mode strokes the mark in the muted dark
        // accent and draws the eyes in the dark text colour. Glow is suppressed
        // on light (its cyan shadow read as a dark halo).
        @Environment(\.neonTheme) private var neon

        // BRAND.md §3 canonical tokens.
        private static let cyan = Color(hex: "#22d3ee")
        private static let green = Color(hex: "#3ef0a0")
        private static let eye = Color(hex: "#eafcff")

        var body: some View {
            let dark = neon.dark
            // Eyes/smile key off the *mode*, not the glow toggle: glow is an
            // independent switch that can be on in light mode, and the near-white
            // `eye` colour is invisible on a light canvas. Use dark text glyphs in
            // light mode (and suppress the cyan halo there — it reads as a dark blob).
            let eyeColor = dark ? Self.eye : neon.text
            let showGlow = glow && neon.glow && dark
            return Canvas { ctx, canvasSize in
                let s = canvasSize.width / 32.0
                func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }

                let outline: GraphicsContext.Shading = color.map { .color($0) }
                    ?? (dark
                        ? .linearGradient(
                            Gradient(colors: [Self.cyan, Self.green]),
                            startPoint: pt(4, 4), endPoint: pt(28, 28))
                        : .color(neon.accent))

                // Body — rounded square.
                let body = Path(
                    roundedRect: CGRect(x: 5.4 * s, y: 5.4 * s, width: 21.2 * s, height: 21.2 * s),
                    cornerRadius: 6.4 * s
                )
                ctx.stroke(body, with: outline, lineWidth: 2 * s)

                // Connector pills (cyan/green in dark, muted accent in light; flat tint when forced).
                let topFill: GraphicsContext.Shading = color.map { .color($0) } ?? .color(dark ? Self.cyan : neon.accent)
                let bottomFill: GraphicsContext.Shading = color.map { .color($0) } ?? .color(dark ? Self.green : neon.accent)
                ctx.fill(Path(roundedRect: CGRect(x: 14.4 * s, y: 4.4 * s, width: 3.2 * s, height: 2 * s), cornerRadius: 1 * s), with: topFill)
                ctx.fill(Path(roundedRect: CGRect(x: 14.4 * s, y: 25.6 * s, width: 3.2 * s, height: 2 * s), cornerRadius: 1 * s), with: bottomFill)

                // Face: `>` `<` squint eyes + smile.
                var face = Path()
                face.move(to: pt(11, 13.4)); face.addLine(to: pt(13.6, 15.4)); face.addLine(to: pt(11, 17.4))
                face.move(to: pt(21, 13.4)); face.addLine(to: pt(18.4, 15.4)); face.addLine(to: pt(21, 17.4))
                face.move(to: pt(13, 20)); face.addQuadCurve(to: pt(19, 20), control: pt(16, 22.4))
                ctx.stroke(face, with: .color(eyeColor),
                           style: StrokeStyle(lineWidth: 1.7 * s, lineCap: .round, lineJoin: .round))
            }
            .frame(width: size, height: size)
            .shadow(color: showGlow ? (color ?? Self.cyan).opacity(0.53) : .clear, radius: showGlow ? size * 0.1 : 0)
        }
    }
}
