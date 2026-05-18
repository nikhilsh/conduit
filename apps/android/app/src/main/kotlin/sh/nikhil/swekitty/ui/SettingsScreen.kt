package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.ConnectionState
import sh.nikhil.swekitty.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: SessionStore, onDismiss: () -> Unit) {
    val endpoint by store.endpoint.collectAsState()
    val connection by store.connection.collectAsState()

    var url by remember(endpoint.url) { mutableStateOf(endpoint.url) }
    var token by remember(endpoint.token) { mutableStateOf(endpoint.token) }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.padding(16.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Settings", style = MaterialTheme.typography.titleLarge)

            OutlinedTextField(
                value = url,
                onValueChange = { url = it },
                label = { Text("Endpoint (ws://host:1977)") },
                singleLine = true,
                keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                modifier = Modifier.fillMaxWidth(),
            )

            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("Bearer token") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )

            Button(
                onClick = {
                    store.setEndpoint(url, token)
                    store.disconnect()
                    store.connect()
                    onDismiss()
                },
                enabled = url.isNotBlank() && token.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save & Connect") }

            Text(
                text = when (val c = connection) {
                    is ConnectionState.Disconnected -> "Status: disconnected"
                    is ConnectionState.Connecting   -> "Status: connecting…"
                    is ConnectionState.Connected    -> "Status: connected"
                    is ConnectionState.Failed       -> "Status: failed — ${c.reason}"
                },
                style = MaterialTheme.typography.bodySmall,
            )
        }
    }
}
