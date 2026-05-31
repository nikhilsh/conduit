package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.Endpoint
import sh.nikhil.conduit.HarnessState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmptyDetail(
    harness: HarnessState,
    endpoint: Endpoint,
    onOpenDrawer: () -> Unit,
    onOpenSettings: () -> Unit,
    onReconnect: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Conduit") },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) { Icon(Icons.Default.Menu, contentDescription = "Sessions") }
                },
                actions = {
                    IconButton(onClick = onOpenSettings) { Icon(Icons.Default.Settings, contentDescription = "Settings") }
                },
            )
        },
    ) { padding ->
        Column(
            modifier = Modifier.fillMaxSize().padding(padding).padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            val (title, body) = labels(harness, endpoint)
            Text(title, style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            Text(
                body,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center,
            )
            Spacer(Modifier.height(20.dp))
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                if (!endpoint.isComplete) {
                    Button(onClick = onOpenSettings) { Text("Pair server") }
                } else {
                    when (harness) {
                        is HarnessState.Failed, is HarnessState.Disconnected -> {
                            Button(onClick = onReconnect) {
                                Icon(Icons.Default.Refresh, null); Spacer(Modifier.width(6.dp)); Text("Reconnect")
                            }
                            OutlinedButton(onClick = onOpenDrawer) { Text("Sessions") }
                        }
                        else -> {
                            Button(onClick = onOpenDrawer) {
                                Icon(Icons.Default.Menu, null); Spacer(Modifier.width(6.dp)); Text("Open sessions")
                            }
                        }
                    }
                }
            }
        }
    }
}

private fun labels(harness: HarnessState, endpoint: Endpoint): Pair<String, String> = when (harness) {
    is HarnessState.Disconnected -> if (endpoint.isComplete)
        "Disconnected" to "We're not currently linked to the server."
    else
        "Welcome to Conduit" to "Pair this device with a running conduit server in Settings to begin."
    is HarnessState.Connecting   -> "Connecting" to "Establishing a websocket link to ${endpoint.displayHost}."
    is HarnessState.Reconnecting -> "Reconnecting…" to "Lost link to ${endpoint.displayHost}. Reconnecting (attempt ${harness.attempt} of ${harness.maxAttempts})."
    is HarnessState.Linked,
    is HarnessState.Live         -> "No session selected" to "Tap the menu to start a session against ${endpoint.displayHost}."
    is HarnessState.Failed       -> "Server unreachable" to harness.reason
}
