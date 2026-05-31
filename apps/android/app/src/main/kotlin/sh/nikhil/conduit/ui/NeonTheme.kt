package sh.nikhil.conduit.ui

import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color

/**
 * "Neon Terminal" theme system — Android mirror of
 * `apps/ios/Sources/Theme/NeonTheme.swift`. Same four palettes, same
 * light/dark token resolution, same glow descriptors. Both platforms
 * must stay value-for-value in sync (the unit tests on each side pin the
 * exact ARGB / hex values for dark-Ice + light-Ice).
 *
 * Scope is the theme SYSTEM only (palettes + resolver + glow descriptors
 * + CompositionLocal injection). Later card work consumes the resolved
 * [NeonTheme] (including glow) from [LocalNeonTheme]; nothing renders the
 * glow yet.
 *
 * User choices feeding the resolver:
 *   - palette : [NeonPalette] (Ice / Synthwave / Matrix / Amber CRT)
 *   - dark    : derived from `AppearanceStore.themeMode` resolved against
 *               `isSystemInDarkTheme()` (System → follow OS), exactly as
 *               [LocalUseDarkTheme] is computed in MainActivity
 *   - glow    : Boolean on/off
 * Palette + glow are persisted by `AppearanceStore`; mode reuses the
 * existing themeMode mechanism.
 */
enum class NeonPalette(
    val id: String,
    val label: String,
    /** Bright accent (`A`) — used directly in dark mode. */
    val accent: Long,
    /** Secondary accent (`accent2` / `A2`). */
    val accent2: Long,
    /** Darker accent — the primary accent in LIGHT mode. */
    val accentDark: Long,
) {
    ICE("ice", "Ice", 0xFF22D3EE, 0xFF4F8CFF, 0xFF0A93AD),
    SYNTH("synth", "Synthwave", 0xFFFF49E0, 0xFF22D3EE, 0xFFC01EA6),
    MATRIX("matrix", "Matrix", 0xFF39F08A, 0xFFB6F23D, 0xFF14A85C),
    AMBER("amber", "Amber CRT", 0xFFFFB627, 0xFFFF7847, 0xFFC6810A);

    companion object {
        /** Resolve a persisted id back to a palette (fallback [ICE]). */
        fun fromId(id: String?): NeonPalette =
            entries.firstOrNull { it.id == id } ?: ICE
    }
}

// region Glow descriptors
//
// Glow renders as layered shadows (README §3.5). Nothing renders these
// yet, but the resolved theme carries them so step-3 card work can
// consume the rules without recomputing:
//   - text glow (dark only): 0 0 6px {c}CC, 0 0 16px {c}66 (× strength)
//   - box glow:              0 0 10px {c}33, 0 0 26px {c}1F ; light ×0.5
//   - glow OFF: no shadow (borderStrong hairline instead); light mode
//     keeps a soft card elevation 0 4px 16px rgba(13,26,48,0.10).

/** A single layered shadow (`0 0 <radiusDp> <color>`). */
data class NeonShadowLayer(val radiusDp: Float, val color: Color)

/** Box-glow descriptor (two layers). Radii are pre-scaled for the active
 *  mode (×0.5 in light mode). */
data class NeonGlowBox(val inner: NeonShadowLayer, val outer: NeonShadowLayer)

/** Text-glow descriptor — `null` in light mode and when glow is off. */
data class NeonTextGlow(val inner: NeonShadowLayer, val outer: NeonShadowLayer)

/** Soft card elevation used in LIGHT mode when glow is OFF
 *  (`0 4px 16px rgba(13,26,48,0.10)`). */
data class NeonCardElevation(val radiusDp: Float, val yOffsetDp: Float, val color: Color)
// endregion

/**
 * Fully resolved Neon Terminal token set for one (palette, dark, glow)
 * combination. Every token from iOS `makeNeon()` is present as a Compose
 * [Color], plus the [appBg] gradient and glow descriptors.
 */
data class NeonTheme(
    // Identity / inputs
    val paletteId: String,
    val mode: String,        // "dark" | "light"
    val dark: Boolean,
    val glow: Boolean,

    // Accents
    val accent: Color,
    val accent2: Color,
    /** Bright accent — equals [accent] in dark mode, the bright palette
     *  accent in light mode (where [accent] is the darker variant). */
    val accentBright: Color,

    // Brand / semantic
    val claude: Color,
    val codex: Color,
    val purple: Color,
    val blue: Color,
    val green: Color,
    val red: Color,
    val yellow: Color,

    // Surfaces / chrome
    val bg: Color,
    val surface: Color,
    val surface2: Color,
    val surfaceSolid: Color,
    val panel: Color,
    val border: Color,
    val borderStrong: Color,
    val grid: Color,

    // Text
    val text: Color,
    val textDim: Color,
    val textFaint: Color,
    val accentText: Color,

    // Code
    val codeBg: Color,
    val codeText: Color,

    // Shape
    val radiusDp: Float,

    // Background gradient (approximates the CSS radial-gradient stops).
    val appBg: Brush,

    // Glow
    val glowColor: Color,
    val textGlowEnabled: Boolean,
    val textGlow: NeonTextGlow?,
    val glowBox: NeonGlowBox?,
    val cardElevation: NeonCardElevation?,
) {
    /**
     * Type intent (README §3.4): sans = Space Grotesk → system sans;
     * mono = JetBrains Mono → system monospace. No font assets are
     * bundled. Exposed as [androidx.compose.ui.text.font.FontFamily]
     * accessors mirroring the iOS `sans`/`mono` helpers.
     */
    val sans: androidx.compose.ui.text.font.FontFamily
        get() = androidx.compose.ui.text.font.FontFamily.SansSerif
    val mono: androidx.compose.ui.text.font.FontFamily
        get() = androidx.compose.ui.text.font.FontFamily.Monospace

    companion object {
        const val RADIUS_DP: Float = 20f

        /** Tint a `0xRRGGBB`-style base ARGB to an 8-bit alpha byte
         *  (`0..255`). Mirrors the CSS `{color}AA` hex-alpha suffix used
         *  throughout the neon tokens (e.g. border = accent + 0x22). The
         *  base [rgb] is expected to be opaque (0xFF... ) — its own alpha
         *  byte is replaced. */
        private fun withAlpha(rgb: Long, alpha: Int): Color {
            val base = rgb and 0x00FFFFFF
            return Color((alpha.toLong() shl 24) or base)
        }

        /** Resolve the token set for a (palette, dark, glow) combination.
         *  Reproduces iOS `NeonTheme.resolve(...)` / `makeNeon(...)`. */
        fun resolve(palette: NeonPalette, dark: Boolean, glow: Boolean): NeonTheme {
            val aBright = Color(palette.accent)            // A
            val a2 = Color(palette.accent2)                // A2
            val accent = if (dark) aBright else Color(palette.accentDark)

            // Common (mode-independent) brand/semantic tokens.
            val claude = if (dark) Color(0xFFFF9D4D) else Color(0xFFD9731A)
            val codex = aBright
            val purple = if (dark) Color(0xFFB487FF) else Color(0xFF7A48D8)
            val blue = a2
            val green = if (dark) Color(0xFF3EF0A0) else Color(0xFF12A866)
            val red = if (dark) Color(0xFFFF5C72) else Color(0xFFD83048)
            val yellow = if (dark) Color(0xFFFFD24D) else Color(0xFFC79200)

            val bg: Color
            val surface: Color
            val surface2: Color
            val surfaceSolid: Color
            val panel: Color
            val border: Color
            val borderStrong: Color
            val grid: Color
            val text: Color
            val textDim: Color
            val textFaint: Color
            val accentText: Color
            val codeBg: Color
            val codeText: Color
            val appBg: Brush

            if (dark) {
                bg = Color(0xFF04050A)
                surface = Color(red = 16, green = 24, blue = 42, alpha = (0.66f * 255).toInt())
                surface2 = Color(red = 26, green = 38, blue = 64, alpha = (0.74f * 255).toInt())
                surfaceSolid = Color(0xFF0A1120)
                panel = Color(0xFF0B1322)
                border = withAlpha(palette.accent, 0x22)
                borderStrong = withAlpha(palette.accent, 0x44)
                grid = withAlpha(palette.accent, 0x0E)
                text = Color(0xFFEAF3FF)
                textDim = Color(red = 196, green = 214, blue = 244, alpha = (0.66f * 255).toInt())
                textFaint = Color(red = 160, green = 184, blue = 224, alpha = (0.40f * 255).toInt())
                accentText = Color(0xFF03121A)
                codeBg = Color(red = 0, green = 4, blue = 12, alpha = (0.6f * 255).toInt())
                codeText = text
                // radial-gradient(... {A}14, #0a1020 34%, #05060d 70%, #04050a 100%)
                appBg = Brush.radialGradient(
                    colorStops = arrayOf(
                        0.0f to withAlpha(palette.accent, 0x14),
                        0.34f to Color(0xFF0A1020),
                        0.70f to Color(0xFF05060D),
                        1.0f to Color(0xFF04050A),
                    ),
                    center = Offset.Unspecified,
                    radius = Float.POSITIVE_INFINITY,
                )
            } else {
                bg = Color(0xFFDFE6F2)
                surface = Color(red = 255, green = 255, blue = 255, alpha = (0.8f * 255).toInt())
                surface2 = Color(0xFFFFFFFF)
                surfaceSolid = Color(0xFFFFFFFF)
                panel = Color(0xFFF4F7FC)
                border = Color(red = 18, green = 32, blue = 58, alpha = (0.12f * 255).toInt())
                borderStrong = withAlpha(palette.accentDark, 0x55)
                grid = Color(red = 18, green = 32, blue = 58, alpha = (0.05f * 255).toInt())
                text = Color(0xFF0D1A30)
                textDim = Color(red = 28, green = 46, blue = 78, alpha = (0.66f * 255).toInt())
                textFaint = Color(red = 40, green = 60, blue = 96, alpha = (0.42f * 255).toInt())
                accentText = Color(0xFFFFFFFF)
                codeBg = Color(0xFF0C1322)   // code stays DARK in light mode
                codeText = Color(0xFFD6E6FF)
                // radial-gradient(... {A}1f, #eef3fb 40%, #e7edf7 100%)
                appBg = Brush.radialGradient(
                    colorStops = arrayOf(
                        0.0f to withAlpha(palette.accent, 0x1F),
                        0.40f to Color(0xFFEEF3FB),
                        1.0f to Color(0xFFE7EDF7),
                    ),
                    center = Offset.Unspecified,
                    radius = Float.POSITIVE_INFINITY,
                )
            }

            // Glow descriptors. Glow colour is the bright accent.
            val glowColor = aBright
            val textGlowEnabled = dark && glow
            val textGlow: NeonTextGlow? = if (textGlowEnabled) {
                NeonTextGlow(
                    inner = NeonShadowLayer(6f, aBright.copy(alpha = 0.80f)),
                    outer = NeonShadowLayer(16f, aBright.copy(alpha = 0.40f)),
                )
            } else {
                null
            }

            val glowBox: NeonGlowBox?
            val cardElevation: NeonCardElevation?
            if (glow) {
                val scale = if (dark) 1.0f else 0.5f
                glowBox = NeonGlowBox(
                    inner = NeonShadowLayer(10f * scale, aBright.copy(alpha = 0.20f)),
                    outer = NeonShadowLayer(26f * scale, aBright.copy(alpha = 0.12f)),
                )
                cardElevation = null
            } else {
                glowBox = null
                cardElevation = if (dark) {
                    null
                } else {
                    NeonCardElevation(
                        radiusDp = 16f,
                        yOffsetDp = 4f,
                        color = Color(red = 13, green = 26, blue = 48, alpha = (0.10f * 255).toInt()),
                    )
                }
            }

            return NeonTheme(
                paletteId = palette.id,
                mode = if (dark) "dark" else "light",
                dark = dark,
                glow = glow,
                accent = accent,
                accent2 = a2,
                accentBright = aBright,
                claude = claude,
                codex = codex,
                purple = purple,
                blue = blue,
                green = green,
                red = red,
                yellow = yellow,
                bg = bg,
                surface = surface,
                surface2 = surface2,
                surfaceSolid = surfaceSolid,
                panel = panel,
                border = border,
                borderStrong = borderStrong,
                grid = grid,
                text = text,
                textDim = textDim,
                textFaint = textFaint,
                accentText = accentText,
                codeBg = codeBg,
                codeText = codeText,
                radiusDp = RADIUS_DP,
                appBg = appBg,
                glowColor = glowColor,
                textGlowEnabled = textGlowEnabled,
                textGlow = textGlow,
                glowBox = glowBox,
                cardElevation = cardElevation,
            )
        }
    }
}

/**
 * CompositionLocal carrying the resolved [NeonTheme]. Wired in
 * MainActivity from `AppearanceStore.themeMode` + `neonPalette` +
 * `neonGlow` + `isSystemInDarkTheme()`, next to [LocalAppearanceStore] /
 * [LocalUseDarkTheme]. Default is dark Ice with glow on so detached
 * previews still render.
 */
val LocalNeonTheme = staticCompositionLocalOf<NeonTheme> {
    NeonTheme.resolve(NeonPalette.ICE, dark = true, glow = true)
}
