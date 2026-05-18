package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.ConnectionState

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun EmptyDetail(
    connection: ConnectionState,
    onOpenDrawer: () -> Unit,
    onOpenSettings: () -> Unit,
) {
    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("SweKitty") },
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
            Text("No session selected", style = MaterialTheme.typography.headlineSmall)
            Spacer(Modifier.height(8.dp))
            Text(
                text = when (connection) {
                    is ConnectionState.Disconnected -> "Open Settings to enter an endpoint and bearer token."
                    is ConnectionState.Connecting   -> "Connecting…"
                    is ConnectionState.Connected    -> "Tap the menu to start a session."
                    is ConnectionState.Failed       -> "Connection failed: ${connection.reason}"
                },
                style = MaterialTheme.typography.bodyMedium,
            )
        }
    }
}
