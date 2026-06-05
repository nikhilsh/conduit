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
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.PowerSettingsNew
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.Text
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import uniffi.conduit_core.ProjectSession

/**
 * Box health (handoff §B.7) — Android mirror of iOS
 * `ConduitUI.BoxHealthView` (`apps/ios/Sources/ConduitUI/Views/ConduitBoxHealthView.swift`).
 *
 * The redesign reference (`images/08-box-health.png`) shows CPU / MEM / DISK
 * rings + load / uptime / agent-runtime, the sessions running on the box, and a
 * Reconnect · SSH · Wake action row.
 *
 * ── Data honesty ──────────────────────────────────────────────────────────
 * There is **NO host-metrics source** anywhere in the stack. Grepped
 * `core/src` (`SessionStatus`, `ProjectSession`) and `broker/internal` for
 * cpu / mem / disk / load / uptime / loadavg / sysinfo — zero hits. The design's
 * percentage rings and load/uptime/runtime readouts have no data to bind to, so
 * the Health section renders an **honest unavailable state**: dimmed rings
 * showing "—" plus a one-line note ("metrics not reported by this box"). No
 * fabricated numbers.
 *
 * What IS real and shown:
 *   • Box identity      — [SavedServer.name] + `endpoint.displayHost`.
 *   • Connection status — derived like the Home boxes list:
 *                         `store.endpoint == server.endpoint` (is this the
 *                         active box) && `store.harness` (connected / offline).
 *   • Sessions on box   — `store.sessions` are the live sessions of the
 *                         *connected* endpoint, so they belong to this box only
 *                         when it is the active one. A non-active box shows a
 *                         "reconnect to view" hint (we can't enumerate a
 *                         machine's sessions without being connected to it).
 *
 * ── Per-box quota rule (handoff "Data model") ───────────────────────────────
 * Plan limits are **per account**, never per box. This screen shows NO quota —
 * just a hairline pointer to Settings ("limits are account-wide").
 *
 * ── Presentation / entry suggestion ─────────────────────────────────────────
 * Present as a screen (or bottom sheet) opened by tapping a box row in Home's
 * Boxes list. The caller passes the tapped [SavedServer] plus the real
 * reconnect action and (optional) SSH / Wake closures:
 *
 *     BoxHealthScreen(
 *         store = store,
 *         server = server,
 *         onReconnect = { store.selectSavedServer(server.id, autoConnect = true) },
 *         onDismiss = { /* pop */ },
 *     )
 *
 * [onReconnect] defaults to a no-op so the screen compiles standalone; the real
 * reconnect path is `store.reconnect()` (current endpoint) or
 * `store.selectSavedServer(id, autoConnect = true)` (switch + connect). SSH and
 * Wake have NO backing action in the store today, so they default to no-ops.
 */
@Composable
fun BoxHealthScreen(
    store: SessionStore,
    server: SavedServer,
    onReconnect: () -> Unit = {},
    onSSH: () -> Unit = {},
    onWake: () -> Unit = {},
    onDismiss: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()

    val isActive = endpoint == server.endpoint
    val connected = isActive && harness.canIssueCommands
    val sessionsOnBox = if (isActive) sessions else emptyList()

    val (statusText, statusColor) = when {
        !isActive -> "tap reconnect" to neon.textFaint
        harness is HarnessState.Live || harness is HarnessState.Linked -> "connected" to neon.green
        harness is HarnessState.Connecting -> "connecting…" to neon.yellow
        harness is HarnessState.Reconnecting -> "reconnecting…" to neon.yellow
        else -> "offline" to neon.textFaint
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(neon.bg)
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 18.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        // ── Header — name · host · status chip ──────────────────────────
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(
                    neon = neon,
                    shape = RoundedCornerShape(14.dp),
                    fill = if (connected) neon.green.copy(alpha = if (neon.dark) 0.06f else 0.04f) else neon.surface,
                    borderColor = if (connected) neon.green.copy(alpha = 0.27f) else neon.border,
                )
                .padding(13.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .clipRounded(9.dp)
                    .background((if (connected) neon.green else neon.accent).copy(alpha = 0.12f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(">_", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = if (connected) neon.green else neon.accent)
            }
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Text(server.name, fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 17.sp, color = neon.text, maxLines = 1)
                Text(server.endpoint.displayHost, fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint, maxLines = 1)
            }
            Row(
                modifier = Modifier
                    .clipRounded(99.dp)
                    .background(statusColor.copy(alpha = 0.12f))
                    .border(1.dp, statusColor.copy(alpha = 0.28f), RoundedCornerShape(99.dp))
                    .padding(horizontal = 9.dp, vertical = 5.dp),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(Modifier.size(7.dp).clipRounded(99.dp).background(statusColor))
                Text(statusText, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = statusColor)
            }
        }

        // ── Health — HONEST "metrics not reported" state ────────────────
        // Keep the three-ring layout from the design, but each ring is
        // dimmed at 0 with a "—" value: no host-metrics frame exists.
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface, borderColor = neon.border)
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SectionLabel("HEALTH")
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                UnavailableRing("CPU", Modifier.weight(1f))
                UnavailableRing("MEM", Modifier.weight(1f))
                UnavailableRing("DISK", Modifier.weight(1f))
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                Icon(Icons.Default.Info, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(13.dp))
                Text("metrics not reported by this box", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
            }
        }

        // ── Sessions on this box ────────────────────────────────────────
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface, borderColor = neon.border)
                .padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            SectionLabel("SESSIONS HERE")
            if (!isActive) {
                EmptyHint("reconnect to view this box's sessions")
            } else if (sessionsOnBox.isEmpty()) {
                EmptyHint("no sessions running on this box")
            } else {
                sessionsOnBox.forEach { session ->
                    SessionRow(
                        title = store.displayName(session),
                        assistant = session.assistant,
                        phase = statuses[session.id]?.phase,
                    )
                }
            }
        }

        // ── Account-wide limits pointer (NO per-box quota — data rule) ───
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface, borderColor = neon.border)
                .padding(12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(Icons.Default.Info, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(14.dp))
            Text(
                "Plan limits are account-wide, not per box — see Settings.",
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textFaint,
            )
        }

        // ── Actions — Reconnect · SSH · Wake ────────────────────────────
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionButton(Icons.Default.Refresh, "Reconnect", Modifier.weight(1f), onReconnect)
            ActionButton(Icons.Default.Terminal, "SSH", Modifier.weight(1f), onSSH)
            ActionButton(Icons.Default.PowerSettingsNew, "Wake", Modifier.weight(1f), onWake)
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(text, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textDim)
}

/**
 * A dimmed health ring — same `drawArc` idiom as the Session Info context
 * ring ([ContextRing] in NeonUsageCard): a full track arc + a (here empty)
 * fill arc rotated from -90°. No data → fill sweep is 0, value reads "—".
 */
@Composable
private fun UnavailableRing(label: String, modifier: Modifier = Modifier) {
    val neon = LocalNeonTheme.current
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(modifier = Modifier.size(64.dp), contentAlignment = Alignment.Center) {
            Canvas(Modifier.size(64.dp)) {
                val sw = 7.dp.toPx()
                val inset = sw / 2f
                val arcSize = Size(size.width - sw, size.height - sw)
                val topLeft = Offset(inset, inset)
                drawArc(
                    color = neon.border,
                    startAngle = -90f,
                    sweepAngle = 360f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = sw),
                )
                // Fill sweep intentionally 0f — metrics unavailable.
                drawArc(
                    color = neon.textFaint,
                    startAngle = -90f,
                    sweepAngle = 0f,
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = sw, cap = androidx.compose.ui.graphics.StrokeCap.Round),
                )
            }
            Text("—", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 18.sp, color = neon.textFaint)
        }
        Text(label, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, color = neon.textFaint)
    }
}

@Composable
private fun SessionRow(title: String, assistant: String, phase: String?) {
    val neon = LocalNeonTheme.current
    val tint = neonAgentColor(assistant, neon)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(11.dp),
                fill = tint.copy(alpha = if (neon.dark) 0.06f else 0.04f),
                borderColor = tint.copy(alpha = 0.22f),
            )
            .padding(horizontal = 11.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(26.dp).clipRounded(7.dp).background(tint.copy(alpha = 0.14f)),
            contentAlignment = Alignment.Center,
        ) {
            Box(Modifier.size(7.dp).clipRounded(99.dp).background(tint))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(title, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.text, maxLines = 1)
            Row(horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                Text(assistant.lowercase(), fontFamily = neon.mono, fontSize = 10.5.sp, color = tint)
                if (!phase.isNullOrBlank()) {
                    Text("· $phase", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint, maxLines = 1)
                }
            }
        }
        Icon(
            Icons.AutoMirrored.Filled.KeyboardArrowRight,
            contentDescription = null,
            tint = neon.textFaint,
            modifier = Modifier.size(16.dp),
        )
    }
}

@Composable
private fun EmptyHint(text: String) {
    val neon = LocalNeonTheme.current
    Text(text, fontFamily = neon.mono, fontSize = 11.5.sp, color = neon.textFaint)
}

@Composable
private fun ActionButton(icon: ImageVector, label: String, modifier: Modifier = Modifier, onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = modifier
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface, borderColor = neon.borderStrong)
            .clickable(onClick = onClick)
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(icon, contentDescription = null, tint = neon.accent, modifier = Modifier.size(16.dp))
        Spacer(Modifier.size(7.dp))
        Text(label, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.accent)
    }
}

private fun Modifier.clipRounded(radius: androidx.compose.ui.unit.Dp): Modifier =
    this.clip(RoundedCornerShape(radius))
