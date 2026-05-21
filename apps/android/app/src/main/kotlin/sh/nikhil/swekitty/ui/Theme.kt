package sh.nikhil.swekitty.ui

import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.ReadOnlyComposable
import androidx.compose.ui.graphics.Color

/**
 * Compose mirror of `apps/ios/Sources/Theme/Palette.swift` +
 * `Theme.swift`. Same hex values, same semantic tokens. The composables
 * here resolve to light/dark via `isSystemInDarkTheme()` so call sites
 * read like `SweKittyTheme.accentStrong()` rather than threading a
 * `ColorScheme` parameter.
 */
internal data class AdaptiveColor(val light: Long, val dark: Long) {
    @Composable @ReadOnlyComposable
    fun color(): Color = if (isSystemInDarkTheme()) Color(dark) else Color(light)
}

internal object SweKittyPalette {
    val accent          = AdaptiveColor(0xFF4A4A4A, 0xFFB0B0B0)
    // Brand accent moved from green to Anthropic copper to match
    // litter's visual reference (see iOS Palette.swift comment).
    val accentStrong    = AdaptiveColor(0xFFCC785C, 0xFFE89677)
    val claudeAccent    = AdaptiveColor(0xFFCC785C, 0xFFE89677)
    val claudeAccentStrong = AdaptiveColor(0xFFA85A3F, 0xFFCC785C)
    val codexAccent     = AdaptiveColor(0xFF10B981, 0xFF34D399)
    val codexAccentStrong  = AdaptiveColor(0xFF047857, 0xFF10B981)
    // Hermes purple — Tailwind purple-500. No public Hermes adapter
    // brand to anchor to, so this is a defensible choice that contrasts
    // cleanly with claude/codex.
    val hermesAccent    = AdaptiveColor(0xFFA855F7, 0xFFC084FC)
    val hermesAccentStrong = AdaptiveColor(0xFF7E22CE, 0xFFA855F7)
    // Inflection Pi blue — Tailwind blue-500.
    val piAccent        = AdaptiveColor(0xFF3B82F6, 0xFF60A5FA)
    val piAccentStrong  = AdaptiveColor(0xFF1D4ED8, 0xFF3B82F6)
    // opencode orange — Tailwind orange-500. sst.dev's opencode docs
    // site reads orange.
    val opencodeAccent  = AdaptiveColor(0xFFF97316, 0xFFFB923C)
    val opencodeAccentStrong = AdaptiveColor(0xFFC2410C, 0xFFF97316)
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

object SweKittyTheme {
    @Composable @ReadOnlyComposable fun accent()          : Color = SweKittyPalette.accent.color()
    @Composable @ReadOnlyComposable fun accentStrong()    : Color = SweKittyPalette.accentStrong.color()
    @Composable @ReadOnlyComposable fun claudeAccent()    : Color = SweKittyPalette.claudeAccent.color()
    @Composable @ReadOnlyComposable fun codexAccent()     : Color = SweKittyPalette.codexAccent.color()
    @Composable @ReadOnlyComposable fun hermesAccent()    : Color = SweKittyPalette.hermesAccent.color()
    @Composable @ReadOnlyComposable fun piAccent()        : Color = SweKittyPalette.piAccent.color()
    @Composable @ReadOnlyComposable fun opencodeAccent()  : Color = SweKittyPalette.opencodeAccent.color()

    /**
     * Per-agent accent. Each adapter that ships with the harness gets
     * a distinct hue — Claude copper, Codex green, Hermes purple,
     * Pi blue, opencode orange. Falls back to the neutral gray
     * [accent] for unknown agents (rather than the copper brand
     * accent, so an unknown agent doesn't masquerade as Claude).
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
        "claude"   -> SweKittyPalette.claudeAccentStrong.color()
        "codex"    -> SweKittyPalette.codexAccentStrong.color()
        "hermes"   -> SweKittyPalette.hermesAccentStrong.color()
        "pi"       -> SweKittyPalette.piAccentStrong.color()
        "opencode" -> SweKittyPalette.opencodeAccentStrong.color()
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
        "claude"   -> SweKittyPalette.claudeAccent.light
        "codex"    -> SweKittyPalette.codexAccent.light
        "hermes"   -> SweKittyPalette.hermesAccent.light
        "pi"       -> SweKittyPalette.piAccent.light
        "opencode" -> SweKittyPalette.opencodeAccent.light
        else       -> SweKittyPalette.accent.light
    }

    fun accentStrongForAgentLightRgb(forAgent: String): Long = when (forAgent.lowercase()) {
        "claude"   -> SweKittyPalette.claudeAccentStrong.light
        "codex"    -> SweKittyPalette.codexAccentStrong.light
        "hermes"   -> SweKittyPalette.hermesAccentStrong.light
        "pi"       -> SweKittyPalette.piAccentStrong.light
        "opencode" -> SweKittyPalette.opencodeAccentStrong.light
        else       -> SweKittyPalette.accent.light
    }
    @Composable @ReadOnlyComposable fun textPrimary()   : Color = SweKittyPalette.textPrimary.color()
    @Composable @ReadOnlyComposable fun textSecondary() : Color = SweKittyPalette.textSecondary.color()
    @Composable @ReadOnlyComposable fun textMuted()     : Color = SweKittyPalette.textMuted.color()
    @Composable @ReadOnlyComposable fun textBody()      : Color = SweKittyPalette.textBody.color()
    @Composable @ReadOnlyComposable fun textOnAccent()  : Color = SweKittyPalette.textOnAccent.color()
    @Composable @ReadOnlyComposable fun surface()       : Color = SweKittyPalette.surface.color()
    @Composable @ReadOnlyComposable fun surfaceLight()  : Color = SweKittyPalette.surfaceLight.color()
    @Composable @ReadOnlyComposable fun border()        : Color = SweKittyPalette.border.color()
    @Composable @ReadOnlyComposable fun separator()     : Color = SweKittyPalette.separator.color()
    @Composable @ReadOnlyComposable fun danger()        : Color = SweKittyPalette.danger.color()
    @Composable @ReadOnlyComposable fun success()       : Color = SweKittyPalette.success.color()
    @Composable @ReadOnlyComposable fun warning()       : Color = SweKittyPalette.warning.color()
    @Composable @ReadOnlyComposable fun background()    : Color = SweKittyPalette.background.color()

    /** iOS: 22. Use a [androidx.compose.foundation.shape.RoundedCornerShape] of this radius. */
    const val cardCornerRadiusDp: Float = 22f
    const val smallCornerRadiusDp: Float = 14f
}
