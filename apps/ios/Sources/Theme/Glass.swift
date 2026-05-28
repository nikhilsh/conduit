import SwiftUI

// MARK: - Glass effect wrappers
//
// The previous pass tried to use unreleased Liquid Glass-specific SwiftUI
// symbols that are not present in the runner SDK yet. Keep the same visual
// direction, but implement it with compile-safe material layering so CI and
// release builds stay shippable.
//
// Stage 6 polish (litter):
//   - Each modifier's `Material` is chosen by intent rather than uniformly
//     `.thinMaterial`. Solid cards (`glassRoundedRect`, `glassCapsule`)
//     use `.regularMaterial` so they read closer to litter's chunky
//     surfaces; transient affordances (`glassCircle` for floating FAB-ish
//     buttons) stay on `.ultraThinMaterial` so they melt into whatever
//     scrolls underneath.
//   - `glassRoundedRect(agentTint:)` overlays the per-agent accent at
//     0.08 opacity on top of the material — same shape as the bare
//     overload, just a faint hue.

/// Pure-data summary of a glass surface's tunables. Used directly by the
/// rendering modifiers, and exposed so the test suite can compare
/// configurations without running SwiftUI.
///
/// `shadowOpacity` values were halved (0.16 → 0.08) in
/// `PLAN-LITTER-VISUAL-PARITY` PR 1 — the prior "magazine drop shadow"
/// under every glass surface read heavy against litter's nearly-flat
/// reference. `isInteractive` was added so the capsule path can opt
/// into iOS 26's `.glassEffect(.regular.interactive(), …)` modifier
/// (Liquid Glass press-deformation) without a separate config field.
struct GlassConfig: Equatable {
    var highlightOpacity: Double
    var shadowOpacity: Double
    var tintOverlayOpacity: Double
    var isInteractive: Bool

    /// Default for solid card surfaces (`glassRoundedRect`, `glassCapsule`).
    static let solid = GlassConfig(
        highlightOpacity: 0.24,
        shadowOpacity: 0.08,
        tintOverlayOpacity: 0.0,
        isInteractive: false
    )

    /// Default for transient / floating surfaces (`glassCircle`).
    static let transient = GlassConfig(
        highlightOpacity: 0.28,
        shadowOpacity: 0.08,
        tintOverlayOpacity: 0.0,
        isInteractive: false
    )

    /// Solid card with a per-agent tint overlay (8% opacity of the
    /// agent accent painted over the glass).
    static func solidAgentTinted(opacity: Double = 0.08) -> GlassConfig {
        GlassConfig(
            highlightOpacity: 0.24,
            shadowOpacity: 0.08,
            tintOverlayOpacity: opacity,
            isInteractive: false
        )
    }
}

private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var config: GlassConfig = .solid

    func body(content: Content) -> some View {
        // iOS 26's Liquid Glass primitive paints its own specular edge
        // highlight and ambient shadow — manual stroke + drop shadow on
        // top doubled the edge and made surfaces read "too heavy"
        // (device feedback). Now we let the system glass own those.
        content
            .modifier(GlassBackdrop(shape: shape, config: config, tint: tint))
            .clipShape(shape)
    }
}

/// Picks the right backdrop primitive based on OS version. On iOS 26+
/// Native Liquid Glass backdrop. SwiftUI's `.glassEffect(_:in:)` paints
/// refraction + edge highlight natively; we only layer an optional
/// per-agent tint on top. The app's deployment target is iOS 26, so
/// there's no material+gradient fallback path.
private struct GlassBackdrop<S: InsettableShape>: ViewModifier {
    let shape: S
    let config: GlassConfig
    let tint: Color?

    func body(content: Content) -> some View {
        content
            .glassEffect(
                config.isInteractive ? .regular.interactive() : .regular,
                in: shape
            )
            .overlay {
                if let tint, config.tintOverlayOpacity > 0 {
                    shape.fill(tint.opacity(config.tintOverlayOpacity))
                }
            }
    }
}

struct GlassRectModifier: ViewModifier {
    let cornerRadius: CGFloat
    var tint: Color?

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: tint,
                config: .solid
            )
        )
    }
}

struct GlassRoundedRectModifier: ViewModifier {
    var cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius
    var agentTint: Color? = nil

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                tint: agentTint,
                config: agentTint == nil ? .solid : .solidAgentTinted()
            )
        )
    }
}

struct GlassCapsuleModifier: ViewModifier {
    var interactive: Bool = false
    var tint: Color?

    func body(content: Content) -> some View {
        var config = GlassConfig.solid
        // Routes to `.glassEffect(.regular.interactive(), in: shape)`
        // for press-deformation when the caller flags the capsule as
        // interactive (the bottom-bar buttons do; pill chips do not).
        config.isInteractive = interactive
        return content
            .modifier(
                GlassSurfaceModifier(
                    shape: Capsule(),
                    tint: tint,
                    config: config
                )
            )
            .scaleEffect(interactive ? 1.0 : 0.995)
    }
}

struct GlassCircleModifier: ViewModifier {
    var tint: Color?

    func body(content: Content) -> some View {
        content.modifier(
            GlassSurfaceModifier(
                shape: Circle(),
                tint: tint,
                config: .transient
            )
        )
    }
}

/// Wraps a group of glass surfaces so Liquid Glass can morph between
/// them (e.g. `+` button → composer). Thin wrapper over SwiftUI's
/// `GlassEffectContainer`.
struct GlassMorphContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            content()
        }
    }
}

extension View {
    func glassRect(cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius, tint: Color? = nil) -> some View {
        modifier(GlassRectModifier(cornerRadius: cornerRadius, tint: tint))
    }

    func glassRoundedRect(cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius) -> some View {
        modifier(GlassRoundedRectModifier(cornerRadius: cornerRadius))
    }

    /// Agent-tinted overload: same surface as `glassRoundedRect`, plus a
    /// flat 8% overlay of the agent accent so cards in a session pick
    /// up the agent hue without the heavy capsule tint.
    func glassRoundedRect(cornerRadius: CGFloat = SweKittyTheme.cardCornerRadius, agentTint: Color) -> some View {
        modifier(GlassRoundedRectModifier(cornerRadius: cornerRadius, agentTint: agentTint))
    }

    func glassCapsule(interactive: Bool = false, tint: Color? = nil) -> some View {
        modifier(GlassCapsuleModifier(interactive: interactive, tint: tint))
    }

    func glassCircle(tint: Color? = nil) -> some View {
        modifier(GlassCircleModifier(tint: tint))
    }

    /// Pairs with `GlassMorphContainer` so Liquid Glass can morph
    /// between surfaces (e.g. `+` button → expanded composer). Thin
    /// wrapper over `glassEffectID(_:in:)`.
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        glassEffectID(id, in: namespace)
    }
}
