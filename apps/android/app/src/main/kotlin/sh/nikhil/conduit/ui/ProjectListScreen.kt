package sh.nikhil.conduit.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.*
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
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.VisibleSession

@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun ProjectListScreen(
    store: SessionStore,
    onOpenSettings: () -> Unit,
    onCloseDrawer: () -> Unit,
) {
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val selectedId by store.selectedId.collectAsState()
    val harness by store.harness.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val creationError by store.sessionCreationError.collectAsState()
    var showAgentPicker by remember { mutableStateOf(false) }
    var showAddServer by remember { mutableStateOf(false) }
    // Long-press archive confirmation target. The drawer list previously
    // had no delete affordance (only HomeScreen did); we mirror that
    // long-press → confirm → store.archive flow here. Archiving ends the
    // live session on the broker (PR #206 DELETE) but keeps it read-only
    // in History; permanent deletion is a History-only action.
    var pendingDelete by remember { mutableStateOf<DrawerSessionDeleteTarget?>(null) }

    val visible = remember(sessions, lifecycle) { store.visibleSessions() }
    val connected = harness is HarnessState.Live || harness is HarnessState.Linked

    ModalDrawerSheet(modifier = Modifier.fillMaxHeight()) {
        // statusBarsPadding so the "Conduit" title clears the system clock —
        // applies both as the phone nav drawer and the tablet left pane
        // (device bug: top cuts into the status bar).
        Column(modifier = Modifier.fillMaxSize().statusBarsPadding()) {
            // Title + actions — Material header (title + endpoint subtitle).
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "Conduit",
                        style = MaterialTheme.typography.titleLarge,
                        fontWeight = FontWeight.SemiBold,
                        color = MaterialTheme.colorScheme.onSurface,
                    )
                    Text(
                        endpoint.displayHost,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, "Settings") }
                IconButton(onClick = {
                    if (harness.canIssueCommands) showAgentPicker = true else showAddServer = true
                }) { Icon(Icons.Default.Add, "New session") }
            }

            HarnessStatusStrip(
                harness = harness,
                onReconnect = { store.reconnect() },
                modifier = Modifier.padding(horizontal = 16.dp),
            )

            creationError?.let { msg ->
                Spacer(Modifier.height(8.dp))
                InlineErrorBanner(
                    message = msg,
                    onDismiss = { store.clearSessionCreationError() },
                    modifier = Modifier.padding(horizontal = 16.dp),
                )
            }

            Spacer(Modifier.height(8.dp))
            HorizontalDivider()

            if (visible.isEmpty()) {
                EmptySessionsHint(
                    canCreate = harness.canIssueCommands,
                    onCreate = { agent ->
                        store.createSession(agent)
                    },
                    modifier = Modifier.padding(16.dp),
                )
            } else {
                LazyColumn(
                    modifier = Modifier.weight(1f),
                    contentPadding = PaddingValues(vertical = 8.dp),
                ) {
                    item {
                        SectionHeader(
                            label = if (connected) "Live" else "Sessions",
                            modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                        )
                    }
                    items(visible, key = { it.id }) { entry ->
                        val realSession = (entry as? VisibleSession.Real)?.session
                        val realId = realSession?.id
                        // Friendly, never-raw-UUID label (custom rename →
                        // first user message → broker label → "<agent> · time").
                        // Derived from collected state so the row recomposes
                        // when the rename map or conversation log changes.
                        val friendly = realSession?.let { s ->
                            sh.nikhil.conduit.SessionNaming.friendlyFor(
                                session = s,
                                custom = displayNames[s.id],
                                firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(
                                    conversationLog[s.id],
                                ),
                            )
                        }
                        SessionRow(
                            entry = entry,
                            displayName = friendly,
                            health = realId?.let { statuses[it]?.health },
                            phase = realId?.let { statuses[it]?.phase },
                            lifecycle = lifecycle[entry.id],
                            connected = connected,
                            selected = entry.id == selectedId,
                            onTap = {
                                if (entry is VisibleSession.Real) {
                                    store.select(entry.session.id)
                                    onCloseDrawer()
                                }
                            },
                            onLongPress = {
                                if (entry is VisibleSession.Real) {
                                    pendingDelete = DrawerSessionDeleteTarget(
                                        entry.session.id,
                                        friendly ?: entry.session.id.take(8),
                                    )
                                }
                            },
                        )
                    }
                }
            }
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive session?") },
            text = {
                Text(
                    "Ends ${target.title} on the server. It stays in History (read-only) — delete it permanently from there.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    store.archive(target.id)
                    pendingDelete = null
                }) {
                    Text("Archive")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }

    if (showAgentPicker) {
        AgentPickerSheet(
            store = store,
            headerNote = null,
            onDismiss = { showAgentPicker = false },
        )
    }
    if (showAddServer) {
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }
}

/**
 * Carrier for the session-row long-press delete confirmation. Holds the
 * id (the [SessionStore.exit] target, which now also fires the broker
 * DELETE from PR #206) plus the already-resolved title so the alert can
 * name the session without re-reading displayNames at render time.
 */
private data class DrawerSessionDeleteTarget(val id: String, val title: String)

@Composable
private fun SectionHeader(label: String, modifier: Modifier = Modifier) {
    Text(
        label.uppercase(),
        modifier = modifier,
        style = MaterialTheme.typography.titleSmall,
        fontWeight = FontWeight.SemiBold,
        color = MaterialTheme.colorScheme.onSurfaceVariant,
    )
}

@Composable
fun HealthDot(health: String?, size: androidx.compose.ui.unit.Dp = 10.dp) {
    val color = when (health) {
        "green"  -> Color(0xFF34C759)
        "yellow" -> Color(0xFFEAB308)
        "red"    -> Color(0xFFEF4444)
        else     -> Color(0xFF94A3B8)
    }
    Box(
        modifier = Modifier
            .size(size)
            .clip(CircleShape)
            .background(color)
    )
}

@Composable
fun HarnessStatusStrip(
    harness: HarnessState,
    onReconnect: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(ConduitTheme.smallCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
        tonalElevation = 1.dp,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            HarnessBadge(harness)
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    harness.badgeLabel,
                    style = MaterialTheme.typography.labelLarge,
                    fontWeight = FontWeight.SemiBold,
                    color = MaterialTheme.colorScheme.onSurface,
                )
                harness.failureReason?.let {
                    Text(
                        it,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
            if (harness is HarnessState.Failed || harness is HarnessState.Disconnected) {
                TextButton(onClick = onReconnect) {
                    Icon(Icons.Default.Refresh, contentDescription = null, tint = LocalNeonTheme.current.accent)
                    Spacer(Modifier.width(4.dp))
                    Text("Reconnect", color = LocalNeonTheme.current.accent)
                }
            }
        }
    }
}

@Composable
fun HarnessBadge(state: HarnessState) {
    when (state) {
        is HarnessState.Connecting,
        is HarnessState.Reconnecting -> CircularProgressIndicator(
            modifier = Modifier.size(14.dp),
            strokeWidth = 2.dp,
        )
        is HarnessState.Live -> HealthDot("green", 12.dp)
        is HarnessState.Linked -> HealthDot("yellow", 12.dp)
        is HarnessState.Failed -> HealthDot("red", 12.dp)
        is HarnessState.Disconnected -> HealthDot(null, 12.dp)
    }
}

@Composable
private fun InlineErrorBanner(
    message: String,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(ConduitTheme.smallCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.errorContainer,
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Outlined.Warning,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onErrorContainer,
            )
            Spacer(Modifier.width(10.dp))
            Text(
                message,
                modifier = Modifier.weight(1f),
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onErrorContainer,
                maxLines = 3,
                overflow = TextOverflow.Ellipsis,
            )
            IconButton(onClick = onDismiss, modifier = Modifier.size(20.dp)) {
                Icon(Icons.Default.Close, "Dismiss", tint = MaterialTheme.colorScheme.onErrorContainer)
            }
        }
    }
}

@Composable
private fun EmptySessionsHint(
    canCreate: Boolean,
    onCreate: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Surface(
        modifier = modifier.fillMaxWidth(),
        shape = RoundedCornerShape(ConduitTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f),
        tonalElevation = 1.dp,
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                if (canCreate) "Start a session" else "Waiting for server",
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurface,
            )
            Spacer(Modifier.height(6.dp))
            Text(
                if (canCreate)
                    "Pick an agent and we'll spin up a new conversation against the server."
                else
                    "Once we can reach the server this is where your sessions will appear.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            if (canCreate) {
                Spacer(Modifier.height(12.dp))
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Button(onClick = { onCreate("claude") }) { Text("Claude") }
                    OutlinedButton(onClick = { onCreate("codex") }) { Text("Codex") }
                }
            }
        }
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun SessionRow(
    entry: VisibleSession,
    displayName: String?,
    health: String?,
    phase: String?,
    lifecycle: SessionLifecycle?,
    connected: Boolean,
    selected: Boolean,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
) {
    val isFailed = lifecycle is SessionLifecycle.FailedToStart
    // device bug #30 parity: only "live" when the connection is actually
    // up — a stale "running" phase must not read green while offline.
    val isRunning = entry is VisibleSession.Real &&
        connected && !(phase ?: "ready").startsWith("exited")

    // Material tonal containers instead of the iOS copper glass pill:
    //  - selected → accent-tinted secondary container (copper, Material way)
    //  - failed   → errorContainer
    //  - else     → surfaceVariant tonal card
    val containerColor = when {
        selected -> LocalNeonTheme.current.accent.copy(alpha = 0.16f)
        isFailed -> MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.6f)
        else     -> MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.5f)
    }

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 4.dp)
            .combinedClickable(
                enabled = entry is VisibleSession.Real,
                onClick = onTap,
                onLongClick = onLongPress,
            ),
        shape = RoundedCornerShape(ConduitTheme.smallCornerRadiusDp.dp),
        colors = CardDefaults.cardColors(containerColor = containerColor),
        elevation = CardDefaults.cardElevation(defaultElevation = if (selected) 2.dp else 1.dp),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            when {
                lifecycle is SessionLifecycle.Creating ->
                    CircularProgressIndicator(modifier = Modifier.size(14.dp), strokeWidth = 2.dp)
                isFailed ->
                    Icon(
                        Icons.Outlined.Warning,
                        contentDescription = null,
                        tint = MaterialTheme.colorScheme.error,
                        modifier = Modifier.size(14.dp),
                    )
                else ->
                    // Leading status dot: copper accent when live/running,
                    // muted onSurfaceVariant when exited/idle.
                    Box(
                        modifier = Modifier
                            .size(10.dp)
                            .clip(CircleShape)
                            .background(
                                if (isRunning) LocalNeonTheme.current.accent
                                else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
                            ),
                    )
            }
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    rowTitle(entry, displayName),
                    style = MaterialTheme.typography.titleSmall,
                    fontWeight = FontWeight.Medium,
                    color = MaterialTheme.colorScheme.onSurface,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    rowSubtitle(entry, phase, lifecycle),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Headline for a row: the friendly `displayName` the caller resolved
 * (custom rename → first user message → broker label → "<agent> · time"),
 * never the raw UUID. Falls back to a short id only if the friendly name
 * is somehow blank.
 */
private fun rowTitle(entry: VisibleSession, displayName: String?): String = when (entry) {
    is VisibleSession.Real -> {
        val s = entry.session
        displayName?.trim()?.takeIf { it.isNotEmpty() }
            ?: s.id.take(8)
    }
    is VisibleSession.Creating -> "Starting session…"
}

/** Supporting text: "<agent> — <status>" (e.g. "codex — running"). */
private fun rowSubtitle(
    entry: VisibleSession,
    phase: String?,
    lifecycle: SessionLifecycle?,
): String = when (entry) {
    is VisibleSession.Real ->
        "${entry.session.assistant} — ${phase ?: "ready"}"
    is VisibleSession.Creating ->
        if (lifecycle is SessionLifecycle.FailedToStart) lifecycle.reason
        else "asking server for a session…"
}
