package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlin.math.roundToInt
import sh.nikhil.conduit.SessionStore
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

// Ambient account-usage surfaces (design handoff §3b). The Claude plan limits
// (5-hour + weekly windows from GET /api/oauth/usage) used to live only in the
// per-session Info sheet; these lift them into a slim Home strip and a Settings
// card. Account-level (not per-session) and Claude-only — Codex has no usage
// endpoint, so we show Claude and omit Codex rather than fabricate a number.
// Mirrors apps/ios .../ConduitUsageSurfaces.swift.

/** Account-level Claude plan-limit snapshot. Claude-only by design. */
data class AccountUsageSnapshot(
    val fivePct: Double? = null,
    val fiveResetsAt: String? = null,
    val weekPct: Double? = null,
    val weekResetsAt: String? = null,
    val sourceSessionId: String? = null,
) {
    val hasData: Boolean get() = fivePct != null || weekPct != null
}

/** Freshest account usage across claude sessions (live status preferred). */
fun accountUsageSnapshot(
    sessions: List<ProjectSession>,
    statuses: Map<String, SessionStatus>,
): AccountUsageSnapshot {
    for (s in sessions) {
        if (s.assistant != "claude") continue
        val st = statuses[s.id]
        val five = st?.account5hPct ?: s.account5hPct
        val week = st?.account7dPct ?: s.account7dPct
        if (five != null || week != null) {
            return AccountUsageSnapshot(
                fivePct = five,
                fiveResetsAt = st?.account5hResetsAt ?: s.account5hResetsAt,
                weekPct = week,
                weekResetsAt = st?.account7dResetsAt ?: s.account7dResetsAt,
                sourceSessionId = s.id,
            )
        }
    }
    return AccountUsageSnapshot(sourceSessionId = sessions.firstOrNull { it.assistant == "claude" }?.id)
}

internal object AccountUsageFormat {
    fun tint(pct: Double, neon: NeonTheme): Color = when {
        pct < 70 -> neon.green
        pct < 90 -> neon.yellow
        else -> neon.red
    }

    fun resetCaption(iso: String?): String {
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
}

/**
 * Slim, tappable Home strip: the account's Claude plan limits (weekly + 5-hour)
 * with mini bars. Tap expands one `scope · resets` line per window. Self-hides
 * until data exists so it never dominates the session list (ambient, §3b).
 */
@Composable
fun HomeUsageStrip(store: SessionStore, modifier: Modifier = Modifier) {
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val u = remember(sessions, statuses) { accountUsageSnapshot(sessions, statuses) }
    if (!u.hasData) return
    val neon = LocalNeonTheme.current
    var expanded by remember { mutableStateOf(false) }
    Column(
        modifier = modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface)
            .clickable { expanded = !expanded }
            .padding(horizontal = 12.dp, vertical = 9.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Box(Modifier.size(6.dp).background(neon.claude, CircleShape))
            Text("claude", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = neon.textDim)
            MiniBar(neon, "weekly", u.weekPct)
            MiniBar(neon, "5h", u.fivePct)
            Spacer(Modifier.weight(1f))
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = neon.textFaint,
            )
        }
        if (expanded) {
            Column(verticalArrangement = Arrangement.spacedBy(4.dp)) {
                Text("weekly · ${AccountUsageFormat.resetCaption(u.weekResetsAt)}", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textDim)
                Text("5h window · ${AccountUsageFormat.resetCaption(u.fiveResetsAt)}", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textDim)
            }
        }
    }
}

/**
 * Settings "Usage & limits" card: collapsed = two sparks; tap to expand to full
 * per-window bars + reset countdowns and a note that limits are account-wide.
 * Claude-only. Tablet shows it expanded (`startExpanded = true`).
 */
@Composable
fun UsageLimitsCard(store: SessionStore, startExpanded: Boolean = false) {
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val u = remember(sessions, statuses) { accountUsageSnapshot(sessions, statuses) }
    val neon = LocalNeonTheme.current
    var expanded by remember { mutableStateOf(startExpanded) }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            modifier = Modifier.clickable { expanded = !expanded },
        ) {
            Box(Modifier.size(6.dp).background(neon.claude, CircleShape))
            Text("claude", fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = neon.textDim)
            Spacer(Modifier.weight(1f))
            if (!expanded) {
                MiniBar(neon, "weekly", u.weekPct)
                MiniBar(neon, "5h", u.fivePct)
            }
            IconButton(onClick = { store.refreshAccountUsage() }, modifier = Modifier.size(26.dp)) {
                Icon(Icons.Filled.Refresh, contentDescription = "Refresh account usage", tint = neon.accent, modifier = Modifier.size(15.dp))
            }
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = neon.textFaint,
            )
        }
        if (expanded) {
            UsageWindowBar(neon, "5-hour", u.fivePct, u.fiveResetsAt)
            UsageWindowBar(neon, "Weekly", u.weekPct, u.weekResetsAt)
            Text(
                "usage counts every session on this account, across boxes.",
                fontFamily = neon.mono,
                fontSize = 10.sp,
                color = neon.textFaint,
            )
        }
    }
}

@Composable
private fun MiniBar(neon: NeonTheme, label: String, pct: Double?) {
    val frac = ((pct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Text(label, fontFamily = neon.mono, fontSize = 10.sp, color = neon.textFaint)
        Box(
            modifier = Modifier.width(34.dp).height(5.dp).clip(CircleShape).background(neon.border),
        ) {
            Box(Modifier.fillMaxWidth(frac).height(5.dp).clip(CircleShape).background(AccountUsageFormat.tint(pct ?: 0.0, neon)))
        }
        Text(
            if (pct != null) "${pct.roundToInt()}%" else "—",
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 11.sp,
            color = neon.text,
        )
    }
}

@Composable
private fun UsageWindowBar(neon: NeonTheme, label: String, pct: Double?, resetsAt: String?) {
    val frac = ((pct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
    val tint = AccountUsageFormat.tint(pct ?: 0.0, neon)
    Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(label.uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, color = neon.textFaint)
            Spacer(Modifier.weight(1f))
            Text(
                if (pct != null) "${pct.roundToInt()}%" else "—",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 13.sp,
                color = if (pct != null) neon.text else neon.textFaint,
            )
        }
        Box(modifier = Modifier.fillMaxWidth().height(8.dp).clip(CircleShape).background(neon.border)) {
            Box(Modifier.fillMaxWidth(frac).height(8.dp).clip(CircleShape).background(tint))
        }
        Text(AccountUsageFormat.resetCaption(resetsAt), fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textDim)
    }
}
