import Testing
@testable import SweKitty

/// Defends the agent-tint overlay on `GlassConfig`. The rendering
/// surface itself is hard to snapshot in a Swift Testing run
/// (SwiftUI / Metal), so the params are lifted into a pure-data
/// `GlassConfig` struct that we can compare directly.
///
/// The old "material audit" tests pinned `GlassConfig.material` to
/// `.regular` / `.ultraThin` — those targeted the pre-iOS-26 material
/// fallback path. With the app's deployment target at iOS 26.0 we now
/// render through `.glassEffect(.regular, in: shape)` exclusively, so
/// the `material` enum was removed from `GlassConfig`. The remaining
/// knob we still care about is `tintOverlayOpacity` — the per-agent
/// wash painted on top of the system glass.
@Suite("GlassConfig — agent-tint overload")
struct GlassModifierTests {

    @Test func solidPresetHasNoAgentTintOverlay() {
        // The bare `glassRoundedRect()` must paint zero tint overlay,
        // otherwise call sites that don't pass an agent would silently
        // pick up a hue.
        #expect(GlassConfig.solid.tintOverlayOpacity == 0.0)
    }

    @Test func transientPresetHasNoAgentTintOverlay() {
        // Same guarantee for `glassCircle` (floating FAB-style
        // controls): no accidental tint without explicit opt-in.
        #expect(GlassConfig.transient.tintOverlayOpacity == 0.0)
    }

    @Test func agentTintedConfigDiffersFromBare() {
        // The headline assertion for the agent-tint overload: passing
        // an `agentTint:` overload must produce a different
        // `GlassConfig` than the bare overload — otherwise the overlay
        // isn't being applied and call sites that switched to the
        // agent-aware overload regress to a flat card.
        let bare = GlassConfig.solid
        let tinted = GlassConfig.solidAgentTinted()
        #expect(bare != tinted)
    }

    @Test func agentTintedOverlayIsSubtle() {
        // Spec says 0.08 opacity — light enough that the underlying
        // glass still reads as the dominant surface, dark enough that
        // the agent hue is visible against the specular highlight.
        #expect(GlassConfig.solidAgentTinted().tintOverlayOpacity == 0.08)
    }

    @Test func agentTintedOpacityIsConfigurable() {
        // Optional override — `solidAgentTinted` accepts a custom
        // opacity for tool/diff cards in ConversationView (4%) so the
        // hue stays even quieter on dense surfaces.
        let cfg = GlassConfig.solidAgentTinted(opacity: 0.04)
        #expect(cfg.tintOverlayOpacity == 0.04)
    }
}
