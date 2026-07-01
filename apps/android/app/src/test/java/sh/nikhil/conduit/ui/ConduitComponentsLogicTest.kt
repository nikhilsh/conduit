package sh.nikhil.conduit.ui

import androidx.compose.ui.graphics.Color
import org.junit.Assert.assertEquals
import org.junit.Test
import sh.nikhil.conduit.ui.components.ActionPillVariant
import sh.nikhil.conduit.ui.components.ButtonVariant
import sh.nikhil.conduit.ui.components.resolveActionPillColors
import sh.nikhil.conduit.ui.components.resolveButtonColors
import sh.nikhil.conduit.ui.components.resolveChipFg

/**
 * Pins the pure color-resolution logic behind [ConduitChip] and
 * [ConduitButton]. These functions have no Compose runtime dependency
 * so they run on the plain JVM, mirroring the pattern in
 * [NeonComponentsLogicTest].
 */
class ConduitComponentsLogicTest {

    // region ConduitChip foreground resolution

    private val accent = Color(0xFF22D3EE)
    private val accentText = Color(0xFF03121A)
    private val text = Color(0xFFEAF3FF)
    private val customTint = Color(0xFFFF9D4D)

    @Test
    fun chipFg_selectedNoTint_returnsAccentText() {
        val fg = resolveChipFg(
            selected = true,
            tint = null,
            accent = accent,
            accentText = accentText,
            text = text,
        )
        assertEquals(accentText, fg)
    }

    @Test
    fun chipFg_selectedWithTint_stillReturnsAccentText() {
        // selected takes priority over tint for fg
        val fg = resolveChipFg(
            selected = true,
            tint = customTint,
            accent = accent,
            accentText = accentText,
            text = text,
        )
        assertEquals(accentText, fg)
    }

    @Test
    fun chipFg_unselectedWithTint_returnsTint() {
        val fg = resolveChipFg(
            selected = false,
            tint = customTint,
            accent = accent,
            accentText = accentText,
            text = text,
        )
        assertEquals(customTint, fg)
    }

    @Test
    fun chipFg_unselectedNoTint_returnsText() {
        val fg = resolveChipFg(
            selected = false,
            tint = null,
            accent = accent,
            accentText = accentText,
            text = text,
        )
        assertEquals(text, fg)
    }

    // endregion

    // region ConduitButton color resolution

    private val green = Color(0xFF3EF0A0)

    @Test
    fun buttonColors_primaryNoTint_accentIsGreenFgIsAccentText() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Primary,
            tint = null,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(green, btnAccent)
        assertEquals(accentText, labelFg)
    }

    @Test
    fun buttonColors_primaryWithTint_accentIsTintFgIsAccentText() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Primary,
            tint = customTint,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(customTint, btnAccent)
        assertEquals(accentText, labelFg)
    }

    @Test
    fun buttonColors_secondaryNoTint_accentIsThemeAccentFgIsAccent() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Secondary,
            tint = null,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(accent, btnAccent)
        assertEquals(accent, labelFg)
    }

    @Test
    fun buttonColors_secondaryWithTint_accentIsTintFgIsTint() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Secondary,
            tint = customTint,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(customTint, btnAccent)
        assertEquals(customTint, labelFg)
    }

    @Test
    fun buttonColors_ghostNoTint_accentIsThemeAccentFgIsAccent() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Ghost,
            tint = null,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(accent, btnAccent)
        assertEquals(accent, labelFg)
    }

    @Test
    fun buttonColors_ghostWithTint_accentIsTintFgIsTint() {
        val (btnAccent, labelFg) = resolveButtonColors(
            variant = ButtonVariant.Ghost,
            tint = customTint,
            green = green,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(customTint, btnAccent)
        assertEquals(customTint, labelFg)
    }

    // endregion

    // region ConduitActionPill color resolution

    @Test
    fun pillColors_softNoTint_fillIsAccentAt14Alpha_fgIsAccent() {
        val (fill, fg) = resolveActionPillColors(
            variant = ActionPillVariant.Soft,
            tint = null,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(accent.copy(alpha = 0.14f), fill)
        assertEquals(accent, fg)
    }

    @Test
    fun pillColors_softWithTint_fillIsTintAt14Alpha_fgIsTint() {
        val (fill, fg) = resolveActionPillColors(
            variant = ActionPillVariant.Soft,
            tint = customTint,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(customTint.copy(alpha = 0.14f), fill)
        assertEquals(customTint, fg)
    }

    @Test
    fun pillColors_solidNoTint_fillIsAccent_fgIsAccentText() {
        val (fill, fg) = resolveActionPillColors(
            variant = ActionPillVariant.Solid,
            tint = null,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(accent, fill)
        assertEquals(accentText, fg)
    }

    @Test
    fun pillColors_solidWithTint_fillIsTint_fgIsAccentText() {
        val (fill, fg) = resolveActionPillColors(
            variant = ActionPillVariant.Solid,
            tint = customTint,
            accent = accent,
            accentText = accentText,
        )
        assertEquals(customTint, fill)
        assertEquals(accentText, fg)
    }

    @Test
    fun actionPillVariantEnumHasTwoMembers() {
        assertEquals(2, ActionPillVariant.entries.size)
    }

    // endregion

    // region ButtonVariant enum sanity

    @Test
    fun buttonVariantEnumHasThreeMembers() {
        assertEquals(3, ButtonVariant.entries.size)
    }

    // endregion
}
