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

            let base = content
                .modifier(LitterGlassBackdrop(shape: shape, config: config, glow: glow, tint: tint))

            if #available(iOS 26.0, *) {
                // iOS 26's native Liquid Glass already renders its own
                // specular edge highlight and ambient shadow. Stacking our
                // manual 1px stroke + drop shadow on top of it doubled the
                // edge and made the buttons read "too heavy" on device
                // (#28 — confirmed against device feedback). On 26 we let
                // the glass own its edge/shadow and keep only the clip.
                base.clipShape(shape)
            } else {
                // Pre-26 material fallback has no built-in edge or shadow,
                // so we draw them ourselves. Shadow halved (radius 12→8,
                // y 6→4) in PLAN-LITTER-VISUAL-PARITY PR 2 to match
                // SweKittyTheme/Glass.swift PR 1 — only radius + offset
                // needed the trim so settings cards stop dropping a
                // "magazine" shadow over flat content.
                base
                    .overlay {
                        shape.stroke(stroke, lineWidth: 1)
                    }
                    .clipShape(shape)
                    .shadow(
                        color: LitterUI.Palette.textPrimary.color.opacity(config.shadowOpacity),
                        radius: 8,
                        x: 0,
                        y: 4
                    )
            }
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

extension LitterUI {
    /// Wraps a group of LitterUI glass surfaces so iOS 26's Liquid
    /// Glass can morph between them (e.g. the bottom-bar `+` button
    /// expanding into a composer). On iOS 26+ this is SwiftUI's
    /// `GlassEffectContainer`; on older OSes it falls through to a
    /// pass-through `Group` and `litterGlassMorphID` falls back to
    /// `matchedGeometryEffect`. Mirrors the same container landed in
    /// `apps/ios/Sources/Theme/Glass.swift` (PR 1) but namespaced into
    /// LitterUI so the rebuilt home / chat surfaces can opt in
    /// independently.
    struct GlassMorphContainer<Content: View>: View {
        var spacing: CGFloat = 14
        @ViewBuilder var content: () -> Content

        var body: some View {
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: spacing) {
                    content()
                }
            } else {
                Group { content() }
            }
        }
    }
}

extension View {
    /// Pairs with `LitterUI.GlassMorphContainer` so iOS 26's Liquid
    /// Glass can morph between surfaces (e.g. `+` button expanding into
    /// the composer). On iOS 26+ delegates to `glassEffectID(_:in:)`
    /// so the system owns the morph; pre-26 falls back to
    /// `matchedGeometryEffect`, which animates frame/opacity but does
    /// not actually melt-and-fuse the surfaces.
    @ViewBuilder
    func litterGlassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffectID(id, in: namespace)
        } else {
            self.matchedGeometryEffect(id: id, in: namespace)
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
