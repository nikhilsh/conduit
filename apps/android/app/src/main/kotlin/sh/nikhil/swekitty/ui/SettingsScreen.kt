package sh.nikhil.swekitty.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.PairingURL
import sh.nikhil.swekitty.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: SessionStore, onDismiss: () -> Unit) {
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()

    var url by remember(endpoint.url) { mutableStateOf(endpoint.url) }
    var token by remember(endpoint.token) { mutableStateOf(endpoint.token) }
    var scanError by remember { mutableStateOf<String?>(null) }

    val scanner = rememberLauncherForActivityResult(SweKittyScanContract()) { result ->
        if (result == null) return@rememberLauncherForActivityResult
        val parsed = PairingURL.parse(result)
        if (parsed == null) {
            scanError = "Not a SweKitty pairing URL: ${result.take(40)}…"
        } else {
            scanError = null
            url = parsed.endpoint
            token = parsed.token
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss) {
        Column(
            modifier = Modifier.padding(16.dp).fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Settings", style = MaterialTheme.typography.titleLarge)

            if (endpoint.isComplete) {
                SectionTitle("Paired Harness")
                LabeledRow("Host", endpoint.displayHost)
                LabeledRow("Token", "Stored in EncryptedSharedPreferences")
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    TextButton(onClick = { store.reconnect() }) {
                        Icon(Icons.Default.Refresh, null); Spacer(Modifier.width(6.dp)); Text("Reconnect")
                    }
                    TextButton(onClick = {
                        store.forgetEndpoint()
                        url = ""
                        token = ""
                    }) {
                        Icon(Icons.Default.Delete, null); Spacer(Modifier.width(6.dp)); Text("Forget")
                    }
                }
                HorizontalDivider()
            }

            SectionTitle(if (endpoint.isComplete) "Re-pair" else "Pair a harness")

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

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { scanner.launch(Unit) },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.QrCodeScanner, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text("Scan QR")
                }
                Button(
                    onClick = {
                        store.setEndpoint(url, token)
                        store.disconnect()
                        store.connect()
                        onDismiss()
                    },
                    enabled = url.isNotBlank() && token.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) { Text("Save & Connect") }
            }

            scanError?.let {
                Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
            }

            HorizontalDivider()
            SectionTitle("Harness Status")
            Row(verticalAlignment = Alignment.CenterVertically) {
                HarnessBadge(harness)
                Spacer(Modifier.width(8.dp))
                Text(harness.badgeLabel, style = MaterialTheme.typography.bodyMedium)
            }
            harness.failureReason?.let {
                Text(
                    it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                    maxLines = 3,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

@Composable
private fun SectionTitle(text: String) {
    Text(
        text,
        style = MaterialTheme.typography.labelLarge,
        color = MaterialTheme.colorScheme.primary,
    )
}

@Composable
private fun LabeledRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, modifier = Modifier.width(100.dp), style = MaterialTheme.typography.bodyMedium)
        Text(
            value,
            modifier = Modifier.weight(1f),
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
