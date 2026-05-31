import Testing
import SwiftUI
@testable import Conduit

/// Pins the ConduitUI glass surface defaults still meaningful after the
/// iOS-26 deployment-target migration:
///   - `conduitGlassRoundedRect` default corner radius dropped 16 → 14.
///   - `ConduitUI.Card` default corner radius dropped 16 → 14.
///   - Per-shape highlight opacity (card / pill / floating) still
///     differs so the three variants don't render identically.
///
/// The earlier shadow-opacity assertions targeted the pre-26 material
/// fallback's manual drop shadow — that path is gone now (Liquid Glass
/// paints its own ambient shadow), so the `shadowOpacity` / `borderOpacity`
/// / `fallbackFillOpacity` fields were removed from `ConduitUI.GlassConfig`
/// and their pin-tests with them.
@Suite("ConduitGlass defaults")
struct ConduitGlassDefaultsTests {

    @Test func cardConfigHighlightIsSubtle() {
        // Cards (home rows, settings sections) carry the lightest
        // highlight wash so dense surfaces don't read as glowing.
        #expect(ConduitUI.GlassConfig.card.highlightOpacity == 0.12)
    }

    @Test func pillConfigHighlightSitsBetween() {
        // Pill (chips, server pills) — between card and floating so
        // small surfaces stay legible without screaming.
        #expect(ConduitUI.GlassConfig.pill.highlightOpacity == 0.16)
    }

    @Test func floatingConfigHighlightLeads() {
        // Floating affordances (FAB, BottomActionBar buttons) get the
        // brightest highlight so they read as "above" the content.
        #expect(ConduitUI.GlassConfig.floating.highlightOpacity == 0.22)
    }

    @Test func conduitCardDefaultCornerRadiusIs14() {
        let card = ConduitUI.Card { Text("x") }
        #expect(card.cornerRadius == 14)
    }
}
