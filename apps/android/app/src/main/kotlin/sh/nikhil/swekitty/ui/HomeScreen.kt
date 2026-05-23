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
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material.icons.outlined.RadioButtonChecked
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.SessionLifecycle

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
    val statuses by store.statusBySession.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val selectedId by store.selectedId.collectAsState()

    // Pending exit target for the session-row long-press confirmation.
    // Mirror of iOS PR #128's `pendingDelete` on LitterHomeView — we
    // keep the title alongside the id so the prompt can name the
    // session being ended without re-resolving displayNames.
    var pendingDelete by remember { mutableStateOf<SessionDeleteTarget?>(null) }

    Column(modifier = Modifier.fillMaxSize().padding(top = 8.dp)) {
        // Top row: settings · centered title · list (drawer)
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            CircleIconButton(Icons.Default.Settings, "Settings", onClick = onOpenSettings)
            Spacer(Modifier.weight(1f))
            Column(horizontalAlignment = Alignment.CenterHorizontally) {
                Text("SweKitty", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
                Text(
                    if (endpoint.isComplete) endpoint.displayHost else "no harness",
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
                                .background(
                                    if (isActive) SweKittyTheme.accentStrong() else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.4f),
                                    CircleShape,
                                ),
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
                        if (canIssueCommands(harness)) "No sessions yet" else "Waiting for harness",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        if (canIssueCommands(harness))
                            "Tap + below to spin up a new conversation."
                        else
                            "Once we can reach the harness, your sessions appear here.",
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
                        val rowTitle = displayNames[session.id] ?: session.name
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .combinedClickable(
                                    onClick = { store.select(session.id) },
                                    onLongClick = {
                                        pendingDelete = SessionDeleteTarget(session.id, rowTitle)
                                    },
                                )
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(12.dp),
                        ) {
                            Icon(
                                if (isSelected) Icons.Outlined.RadioButtonChecked else Icons.Outlined.Circle,
                                contentDescription = null,
                                tint = if (isSelected) SweKittyTheme.accentStrong() else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f),
                                modifier = Modifier.size(16.dp),
                            )
                            Column(modifier = Modifier.weight(1f)) {
                                Text(
                                    rowTitle,
                                    style = MaterialTheme.typography.titleSmall,
                                    fontWeight = FontWeight.SemiBold,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                                Text(
                                    "${session.assistant} · ${statuses[session.id]?.phase ?: "ready"}",
                                    style = MaterialTheme.typography.labelSmall,
                                    fontFamily = FontFamily.Monospace,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                                    maxLines = 1,
                                    overflow = TextOverflow.Ellipsis,
                                )
                            }
                        }
                    }
                }
            }
        }

        // Bottom action bar
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(24.dp, Alignment.CenterHorizontally),
        ) {
            CircleActionButton(Icons.Default.Mic, "Voice", size = 52.dp, onClick = onVoice)
            // Primary +
            Surface(
                shape = CircleShape,
                color = SweKittyTheme.accentStrong(),
                modifier = Modifier
                    .size(68.dp)
                    .clip(CircleShape)
                    .clickable(onClick = onNewSession),
            ) {
                Box(contentAlignment = Alignment.Center, modifier = Modifier.fillMaxSize()) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "New session",
                        tint = MaterialTheme.colorScheme.onPrimary,
                        modifier = Modifier.size(32.dp),
                    )
                }
            }
            CircleActionButton(Icons.Default.Search, "Search", size = 52.dp, onClick = onSearch)
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete session?") },
            text = {
                Text(
                    "This ends ${target.title} on the harness. The conversation history stays available under Sessions.",
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

private fun canIssueCommands(state: HarnessState): Boolean = when (state) {
    is HarnessState.Live, is HarnessState.Linked -> true
    else -> false
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
