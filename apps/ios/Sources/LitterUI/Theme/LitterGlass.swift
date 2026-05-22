import SwiftUI

// MARK: - LitterGlass
//
// Glass primitives matching litter's Extensions.swift glass modifiers
// (`GlassRectModifier`, `GlassRoundedRectModifier`, `GlassCapsuleModifier`,
// `GlassCircleModifier`). Litter ships these as thin wrappers around
// iOS 26's `.glassEffect(...)`. To stay deployable on iOS 17/18 we
// fall back to material layering the way our existing
// `apps/ios/Sources/Theme/Glass.swift` does — but parameter shapes
// were re-derived from litter so the LitterUI views feel right when
// run on iOS 26 hosts (where `.glassEffect` IS available).
//
// We don't reuse the SweKittyTheme glass wrappers because the LitterUI
// palette has different default opacity + border tokens, and we want
// the legacy and new UIs to be tunable independently.

extension LitterUI {

    /// Rendering knobs for a single glass surface. Parallel to
    /// `GlassConfig` in `apps/ios/Sources/Theme/Glass.swift` but with
    /// LitterUI-specific defaults: slightly less highlight + lower
    /// shadow so cards read flatter (closer to litter's actual visual).
    struct GlassConfig: Equatable, Sendable {
        var highlightOpacity: Double
        var shadowOpacity: Double
        var borderOpacity: Double
        var fallbackFillOpacity: Double

        /// Card surface (HomeView session row, settings row,
        /// SessionInfo stat).
        static let card = GlassConfig(
            highlightOpacity: 0.12,
            shadowOpacity: 0.08,
            borderOpacity: 0.40,
            fallbackFillOpacity: 0.90
        )

        /// Floating control (BottomActionBar, FAB, icon button).
        static let floating = GlassConfig(
            highlightOpacity: 0.22,
            shadowOpacity: 0.18,
            borderOpacity: 0.48,
            fallbackFillOpacity: 0.95
        )

        /// Subtle / inline pill (ServerPill, ContextChip).
        static let pill = GlassConfig(
            highlightOpacity: 0.16,
            shadowOpacity: 0.04,
            borderOpacity: 0.36,
            fallbackFillOpacity: 0.85
        )
    }

    struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
        let shape: S
        var tint: Color?
        var config: GlassConfig

        func body(content: Content) -> some View {
            let stroke = (tint ?? LitterUI.Palette.border.color).opacity(config.borderOpacity)
            let glow = (tint ?? LitterUI.Palette.brand.color).opacity(config.highlightOpacity)

            content
                .background {
                    shape
                        .fill(.regularMaterial)
                        .overlay {
                            shape
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            glow,
                                            LitterUI.Palette.surfaceLight.color.opacity(0.04),
                                            .clear,
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        }
                        .overlay {
                            // Tint overlay (low opacity) when explicitly
                            // requested — agent-tinted variants want a
                            // faint hue on top of the material.
                            if let tint {
                                shape.fill(tint.opacity(0.06))
                            }
                        }
                }
                .overlay {
                    shape.stroke(stroke, lineWidth: 1)
                }
                .clipShape(shape)
                .shadow(
                    color: LitterUI.Palette.textPrimary.color.opacity(config.shadowOpacity),
                    radius: 12,
                    x: 0,
                    y: 6
                )
        }
    }
}

extension View {
    /// Litter-style rounded-rect glass surface. Defaults match litter's
    /// `GlassRoundedRectModifier` (16pt corner radius).
    func litterGlassRoundedRect(
        cornerRadius: CGFloat = 16,
        tint: Color? = nil,
        config: LitterUI.GlassConfig = .card
    ) -> some View {
        modifier(LitterUI.GlassSurfaceModifier(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            tint: tint,
            config: config
        ))
    }

    /// Litter-style capsule glass surface (used for server pills,
    /// agent chips, and BottomActionBar buttons).
    func litterGlassCapsule(
        tint: Color? = nil,
        config: LitterUI.GlassConfig = .pill
    ) -> some View {
        modifier(LitterUI.GlassSurfaceModifier(
            shape: Capsule(),
            tint: tint,
            config: config
        ))
    }

    /// Litter-style circular glass surface (used for floating icon
    /// buttons in the home top row).
    func litterGlassCircle(
        tint: Color? = nil,
        config: LitterUI.GlassConfig = .floating
    ) -> some View {
        modifier(LitterUI.GlassSurfaceModifier(
            shape: Circle(),
            tint: tint,
            config: config
        ))
    }
}
