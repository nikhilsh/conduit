package sh.nikhil.conduit.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.runtime.mutableStateOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.ui.AgentAvatar
import sh.nikhil.conduit.ui.ConduitMark
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.NeonPalette
import sh.nikhil.conduit.ui.NeonTheme
import sh.nikhil.conduit.ui.glassCapsule
import sh.nikhil.conduit.ui.neonAgentColor

// -- Style + debug setting ---------------------------------------------------------------

/**
 * Two-style pre-output working indicator (design handoff "working-indicator",
 * trimmed per owner device feedback: single inline row, no detached bar).
 * Replaces the legacy "WORKING..." label + single pulsing dot.
 *
 * Styles: Packets (avatar + flowing packets + verb, one line), Mark
 * (breathing mark + shimmer verb, one line). Selected via [PREF_KEY] in
 * AppearanceStore (default Packets).
 *
 * Animation periods match the iOS mirror:
 *   2.1s breathe  1.5s packet  2.2s shimmer  1.9s verb cycle
 */
enum class ConduitWorkingStyle(val displayName: String) {
    Packets("B - Packets"),
    Mark("C - Breathing mark");

    companion object {
        /** SharedPreferences key (matches iOS debug.workingIndicatorStyle). */
        const val PREF_KEY = "debug.workingIndicatorStyle"

        /** Falls back to [Packets] for both an unset key AND a stale name left
         *  over from a removed style (Spine/Prompt/PacketsPrompt/PipedPrompt). */
        fun from(raw: String?): ConduitWorkingStyle =
            entries.firstOrNull { it.name == raw } ?: Packets
    }
}

private val VERBS = listOf("thinking", "reading files", "running tests", "writing the patch", "pushing")

// -- The indicator -----------------------------------------------------------------------

/**
 * Working indicator composable.
 *
 * @param style   Which of the two visual styles to render.
 * @param agent   Agent key used for the tint (e.g. "claude", "codex").
 * @param status  Live activity text. null -> cycles VERBS set.
 * @param modifier Optional layout modifier.
 *
 * Reduce-motion is read from [android.provider.Settings.Global.ANIMATOR_DURATION_SCALE]
 * internally (same as [TypingIndicatorRow]); no caller parameter required.
 */
@Composable
fun ConduitWorkingIndicator(
    style: ConduitWorkingStyle,
    modifier: Modifier = Modifier,
    agent: String = "claude",
    status: String? = null,
) {
    val neon = LocalNeonTheme.current
    val agentTint = neonAgentColor(agent, neon)

    // Reduce-motion: read ANIMATOR_DURATION_SCALE from system settings.
    // Pattern mirrors TypingIndicatorRow in ChatPage.kt.
    val context = LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    // Single shared clock frozen at t=0 under reduce-motion so every style shows its calm state.
    val t by if (reduceMotion) {
        remember { mutableStateOf(0f) }
    } else {
        rememberInfiniteTransition(label = "wi").animateFloat(
            initialValue = 0f,
            targetValue = 100f,
            animationSpec = infiniteRepeatable(
                animation = tween(durationMillis = 100_000, easing = LinearEasing),
            ),
            label = "wi_t",
        )
    }

    val verb = status ?: VERBS[((t / 1.9f).toInt()) % VERBS.size]

    when (style) {
        ConduitWorkingStyle.Packets       -> PacketsStyle(modifier, neon, agentTint, agent, verb, t)
        ConduitWorkingStyle.Mark          -> MarkStyle(modifier, neon, agent, t)
    }
}

// B: packets through the pipe, single inline row
@Composable
private fun PacketsStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(agentTint.copy(alpha = 0.12f))
                .border(1.dp, agentTint.copy(alpha = 0.36f), RoundedCornerShape(7.dp)),
            contentAlignment = Alignment.Center,
        ) { AgentAvatar(assistant = agent, size = 13.dp) }
        PacketPipe(neon = neon, t = t, modifier = Modifier.width(34.dp).height(14.dp))
        Row {
            Text(agent, fontFamily = neon.mono, fontSize = 12.sp, color = agentTint)
            Text("  -  ", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint.copy(alpha = 0.6f))
            Text(verb, fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
        }
    }
}

// C: the mark, breathing -- single inline row
@Composable
private fun MarkStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agent: String,
    t: Float,
) {
    Row(
        modifier,
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            Modifier
                .size(22.dp)
                .clip(RoundedCornerShape(7.dp))
                .background(Color.White.copy(alpha = 0.03f))
                .border(1.dp, neon.border, RoundedCornerShape(7.dp)),
            contentAlignment = Alignment.Center,
        ) { ConduitMark(size = 15.dp) }
        // Shimmer sweep across the label (mask a bright copy over a faint base).
        val x = ((t / 2.2f) % 1f) * 2.2f - 0.6f
        Box {
            Text(
                "$agent is working...",
                fontFamily = neon.sans,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                color = neon.textFaint,
            )
            Text(
                "$agent is working...",
                fontFamily = neon.sans,
                fontSize = 15.sp,
                fontWeight = FontWeight.SemiBold,
                style = TextStyle(
                    brush = Brush.horizontalGradient(
                        (x - 0.18f).coerceIn(0f, 1f) to Color.Transparent,
                        x.coerceIn(0f, 1f) to neon.text,
                        (x + 0.18f).coerceIn(0f, 1f) to Color.Transparent,
                    )
                ),
            )
        }
    }
}

// -- Shared atoms ------------------------------------------------------------------------

/**
 * Capsule pipe with 3 flowing packets. Mirrors iOS PacketPipe(t:).
 */
@Composable
private fun PacketPipe(neon: NeonTheme, t: Float, modifier: Modifier = Modifier) {
    Box(
        modifier
            .glassCapsule()
            .drawBehind {
                val w = size.width
                for (i in 0..2) {
                    val phase = ((t / 1.5f) + i / 3f) % 1f
                    val alpha = when {
                        phase < 0.12f -> phase / 0.12f
                        phase > 0.88f -> (1f - phase) / 0.12f
                        else -> 1f
                    }
                    drawCircle(
                        color = (if (i % 2 == 0) neon.accent else neon.green).copy(alpha = alpha),
                        radius = 3.dp.toPx(),
                        center = Offset(phase * (w + 12.dp.toPx()) - 6.dp.toPx(), size.height / 2),
                    )
                }
            },
    )
}

// -- Preview -----------------------------------------------------------------------------

@Preview(showBackground = true, backgroundColor = 0xFF04050A)
@Composable
private fun WorkingIndicatorPreview() {
    val neon = NeonTheme.resolve(
        palette = NeonPalette.ICE,
        dark = true,
        glow = true,
    )
    androidx.compose.runtime.CompositionLocalProvider(
        LocalNeonTheme provides neon,
    ) {
        Column(
            modifier = Modifier.padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(24.dp),
        ) {
            ConduitWorkingStyle.entries.forEach { style ->
                ConduitWorkingIndicator(
                    style = style,
                    agent = "claude",
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
