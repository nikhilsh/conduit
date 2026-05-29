import SwiftUI

// MARK: - NeonComponents
//
// Small, reused styling primitives that consume the resolved `NeonTheme`
// (injected at `\.neonTheme`) and apply the glow descriptors from
// `NeonTheme` (README §3.5). Cards in the chat surface build on these so
// the glow / surface / border rules live in exactly one place.
//
//   - `neonGlowBox(_:)`  — layers the two box-glow shadows (no-op when nil)
//   - `neonTextGlow(_:)`  — layers the two text-glow shadows (no-op when nil)
//   - `neonCardSurface(...)` — codeBg/surface fill + radius + 1px border
//     (borderStrong, or red on failure) + glowBox (glow on) / cardElevation
//     (light-mode glow off)
//   - `NeonGrid` — faint grid overlay for the canvas

// MARK: Glow modifiers

private struct NeonGlowBoxModifier: ViewModifier {
    let box: NeonGlowBox?

    func body(content: Content) -> some View {
        if let box {
            content
                .shadow(color: box.inner.color, radius: box.inner.radius)
                .shadow(color: box.outer.color, radius: box.outer.radius)
        } else {
            content
        }
    }
}

private struct NeonTextGlowModifier: ViewModifier {
    let glow: NeonTextGlow?

    func body(content: Content) -> some View {
        if let glow {
            content
                .shadow(color: glow.inner.color, radius: glow.inner.radius)
                .shadow(color: glow.outer.color, radius: glow.outer.radius)
        } else {
            content
        }
    }
}

extension View {
    /// Layer the two box-glow shadows from a `NeonGlowBox` descriptor.
    /// No-op when `box` is nil (glow off). Tint a custom colour by passing
    /// a re-tinted descriptor; the default uses the theme's `glowBox`.
    func neonGlowBox(_ box: NeonGlowBox?) -> some View {
        modifier(NeonGlowBoxModifier(box: box))
    }

    /// Layer the two text-glow shadows from a `NeonTextGlow` descriptor.
    /// No-op when `glow` is nil (light mode / glow off).
    func neonTextGlow(_ glow: NeonTextGlow?) -> some View {
        modifier(NeonTextGlowModifier(glow: glow))
    }
}

// MARK: Glow re-tint helpers

extension NeonGlowBox {
    /// Re-tint both layers to `color`, preserving each layer's radius +
    /// alpha. Lets a card glow in its status colour (running/ok/fail)
    /// rather than the theme accent.
    func tinted(_ color: Color) -> NeonGlowBox {
        NeonGlowBox(
            inner: NeonShadowLayer(radius: inner.radius, color: color.opacity(inner.alpha), alpha: inner.alpha),
            outer: NeonShadowLayer(radius: outer.radius, color: color.opacity(outer.alpha), alpha: outer.alpha)
        )
    }
}

extension NeonTextGlow {
    /// Re-tint both layers to `color`, preserving radius + alpha.
    func tinted(_ color: Color) -> NeonTextGlow {
        NeonTextGlow(
            inner: NeonShadowLayer(radius: inner.radius, color: color.opacity(inner.alpha), alpha: inner.alpha),
            outer: NeonShadowLayer(radius: outer.radius, color: color.opacity(outer.alpha), alpha: outer.alpha)
        )
    }
}

// MARK: Card surface

private struct NeonCardSurfaceModifier: ViewModifier {
    let neon: NeonTheme
    /// Fill — `codeBg` for code/command/output containers, `surface`
    /// for prose-ish cards.
    let fill: Color
    let cornerRadius: CGFloat
    /// Border colour — defaults to `borderStrong`; pass `neon.red` for a
    /// failed state.
    let border: Color
    let borderWidth: CGFloat
    /// Glow tint — when `neon.glow` is on, the box glow is re-tinted to
    /// this. nil → theme accent glow.
    let glowTint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let tintedBox: NeonGlowBox? = {
            guard let box = neon.glowBox else { return nil }
            return glowTint.map { box.tinted($0) } ?? box
        }()
        return content
            .background(shape.fill(fill))
            .overlay(shape.stroke(border, lineWidth: borderWidth))
            .clipShape(shape)
            .neonGlowBox(tintedBox)
            // Glow OFF + light mode → soft card elevation (README §3.5).
            .modifier(NeonCardElevationModifier(elevation: neon.cardElevation))
    }
}

private struct NeonCardElevationModifier: ViewModifier {
    let elevation: NeonCardElevation?

    func body(content: Content) -> some View {
        if let elevation {
            content.shadow(color: elevation.color, radius: elevation.radius, x: 0, y: elevation.yOffset)
        } else {
            content
        }
    }
}

extension View {
    /// Neon card surface: fill + radius + 1px border + glow (when on) or
    /// light-mode elevation (when glow off). The single place the
    /// surface/border/glow rules are applied so every card stays in sync.
    func neonCardSurface(
        _ neon: NeonTheme,
        fill: Color? = nil,
        cornerRadius: CGFloat? = nil,
        border: Color? = nil,
        borderWidth: CGFloat = 1,
        failed: Bool = false,
        glowTint: Color? = nil
    ) -> some View {
        modifier(NeonCardSurfaceModifier(
            neon: neon,
            fill: fill ?? neon.surface,
            cornerRadius: cornerRadius ?? 14,
            border: border ?? (failed ? neon.red.opacity(0.66) : neon.borderStrong),
            borderWidth: borderWidth,
            glowTint: glowTint ?? (failed ? neon.red : nil)
        ))
    }
}

// MARK: - NeonGrid

/// Faint grid overlay for the app canvas — thin lines in `neon.grid`.
/// Drawn with a `Canvas` so it costs nothing in the view graph and never
/// intercepts touches.
struct NeonGrid: View {
    @Environment(\.neonTheme) private var neon

    /// Cell size in points. 44 reads as a quiet "terminal grid" without
    /// turning into graph paper.
    var spacing: CGFloat = 44

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x: CGFloat = 0
            while x <= size.width {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                x += spacing
            }
            var y: CGFloat = 0
            while y <= size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += spacing
            }
            context.stroke(path, with: .color(neon.grid), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
