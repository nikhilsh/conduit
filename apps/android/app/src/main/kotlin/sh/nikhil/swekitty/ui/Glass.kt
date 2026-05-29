package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.unit.dp

/**
 * "Neon Terminal" chrome surfaces (Phase 2 reskin).
 *
 * These keep the historical `glass*` modifier names + signatures so the
 * existing call sites (header rows, key caps, in-session dock, project
 * list, composer) stay untouched, but they now paint the resolved
 * [NeonTheme] from [LocalNeonTheme] instead of the old translucent glass
 * wash: a neon `surface` fill, a neon border, and the theme's box glow
 * (glow ON) or the soft light-mode card elevation (glow OFF) via the
 * shared [neonCardSurface] / [neonGlowBox] helpers.
 *
 * A `tint` (per-agent accent) recolors both the border and the glow so
 * agent-tinted controls (the agent pill) still read as branded.
 *
 * Compose's single blurred drop-shadow can't reproduce the two-layer CSS
 * box-glow exactly — fidelity gaps are expected (see NeonComponents).
 */

@Composable
fun Modifier.glassRect(
    cornerRadiusDp: Float = SweKittyTheme.cardCornerRadiusDp,
    tint: Color? = null,
): Modifier = neonChromeSurface(
    shape = RoundedCornerShape(cornerRadiusDp.dp),
    tint = tint,
)

@Composable
fun Modifier.glassRoundedRect(
    cornerRadiusDp: Float = SweKittyTheme.cardCornerRadiusDp,
): Modifier = neonChromeSurface(
    shape = RoundedCornerShape(cornerRadiusDp.dp),
    tint = null,
)

@Composable
fun Modifier.glassCapsule(
    interactive: Boolean = false,
    tint: Color? = null,
): Modifier = neonChromeSurface(
    // Pills are fully rounded (handoff radius 99) — percent=50 is the
    // Compose idiom for a capsule of any height.
    shape = RoundedCornerShape(percent = 50),
    tint = tint,
)

@Composable
fun Modifier.glassCircle(tint: Color? = null): Modifier = neonChromeSurface(
    shape = CircleShape,
    tint = tint,
)

/**
 * The shared neon chrome fill used by every `glass*` modifier above. A
 * neon `surface` background, a neon (or tinted) hairline border, and the
 * theme glow box (glow ON) / light card elevation (glow OFF). `tint`
 * recolors the border + glow to a per-agent accent when supplied.
 */
@Composable
private fun Modifier.neonChromeSurface(
    shape: Shape,
    tint: Color?,
): Modifier {
    val neon = LocalNeonTheme.current
    val border = tint?.copy(alpha = 0.55f) ?: neon.borderStrong
    val box = neon.glowBox?.let { gb ->
        if (tint == null) gb else NeonGlowBox(
            inner = NeonShadowLayer(gb.inner.radiusDp, tint.copy(alpha = gb.inner.color.alpha)),
            outer = NeonShadowLayer(gb.outer.radiusDp, tint.copy(alpha = gb.outer.color.alpha)),
        )
    }
    var m = this
    if (box != null) {
        m = m.neonGlowBox(box, shape)
    } else {
        neon.cardElevation?.let { elev ->
            m = m.shadow(
                elevation = elev.radiusDp.dp,
                shape = shape,
                ambientColor = elev.color,
                spotColor = elev.color,
            )
        }
    }
    return m
        .clip(shape)
        .background(color = neon.surface, shape = shape)
        .border(width = 1.dp, color = border, shape = shape)
}
