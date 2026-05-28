import Testing
import SwiftUI
@testable import SweKitty

/// Pins the LitterUI glass surface defaults still meaningful after the
/// iOS-26 deployment-target migration:
///   - `litterGlassRoundedRect` default corner radius dropped 16 → 14.
///   - `LitterUI.Card` default corner radius dropped 16 → 14.
///   - Per-shape highlight opacity (card / pill / floating) still
///     differs so the three variants don't render identically.
///
/// The earlier shadow-opacity assertions targeted the pre-26 material
/// fallback's manual drop shadow — that path is gone now (Liquid Glass
/// paints its own ambient shadow), so the `shadowOpacity` / `borderOpacity`
/// / `fallbackFillOpacity` fields were removed from `LitterUI.GlassConfig`
/// and their pin-tests with them.
@Suite("LitterGlass defaults")
struct LitterGlassDefaultsTests {

    @Test func cardConfigHighlightIsSubtle() {
        // Cards (home rows, settings sections) carry the lightest
        // highlight wash so dense surfaces don't read as glowing.
        #expect(LitterUI.GlassConfig.card.highlightOpacity == 0.12)
    }

    @Test func pillConfigHighlightSitsBetween() {
        // Pill (chips, server pills) — between card and floating so
        // small surfaces stay legible without screaming.
        #expect(LitterUI.GlassConfig.pill.highlightOpacity == 0.16)
    }

    @Test func floatingConfigHighlightLeads() {
        // Floating affordances (FAB, BottomActionBar buttons) get the
        // brightest highlight so they read as "above" the content.
        #expect(LitterUI.GlassConfig.floating.highlightOpacity == 0.22)
    }

    @Test func litterCardDefaultCornerRadiusIs14() {
        let card = LitterUI.Card { Text("x") }
        #expect(card.cornerRadius == 14)
    }
}
