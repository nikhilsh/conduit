package sh.nikhil.conduit.ui

import androidx.compose.material3.ColorScheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * Effective dark-mode flag for the rendered tree. Provided by the
 * activity once it has resolved `AppearanceStore.themeMode` against
 * the system theme (System → follow OS, Light/Dark → force). All
 * palette lookups read this rather than `isSystemInDarkTheme()` so a
 * user-forced Light/Dark stays consistent across surfaces — including
 * sheets, dialogs, and any other window that inherits the parent
 * composition. Without this we ended up half-dark when the user
 * override disagreed with the OS theme.
 */
val LocalUseDarkTheme = compositionLocalOf { false }

/**
 * Compose mirror of `apps/ios/Sources/Theme/Palette.swift` +
 * `Theme.swift`. Same hex values, same semantic tokens. The composables
 * here resolve to light/dark via [LocalUseDarkTheme] so call sites
 * read like `ConduitTheme.accentStrong()` rather than threading a
 * `ColorScheme` parameter.
 */
internal data class AdaptiveColor(val light: Long, val dark: Long) {
    @Composable @ReadOnlyComposable
    fun color(): Color = if (LocalUseDarkTheme.current) Color(dark) else Color(light)
}

internal object ConduitPalette {
    val accent          = AdaptiveColor(0xFF4A4A4A, 0xFFB0B0B0)
    // Conduit redesign: primary brand accent is the ice cyan
    // (--cyan #22D3EE, BRAND.md §3). Dark ships first, so the dark value
    // is canonical; light is deepened for legibility. (See iOS
    // ConduitUI.Palette.brand.)
    val accentStrong    = AdaptiveColor(0xFF0FB5D6, 0xFF22D3EE)
    // Claude agent tint — warm orange (--claude #FF9D4D), confirmed
    // against the target art.
    val claudeAccent    = AdaptiveColor(0xFFE07A1E, 0xFFFF9D4D)
    val claudeAccentStrong = AdaptiveColor(0xFFC2630F, 0xFFFFB264)
    // Codex agent tint — brand cyan (#22D3EE). Matches the primary
    // accent on purpose in the ice palette.
    val codexAccent     = AdaptiveColor(0xFF0E90A8, 0xFF22D3EE)
    val codexAccentStrong  = AdaptiveColor(0xFF0A7E95, 0xFF5BDFF2)
    // Hermes purple — Tailwind purple-500. No public Hermes adapter
    // brand to anchor to, so this is a defensible choice that contrasts
    // cleanly with claude/codex.
    val hermesAccent    = AdaptiveColor(0xFFA855F7, 0xFFC084FC)
    val hermesAccentStrong = AdaptiveColor(0xFF7E22CE, 0xFFA855F7)
    // Inflection Pi blue — Tailwind blue-500.
    val piAccent        = AdaptiveColor(0xFF3B82F6, 0xFF60A5FA)
    val piAccentStrong  = AdaptiveColor(0xFF1D4ED8, 0xFF3B82F6)
    // opencode lime — Tailwind lime-400 (#A3E635) dark / lime-700 (#6B9A0F) light.
    // opencode.ai's brand is intentionally monochromatic gray; lime is chosen
    // for the neon palette because it is distinct from claude (orange) and
    // codex (cyan), evokes open-source terminal culture, and sits in the same
    // vibrancy band as the other agent tints. Matches the NeonTheme opencode token.
    val opencodeAccent  = AdaptiveColor(0xFF6B9A0F, 0xFFA3E635)
    val opencodeAccentStrong = AdaptiveColor(0xFF4A6A08, 0xFF84CC16)
    val textPrimary     = AdaptiveColor(0xFF1A1A1A, 0xFFFFFFFF)
    val textSecondary   = AdaptiveColor(0xFF6B6B6B, 0xFF888888)
    val textMuted       = AdaptiveColor(0xFF9E9E9E, 0xFF555555)
    val textBody        = AdaptiveColor(0xFF2D2D2D, 0xFFE0E0E0)
    val textOnAccent    = AdaptiveColor(0xFFFFFFFF, 0xFF0D0D0D)
    val surface         = AdaptiveColor(0xFFF2F2F7, 0xFF1A1A1A)
    val surfaceLight    = AdaptiveColor(0xFFE5E5EA, 0xFF2A2A2A)
    val border          = AdaptiveColor(0xFFD1D1D6, 0xFF333333)
    val separator       = AdaptiveColor(0xFFE0E0E0, 0xFF1E1E1E)
    val danger          = AdaptiveColor(0xFFD32F2F, 0xFFFF5555)
    val success         = AdaptiveColor(0xFF2E7D32, 0xFF6EA676)
    val warning         = AdaptiveColor(0xFFE65100, 0xFFE2A644)
    val background      = AdaptiveColor(0xFFFAFAFA, 0xFF0C0E12)
}

object ConduitTheme {
    @Composable @ReadOnlyComposable fun accent()          : Color = ConduitPalette.accent.color()
    @Composable @ReadOnlyComposable fun accentStrong()    : Color = ConduitPalette.accentStrong.color()
    @Composable @ReadOnlyComposable fun claudeAccent()    : Color = ConduitPalette.claudeAccent.color()
    @Composable @ReadOnlyComposable fun codexAccent()     : Color = ConduitPalette.codexAccent.color()
    @Composable @ReadOnlyComposable fun hermesAccent()    : Color = ConduitPalette.hermesAccent.color()
    @Composable @ReadOnlyComposable fun piAccent()        : Color = ConduitPalette.piAccent.color()
    @Composable @ReadOnlyComposable fun opencodeAccent()  : Color = ConduitPalette.opencodeAccent.color()

    /**
     * Per-agent accent. Each adapter that ships with the harness gets
     * a distinct hue — Claude copper, Codex mono (white/black, matching
     * OpenAI's monochrome brand), Hermes purple, Pi blue, opencode
     * orange. Falls back to the neutral gray [accent] for unknown
     * agents (rather than the copper brand accent, so an unknown agent
     * doesn't masquerade as Claude).
     */
    @Composable @ReadOnlyComposable
    fun accent(forAgent: String): Color = when (forAgent.lowercase()) {
        "claude"   -> claudeAccent()
        "codex"    -> codexAccent()
        "hermes"   -> hermesAccent()
        "pi"       -> piAccent()
        "opencode" -> opencodeAccent()
        else       -> accent()
    }

    /**
     * High-emphasis sibling of [accent]. Use for filled avatars, the
     * user-bubble background on agent-tinted surfaces, or any chrome
     * where the regular accent reads too light against
     * [textOnAccent]. Same fallback policy: neutral gray for unknown.
     */
    @Composable @ReadOnlyComposable
    fun accentStrong(forAgent: String): Color = when (forAgent.lowercase()) {
        "claude"   -> ConduitPalette.claudeAccentStrong.color()
        "codex"    -> ConduitPalette.codexAccentStrong.color()
        "hermes"   -> ConduitPalette.hermesAccentStrong.color()
        "pi"       -> ConduitPalette.piAccentStrong.color()
        "opencode" -> ConduitPalette.opencodeAccentStrong.color()
        else       -> accent()
    }

    /**
     * Pure (non-Composable) per-agent light-mode RGB. Lives here so
     * unit tests can pin the color map without instantiating a
     * Compose runtime — JUnit isn't a Composable scope. The
     * Composable [accent] above is still the call site for the
     * actual UI; this just exposes the same source-of-truth list
     * for parity tests.
     */
    fun accentForAgentLightRgb(forAgent: String): Long = when (forAgent.lowercase()) {
        "claude"   -> ConduitPalette.claudeAccent.light
        "codex"    -> ConduitPalette.codexAccent.light
        "hermes"   -> ConduitPalette.hermesAccent.light
        "pi"       -> ConduitPalette.piAccent.light
        "opencode" -> ConduitPalette.opencodeAccent.light
        else       -> ConduitPalette.accent.light
    }

    fun accentStrongForAgentLightRgb(forAgent: String): Long = when (forAgent.lowercase()) {
        "claude"   -> ConduitPalette.claudeAccentStrong.light
        "codex"    -> ConduitPalette.codexAccentStrong.light
        "hermes"   -> ConduitPalette.hermesAccentStrong.light
        "pi"       -> ConduitPalette.piAccentStrong.light
        "opencode" -> ConduitPalette.opencodeAccentStrong.light
        else       -> ConduitPalette.accent.light
    }
    @Composable @ReadOnlyComposable fun textPrimary()   : Color = ConduitPalette.textPrimary.color()
    @Composable @ReadOnlyComposable fun textSecondary() : Color = ConduitPalette.textSecondary.color()
    @Composable @ReadOnlyComposable fun textMuted()     : Color = ConduitPalette.textMuted.color()
    @Composable @ReadOnlyComposable fun textBody()      : Color = ConduitPalette.textBody.color()
    @Composable @ReadOnlyComposable fun textOnAccent()  : Color = ConduitPalette.textOnAccent.color()
    @Composable @ReadOnlyComposable fun surface()       : Color = ConduitPalette.surface.color()
    @Composable @ReadOnlyComposable fun surfaceLight()  : Color = ConduitPalette.surfaceLight.color()
    @Composable @ReadOnlyComposable fun border()        : Color = ConduitPalette.border.color()
    @Composable @ReadOnlyComposable fun separator()     : Color = ConduitPalette.separator.color()
    @Composable @ReadOnlyComposable fun danger()        : Color = ConduitPalette.danger.color()
    @Composable @ReadOnlyComposable fun success()       : Color = ConduitPalette.success.color()
    @Composable @ReadOnlyComposable fun warning()       : Color = ConduitPalette.warning.color()
    @Composable @ReadOnlyComposable fun background()    : Color = ConduitPalette.background.color()

    /** iOS: 22. Use a [androidx.compose.foundation.shape.RoundedCornerShape] of this radius. */
    const val cardCornerRadiusDp: Float = 22f
    const val smallCornerRadiusDp: Float = 14f
}

/**
 * Build a Material3 [ColorScheme] whose accent / container / surface slots
 * are driven by the resolved Neon Terminal palette ([neon]) instead of
 * Material's stock purple/lavender defaults.
 *
 * Why this exists: `MaterialTheme(colorScheme = darkColorScheme())` ships
 * Material's reference *purple* tones into every component that does NOT set
 * an explicit color (FilledTonalButton, FilterChip, Switch, RadioButton,
 * Slider, ProgressIndicator, default menu/dialog/dropdown/snackbar surfaces,
 * SwipeToDismiss). Those purples are visibly off-theme against the neon app.
 * This maps each accent/container/surface slot onto a concrete neon [Color]
 * with a CONTRASTING paired on-color, so the defaults read as neon, not
 * lavender. Components that set explicit colors (per-component `neon.*` reads,
 * FoundSessions Resume=green/Branch=yellow #667) override the scheme and are
 * unaffected.
 *
 * Invariant: every container/surface slot has a legible paired on-color.
 * Never leave a slot at the Material purple default.
 *
 * The neon tokens already resolve light vs dark internally (via
 * `NeonTheme.resolve(dark = ...)`), so callers pass the resolved theme and
 * pick the matching [darkColorScheme]/[lightColorScheme] base for the few
 * slots we intentionally leave at sensible Material neutrals (e.g. scrim,
 * inverse*). [conduitColorScheme] dispatches on `neon.dark`.
 */
fun conduitColorScheme(neon: NeonTheme): ColorScheme =
    if (neon.dark) conduitDarkColorScheme(neon) else conduitLightColorScheme(neon)

/**
 * Dark neon [ColorScheme]. Surfaces are the dark navy neon panels; the
 * accent is the bright palette accent (legible dark text on top). The
 * default tonal container ([secondaryContainer]) is a NEUTRAL elevated neon
 * surface — NOT bright green — because FilledTonalButtons that want green set
 * it explicitly (#667); the default must be a calm neon surface, not lavender.
 */
fun conduitDarkColorScheme(neon: NeonTheme): ColorScheme {
    // Opaque siblings of the alpha-blended neon surfaces, so Material popups
    // (menus/dialogs/dropdowns) that paint a SOLID surface read as neon-dark
    // rather than letting a translucent fill wash to grey over whatever sits
    // behind them.
    val surfaceSolid = neon.surfaceSolid              // 0xFF0A1120
    val surfaceElevated = Color(0xFF12203A)           // opaque sibling of surface2
    val accentMuted = neon.accent.copy(alpha = 0.16f) // translucent accent fill
    val errorContainer = Color(0xFF3A1620)            // deep desaturated red panel
    return darkColorScheme(
        primary = neon.accent,
        onPrimary = neon.accentText,                  // near-black on bright accent
        primaryContainer = accentMuted,
        onPrimaryContainer = neon.text,
        inversePrimary = neon.accent,

        secondary = neon.accent2,
        onSecondary = neon.accentText,
        secondaryContainer = surfaceElevated,         // the FilledTonalButton slot
        onSecondaryContainer = neon.text,

        tertiary = neon.codex,                         // brand cyan
        onTertiary = neon.accentText,
        tertiaryContainer = surfaceElevated,
        onTertiaryContainer = neon.text,

        error = neon.red,
        onError = Color(0xFF1A0307),                   // near-black on bright coral
        errorContainer = errorContainer,
        onErrorContainer = neon.red,                   // bright red text on deep panel

        background = neon.bg,
        onBackground = neon.text,
        surface = surfaceSolid,
        onSurface = neon.text,
        surfaceVariant = surfaceElevated,
        onSurfaceVariant = neon.textDim,
        surfaceTint = neon.accent,
        inverseSurface = neon.text,
        inverseOnSurface = neon.bg,

        surfaceBright = surfaceElevated,
        surfaceDim = neon.bg,
        surfaceContainerLowest = neon.bg,
        surfaceContainerLow = surfaceSolid,
        surfaceContainer = surfaceSolid,
        surfaceContainerHigh = surfaceElevated,
        surfaceContainerHighest = surfaceElevated,

        outline = neon.borderStrong,
        outlineVariant = neon.border,
    )
}

/**
 * Light neon [ColorScheme]. Surfaces are the near-white neon panels; the
 * accent is the deepened light-mode accent (white text on top). Same slot
 * contract as [conduitDarkColorScheme]; only the resolved [neon] values
 * differ (light side of every AdaptiveColor).
 */
fun conduitLightColorScheme(neon: NeonTheme): ColorScheme {
    val surfaceSolid = neon.surfaceSolid              // 0xFFFFFFFF
    val surfacePanel = neon.panel                     // 0xFFF4F7FC subtle elevated
    val accentMuted = neon.accent.copy(alpha = 0.14f)
    val errorContainer = Color(0xFFFCE4E8)            // soft red panel
    return lightColorScheme(
        primary = neon.accent,                         // deepened teal in light
        onPrimary = neon.accentText,                   // white on deep teal
        primaryContainer = accentMuted,
        onPrimaryContainer = neon.text,
        inversePrimary = neon.accentBright,

        secondary = neon.accent2,
        onSecondary = neon.accentText,
        secondaryContainer = surfacePanel,             // the FilledTonalButton slot
        onSecondaryContainer = neon.text,

        tertiary = neon.codex,
        onTertiary = Color(0xFFFFFFFF),
        tertiaryContainer = surfacePanel,
        onTertiaryContainer = neon.text,

        error = neon.red,                              // 0xFFD83048
        onError = Color(0xFFFFFFFF),                   // white on deep red
        errorContainer = errorContainer,
        onErrorContainer = Color(0xFF7A101F),          // deep red text on soft panel

        background = neon.bg,
        onBackground = neon.text,
        surface = surfaceSolid,
        onSurface = neon.text,
        surfaceVariant = surfacePanel,
        onSurfaceVariant = neon.textDim,
        surfaceTint = neon.accent,
        inverseSurface = neon.text,
        inverseOnSurface = surfaceSolid,

        surfaceBright = surfaceSolid,
        surfaceDim = neon.bg,
        surfaceContainerLowest = surfaceSolid,
        surfaceContainerLow = surfacePanel,
        surfaceContainer = surfacePanel,
        surfaceContainerHigh = surfacePanel,
        surfaceContainerHighest = neon.bg,

        outline = neon.borderStrong,
        outlineVariant = neon.border,
    )
}
