package sh.nikhil.conduit.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of iOS `NeonThemeTests`. Pins the Neon Terminal token
 * resolver to the documented values for dark-Ice + light-Ice, the
 * palette id/label mapping, and the glow descriptor rules. Compose
 * [Color] is a data-like value with structural equality, so each token
 * is compared against a `Color(0xAARRGGBB)` literal built the same way
 * the resolver builds it.
 *
 * Pure JVM (no Robolectric / Compose runtime needed) — `Color` and
 * `NeonTheme.resolve` are plain values. The AppearanceStore round-trip
 * for the two new neon prefs lives in the Robolectric
 * `AppearanceStoreTerminalTest` siblings; this file pins the resolver.
 */
class NeonThemeTest {

    // region Palette id / label mapping

    @Test
    fun paletteIdsAndLabels() {
        assertEquals("ice", NeonPalette.ICE.id)
        assertEquals("synth", NeonPalette.SYNTH.id)
        assertEquals("matrix", NeonPalette.MATRIX.id)
        assertEquals("amber", NeonPalette.AMBER.id)

        assertEquals("Ice", NeonPalette.ICE.label)
        assertEquals("Synthwave", NeonPalette.SYNTH.label)
        assertEquals("Matrix", NeonPalette.MATRIX.label)
        assertEquals("Amber CRT", NeonPalette.AMBER.label)

        assertEquals(4, NeonPalette.entries.size)
    }

    @Test
    fun fromIdResolvesAndFallsBack() {
        assertEquals(NeonPalette.MATRIX, NeonPalette.fromId("matrix"))
        assertEquals(NeonPalette.ICE, NeonPalette.fromId(null))
        assertEquals(NeonPalette.ICE, NeonPalette.fromId("not-a-palette"))
    }

    // endregion

    // region Dark / Ice tokens

    @Test
    fun darkIceCoreTokens() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertTrue(t.dark)
        assertEquals("dark", t.mode)
        // accent == bright accent in dark mode
        assertEquals(Color(0xFF22D3EE), t.accent)
        assertEquals(Color(0xFF22D3EE), t.accentBright)
        assertEquals(Color(0xFF4F8CFF), t.accent2)
        assertEquals(Color(0xFF04050A), t.bg)
        assertEquals(Color(0xFF0A1120), t.surfaceSolid)
        assertEquals(Color(0xFF0B1322), t.panel)
        assertEquals(Color(0xFFEAF3FF), t.text)
        assertEquals(Color(0xFF03121A), t.accentText)
        // border = accent at 0x22 alpha (ARGB 0x22_22D3EE)
        assertEquals(Color(0x2222D3EE), t.border)
        assertEquals(Color(0x4422D3EE), t.borderStrong)
        assertEquals(Color(0x0E22D3EE), t.grid)
        // codeText defaults to text in dark
        assertEquals(t.text, t.codeText)
        assertEquals(20f, t.radiusDp)
    }

    @Test
    fun darkSemanticTokens() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertEquals(Color(0xFFFF9D4D), t.claude)
        assertEquals(Color(0xFF22D3EE), t.codex)      // == bright accent
        assertEquals(Color(0xFFB487FF), t.purple)
        assertEquals(Color(0xFF4F8CFF), t.blue)        // == accent2
        assertEquals(Color(0xFF3EF0A0), t.green)
        assertEquals(Color(0xFFFF5C72), t.red)
        assertEquals(Color(0xFFFFD24D), t.yellow)
    }

    // endregion

    // region Light / Ice tokens

    @Test
    fun lightIceCoreTokens() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = true)
        assertFalse(t.dark)
        assertEquals("light", t.mode)
        // accent switches to the darker accent in light mode
        assertEquals(Color(0xFF0A93AD), t.accent)
        // bright accent retained for glows / badges
        assertEquals(Color(0xFF22D3EE), t.accentBright)
        assertEquals(Color(0xFFDFE6F2), t.bg)
        assertEquals(Color(0xFFFFFFFF), t.surface2)
        assertEquals(Color(0xFFFFFFFF), t.surfaceSolid)
        assertEquals(Color(0xFFF4F7FC), t.panel)
        assertEquals(Color(0xFF0D1A30), t.text)
        assertEquals(Color(0xFFFFFFFF), t.accentText)
        // borderStrong = accentDark at 0x55 alpha (ARGB 0x55_0A93AD)
        assertEquals(Color(0x550A93AD), t.borderStrong)
        // Code blocks stay DARK in light mode.
        assertEquals(Color(0xFF0C1322), t.codeBg)
        assertEquals(Color(0xFFD6E6FF), t.codeText)
    }

    // endregion

    // region Glow descriptors

    @Test
    fun textGlowOnlyInDark() {
        val dark = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertTrue(dark.textGlowEnabled)
        assertNotNull(dark.textGlow)
        assertNotNull(dark.glowBox)
        assertNull(dark.cardElevation)

        val light = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = true)
        // text-shadow glow is always off in light mode
        assertFalse(light.textGlowEnabled)
        assertNull(light.textGlow)
        // box glow still present (softened) in light mode
        assertNotNull(light.glowBox)
    }

    @Test
    fun glowOffDropsShadows() {
        val dark = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = false)
        assertNull(dark.textGlow)
        assertNull(dark.glowBox)
        assertNull(dark.cardElevation)   // no elevation in dark

        val light = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = false)
        assertNull(light.glowBox)
        // light mode keeps a soft card elevation when glow is off
        assertNotNull(light.cardElevation)
    }

    @Test
    fun glowColorIsBrightAccent() {
        val light = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = true)
        assertEquals(Color(0xFF22D3EE), light.glowColor)
    }

    // endregion
}
