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

/** Per-agent account usage for one agent ("claude" / "codex"). */
data class AgentUsageSnapshot(
    val agent: String,
    val fivePct: Double? = null,
    val fiveResetsAt: String? = null,
    val weekPct: Double? = null,
    val weekResetsAt: String? = null,
) {
    val hasData: Boolean get() = fivePct != null || weekPct != null
}

/**
 * Freshest account usage for each agent that carries any, in a stable
 * display order (claude first, then codex, then others). The broker now
 * folds BOTH Anthropic (/api/oauth/usage) and ChatGPT (/wham/usage —
 * codexaccountusage.go) limits into the same per-session status-frame
 * fields, so the ambient Home strip can show `claude · codex` side by side
 * (handoff §B.10) — but only for agents that actually have data, never a
 * fabricated number. Mirror of iOS `SessionStore.accountUsageByAgent`.
 */
fun accountUsageByAgent(
    sessions: List<ProjectSession>,
    statuses: Map<String, SessionStatus>,
): List<AgentUsageSnapshot> {
    val byAgent = LinkedHashMap<String, AgentUsageSnapshot>()
    for (s in sessions) {
        if (byAgent[s.assistant]?.hasData == true) continue
        val st = statuses[s.id]
        val five = st?.account5hPct ?: s.account5hPct
        val week = st?.account7dPct ?: s.account7dPct
        if (five == null && week == null) continue
        byAgent[s.assistant] = AgentUsageSnapshot(
            agent = s.assistant,
            fivePct = five,
            fiveResetsAt = st?.account5hResetsAt ?: s.account5hResetsAt,
            weekPct = week,
            weekResetsAt = st?.account7dResetsAt ?: s.account7dResetsAt,
        )
    }
    val order = listOf("claude", "codex")
    return byAgent.values.sortedWith(
        compareBy({ order.indexOf(it.agent).let { i -> if (i < 0) order.size else i } }, { it.agent }),
    )
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

    /** Compact reset for tight window rows — just the countdown (`5d 8h`),
     *  or `resetting…` once it elapses. "—" when unknown. */
    fun resetShort(iso: String?): String {
        if (iso == null) return "—"
        val date = runCatching { java.time.OffsetDateTime.parse(iso) }.getOrNull() ?: return "—"
        val secs = java.time.Duration.between(java.time.OffsetDateTime.now(), date).seconds
        if (secs <= 0) return "resetting…"
        return fmtInterval(secs)
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
    val agents = remember(sessions, statuses) { accountUsageByAgent(sessions, statuses).filter { it.hasData } }
    if (agents.isEmpty()) return
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
        // `claude 62% · codex 28%` — one dot + mini-bar + headline 5-hour %
        // per agent that carries usage (handoff §B.10).
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            agents.forEachIndexed { idx, a ->
                if (idx > 0) {
                    Text("·", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
                }
                AgentGlance(neon, a)
            }
            Spacer(Modifier.weight(1f))
            Icon(
                if (expanded) Icons.Filled.KeyboardArrowUp else Icons.Filled.KeyboardArrowDown,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
                tint = neon.textFaint,
            )
        }
        // Round-2 fix 4 (handoff images 07→08): every expanded window row
        // carries ALL THREE — meter · % used · reset. The old rows showed
        // only the reset caption, so the expanded view had LESS information
        // than the collapsed glance. Two rows per agent (5h + weekly),
        // agent-tinted.
        if (expanded) {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                agents.forEachIndexed { idx, a ->
                    if (idx > 0) {
                        androidx.compose.material3.HorizontalDivider(color = neon.border)
                    }
                    val tint = neonAgentColor(a.agent, neon)
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                            Box(Modifier.size(5.dp).background(tint, CircleShape))
                            Text(a.agent, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.5.sp, color = tint)
                        }
                        UsageWindowRow(neon, "5h", a.fivePct, a.fiveResetsAt, tint)
                        UsageWindowRow(neon, "weekly", a.weekPct, a.weekResetsAt, tint)
                    }
                }
            }
        }
    }
}

/**
 * One expanded window row: `label · meter · NN% · reset` (fix 4). The meter
 * fills with the agent tint; % is bold; the reset is the compact countdown
 * so the row stays one line.
 */
@Composable
private fun UsageWindowRow(neon: NeonTheme, label: String, pct: Double?, resetsAt: String?, tint: Color) {
    val frac = ((pct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            label,
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
            modifier = Modifier.width(42.dp),
        )
        Box(
            modifier = Modifier
                .weight(1f)
                .height(6.dp)
                .clip(CircleShape)
                .background(neon.border),
        ) {
            Box(Modifier.fillMaxWidth(frac).height(6.dp).clip(CircleShape).background(tint))
        }
        Text(
            if (pct != null) "${pct.roundToInt()}%" else "—",
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 11.5.sp,
            color = if (pct != null) neon.text else neon.textFaint,
            modifier = Modifier.width(38.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
        Text(
            AccountUsageFormat.resetShort(resetsAt),
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
            maxLines = 1,
            modifier = Modifier.width(64.dp),
            textAlign = androidx.compose.ui.text.style.TextAlign.End,
        )
    }
}

/**
 * One agent's collapsed glance: tinted dot, label, mini bar, headline %.
 *
 * The headline (and the mini-bar fill) is the MORE-CONSTRAINING of the two
 * windows — `max(5h%, weekly%)` — so it surfaces whichever limit is closest to
 * throttling; the expanded detail still breaks out both windows + their resets.
 * Falls back to whichever single window has data; null only when neither does
 * (those agents are already filtered out of the strip via `hasData`).
 */
@Composable
private fun AgentGlance(neon: NeonTheme, a: AgentUsageSnapshot) {
    val pct = listOfNotNull(a.fivePct, a.weekPct).maxOrNull()
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(6.dp).background(neonAgentColor(a.agent, neon), CircleShape))
        Text(a.agent, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = neon.textDim)
        val frac = ((pct ?: 0.0) / 100.0).coerceIn(0.0, 1.0).toFloat()
        Box(modifier = Modifier.width(34.dp).height(5.dp).clip(CircleShape).background(neon.border)) {
            Box(Modifier.fillMaxWidth(frac).height(5.dp).clip(CircleShape).background(neonAgentColor(a.agent, neon)))
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
