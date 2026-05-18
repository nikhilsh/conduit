package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SessionLifecycle
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.VisibleSession

@OptIn(ExperimentalMaterial3Api::class)
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
    val creationError by store.sessionCreationError.collectAsState()
    var showAgentMenu by remember { mutableStateOf(false) }

    val visible = remember(sessions, lifecycle) { store.visibleSessions() }

    ModalDrawerSheet(modifier = Modifier.fillMaxHeight()) {
        Column(modifier = Modifier.fillMaxSize()) {
            // Title + actions
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f)) {
                    Text("SweKitty", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    Text(
                        endpoint.displayHost,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
                IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, "Settings") }
                Box {
                    IconButton(
                        onClick = { showAgentMenu = true },
                        enabled = harness.canIssueCommands,
                    ) { Icon(Icons.Default.Add, "New session") }
                    DropdownMenu(expanded = showAgentMenu, onDismissRequest = { showAgentMenu = false }) {
                        DropdownMenuItem(text = { Text("Claude") }, onClick = {
                            showAgentMenu = false
                            store.createSession("claude")
                        })
                        DropdownMenuItem(text = { Text("Codex") }, onClick = {
                            showAgentMenu = false
                            store.createSession("codex")
                        })
                    }
                }
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
                LazyColumn(modifier = Modifier.weight(1f)) {
                    items(visible, key = { it.id }) { entry ->
                        SessionRow(
                            entry = entry,
                            health = (entry as? VisibleSession.Real)?.session?.id?.let { statuses[it]?.health },
                            phase = (entry as? VisibleSession.Real)?.session?.id?.let { statuses[it]?.phase },
                            lifecycle = lifecycle[entry.id],
                            selected = entry.id == selectedId,
                            onTap = {
                                if (entry is VisibleSession.Real) {
                                    store.select(entry.session.id)
                                    onCloseDrawer()
                                }
                            },
                        )
                    }
                }
            }
        }
    }
}

@Composable
fun HealthDot(health: String?, size: androidx.compose.ui.unit.Dp = 10.dp) {
    val color = when (health) {
        "green"  -> Color(0xFF22C55E)
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
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        HarnessBadge(harness)
        Spacer(Modifier.width(10.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(harness.badgeLabel, style = MaterialTheme.typography.labelMedium, fontWeight = FontWeight.SemiBold)
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
                Icon(Icons.Default.Refresh, contentDescription = null)
                Spacer(Modifier.width(4.dp))
                Text("Reconnect")
            }
        }
    }
}

@Composable
fun HarnessBadge(state: HarnessState) {
    when (state) {
        is HarnessState.Connecting -> CircularProgressIndicator(
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
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(MaterialTheme.colorScheme.errorContainer)
            .border(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Icon(
            Icons.Outlined.Warning,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error,
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

@Composable
private fun EmptySessionsHint(
    canCreate: Boolean,
    onCreate: (String) -> Unit,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
            .background(MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.4f))
            .padding(20.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            if (canCreate) "Start a session" else "Waiting for harness",
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            if (canCreate)
                "Pick an agent and we'll spin up a new conversation against the harness."
            else
                "Once we can reach the harness this is where your sessions will appear.",
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

@Composable
private fun SessionRow(
    entry: VisibleSession,
    health: String?,
    phase: String?,
    lifecycle: SessionLifecycle?,
    selected: Boolean,
    onTap: () -> Unit,
) {
    val isFailed = lifecycle is SessionLifecycle.FailedToStart
    val rowBg = when {
        selected -> MaterialTheme.colorScheme.secondaryContainer
        else     -> Color.Transparent
    }
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = entry is VisibleSession.Real, onClick = onTap)
            .background(rowBg)
            .padding(horizontal = 16.dp, vertical = 12.dp),
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
            else -> HealthDot(health)
        }
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                when (entry) {
                    is VisibleSession.Real     -> entry.session.name
                    is VisibleSession.Creating -> "Starting session…"
                },
                style = MaterialTheme.typography.bodyLarge,
                fontWeight = FontWeight.Medium,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            val subtitle: String = when (entry) {
                is VisibleSession.Real -> {
                    val branch = entry.session.branch ?: "—"
                    listOf(entry.session.assistant, branch, phase ?: "ready").joinToString(" · ")
                }
                is VisibleSession.Creating -> {
                    if (lifecycle is SessionLifecycle.FailedToStart) lifecycle.reason
                    else "asking harness for a session…"
                }
            }
            Text(
                subtitle,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}
