package sh.nikhil.swekitty.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.List
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.SessionLifecycle
import sh.nikhil.swekitty.SessionNaming

/**
 * Litter-style home screen — shown when no session is selected, in
 * place of `EmptyDetail`. Top row (settings · title · list) +
 * ServerTabsStrip + sessions list + BottomActionBar (mic / + / search).
 * Mirrors `apps/ios/Sources/Views/HomeView.swift`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(
    store: SessionStore,
    onOpenSettings: () -> Unit,
    onOpenDrawer: () -> Unit,
    onAddServer: () -> Unit,
    onNewSession: () -> Unit,
    onSearch: () -> Unit,
    onVoice: () -> Unit,
) {
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val sessions by store.sessions.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    // Collected so a row's friendly name recomposes the moment the first
    // user message lands in the conversation log.
    val conversationLog by store.conversationLog.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val selectedId by store.selectedId.collectAsState()

    // Pending exit target for the session-row long-press confirmation.
    // Mirror of iOS PR #128's `pendingDelete` on LitterHomeView — we
    // keep the title alongside the id so the prompt can name the
    // session being ended without re-resolving displayNames.
    var pendingDelete by remember { mutableStateOf<SessionDeleteTarget?>(null) }

    Column(modifier = Modifier.fillMaxSize().padding(top = 8.dp)) {
        // Top row. Litter parity put settings behind a hidden long-press
        // on the title — undiscoverable in practice (user feedback
        // 2026-05-23). Restore a visible gear in the leading slot; the
        // long-press stays as a secondary path. Trailing keeps the
        // sessions-drawer affordance (litter has no remote multiplexer
        // so this is swe-kitty-specific).
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CircleIconButton(Icons.Default.Settings, "Settings", onClick = onOpenSettings)
            Spacer(Modifier.weight(1f))
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.combinedClickable(
                    onClick = {},
                    onLongClick = onOpenSettings,
                ),
            ) {
                Text("SweKitty", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    if (endpoint.isComplete) endpoint.displayHost else "no server",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Spacer(Modifier.weight(1f))
            CircleIconButton(Icons.Default.List, "Sessions", onClick = onOpenDrawer)
        }

        Spacer(Modifier.height(12.dp))

        // ServerTabsStrip
        Row(
            modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Spacer(Modifier.width(8.dp))
            savedServers.forEach { server ->
                val isActive = endpoint == server.endpoint
                // device bug #23: the dot meant "selected", so it stayed
                // green with the broker down. Drive it from the live
                // connection state for the active server.
                val dotColor = when {
                    !isActive -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                    harness is HarnessState.Live || harness is HarnessState.Linked -> SweKittyTheme.accentStrong()
                    harness is HarnessState.Connecting || harness is HarnessState.Reconnecting -> SweKittyTheme.warning()
                    else -> MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f)
                }
                Surface(
                    shape = RoundedCornerShape(50),
                    color = if (isActive) SweKittyTheme.accentStrong().copy(alpha = 0.32f) else MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
                    modifier = Modifier.clickable { store.selectSavedServer(server.id, autoConnect = true) },
                ) {
                    Row(
                        modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(6.dp)
                                .background(dotColor, CircleShape),
                        )
                        Text(
                            server.name,
                            style = MaterialTheme.typography.titleSmall,
                            fontWeight = FontWeight.SemiBold,
                            maxLines = 1,
                        )
                    }
                }
            }
            // Add server pill
            Surface(
                shape = RoundedCornerShape(50),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                modifier = Modifier.clickable { onAddServer() },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 8.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Icon(Icons.Default.Add, null, modifier = Modifier.size(14.dp))
                    Text("server", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                }
            }
            Spacer(Modifier.width(8.dp))
        }

        Spacer(Modifier.height(12.dp))

        // Sessions list
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            if (sessions.isEmpty()) {
                Column(
                    modifier = Modifier.fillMaxSize().padding(24.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(
                        if (canIssueCommands(harness)) "No sessions yet" else "Waiting for server",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        if (canIssueCommands(harness))
                            "Tap + below to spin up a new conversation."
                        else
                            "Once we can reach the server, your sessions appear here.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp),
                ) {
                    sessions.forEach { session ->
                        val isSelected = selectedId == session.id
                        // device bug #9: dot tracks run state, not selection.
                        // device bug #30: and only green when actually
                        // connected — a stale "running" phase must not show
                        // green while the connection is down.
                        val connected = harness is HarnessState.Live || harness is HarnessState.Linked
                        val phase = statuses[session.id]?.phase
                        val isRunning = connected && !(phase ?: "ready").startsWith("exited")
                        // Friendly name (never the raw UUID): custom rename →
                        // first user message → broker label → "<agent> · time".
                        // Derived from the collected displayNames + conversation
                        // log so the row recomposes when either changes.
                        val rowTitle = SessionNaming.friendlyFor(
                            session = session,
                            custom = displayNames[session.id],
                            firstUserMessage = sh.nikhil.swekitty.firstUserMessageOf(
                                conversationLog[session.id],
                            ),
                        )
                        // Active-row fill per audit §A.1.3 — litter
                        // selects by painting a 6dp rounded rect at
                        // 55% surfaceVariant, not by swapping an icon.
                        Surface(
                            shape = RoundedCornerShape(LitterHomeRowMetrics.activeRowCornerRadius.dp),
                            color = if (isSelected)
                                MaterialTheme.colorScheme.surfaceVariant.copy(alpha = LitterHomeRowMetrics.activeRowOpacity)
                            else
                                androidx.compose.ui.graphics.Color.Transparent,
                            modifier = Modifier
                                .fillMaxWidth()
                                .combinedClickable(
                                    onClick = { store.select(session.id) },
                                    onLongClick = {
                                        pendingDelete = SessionDeleteTarget(session.id, rowTitle)
                                    },
                                ),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    // Comfortable two-line row with a proper
                                    // tap target — looser than the single-line
                                    // litter metrics now that the secondary
                                    // line carries an agent chip + time.
                                    .padding(horizontal = 8.dp, vertical = 10.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(12.dp),
                            ) {
                                // Status dot: copper accent when live/running,
                                // muted when exited/idle/offline.
                                Box(
                                    modifier = Modifier
                                        .size(LitterHomeRowMetrics.indicatorSize.dp)
                                        .background(
                                            color = if (isRunning) SweKittyTheme.accentStrong() else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                                            shape = CircleShape,
                                        ),
                                )
                                Column(
                                    modifier = Modifier.weight(1f),
                                    verticalArrangement = Arrangement.spacedBy(5.dp),
                                ) {
                                    // Prominent friendly name, single line.
                                    Text(
                                        rowTitle,
                                        style = MaterialTheme.typography.titleSmall,
                                        fontWeight = FontWeight.SemiBold,
                                        color = MaterialTheme.colorScheme.onSurface,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    // Secondary line: agent chip + status + relative time.
                                    SessionMetaRow(
                                        agent = session.assistant,
                                        statusLabel = sessionStatusLabel(connected, phase),
                                        running = isRunning,
                                        relativeTime = SessionNaming.relativeAgo(
                                            session.lastActivityAt ?: session.startedAt,
                                        ),
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }

        // Bottom action bar — audit §A.1.5 / PR 3. Litter uses 44dp
        // for ALL three controls (not 52/68); the prior 68dp filled
        // accent + plus over-built the FAB relative to the mic/search
        // peers. We keep the brand fill on the plus so it still reads
        // as the primary action, but the size now matches.
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally),
        ) {
            CircleActionButton(Icons.Default.Mic, "Voice", size = 44.dp, onClick = onVoice)
            Surface(
                shape = CircleShape,
                color = SweKittyTheme.accentStrong(),
                modifier = Modifier
                    .size(44.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onNewSession),
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "New session",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(22.dp),
                    )
                }
            }
            CircleActionButton(Icons.Default.Search, "Search", size = 44.dp, onClick = onSearch)
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete session?") },
            text = {
                Text(
                    "This permanently deletes ${target.title} from the server, including its history.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    store.exit(target.id)
                    pendingDelete = null
                }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

/**
 * Carrier for the long-press delete confirmation on the home sessions
 * list. Holds the session id (so we know what to call `store.exit` on)
 * plus its already-resolved title (so the prompt can name the session
 * without re-resolving `displayNames` at render time, and the row's
 * label can never disagree with the alert's body text).
 */
private data class SessionDeleteTarget(val id: String, val title: String)

/**
 * Row metrics for the litter-faithful home list, mirror of iOS
 * `HomeRowMetrics`. Extracted as named constants so
 * `LitterHomeRowMetricsTest` can pin them — silently regrowing any of
 * these would re-introduce the audit drift PR 3 is trying to stop
 * (audit §A.1.1 / §A.1.2 / §A.1.7).
 */
internal object LitterHomeRowMetrics {
    const val titlePointSize: Float = 13f
    const val subtitlePointSize: Float = 11f
    const val leadingPadding: Float = 1f
    const val trailingPadding: Float = 8f
    const val verticalPadding: Float = 5f
    const val indicatorSize: Float = 7f
    const val activeRowCornerRadius: Float = 6f
    const val activeRowOpacity: Float = 0.55f
}

private fun canIssueCommands(state: HarnessState): Boolean = when (state) {
    is HarnessState.Live, is HarnessState.Linked -> true
    else -> false
}

/**
 * Human-readable status word for a session row. When the connection is
 * down we say "idle" rather than echoing a stale "running" phase (device
 * bug #30 parity). Otherwise map the broker phase to a short word.
 */
private fun sessionStatusLabel(connected: Boolean, phase: String?): String {
    if (!connected) return "idle"
    val p = (phase ?: "ready").trim().lowercase()
    return when {
        p.isEmpty() -> "idle"
        p.startsWith("exited") -> "exited"
        p.startsWith("failed") || p.startsWith("dead") -> "exited"
        p == "ready" || p == "idle" -> "idle"
        else -> p
    }
}

/**
 * Secondary line for a session row: an agent chip, a status word with a
 * matching dot, and a relative time, all in one tidy line. Replaces the
 * old monospace "<agent> · <phase>" plus the ugly ephemeral working dir.
 */
@Composable
private fun SessionMetaRow(
    agent: String,
    statusLabel: String,
    running: Boolean,
    relativeTime: String,
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Agent chip — tinted capsule with the agent name.
        val tint = SweKittyTheme.accent(forAgent = agent)
        Surface(
            shape = RoundedCornerShape(50),
            color = tint.copy(alpha = 0.18f),
        ) {
            Text(
                agent,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
                maxLines = 1,
            )
        }
        // Status word with a small dot.
        Box(
            modifier = Modifier
                .size(6.dp)
                .background(
                    color = if (running) SweKittyTheme.accentStrong()
                    else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                    shape = CircleShape,
                ),
        )
        Text(
            statusLabel,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (relativeTime.isNotEmpty()) {
            Text(
                "·",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
            )
            Text(
                relativeTime,
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.8f),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun CircleIconButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.65f),
        modifier = Modifier.size(40.dp).clip(CircleShape).clickable(onClick = onClick),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
            Icon(icon, contentDescription = contentDescription, modifier = Modifier.size(18.dp))
        }
    }
}

@Composable
private fun CircleActionButton(icon: ImageVector, contentDescription: String, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    Surface(
        shape = CircleShape,
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
        modifier = Modifier.size(size).clip(CircleShape).clickable(onClick = onClick),
    ) {
        Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
            Icon(icon, contentDescription = contentDescription, modifier = Modifier.size(22.dp))
        }
    }
}
