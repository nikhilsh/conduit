package sh.nikhil.conduit.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.size
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp

// BRAND.md §3 canonical tokens.
private val MarkCyan = Color(0xFF22D3EE)
private val MarkGreen = Color(0xFF3EF0A0)
private val MarkEye = Color(0xFFEAFCFF)

/**
 * The Conduit brand mark — the "terminal daemon": a rounded-square head with a
 * cyan→green neon outline, top/bottom connector pills, `>` `<` squint eyes and
 * a small smile. Vector reimplementation of the design handoff `ConduitMark`
 * (BRAND.md §2), drawn on a 32×32 grid and scaled to [size]. Mirrors the iOS
 * `ConduitUI.ConduitMark`.
 *
 * @param color when non-null, the outline + pills render in this flat tint
 *   (agent-tinted avatars). When null, the signature cyan→green gradient.
 */
@Composable
fun ConduitMark(size: Dp, modifier: Modifier = Modifier, color: Color? = null) {
    val neon = LocalNeonTheme.current
    // Light theme: the signature cyan→green are pastel and wash out on a light
    // canvas, and the near-white eyes vanish entirely (device feedback: "logo
    // not rendering well"). Mirror the design `ConduitMark`, which is theme-aware
    // — on light it strokes the mark in the muted dark accent and draws the
    // `><` eyes in the dark text colour for contrast. Dark theme keeps the neon
    // cyan→green gradient + bright eyes.
    val markTop = if (color != null) color else if (neon.dark) MarkCyan else neon.accent
    val markBottom = if (color != null) color else if (neon.dark) MarkGreen else neon.accent
    // Eyes/smile key off the *mode*, not the glow toggle: glow is independent and
    // can be on in light mode, where the near-white eye colour vanishes. Use dark
    // text glyphs in light mode for contrast.
    val eyeColor = if (neon.dark) MarkEye else neon.text
    Canvas(modifier = modifier.size(size)) {
        val s = this.size.width / 32f
        fun p(x: Float, y: Float) = Offset(x * s, y * s)

        val outline = when {
            color != null -> SolidColor(color)
            neon.dark -> Brush.linearGradient(listOf(MarkCyan, MarkGreen), start = p(4f, 4f), end = p(28f, 28f))
            else -> SolidColor(neon.accent)
        }

        // Body — rounded square.
        val body = Path().apply {
            addRoundRect(
                RoundRect(
                    left = 5.4f * s, top = 5.4f * s, right = 26.6f * s, bottom = 26.6f * s,
                    cornerRadius = CornerRadius(6.4f * s),
                ),
            )
        }
        drawPath(body, brush = outline, style = Stroke(width = 2f * s))

        // Connector pills (top cyan, bottom green in dark; muted accent in light).
        drawRoundRect(color = markTop, topLeft = p(14.4f, 4.4f), size = Size(3.2f * s, 2f * s), cornerRadius = CornerRadius(1f * s))
        drawRoundRect(color = markBottom, topLeft = p(14.4f, 25.6f), size = Size(3.2f * s, 2f * s), cornerRadius = CornerRadius(1f * s))

        // Face: `>` `<` squint eyes + smile.
        val face = Path().apply {
            moveTo(11f * s, 13.4f * s); lineTo(13.6f * s, 15.4f * s); lineTo(11f * s, 17.4f * s)
            moveTo(21f * s, 13.4f * s); lineTo(18.4f * s, 15.4f * s); lineTo(21f * s, 17.4f * s)
            moveTo(13f * s, 20f * s); quadraticBezierTo(16f * s, 22.4f * s, 19f * s, 20f * s)
        }
        drawPath(face, color = eyeColor, style = Stroke(width = 1.7f * s, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}
