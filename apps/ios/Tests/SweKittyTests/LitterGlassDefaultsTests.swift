import Testing
import SwiftUI
@testable import SweKitty

/// Pins the LitterUI glass surface defaults set in
/// `PLAN-LITTER-VISUAL-PARITY` PR 2:
///   - `litterGlassRoundedRect` default corner radius dropped 16 → 14.
///   - `LitterUI.Card` default corner radius dropped 16 → 14.
///   - Glass config shadow opacities stayed where PR 1 left them
///     (card 0.08 / pill 0.04 / floating 0.18).
///
/// If a future refactor flips any of these back, the downstream PRs
/// (Home rebuild, ChatTab rebuild, Sheet polish) will silently regress
/// to the over-rounded / over-shadowed look the audit flagged in
/// §A.3.2 / §A.1.8. This catches it before that happens.
@Suite("LitterGlass defaults")
struct LitterGlassDefaultsTests {

    @Test func cardConfigShadowOpacityStaysHalved() {
        #expect(LitterUI.GlassConfig.card.shadowOpacity == 0.08)
    }

    @Test func pillConfigShadowIsBarelyThere() {
        #expect(LitterUI.GlassConfig.pill.shadowOpacity == 0.04)
    }

    @Test func floatingConfigShadowKeepsPresence() {
        // Floating affordances (FAB, BottomActionBar buttons) keep a
        // visible shadow so they read as "above" the content; we
        // intentionally don't halve this one.
        #expect(LitterUI.GlassConfig.floating.shadowOpacity == 0.18)
    }

    @Test func litterCardDefaultCornerRadiusIs14() {
        let card = LitterUI.Card { Text("x") }
        #expect(card.cornerRadius == 14)
    }
}
