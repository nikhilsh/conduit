package sh.nikhil.conduit.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
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
        assertEquals(14f, t.radiusDp)
    }

    @Test
    fun darkSemanticTokens() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertEquals(Color(0xFFFF9D4D), t.claude)
        assertEquals(Color(0xFF22D3EE), t.codex)      // fixed brand cyan
        assertEquals(Color(0xFFA3E635), t.opencode)   // lime — distinct from claude/codex
        assertEquals(Color(0xFFB487FF), t.purple)
        assertEquals(Color(0xFF4F8CFF), t.blue)        // == accent2
        assertEquals(Color(0xFF3EF0A0), t.green)
        assertEquals(Color(0xFFFF5C72), t.red)
        assertEquals(Color(0xFFFFD24D), t.yellow)
    }

    /**
     * Agent tints are palette-independent brand hues: in a NON-ice palette
     * (synth, whose accent is magenta) codex must still read brand cyan and
     * claude warm orange — not the palette accent. Locks the device-feedback
     * fix where codex changed color with the theme.
     */
    @Test
    fun agentTintsArePaletteIndependent() {
        val synth = NeonTheme.resolve(NeonPalette.SYNTH, dark = true, glow = true)
        assertEquals(Color(0xFF22D3EE), synth.codex)
        assertEquals(Color(0xFFFF9D4D), synth.claude)
        assertEquals(Color(0xFFA3E635), synth.opencode)
        // sanity: synth's own accent is NOT cyan, so codex differs from accent
        assertNotEquals(synth.accent, synth.codex)
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

    // region Streaming-states neutral chrome tokens (ghost / lineSoft)

    /**
     * ghost and lineSoft are mode-independent: identical ARGB in dark and
     * light (both branches produce the same rgb(160,184,224) base at the
     * specified alpha). Pins the exact ARGB so both platforms stay in sync.
     *
     * Derivation:
     *   ghost    alpha = round(0.24 * 255) = 61  = 0x3D
     *   lineSoft alpha = round(0.12 * 255) = 30  = 0x1E
     *   rgb(160,184,224) = 0xA0B8E0
     */
    @Test
    fun ghostTokenDarkIce() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertEquals(Color(0x3DA0B8E0.toInt()), t.ghost)
    }

    @Test
    fun lineSoftTokenDarkIce() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertEquals(Color(0x1EA0B8E0.toInt()), t.lineSoft)
    }

    @Test
    fun ghostTokenLightIce() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = true)
        assertEquals(Color(0x3DA0B8E0.toInt()), t.ghost)
    }

    @Test
    fun lineSoftTokenLightIce() {
        val t = NeonTheme.resolve(NeonPalette.ICE, dark = false, glow = true)
        assertEquals(Color(0x1EA0B8E0.toInt()), t.lineSoft)
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

    // region Chrome fonts are brand-locked (no serif leak)

    /**
     * [NeonTheme.sans]/[NeonTheme.mono] must always resolve the Terminal
     * pairing (Space Grotesk · JetBrains Mono) regardless of [NeonTheme.chatFont]
     * — chrome never follows the user's §4 chat-font pairing. Pins the
     * device-reported bug where an "Editorial" (Newsreader serif) pairing
     * rendered ALL chrome (buttons, headers) in serif.
     */
    @Test
    fun chromeFontsAreBrandLockedRegardlessOfChatFont() {
        val editorial = NeonTheme.resolve(
            NeonPalette.ICE,
            dark = true,
            glow = true,
            chatFont = sh.nikhil.conduit.AppearanceStore.FontFamily.Editorial,
        )
        assertEquals(NeonBrandFonts.sans, editorial.sans)
        assertEquals(NeonBrandFonts.mono, editorial.mono)

        val terminal = NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
        assertEquals(editorial.sans, terminal.sans)
        assertEquals(editorial.mono, terminal.mono)
    }

    /**
     * Chat prose keeps honouring the pairing — [neonProseFontFamily] /
     * [neonMonoFontFamily] resolve [NeonTheme.chatFont] directly (never
     * through [NeonTheme.sans]/[NeonTheme.mono]), so the Editorial pairing
     * still gets its Newsreader prose face.
     */
    @Test
    fun chatProsePairingStillResolvesIndependently() {
        val editorial = sh.nikhil.conduit.AppearanceStore.FontFamily.Editorial
        assertEquals(NeonBrandFonts.newsreader, neonProseFontFamily(editorial))
        assertEquals(NeonBrandFonts.splineSansMono, neonMonoFontFamily(editorial))
        assertNotEquals(NeonBrandFonts.sans, neonProseFontFamily(editorial))
    }

    // endregion
}
