package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt

// NeonAccountUsageCard — the on-demand /usage card in Session Info. Shows the
// Claude SUBSCRIPTION usage: the 5-hour rolling window and the weekly (7-day)
// window — what the Claude Code CLI's `/usage` reports. Distinct from
// NeonUsageCard (this SESSION's tokens/cost, hidden until a turn): account
// usage is account-global and always shown, with a refresh button. Data rides
// the status frame (broker fetches GET /api/oauth/usage on connect + refresh).
// utilization is a percentage 0–100; resets_at is an ISO-8601 instant rendered
// as a relative countdown. Mirrors apps/ios .../LitterAccountUsageCard.swift.
@Composable
fun NeonAccountUsageCard(
    fivePct: Double?,
    fiveResetsAt: String?,
    weekPct: Double?,
    weekResetsAt: String?,
    onRefresh: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Column {
        Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.padding(bottom = 6.dp, start = 4.dp)) {
            Text(
                "ACCOUNT USAGE",
                style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                color = neon.textDim,
            )
            Spacer(Modifier.weight(1f))
            IconButton(onClick = onRefresh, modifier = Modifier.size(28.dp)) {
                Icon(
                    Icons.Filled.Refresh,
                    contentDescription = "Refresh account usage",
                    tint = neon.accent,
                    modifier = Modifier.size(16.dp),
                )
            }
        }
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape((neon.radiusDp - 4).dp), fill = neon.surface)
                .padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            UsageWindowRow(neon, "5-hour", fivePct, fiveResetsAt)
            UsageWindowRow(neon, "Weekly", weekPct, weekResetsAt)
        }
    }
}

@Composable
private fun UsageWindowRow(neon: NeonTheme, label: String, pct: Double?, resetsAt: String?) {
    val fraction = ((pct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
    val tint = when {
        (pct ?: 0.0) < 70 -> neon.green
        (pct ?: 0.0) < 90 -> neon.yellow
        else -> neon.red
    }
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                label.uppercase(),
                style = androidx.compose.material3.MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                color = neon.textFaint,
            )
            Spacer(Modifier.weight(1f))
            Text(
                if (pct != null) "${pct.roundToInt()}%" else "—",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
                color = if (pct != null) neon.text else neon.textFaint,
            )
        }
        // Track + fill bar.
        Box(
            modifier = Modifier
                .fillMaxWidth()
                .height(8.dp)
                .clip(CircleShape)
                .background(neon.border),
        ) {
            Box(
                modifier = Modifier
                    .fillMaxWidth(fraction)
                    .height(8.dp)
                    .clip(CircleShape)
                    .background(tint),
            )
        }
        Text(
            resetCaption(resetsAt),
            fontFamily = neon.mono,
            fontSize = 10.5.sp,
            color = neon.textDim,
        )
    }
}

private fun resetCaption(iso: String?): String {
    if (iso == null) return "tap refresh to update"
    val date = runCatching { java.time.OffsetDateTime.parse(iso) }.getOrNull()
        ?: return "tap refresh to update"
    val secs = java.time.Duration.between(java.time.OffsetDateTime.now(), date).seconds
    if (secs <= 0) return "resetting…"
    return "resets in ${fmtInterval(secs)}"
}

private fun fmtInterval(secs: Long): String {
    val days = secs / 86_400
    val hours = (secs % 86_400) / 3_600
    val mins = (secs % 3_600) / 60
    return when {
        days > 0 -> "${days}d ${hours}h"
        hours > 0 -> "${hours}h ${mins}m"
        else -> "${mins}m"
    }
}
