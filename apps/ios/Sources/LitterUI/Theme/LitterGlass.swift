import SwiftUI

// MARK: - LitterGlass
//
// Glass primitives matching litter's Extensions.swift glass modifiers
// (`GlassRectModifier`, `GlassRoundedRectModifier`, `GlassCapsuleModifier`,
// `GlassCircleModifier`). Thin wrappers around iOS 26's `.glassEffect(_:in:)`
// — the app's deployment target is 26.0, so there's no material+stroke
// fallback path.
//
// We don't reuse the SweKittyTheme glass wrappers because the LitterUI
// palette has different default opacity + border tokens, and we want
// the legacy and new UIs to be tunable independently.

extension LitterUI {

    /// Rendering knobs for a single glass surface. iOS 26's native
    /// `.glassEffect` paints its own edge highlight + ambient shadow,
    /// so the only knob left for us is an optional brand-tint wash
    /// opacity. The three shapes still pick different values so the
    /// hero / card / pill variants read a touch different even before
    /// tinting; the system glass is identical between them.
    struct GlassConfig: Equatable, Sendable {
        var highlightOpacity: Double

        /// Card surface (HomeView session row, settings row,
        /// SessionInfo stat).
        static let card = GlassConfig(highlightOpacity: 0.12)
        /// Floating control (BottomActionBar, FAB, icon button).
        static let floating = GlassConfig(highlightOpacity: 0.22)
        /// Subtle / inline pill (ServerPill, ContextChip).
        static let pill = GlassConfig(highlightOpacity: 0.16)
    }

    /// iOS 26's Liquid Glass already renders its own specular edge
    /// highlight and ambient shadow. Stacking our manual 1px stroke +
    /// drop shadow on top of it doubled the edge and made the buttons
    /// read "too heavy" on device (#28 — confirmed against device
    /// feedback). On 26 we let the glass own its edge/shadow and keep
    /// only the clip + an optional tint wash for the prominent variants.
    struct GlassSurfaceModifier<S: InsettableShape>: ViewModifier {
        let shape: S
        var tint: Color?
        var config: GlassConfig

        func body(content: Content) -> some View {
            content
                .glassEffect(.regular, in: shape)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.06))
                    }
                }
                .clipShape(shape)
        }
    }
}

extension LitterUI {
    /// Wraps a group of LitterUI glass surfaces so Liquid Glass can
    /// morph between them (e.g. the bottom-bar `+` button expanding
    /// into a composer). Thin wrapper over SwiftUI's
    /// `GlassEffectContainer`.
    struct GlassMorphContainer<Content: View>: View {
        var spacing: CGFloat = 14
        @ViewBuilder var content: () -> Content

        var body: some View {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        }
    }
}

extension View {
    /// Pairs with `LitterUI.GlassMorphContainer` so Liquid Glass can
    /// morph between surfaces (e.g. `+` button expanding into the
    /// composer). Thin wrapper over `glassEffectID(_:in:)`.
    func litterGlassMorphID(_ id: String, in namespace: Namespace.ID) -> some View {
        glassEffectID(id, in: namespace)
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
