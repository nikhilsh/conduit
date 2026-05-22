import Testing
import UIKit
@testable import SweKitty

/// Stage 3.1 — locks the theme-aware palette resolution that
/// `GhosttyTerminalView` reads from `AppearanceStore`. The palette
/// itself is pure data over `UIColor`, so these tests stand up no
/// view hierarchy.
///
/// Mirrors the Android `TerminalPaletteThemeTest` (Robolectric-free
/// JUnit). If the two diverge — e.g. someone re-flavours only the
/// iOS dark palette — the platform-parity defence is the comment on
/// each test, not a generated check; reviewers should re-run both
/// suites when touching either side.
@Suite("TerminalPalette theme resolution")
struct TerminalPaletteThemeTests {

    // MARK: - Explicit light vs dark divergence

    @Test func lightAndDarkPalettesHaveDifferentDefaultBackgrounds() {
        // The whole point of the split: a light theme should paint a
        // near-white background and a dark theme should paint black.
        // If a future palette refresh accidentally aliases them (e.g.
        // sets both `defaultBackground` to the same UIColor) this
        // assertion catches it before users see a "themed" terminal
        // that looks identical in both modes.
        #expect(TerminalPalette.light.defaultBackground != TerminalPalette.dark.defaultBackground)
    }

    @Test func lightAndDarkPalettesHaveDifferentDefaultForegrounds() {
        #expect(TerminalPalette.light.defaultForeground != TerminalPalette.dark.defaultForeground)
    }

    @Test func lightPaletteBackgroundIsBrighterThanDark() {
        // Sanity check on the polarity. RGB sum is a cheap proxy for
        // luminance — fine for "is white-ish brighter than black-ish".
        let lightBg = brightness(TerminalPalette.light.defaultBackground)
        let darkBg = brightness(TerminalPalette.dark.defaultBackground)
        #expect(lightBg > darkBg)
    }

    @Test func lightPaletteForegroundIsDarkerThanDark() {
        // On a white surface the foreground should be dark (high
        // contrast), opposite of the dark theme.
        let lightFg = brightness(TerminalPalette.light.defaultForeground)
        let darkFg = brightness(TerminalPalette.dark.defaultForeground)
        #expect(lightFg < darkFg)
    }

    // MARK: - palette(for:systemStyle:) routing

    @Test func explicitDarkModeResolvesToDarkPalette() {
        let p = TerminalPalette.palette(for: .dark, systemStyle: .light)
        // Even when the system style says light, an explicit `.dark`
        // user choice should win. This is what protects a user who
        // has forced dark mode while the OS is still in light.
        #expect(p.defaultBackground == TerminalPalette.dark.defaultBackground)
    }

    @Test func explicitLightModeResolvesToLightPalette() {
        let p = TerminalPalette.palette(for: .light, systemStyle: .dark)
        #expect(p.defaultBackground == TerminalPalette.light.defaultBackground)
    }

    @Test func systemModeDefersToSuppliedUIStyle() {
        let darkResolved = TerminalPalette.palette(for: .system, systemStyle: .dark)
        let lightResolved = TerminalPalette.palette(for: .system, systemStyle: .light)
        #expect(darkResolved.defaultBackground == TerminalPalette.dark.defaultBackground)
        #expect(lightResolved.defaultBackground == TerminalPalette.light.defaultBackground)
    }

    @Test func systemModeWithUnspecifiedStyleFallsBackToDark() {
        // `.unspecified` shows up in test processes where no window
        // scene has decided yet. We pick `.dark` as the fallback so a
        // pre-attach paint matches the historical Stage 3 behaviour
        // (the renderer was dark-only before this PR).
        let p = TerminalPalette.palette(for: .system, systemStyle: .unspecified)
        #expect(p.defaultBackground == TerminalPalette.dark.defaultBackground)
    }

    // MARK: - ANSI slot count

    @Test func bothPalettesHaveSixteenANSISlots() {
        // The xterm 256-color cube relies on `palette.ansi[0..15]`
        // being safe to index. Catch a future palette edit that
        // accidentally drops or duplicates a slot.
        #expect(TerminalPalette.light.ansi.count == 16)
        #expect(TerminalPalette.dark.ansi.count == 16)
    }

    // MARK: - Helpers

    /// Crude perceived brightness: sum of RGB channel values. Adequate
    /// for "is colour A brighter than colour B" — full Rec. 709 luma
    /// would be more correct but is overkill for the polarity check.
    private func brightness(_ color: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return r + g + b
    }
}
