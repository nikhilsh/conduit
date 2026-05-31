package sh.nikhil.conduit.ui

import android.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import sh.nikhil.conduit.AppearanceStore

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/TerminalPaletteThemeTests.swift`.
 * Locks the theme-aware palette resolution that [TermuxTerminalView]
 * reads from [AppearanceStore]. The palette itself is pure data over
 * Android ARGB ints — but the constants call [Color.argb], which is a
 * stub in plain JUnit and returns zero, so we run under Robolectric.
 *
 * If the iOS and Android palettes diverge, both suites should be
 * updated together — the comments here mirror the iOS tests'
 * rationale so a reviewer can compare line-for-line.
 */
@RunWith(RobolectricTestRunner::class)
class TerminalPaletteThemeTest {

    // --- Explicit light vs dark divergence -----------------------

    @Test
    fun lightAndDarkPalettes_haveDifferentDefaultBackgrounds() {
        // The whole point of the split: a light theme paints a near-
        // white background; a dark theme paints black. Aliasing the
        // two backgrounds in a future palette refresh would silently
        // produce a "themed" terminal that looks identical in both
        // modes; this catches that.
        assertNotEquals(
            TerminalPalette.LIGHT.defaultBackground,
            TerminalPalette.DARK.defaultBackground,
        )
    }

    @Test
    fun lightAndDarkPalettes_haveDifferentDefaultForegrounds() {
        assertNotEquals(
            TerminalPalette.LIGHT.defaultForeground,
            TerminalPalette.DARK.defaultForeground,
        )
    }

    @Test
    fun lightPaletteBackground_isBrighterThanDark() {
        val lightBg = brightness(TerminalPalette.LIGHT.defaultBackground)
        val darkBg = brightness(TerminalPalette.DARK.defaultBackground)
        assertTrue(
            "light bg ($lightBg) should be brighter than dark bg ($darkBg)",
            lightBg > darkBg,
        )
    }

    @Test
    fun lightPaletteForeground_isDarkerThanDarkPaletteForeground() {
        val lightFg = brightness(TerminalPalette.LIGHT.defaultForeground)
        val darkFg = brightness(TerminalPalette.DARK.defaultForeground)
        assertTrue(
            "light fg ($lightFg) should be darker than dark fg ($darkFg)",
            lightFg < darkFg,
        )
    }

    // --- forMode routing -----------------------------------------

    @Test
    fun explicitDarkMode_resolvesToDarkPalette() {
        // An explicit `.Dark` user choice should win even when the
        // system is in light mode. Protects the user who has forced
        // dark while the OS is still in light.
        val p = TerminalPalette.forMode(AppearanceStore.ThemeMode.Dark, isSystemDark = false)
        assertEquals(TerminalPalette.DARK.defaultBackground, p.defaultBackground)
    }

    @Test
    fun explicitLightMode_resolvesToLightPalette() {
        val p = TerminalPalette.forMode(AppearanceStore.ThemeMode.Light, isSystemDark = true)
        assertEquals(TerminalPalette.LIGHT.defaultBackground, p.defaultBackground)
    }

    @Test
    fun systemMode_followsTheIsSystemDarkSignal() {
        val darkResolved = TerminalPalette.forMode(
            AppearanceStore.ThemeMode.System,
            isSystemDark = true,
        )
        val lightResolved = TerminalPalette.forMode(
            AppearanceStore.ThemeMode.System,
            isSystemDark = false,
        )
        assertEquals(TerminalPalette.DARK.defaultBackground, darkResolved.defaultBackground)
        assertEquals(TerminalPalette.LIGHT.defaultBackground, lightResolved.defaultBackground)
    }

    // --- ANSI slot count -----------------------------------------

    @Test
    fun bothPalettes_haveSixteenANSISlots() {
        // The xterm-256 colour cube relies on `palette.ansi[0..15]`
        // being safe to index; catch a future palette edit that
        // drops or duplicates a slot.
        assertEquals(16, TerminalPalette.LIGHT.ansi.size)
        assertEquals(16, TerminalPalette.DARK.ansi.size)
    }

    // --- Curated terminal themes (iOS GhosttyTheme parity) -------

    @Test
    fun allFiveTerminalThemes_resolveToSixteenANSISlots() {
        // Each curated theme must carry a full 16-slot ANSI table so the
        // xterm-256 cube + Termux colour table can index 0..15 safely.
        for (t in AppearanceStore.TerminalTheme.values()) {
            assertEquals(16, TerminalPalette.forTheme(t).ansi.size)
        }
    }

    @Test
    fun terminalThemes_matchIOSGhosttyThemeHexValues() {
        // The whole point of reading the values from iOS' GhosttyTheme:
        // the two platforms must render identically. Lock the bg/fg of
        // each theme to the exact `#rrggbb` iOS ships (see
        // apps/ios/GhosttyVT/Sources/GhosttyVT/Terminal.swift).
        assertEquals("#1d1f21", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.GhosttyDark).defaultBackground))
        assertEquals("#c5c8c6", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.GhosttyDark).defaultForeground))
        assertEquals("#002b36", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.SolarizedDark).defaultBackground))
        assertEquals("#2e3440", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.Nord).defaultBackground))
        assertEquals("#282a36", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.Dracula).defaultBackground))
        assertEquals("#282828", TerminalPalette.toHex(
            TerminalPalette.forTheme(AppearanceStore.TerminalTheme.GruvboxDark).defaultBackground))
    }

    @Test
    fun draculaRedANSISlot_matchesIOS() {
        // Spot-check an ANSI slot too (index 1 = red) so a future palette
        // edit that shifts the cube is caught, not just the defaults.
        assertEquals(
            "#ff5555",
            TerminalPalette.toHex(
                TerminalPalette.forTheme(AppearanceStore.TerminalTheme.Dracula).ansi[1],
            ),
        )
    }

    @Test
    fun xtermThemeJson_carriesBackgroundForegroundCursorAndAllSixteenSlots() {
        val json = TerminalPalette.xtermThemeJson(AppearanceStore.TerminalTheme.GhosttyDark)
        assertTrue("has background", json.contains("\"background\":\"#1d1f21\""))
        assertTrue("has foreground", json.contains("\"foreground\":\"#c5c8c6\""))
        assertTrue("has cursor", json.contains("\"cursor\":\"#c5c8c6\""))
        // Named ANSI keys xterm.js expects.
        assertTrue("has black", json.contains("\"black\":"))
        assertTrue("has brightWhite", json.contains("\"brightWhite\":\"#eaeaea\""))
        assertTrue("has red", json.contains("\"red\":\"#cc6666\""))
    }

    // --- Helpers -------------------------------------------------

    /** Crude perceived brightness: sum of RGB channel values. */
    private fun brightness(argb: Int): Int {
        return Color.red(argb) + Color.green(argb) + Color.blue(argb)
    }
}
