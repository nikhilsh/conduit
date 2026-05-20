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
    val accentStrong    = AdaptiveColor(0xFF00A86B, 0xFF34C759)
    val claudeAccent    = AdaptiveColor(0xFFCC785C, 0xFFE89677)
    val codexAccent     = AdaptiveColor(0xFF10A37F, 0xFF1FCB9C)
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
    @Composable @ReadOnlyComposable fun accent()        : Color = SweKittyPalette.accent.color()
    @Composable @ReadOnlyComposable fun accentStrong()  : Color = SweKittyPalette.accentStrong.color()
    @Composable @ReadOnlyComposable fun claudeAccent()  : Color = SweKittyPalette.claudeAccent.color()
    @Composable @ReadOnlyComposable fun codexAccent()   : Color = SweKittyPalette.codexAccent.color()

    /** Per-agent accent. Falls back to [accentStrong] for unknown agents. */
    @Composable @ReadOnlyComposable
    fun accent(forAgent assistant: String): Color = when (assistant.lowercase()) {
        "claude" -> claudeAccent()
        "codex"  -> codexAccent()
        else     -> accentStrong()
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
