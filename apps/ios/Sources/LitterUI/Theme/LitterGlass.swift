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
                .modifier(LitterGlassBackdrop(shape: shape, config: config, glow: glow, tint: tint))
                .overlay {
                    shape.stroke(stroke, lineWidth: 1)
                }
                .clipShape(shape)
                // Shadow halved (radius 12→8, y 6→4) in PLAN-LITTER-
                // VISUAL-PARITY PR 2 to match SweKittyTheme/Glass.swift
                // PR 1. Card / pill / floating shadowOpacity values
                // were already in the right band; only radius + offset
                // needed the trim so settings cards stop dropping a
                // "magazine" shadow over flat content.
                .shadow(
                    color: LitterUI.Palette.textPrimary.color.opacity(config.shadowOpacity),
                    radius: 8,
                    x: 0,
                    y: 4
                )
        }
    }

    /// Picks the right backdrop based on OS version. On iOS 26+ we call
    /// SwiftUI's native `.glassEffect(_:in:)` (Liquid Glass) so surfaces
    /// actually refract instead of just blurring; on older OSes we keep
    /// the existing material + gradient + tint stack so the visual
    /// shape stays consistent. Mirrors the pattern landed in
    /// `apps/ios/Sources/Theme/Glass.swift` (PR 1) for the SweKittyTheme
    /// glass primitives — same direction, applied to the LitterUI tree
    /// so the visual rebuild in PR 3-5 has real glass where it ships.
    fileprivate struct LitterGlassBackdrop<S: InsettableShape>: ViewModifier {
        let shape: S
        let config: LitterUI.GlassConfig
        let glow: Color
        let tint: Color?

        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content
                    .glassEffect(.regular, in: shape)
                    .overlay {
                        if let tint {
                            shape.fill(tint.opacity(0.06))
                        }
                    }
            } else {
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
                                if let tint {
                                    shape.fill(tint.opacity(0.06))
                                }
                            }
                    }
            }
        }
    }
}

extension View {
    /// Litter-style rounded-rect glass surface. Default corner radius
    /// dropped from 16 → 14 in PLAN-LITTER-VISUAL-PARITY PR 2 to match
    /// litter's flatter card shape (audit §A.3.2 / §B.3); hero surfaces
    /// that want the previous chunkier radius pass an explicit value.
    func litterGlassRoundedRect(
        cornerRadius: CGFloat = 14,
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
