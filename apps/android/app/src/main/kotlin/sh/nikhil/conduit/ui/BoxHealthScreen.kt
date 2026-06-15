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
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material3.Icon
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
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
import androidx.compose.material3.CircularProgressIndicator
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import kotlin.math.roundToInt

/**
 * Box health (handoff §B.7) — Android mirror of iOS
 * `ConduitUI.BoxHealthView` (`apps/ios/Sources/ConduitUI/Views/ConduitBoxHealthView.swift`).
 *
 * The redesign reference (`images/08-box-health.png`) shows CPU / MEM / DISK
 * rings + load / uptime / agent-runtime, the sessions running on the box, and a
 * Reconnect · SSH action row.
 *
 * ── Data honesty ──────────────────────────────────────────────────────────
 * Host metrics are real as of broker v0.0.111: `GET /api/host/metrics`
 * (broker/internal/hostmetrics) serves CPU / MEM / DISK / load / uptime,
 * advertised by the `host_metrics` capability. The screen probes the box on
 * open; when the box does NOT report (older broker, non-Linux, unreachable)
 * the entire Health section is hidden — device feedback round 4 explicitly
 * asked for hide-over-dashes, replacing the earlier "—" placeholder rings.
 *
 * Shell is real too: brokers advertising `shell_sessions` carry a hidden
 * `shell` adapter (bash in the session PTY), so the button creates a plain
 * terminal session on the box and opens it (ProjectScreen lands shell
 * sessions on the Terminal tab). Wake was removed: no backend can wake a
 * WAN box, and dead buttons read as bugs.
 *
 * What else is real and shown:
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
 * `store.selectSavedServer(id, autoConnect = true)` (switch + connect). Shell
 * is self-contained: `store.createSession(assistant = "shell")` on the active
 * box, shown only when the box advertises `shell_sessions` and is connected.
 */
@Composable
fun BoxHealthScreen(
    store: SessionStore,
    server: SavedServer,
    onReconnect: () -> Unit = {},
    onDismiss: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()

    val isActive = endpoint == server.endpoint
    val connected = isActive && harness.canIssueCommands
    val sessionBox by store.sessionBox.collectAsState()
    // Fix 2: filter to sessions stamped with this box's id so sessions from
    // other previously-connected boxes don't bleed into this view.
    val sessionsOnBox = if (isActive) sessions.filter { sessionBox[it.id] == server.id } else emptyList()

    // Probe results for THIS box (fetched on open). null = probe not
    // finished or box doesn't answer -- dependent UI stays hidden.
    var metrics by remember(server.id) { mutableStateOf<SessionStore.HostMetrics?>(null) }
    var features by remember(server.id) { mutableStateOf<SessionStore.BoxFeatures?>(null) }
    var foundSnapshot by remember(server.id) { mutableStateOf<FoundSessionsSnapshot?>(null) }
    var showFoundSheet by remember { mutableStateOf(false) }
    LaunchedEffect(server.id) {
        Telemetry.breadcrumb("box_health", "open", mapOf("host" to server.endpoint.displayHost))
        features = store.fetchBoxFeatures(server.endpoint)
        if (features?.hostMetrics == true) {
            metrics = store.fetchHostMetrics(server.endpoint)
        }
        // Probe found sessions if the box advertises session_discovery
        if (features?.sessionDiscovery == true) {
            Telemetry.breadcrumb("found_sessions", "entry probe", mapOf("host" to server.endpoint.displayHost))
            foundSnapshot = FoundSessionsSnapshot(
                boxId = server.id,
                sessions = emptyList(),
                hiddenIds = store.hiddenFoundIds(server.id),
                query = "",
                filter = FoundFilter.RECENT,
                discoveryState = FoundDiscoveryState.Scanning,
            )
            val page = store.fetchDiscoveredSessions(server.endpoint)
            foundSnapshot = if (page == null) {
                FoundSessionsSnapshot(
                    boxId = server.id,
                    sessions = emptyList(),
                    hiddenIds = store.hiddenFoundIds(server.id),
                    query = "",
                    filter = FoundFilter.RECENT,
                    discoveryState = FoundDiscoveryState.Offline,
                )
            } else {
                FoundSessionsSnapshot(
                    boxId = server.id,
                    sessions = page.sessions.map { d ->
                        FoundSession(
                            externalId = d.externalId,
                            agent = d.agent,
                            title = d.title,
                            cwd = d.cwd,
                            gitBranch = d.gitBranch,
                            turnCount = d.turnCount,
                            lastActivityAtMs = d.lastActivityAtMs,
                            state = if (d.isRunning) FoundSessionState.RUNNING else FoundSessionState.IDLE,
                        )
                    },
                    hiddenIds = store.hiddenFoundIds(server.id),
                    query = "",
                    filter = FoundFilter.RECENT,
                    discoveryState = if (page.sessions.isEmpty()) FoundDiscoveryState.Empty else FoundDiscoveryState.Loaded,
                    totalOnDisk = page.totalOnDisk,
                )
            }
        }
    }

    val (statusText, statusColor) = when {
        !isActive -> "tap reconnect" to neon.textFaint
        harness is HarnessState.Live || harness is HarnessState.Linked -> "connected" to neon.green
        harness is HarnessState.Connecting -> "connecting…" to neon.yellow
        harness is HarnessState.Reconnecting -> "reconnecting…" to neon.yellow
        else -> "offline" to neon.textFaint
    }

    Box(modifier = Modifier.fillMaxWidth()) {
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
                // Fix 1: for SSH-tunneled boxes the endpoint is a loopback; show real ssh host:port.
                val subtitleHost = server.ssh?.let { "${it.host}:${it.port}" } ?: server.endpoint.displayHost
                Text(subtitleHost, fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint, maxLines = 1)
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

        // ── Health — live CPU / MEM / DISK rings ────────────────────────
        // Rendered only when the box reported a snapshot; hidden (not
        // dashed) otherwise — device feedback round 4.
        metrics?.let { m ->
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
                    MetricRing("CPU", m.cpuPct, Modifier.weight(1f))
                    MetricRing("MEM", m.memPct, Modifier.weight(1f))
                    MetricRing("DISK", m.diskPct, Modifier.weight(1f))
                }
                val load = m.load1
                val up = m.uptimeSecs
                if (load != null && up != null) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                        Icon(Icons.Default.Info, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(13.dp))
                        Text(
                            "load ${"%.2f".format(load)} · up ${uptimeText(up)}",
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textFaint,
                        )
                    }
                }
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

        // -- "Started outside Conduit" entry section -------------------------
        // Capability-gated on session_discovery. Hidden when count==0 and not
        // scanning. Offline -> dimmed card routing to reconnect.
        val showFound = FoundSessionsModel.showEntryCard(
            snapshot = foundSnapshot,
            sessionDiscovery = features?.sessionDiscovery == true,
        )
        if (showFound) {
            SectionLabel("STARTED OUTSIDE CONDUIT")
            val snap = foundSnapshot!!
            val hiddenIds = store.hiddenFoundIds(server.id)
            val count = snap.sessions.count { it.externalId !in hiddenIds }
            val scanning = snap.discoveryState is FoundDiscoveryState.Scanning
            val offline = snap.discoveryState is FoundDiscoveryState.Offline
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(
                        neon = neon,
                        shape = RoundedCornerShape(14.dp),
                        fill = neon.accent.copy(alpha = if (neon.dark) 0.05f else 0.03f),
                        borderColor = neon.accent.copy(alpha = if (offline) 0.12f else 0.25f),
                    )
                    .clickable(enabled = !offline) {
                        if (!offline) showFoundSheet = true
                        else onReconnect()
                    }
                    .padding(13.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                Box(
                    Modifier
                        .size(34.dp)
                        .clip(RoundedCornerShape(9.dp))
                        .background(neon.accent.copy(alpha = if (offline) 0.05f else 0.12f)),
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        Icons.Default.Terminal,
                        contentDescription = null,
                        tint = neon.accent.copy(alpha = if (offline) 0.4f else 1f),
                        modifier = Modifier.size(17.dp),
                    )
                }
                Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text(
                        "Continue a session",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 14.sp,
                        color = neon.text.copy(alpha = if (offline) 0.4f else 1f),
                    )
                    Text(
                        when {
                            offline -> "offline -- can't scan"
                            scanning -> "scanning..."
                            else -> "$count found -- resume or branch a copy"
                        },
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.textFaint.copy(alpha = if (offline) 0.4f else 1f),
                        maxLines = 1,
                    )
                }
                if (scanning) {
                    CircularProgressIndicator(
                        color = neon.accent,
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                    )
                } else if (!offline) {
                    Box(
                        Modifier
                            .clip(RoundedCornerShape(99.dp))
                            .background(neon.accent.copy(alpha = 0.15f))
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    ) {
                        Text(
                            count.toString(),
                            fontFamily = neon.mono,
                            fontWeight = FontWeight.Bold,
                            fontSize = 12.sp,
                            color = neon.accent,
                        )
                    }
                }
            }
            // Footnote
            Row(
                Modifier.padding(horizontal = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(5.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Default.Info, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(11.dp))
                Text(
                    "Claude & Codex sessions you launched by hand. Conduit picks up where they left off -- it doesn't take over a live one.",
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
            }
        }

        // -- Account-wide limits pointer (NO per-box quota -- data rule) ---
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

        // ── Actions — Reconnect · Shell ─────────────────────────────────
        // Shell shows only when this box's broker advertises
        // `shell_sessions` AND the box is the connected one (session
        // create rides the live WS client, bound to the active endpoint).
        // Wake is gone: no backend can wake a WAN box.
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            ActionButton(Icons.Default.Refresh, "Reconnect", Modifier.weight(1f), onReconnect)
            if (features?.shellSessions == true && connected) {
                ActionButton(Icons.Default.Terminal, "Shell", Modifier.weight(1f)) {
                    Telemetry.breadcrumb("box_health", "shell open", mapOf("host" to server.endpoint.displayHost))
                    store.createSession(assistant = "shell")
                    onDismiss()
                }
            }
        }
        // -- FoundSessionsSheet modal --
        if (showFoundSheet) {
            FoundSessionsSheet(
                store = store,
                server = server,
                sessionFork = features?.sessionFork == true,
                onDismiss = { showFoundSheet = false },
                onOpenSession = { _ ->
                    // Select this box and navigate to the session.
                    store.selectSavedServer(server.id, autoConnect = true)
                    showFoundSheet = false
                    onDismiss()
                },
            )
        }
    } // end Column
  } // end Box
}

/** "3d 4h" / "5h 12m" / "9m" — coarse box uptime. */
private fun uptimeText(secs: Long): String {
    val mins = secs / 60
    val hours = mins / 60
    val days = hours / 24
    return when {
        days > 0 -> "${days}d ${hours % 24}h"
        hours > 0 -> "${hours}h ${mins % 60}m"
        else -> "${mins}m"
    }
}

@Composable
private fun SectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(text, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = neon.textDim)
}

/**
 * A live health ring — same `drawArc` idiom as the Session Info context
 * ring ([ContextRing] in NeonUsageCard): a full track arc + a fill arc
 * from -90° sweeping `pct` of the circle. Color escalates with pressure:
 * accent → yellow ≥ 75 → red ≥ 90. Mirrors iOS `metricRing`.
 */
@Composable
private fun MetricRing(label: String, pct: Double, modifier: Modifier = Modifier) {
    val neon = LocalNeonTheme.current
    val clamped = pct.coerceIn(0.0, 100.0)
    val color = when {
        clamped >= 90 -> neon.red
        clamped >= 75 -> neon.yellow
        else -> neon.accent
    }
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
                drawArc(
                    color = color,
                    startAngle = -90f,
                    sweepAngle = (clamped / 100.0 * 360.0).toFloat(),
                    useCenter = false,
                    topLeft = topLeft,
                    size = arcSize,
                    style = Stroke(width = sw, cap = androidx.compose.ui.graphics.StrokeCap.Round),
                )
            }
            Text(
                "${clamped.roundToInt()}%",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 15.sp,
                color = neon.text,
            )
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
