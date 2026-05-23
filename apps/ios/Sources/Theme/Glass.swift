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
    var material: GlassMaterial
    var highlightOpacity: Double
    var shadowOpacity: Double
    var tintOverlayOpacity: Double
    var isInteractive: Bool

    /// Default for solid card surfaces (`glassRoundedRect`, `glassCapsule`).
    static let solid = GlassConfig(
        material: .regular,
        highlightOpacity: 0.24,
        shadowOpacity: 0.08,
        tintOverlayOpacity: 0.0,
        isInteractive: false
    )

    /// Default for transient / floating surfaces (`glassCircle`).
    static let transient = GlassConfig(
        material: .ultraThin,
        highlightOpacity: 0.28,
        shadowOpacity: 0.08,
        tintOverlayOpacity: 0.0,
        isInteractive: false
    )

    /// Solid card with a per-agent tint overlay (8% opacity of the
    /// agent accent painted over the material).
    static func solidAgentTinted(opacity: Double = 0.08) -> GlassConfig {
        GlassConfig(
            material: .regular,
            highlightOpacity: 0.24,
            shadowOpacity: 0.08,
            tintOverlayOpacity: opacity,
            isInteractive: false
        )
    }
}

/// Material enum the rendering layer maps to SwiftUI's `Material`. Kept
/// separate so `GlassConfig` stays `Equatable` and unit-testable.
enum GlassMaterial: Equatable {
    case regular
    case thin
    case ultraThin

    var swiftUIMaterial: Material {
        switch self {
        case .regular:   return .regularMaterial
        case .thin:      return .thinMaterial
        case .ultraThin: return .ultraThinMaterial
        }
    }
}

private struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    var tint: Color?
    var config: GlassConfig = .solid

    func body(content: Content) -> some View {
        let stroke = (tint ?? SweKittyTheme.border).opacity(0.42)
        let glow = (tint ?? SweKittyTheme.accentStrong).opacity(config.highlightOpacity)

        content
            .modifier(GlassBackdrop(shape: shape, config: config, glow: glow, tint: tint))
            .overlay {
                shape
                    .stroke(stroke, lineWidth: 1)
            }
            .clipShape(shape)
            // Shadow halved in PLAN-LITTER-VISUAL-PARITY PR 1 — radius
            // 18 → 10, y 10 → 5 — so glass surfaces no longer drop a
            // "magazine" shadow over flat content. Shadow opacity is
            // driven by [GlassConfig.shadowOpacity] (also halved).
            .shadow(color: SweKittyTheme.textPrimary.opacity(config.shadowOpacity), radius: 10, x: 0, y: 5)
    }
}

/// Picks the right backdrop primitive based on OS version. On iOS 26+
/// we call SwiftUI's native `.glassEffect(_:in:)` (Liquid Glass) so
/// surfaces actually refract instead of just blurring — that's the
/// jump from "Material" to "real glass" the audit (PLAN-LITTER-VISUAL-
/// PARITY §B.4) flagged as the biggest missing capability. On older
/// OSes we keep the existing `.regularMaterial` background + highlight
/// gradient stack so the visual shape stays consistent. The per-agent
/// tint overlay applies on both paths.
private struct GlassBackdrop<S: InsettableShape>: ViewModifier {
    let shape: S
    let config: GlassConfig
    let glow: Color
    let tint: Color?

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            // Liquid Glass: the system primitive provides refraction +
            // highlight natively, so we skip the manual glow gradient
            // here and only paint the optional per-agent tint on top.
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
        } else {
            // Material fallback path (pre-iOS-26): manual gradient
            // glow + material fill, identical to the pre-PR shape.
            content
                .background {
                    shape
                        .fill(config.material.swiftUIMaterial)
                        .overlay {
                            shape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            glow,
                                            SweKittyTheme.surfaceLight.opacity(0.06),
                                            .clear,
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .overlay {
                            if let tint, config.tintOverlayOpacity > 0 {
                                shape.fill(tint.opacity(config.tintOverlayOpacity))
                            }
                        }
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
        config.highlightOpacity = interactive ? 0.34 : 0.22
        // Shadow halved alongside the rest of the surfaces in PR 1
        // (0.22 → 0.11 interactive, 0.14 → 0.07 static).
        config.shadowOpacity = interactive ? 0.11 : 0.07
        // Routes to `.glassEffect(.regular.interactive(), in: shape)`
        // on iOS 26+ for press-deformation; pre-26 path keeps today's
        // material treatment.
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

/// Wraps a group of glass surfaces so iOS 26's Liquid Glass can morph
/// between them (e.g. `+` button → composer). On iOS 26+ this drops in
/// SwiftUI's `GlassEffectContainer` so child surfaces decorated with
/// `glassMorphID(_:in:)` actually morph; on older OSes we fall through
/// to the previous pass-through container and `glassMorphID` keeps
/// using `matchedGeometryEffect`.
struct GlassMorphContainer<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
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

    /// Pairs with `GlassMorphContainer` so iOS 26's Liquid Glass can
    /// morph between surfaces (e.g. `+` button → expanded composer).
    /// On iOS 26+ delegates to `glassEffectID(_:in:)` so the system
    /// owns the morph; pre-26 falls back to `matchedGeometryEffect`,
    /// which animates frame/opacity but does not actually melt-and-fuse
    /// the glass surfaces.
    @ViewBuilder
    func glassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self.matchedGeometryEffect(id: id, in: namespace)
        }
    }
}
