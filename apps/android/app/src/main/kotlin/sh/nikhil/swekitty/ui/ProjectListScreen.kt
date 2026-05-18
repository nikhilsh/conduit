package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Settings
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
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.ConnectionState
import sh.nikhil.swekitty.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProjectListScreen(
    store: SessionStore,
    onOpenSettings: () -> Unit,
    onCloseDrawer: () -> Unit,
) {
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val selectedId by store.selectedId.collectAsState()
    val connection by store.connection.collectAsState()
    var showAgentMenu by remember { mutableStateOf(false) }

    ModalDrawerSheet(modifier = Modifier.fillMaxHeight()) {
        Column(modifier = Modifier.fillMaxSize()) {
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Sessions", style = MaterialTheme.typography.titleMedium, modifier = Modifier.weight(1f))
                IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, "Settings") }
                Box {
                    IconButton(
                        onClick = { showAgentMenu = true },
                        enabled = connection is ConnectionState.Connected,
                    ) { Icon(Icons.Default.Add, "New session") }
                    DropdownMenu(expanded = showAgentMenu, onDismissRequest = { showAgentMenu = false }) {
                        DropdownMenuItem(text = { Text("Claude") }, onClick = {
                            showAgentMenu = false
                            store.createSession("claude")
                            onCloseDrawer()
                        })
                        DropdownMenuItem(text = { Text("Codex") }, onClick = {
                            showAgentMenu = false
                            store.createSession("codex")
                            onCloseDrawer()
                        })
                    }
                }
            }

            HorizontalDivider()

            if (sessions.isEmpty()) {
                Text(
                    "No sessions yet",
                    modifier = Modifier.padding(16.dp),
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            } else {
                LazyColumn(modifier = Modifier.weight(1f)) {
                    items(sessions, key = { it.id }) { s ->
                        val status = statuses[s.id]
                        ListItem(
                            headlineContent = { Text(s.name) },
                            supportingContent = { Text("${s.assistant} · ${s.branch ?: "—"}") },
                            leadingContent = { HealthDot(status?.health ?: "unknown") },
                            modifier = Modifier
                                .clickable {
                                    store.select(s.id)
                                    onCloseDrawer()
                                }
                                .background(
                                    if (s.id == selectedId) MaterialTheme.colorScheme.secondaryContainer
                                    else Color.Transparent
                                ),
                        )
                    }
                }
            }

            HorizontalDivider()

            ConnectionFooter(connection = connection, onConnect = { store.connect() })
        }
    }
}

@Composable
fun HealthDot(health: String) {
    val color = when (health) {
        "green"  -> Color(0xFF22C55E)
        "yellow" -> Color(0xFFEAB308)
        "red"    -> Color(0xFFEF4444)
        else     -> Color(0xFF94A3B8)
    }
    Box(
        modifier = Modifier
            .size(10.dp)
            .clip(CircleShape)
            .background(color)
    )
}

@Composable
private fun ConnectionFooter(connection: ConnectionState, onConnect: () -> Unit) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        when (connection) {
            is ConnectionState.Disconnected -> Button(onClick = onConnect) { Text("Connect") }
            is ConnectionState.Connecting -> {
                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                Spacer(Modifier.width(8.dp))
                Text("Connecting…")
            }
            is ConnectionState.Connected -> {
                HealthDot("green"); Spacer(Modifier.width(8.dp)); Text("Connected")
            }
            is ConnectionState.Failed -> {
                HealthDot("red"); Spacer(Modifier.width(8.dp))
                Text(connection.reason, maxLines = 2, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}
