package sh.nikhil.conduit.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

// Android mirror of iOS LitterUI.UsageCard — the design bundle's
// Session-Info usage card (usage.jsx → UsageCardA / UsageCardB + the
// Visual/Terminal segmented switch). Data is the live broker-accumulated
// status (PR #274): tokens in/out/cache, cost (claude), context-window
// gauge (claude only). Turns + duration come from the conversation log.
// Plan limits (Claude weekly / Codex quota) have no data source, so are
// intentionally omitted rather than faked. Hidden until usage lands.

@Composable
fun NeonUsageCard(
    input: Long,
    output: Long,
    cached: Long,
    costUsd: Double?,
    contextUsed: Long,
    contextWindow: Long,
    assistant: String,
    turns: Int,
    execLabel: String?,
) {
    if (input <= 0 && output <= 0) return
    val neon = LocalNeonTheme.current
    var variant by rememberSaveable { mutableStateOf("A") }

    Column(verticalArrangement = Arrangement.spacedBy(11.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "USAGE",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.textDim,
            )
            Spacer(Modifier.weight(1f))
            UsageSegmented(variant) { variant = it }
        }
        if (variant == "A") {
            VisualUsage(input, output, cached, costUsd, contextUsed, contextWindow, assistant)
        } else {
            TerminalUsage(input, output, cached, costUsd, contextUsed, contextWindow, turns, execLabel)
        }
    }
}

@Composable
private fun UsageSegmented(variant: String, onPick: (String) -> Unit) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(11.dp))
            .background(if (neon.dark) Color.Black.copy(alpha = 0.3f) else neon.text.copy(alpha = 0.06f))
            .border(1.dp, neon.border, RoundedCornerShape(11.dp))
            .padding(3.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        listOf("A" to "Visual", "B" to "Terminal").forEach { (v, label) ->
            val selected = v == variant
            Text(
                label,
                fontFamily = neon.sans,
                fontSize = 12.sp,
                fontWeight = if (selected) FontWeight.Bold else FontWeight.Medium,
                color = if (selected) neon.accent else neon.textDim,
                modifier = Modifier
                    .clip(RoundedCornerShape(8.dp))
                    .then(
                        if (selected) {
                            Modifier
                                .background(neon.accent.copy(alpha = if (neon.dark) 0.13f else 0.10f))
                                .border(1.dp, neon.accent.copy(alpha = 0.4f), RoundedCornerShape(8.dp))
                        } else {
                            Modifier
                        },
                    )
                    .clickable { onPick(v) }
                    .padding(horizontal = 12.dp, vertical = 6.dp),
            )
        }
    }
}

// ── Variant A — Visual ──────────────────────────────────────────

@Composable
private fun VisualUsage(
    input: Long,
    output: Long,
    cached: Long,
    costUsd: Double?,
    contextUsed: Long,
    contextWindow: Long,
    assistant: String,
) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        if (contextUsed > 0 && contextWindow > 0) {
            ContextRing(contextUsed, contextWindow, assistant)
        }
        TokenTiles(input, output, cached, costUsd)
    }
}

@Composable
private fun ContextRing(used: Long, window: Long, assistant: String) {
    val neon = LocalNeonTheme.current
    val pct = (used.toFloat() / window).coerceIn(0f, 1f)
    val ringTrack = neon.border
    val ringFill = neon.accentBright
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape((neon.radiusDp - 4).dp))
            .neonCardSurface(neon = neon, shape = RoundedCornerShape((neon.radiusDp - 4).dp), fill = neon.surface)
            .padding(16.dp),
        horizontalArrangement = Arrangement.spacedBy(18.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(modifier = Modifier.size(116.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(116.dp)) {
                val sw = 11.dp.toPx()
                val inset = sw / 2f
                val arcSize = Size(size.width - sw, size.height - sw)
                val topLeft = Offset(inset, inset)
                drawArc(
                    color = ringTrack,
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = sw),
                )
                drawArc(
                    color = ringFill,
                    startAngle = -90f,
                    sweepAngle = 360f * pct,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = sw, cap = StrokeCap.Round),
                )
            }
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text(
                    "${(pct * 100).roundToInt()}",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 28.sp,
                    color = neon.text,
                )
                Text("context", fontFamily = neon.mono, fontSize = 9.5.sp, color = neon.textFaint)
            }
        }
        Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
            Text("WINDOW", fontFamily = neon.mono, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = neon.textFaint)
            Text("${fmtK(used)} / ${fmtK(window)}", fontFamily = neon.mono, fontSize = 19.sp, fontWeight = FontWeight.Bold, color = neon.text)
            Text("${fmtK(window - used.coerceAtMost(window))} left", fontFamily = neon.mono, fontSize = 11.5.sp, color = neon.textDim)
            AgentPill(assistant)
        }
    }
}

@Composable
private fun AgentPill(assistant: String) {
    val neon = LocalNeonTheme.current
    val c = neonAgentColor(assistant, neon)
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(c.copy(alpha = 0.11f))
            .border(1.dp, c.copy(alpha = 0.27f), RoundedCornerShape(99.dp))
            .padding(horizontal = 10.dp, vertical = 4.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(6.dp).clip(RoundedCornerShape(99.dp)).background(c))
        Text(assistant.lowercase(), fontFamily = neon.mono, fontSize = 10.5.sp, color = c)
    }
}

@Composable
private fun TokenTiles(input: Long, output: Long, cached: Long, costUsd: Double?) {
    val neon = LocalNeonTheme.current
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("TOKENS · SESSION", fontFamily = neon.mono, fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = neon.textFaint)
            Spacer(Modifier.weight(1f))
            if (costUsd != null && costUsd > 0) {
                Text(String.format("$%.2f", costUsd), fontFamily = neon.mono, fontSize = 11.sp, color = neon.textDim)
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(9.dp)) {
            TokenTile("in", input, neon.blue, Modifier.weight(1f))
            TokenTile("out", output, neon.green, Modifier.weight(1f))
            TokenTile("cache", cached, neon.purple, Modifier.weight(1f))
        }
    }
}

@Composable
private fun TokenTile(label: String, value: Long, color: Color, modifier: Modifier = Modifier) {
    val neon = LocalNeonTheme.current
    Column(
        modifier = modifier
            .clip(RoundedCornerShape(13.dp))
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(13.dp), fill = neon.surface)
            .padding(horizontal = 12.dp, vertical = 11.dp),
        verticalArrangement = Arrangement.spacedBy(7.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(6.dp).clip(RoundedCornerShape(99.dp)).background(color))
            Text(label, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
        }
        Text(fmtK(value), fontFamily = neon.mono, fontSize = 18.sp, fontWeight = FontWeight.Bold, color = neon.text)
    }
}

// ── Variant B — Terminal ────────────────────────────────────────

@Composable
private fun TerminalUsage(
    input: Long,
    output: Long,
    cached: Long,
    costUsd: Double?,
    contextUsed: Long,
    contextWindow: Long,
    turns: Int,
    execLabel: String?,
) {
    val neon = LocalNeonTheme.current
    val total = (input + output + cached).coerceAtLeast(1)
    val rightMeta = listOfNotNull(execLabel?.takeIf { it != "—" }, turns.takeIf { it > 0 }?.let { "$it turns" })
        .joinToString(" · ")
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape((neon.radiusDp - 4).dp))
            .background(neon.codeBg)
            .border(1.dp, neon.borderStrong, RoundedCornerShape((neon.radiusDp - 4).dp)),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 10.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("$", fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.accentBright)
            Text("conduit usage --session", fontFamily = neon.mono, fontSize = 12.sp, color = neon.codeText)
            Spacer(Modifier.weight(1f))
            if (rightMeta.isNotEmpty()) {
                Text(rightMeta, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.green)
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(neon.borderStrong))
        Column(
            modifier = Modifier.padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (contextUsed > 0 && contextWindow > 0) {
                ContextBlockBar(contextUsed, contextWindow)
            }
            TokenStack(input, output, cached, total, costUsd)
        }
    }
}

@Composable
private fun ContextBlockBar(used: Long, window: Long) {
    val neon = LocalNeonTheme.current
    val pct = (used.toFloat() / window).coerceIn(0f, 1f)
    val seg = 28
    val on = (pct * seg).roundToInt()
    val bar = buildAnnotatedString {
        withStyle(SpanStyle(color = neon.accentBright)) { append("█".repeat(on)) }
        withStyle(SpanStyle(color = neon.codeText.copy(alpha = 0.28f))) { append("░".repeat(seg - on)) }
    }
    Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("context", fontFamily = neon.mono, fontSize = 12.sp, color = neon.codeText.copy(alpha = 0.6f), modifier = Modifier.width(56.dp))
            Text(bar, fontFamily = neon.mono, fontSize = 12.sp, maxLines = 1, modifier = Modifier.weight(1f))
            Text("${(pct * 100).roundToInt()}%", fontFamily = neon.mono, fontSize = 12.sp, fontWeight = FontWeight.Bold, color = neon.codeText)
        }
        Text(
            "${fmtK(used)} / ${fmtK(window)}",
            fontFamily = neon.mono,
            fontSize = 10.5.sp,
            color = neon.codeText.copy(alpha = 0.6f),
            modifier = Modifier.padding(start = 64.dp),
        )
    }
}

@Composable
private fun TokenStack(input: Long, output: Long, cached: Long, total: Long, costUsd: Double?) {
    val neon = LocalNeonTheme.current
    val parts = listOf(Triple("in", input, neon.blue), Triple("out", output, neon.green), Triple("cache", cached, neon.purple))
    val costSuffix = if (costUsd != null && costUsd > 0) String.format(" · $%.2f", costUsd) else ""
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text("tokens · ${fmtK(total)} total$costSuffix", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.codeText.copy(alpha = 0.6f))
        Row(
            modifier = Modifier.fillMaxWidth().height(12.dp).clip(RoundedCornerShape(4.dp)),
        ) {
            parts.forEach { (_, value, color) ->
                if (value > 0) {
                    Box(Modifier.weight(value.toFloat()).fillMaxHeight().background(color))
                }
            }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(16.dp)) {
            parts.forEach { (label, value, color) ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(9.dp).clip(RoundedCornerShape(2.dp)).background(color))
                    Text(label, fontFamily = neon.mono, fontSize = 11.sp, color = neon.codeText)
                    Text(fmtK(value), fontFamily = neon.mono, fontSize = 11.sp, color = neon.codeText.copy(alpha = 0.6f))
                }
            }
        }
    }
}

private fun fmtK(n: Long): String = when {
    n >= 1_000_000 -> String.format("%.1fM", n / 1_000_000.0)
    n >= 1_000 -> "${(n / 1_000.0).roundToInt()}k"
    else -> "$n"
}
