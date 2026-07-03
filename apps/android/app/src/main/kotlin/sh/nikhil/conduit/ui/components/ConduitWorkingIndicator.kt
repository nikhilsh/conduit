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
import androidx.compose.foundation.layout.heightIn
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
 * Six-style pre-output working indicator (design handoff "working-indicator").
 * Replaces the legacy "WORKING..." label + single pulsing dot.
 *
 * Styles: Spine (breathing mark + flowing rail), Packets (3 flowing packets),
 * Mark (shimmer sweep), Prompt (shell prompt card), PacketsPrompt (packets AS
 * the prompt command line), PipedPrompt (stacked pipe + prompt). Selected via
 * [PREF_KEY] in AppearanceStore (default Spine).
 *
 * Animation periods match the iOS mirror:
 *   2.1s breathe  1.4s rail  1.5s packet  2.2s shimmer  1s caret  1.9s verb cycle
 */
enum class ConduitWorkingStyle(val displayName: String) {
    Spine("A - Conduit spine"),
    Packets("B - Packets"),
    Mark("C - Breathing mark"),
    Prompt("D - At the prompt"),
    PacketsPrompt("E - Packets @ prompt"),
    PipedPrompt("F - Piped prompt");

    companion object {
        /** SharedPreferences key (matches iOS debug.workingIndicatorStyle). */
        const val PREF_KEY = "debug.workingIndicatorStyle"

        fun from(raw: String?): ConduitWorkingStyle =
            entries.firstOrNull { it.name == raw } ?: Spine
    }
}

private val VERBS = listOf("thinking", "reading files", "running tests", "writing the patch", "pushing")

// -- The indicator -----------------------------------------------------------------------

/**
 * Working indicator composable.
 *
 * @param style   Which of the six visual styles to render.
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
        ConduitWorkingStyle.Spine         -> SpineStyle(modifier, neon, agentTint, agent, verb, t)
        ConduitWorkingStyle.Packets       -> PacketsStyle(modifier, neon, agentTint, agent, verb, t)
        ConduitWorkingStyle.Mark          -> MarkStyle(modifier, neon, agent, t)
        ConduitWorkingStyle.Prompt        -> PromptStyle(modifier, neon, agentTint, agent, verb, t)
        ConduitWorkingStyle.PacketsPrompt -> PacketsPromptStyle(modifier, neon, agentTint, agent, verb, t)
        ConduitWorkingStyle.PipedPrompt   -> PipedPromptStyle(modifier, neon, agentTint, agent, verb, t)
    }
}

private fun blinkOn(t: Float) = (t % 1f) < 0.52f

// A: spine, warming up
@Composable
private fun SpineStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(13.dp)) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Box(
                Modifier
                    .size(26.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(Color.White.copy(alpha = 0.03f))
                    .border(1.dp, neon.border, RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) { ConduitMark(size = 16.dp) }
            // Flowing rail: cyan->green gradient scrolled by t (matches iOS FlowingRail).
            Box(
                Modifier
                    .width(2.dp)
                    .heightIn(min = 26.dp)
                    .weight(1f)
                    .drawBehind {
                        val shift = (t / 1.4f) % 1f
                        drawRect(
                            Brush.verticalGradient(
                                0f to neon.accent,
                                0.35f to neon.green,
                                0.7f to neon.accent,
                                1f to neon.green,
                                startY = -shift * size.height,
                                endY = (1f - shift) * size.height,
                            )
                        )
                    },
            )
        }
        Row(Modifier.padding(top = 3.dp), verticalAlignment = Alignment.CenterVertically) {
            Text(agent, fontFamily = neon.sans, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = agentTint)
            Text(" is ", fontFamily = neon.sans, fontSize = 15.sp, color = neon.textFaint)
            Text(verb, fontFamily = neon.mono, fontSize = 13.5.sp, color = neon.text)
            CaretBox(neon, t)
        }
    }
}

// B: packets through the pipe
@Composable
private fun PacketsStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(9.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(
                Modifier
                    .size(30.dp)
                    .clip(RoundedCornerShape(8.dp))
                    .background(agentTint.copy(alpha = 0.12f))
                    .border(1.dp, agentTint.copy(alpha = 0.36f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) { AgentAvatar(assistant = agent, size = 16.dp) }
            PacketPipe(neon = neon, t = t, modifier = Modifier.weight(1f).height(26.dp))
        }
        Row(Modifier.padding(start = 40.dp)) {
            Text(agent, fontFamily = neon.mono, fontSize = 12.sp, color = agentTint)
            Text("  -  ", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint.copy(alpha = 0.6f))
            Text(verb, fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
        }
    }
}

// C: the mark, breathing
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
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(32.dp)
                .clip(RoundedCornerShape(9.dp))
                .background(Color.White.copy(alpha = 0.03f))
                .border(1.dp, neon.border, RoundedCornerShape(9.dp)),
            contentAlignment = Alignment.Center,
        ) { ConduitMark(size = 20.dp) }
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

// D: at the prompt
@Composable
private fun PromptStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(neon.codeBg)
            .border(1.dp, neon.border, RoundedCornerShape(12.dp))
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        PromptHeader(neon = neon, agentTint = agentTint, agent = agent)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("$ ", fontFamily = neon.mono, fontSize = 13.sp, color = neon.green)
            Text(verb, fontFamily = neon.mono, fontSize = 13.sp, color = neon.text)
            CaretBox(neon, t)
        }
    }
}

// E: packets AS the prompt command line
@Composable
private fun PacketsPromptStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(neon.codeBg)
            .border(1.dp, neon.border, RoundedCornerShape(12.dp))
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        PromptHeader(neon = neon, agentTint = agentTint, agent = agent)
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text("$ ", fontFamily = neon.mono, fontSize = 13.sp, color = neon.green)
            PacketPipe(neon = neon, t = t, modifier = Modifier.width(96.dp).height(20.dp))
            Text(verb, fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
        }
    }
}

// F: stacked pipe + prompt
@Composable
private fun PipedPromptStyle(
    modifier: Modifier,
    neon: NeonTheme,
    agentTint: Color,
    agent: String,
    verb: String,
    t: Float,
) {
    Column(
        modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(neon.codeBg)
            .border(1.dp, neon.border, RoundedCornerShape(12.dp))
            .padding(horizontal = 13.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        PromptHeader(neon = neon, agentTint = agentTint, agent = agent)
        PacketPipe(neon = neon, t = t, modifier = Modifier.fillMaxWidth().height(22.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("$ ", fontFamily = neon.mono, fontSize = 13.sp, color = neon.green)
            Text(verb, fontFamily = neon.mono, fontSize = 13.sp, color = neon.text)
            CaretBox(neon, t)
        }
    }
}

// -- Shared atoms ------------------------------------------------------------------------

/**
 * Shared header line used by D/E/F: agent@prod ~/broker in mono tints.
 * Mirrors iOS PromptHeader().
 */
@Composable
private fun PromptHeader(neon: NeonTheme, agentTint: Color, agent: String) {
    Row {
        Text(agent, fontFamily = neon.mono, fontSize = 13.sp, color = agentTint)
        Text("@prod", fontFamily = neon.mono, fontSize = 13.sp, color = neon.textFaint)
        Text(" ~/broker", fontFamily = neon.mono, fontSize = 13.sp, color = neon.textFaint.copy(alpha = 0.6f))
    }
}

/**
 * Capsule pipe with 3 flowing packets. Extracted so B/E/F styles can reuse it
 * at different sizes. Mirrors iOS PacketPipe(t:).
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

@Composable
private fun CaretBox(neon: NeonTheme, t: Float) {
    Box(
        Modifier
            .padding(start = 4.dp)
            .width(7.dp)
            .height(16.dp)
            .clip(RoundedCornerShape(1.dp))
            .background(if (blinkOn(t)) neon.accent else Color.Transparent),
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
