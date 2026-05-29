import Testing
import Foundation
import SwiftUI
@testable import SweKitty

/// Pins the Neon Terminal token resolver (`NeonTheme.resolve`) to the
/// documented hex values from `design_handoff_neon_mobile_ui/` for the
/// canonical dark-Ice + light-Ice combinations, plus the palette label
/// mapping and the `AppearanceStore` persistence round-trip for the two
/// new neon choices. Mirrors the assertion style in
/// `AppearanceStoreTests`.
///
/// Colors are compared against `Color(hex:)` / `Color(hex:alpha:)` from
/// the production code so the expectation reads as the documented hex
/// rather than raw RGBA floats.
@Suite("NeonTheme")
struct NeonThemeTests {

    // MARK: - Palette label / id mapping

    @Test func paletteLabels() {
        #expect(NeonPalette.ice.label == "Ice")
        #expect(NeonPalette.synth.label == "Synthwave")
        #expect(NeonPalette.matrix.label == "Matrix")
        #expect(NeonPalette.amber.label == "Amber CRT")
    }

    @Test func paletteRawValuesAreStableIds() {
        #expect(NeonPalette.ice.rawValue == "ice")
        #expect(NeonPalette.synth.rawValue == "synth")
        #expect(NeonPalette.matrix.rawValue == "matrix")
        #expect(NeonPalette.amber.rawValue == "amber")
        #expect(NeonPalette.allCases.count == 4)
    }

    @Test func paletteChoiceBridgesToNeonPalette() {
        #expect(AppearanceStore.NeonPaletteChoice.synth.neonPalette == .synth)
        #expect(AppearanceStore.NeonPaletteChoice.amber.label == "Amber CRT")
    }

    // MARK: - Dark / Ice token values

    @Test func darkIceCoreTokens() {
        let t = NeonTheme.resolve(palette: .ice, dark: true, glow: true)
        #expect(t.dark == true)
        #expect(t.mode == "dark")
        // accent == bright accent in dark mode
        #expect(t.accent == Color(hex: "#22d3ee"))
        #expect(t.accentBright == Color(hex: "#22d3ee"))
        #expect(t.accent2 == Color(hex: "#4f8cff"))
        #expect(t.bg == Color(hex: "#04050a"))
        #expect(t.surfaceSolid == Color(hex: "#0a1120"))
        #expect(t.panel == Color(hex: "#0b1322"))
        #expect(t.text == Color(hex: "#eaf3ff"))
        #expect(t.accentText == Color(hex: "#03121a"))
        // border = accent at 0x22 alpha
        #expect(t.border == Color(hex: "#22d3ee", alpha: 0x22))
        #expect(t.borderStrong == Color(hex: "#22d3ee", alpha: 0x44))
        #expect(t.grid == Color(hex: "#22d3ee", alpha: 0x0e))
        // codeText defaults to text in dark
        #expect(t.codeText == t.text)
        #expect(t.radius == 20)
    }

    @Test func darkSemanticTokens() {
        let t = NeonTheme.resolve(palette: .ice, dark: true, glow: true)
        #expect(t.claude == Color(hex: "#ff9d4d"))
        #expect(t.codex == Color(hex: "#22d3ee"))      // == bright accent
        #expect(t.purple == Color(hex: "#b487ff"))
        #expect(t.blue == Color(hex: "#4f8cff"))        // == accent2
        #expect(t.green == Color(hex: "#3ef0a0"))
        #expect(t.red == Color(hex: "#ff5c72"))
        #expect(t.yellow == Color(hex: "#ffd24d"))
    }

    // MARK: - Light / Ice token values

    @Test func lightIceCoreTokens() {
        let t = NeonTheme.resolve(palette: .ice, dark: false, glow: true)
        #expect(t.dark == false)
        #expect(t.mode == "light")
        // accent switches to the darker accent in light mode
        #expect(t.accent == Color(hex: "#0a93ad"))
        // bright accent is retained for glows / badges
        #expect(t.accentBright == Color(hex: "#22d3ee"))
        #expect(t.bg == Color(hex: "#dfe6f2"))
        #expect(t.surface2 == Color(hex: "#ffffff"))
        #expect(t.surfaceSolid == Color(hex: "#ffffff"))
        #expect(t.panel == Color(hex: "#f4f7fc"))
        #expect(t.text == Color(hex: "#0d1a30"))
        #expect(t.accentText == Color(hex: "#ffffff"))
        // borderStrong = accentDark at 0x55 alpha
        #expect(t.borderStrong == Color(hex: "#0a93ad", alpha: 0x55))
        // Code blocks stay DARK in light mode.
        #expect(t.codeBg == Color(hex: "#0c1322"))
        #expect(t.codeText == Color(hex: "#d6e6ff"))
    }

    // MARK: - Glow descriptors

    @Test func textGlowOnlyInDark() {
        let dark = NeonTheme.resolve(palette: .ice, dark: true, glow: true)
        #expect(dark.textGlowEnabled == true)
        #expect(dark.textGlow != nil)
        #expect(dark.glowBox != nil)
        #expect(dark.cardElevation == nil)

        let light = NeonTheme.resolve(palette: .ice, dark: false, glow: true)
        // text-shadow glow is always off in light mode
        #expect(light.textGlowEnabled == false)
        #expect(light.textGlow == nil)
        // box glow still present (softened) in light mode
        #expect(light.glowBox != nil)
    }

    @Test func glowOffDropsShadows() {
        let dark = NeonTheme.resolve(palette: .ice, dark: true, glow: false)
        #expect(dark.textGlow == nil)
        #expect(dark.glowBox == nil)
        #expect(dark.cardElevation == nil)   // no elevation in dark

        let light = NeonTheme.resolve(palette: .ice, dark: false, glow: false)
        #expect(light.glowBox == nil)
        // light mode keeps a soft card elevation when glow is off
        #expect(light.cardElevation != nil)
    }

    @Test func glowColorIsBrightAccent() {
        let light = NeonTheme.resolve(palette: .ice, dark: false, glow: true)
        #expect(light.glowColor == Color(hex: "#22d3ee"))
    }

    // MARK: - AppearanceStore persistence round-trip

    @Test func persistsAndRestoresNeonPalette() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.neonPalette = .matrix

        let second = AppearanceStore(defaults: defaults)
        #expect(second.neonPalette == .matrix)
    }

    @Test func persistsAndRestoresNeonGlow() {
        let defaults = freshDefaults()
        let first = AppearanceStore(defaults: defaults)
        first.neonGlow = false

        let second = AppearanceStore(defaults: defaults)
        #expect(second.neonGlow == false)
    }

    @Test func freshInstallNeonDefaults() {
        let store = AppearanceStore(defaults: freshDefaults())
        #expect(store.neonPalette == .ice)
        #expect(store.neonGlow == true)
    }

    // MARK: - Helpers

    private func freshDefaults() -> UserDefaults {
        let suite = "swekitty.tests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
