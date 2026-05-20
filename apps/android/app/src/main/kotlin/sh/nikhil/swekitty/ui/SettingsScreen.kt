package sh.nikhil.swekitty.ui

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.collectAsState
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.PairingURL
import sh.nikhil.swekitty.RemoteDirectoryEntry
import sh.nikhil.swekitty.SavedServer
import sh.nikhil.swekitty.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: SessionStore, onDismiss: () -> Unit) {
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val recentDirectories by store.recentDirectories.collectAsState()

    var url by remember(endpoint.url) { mutableStateOf(endpoint.url) }
    var token by remember(endpoint.token) { mutableStateOf(endpoint.token) }
    var startCwd by remember { mutableStateOf("~") }
    var showDirectoryPicker by remember { mutableStateOf(false) }
    var browsingPath by remember { mutableStateOf("~") }
    var browsingParent by remember { mutableStateOf("~") }
    var directoryEntries by remember { mutableStateOf<List<RemoteDirectoryEntry>>(emptyList()) }
    var directoryError by remember { mutableStateOf<String?>(null) }
    var directoryLoading by remember { mutableStateOf(false) }
    var pendingAssistantAfterConnect by remember { mutableStateOf<String?>(null) }
    var scanError by remember { mutableStateOf<String?>(null) }
    var showSshSheet by remember { mutableStateOf(false) }
    var showDiscoverSheet by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    LaunchedEffect(harness, pendingAssistantAfterConnect) {
        if (pendingAssistantAfterConnect != null && harness.canIssueCommands) {
            showDirectoryPicker = true
            directoryLoading = true
            directoryError = null
            runCatching { store.listDirectories(startCwd) }
                .onSuccess { listing ->
                    browsingPath = listing.path
                    browsingParent = listing.parent
                    directoryEntries = listing.entries.filter { it.isDir }
                }
                .onFailure { directoryError = it.message ?: it.toString() }
            directoryLoading = false
        }
    }

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

            if (savedServers.isNotEmpty()) {
                SectionTitle("Saved Servers")
                savedServers.forEach { server ->
                    SavedServerRow(
                        server = server,
                        onUse = {
                            store.selectSavedServer(server.id, autoConnect = true)
                            url = server.endpoint.url
                            token = server.endpoint.token
                        },
                        onRemove = { store.removeSavedServer(server.id) },
                    )
                }
                HorizontalDivider()
            }

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

            OutlinedTextField(
                value = startCwd,
                onValueChange = { startCwd = it },
                label = { Text("Start directory (~/projects/kitty)") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            if (recentDirectories.isNotEmpty()) {
                Row(
                    modifier = Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    recentDirectories.forEach { path ->
                        AssistChip(onClick = { startCwd = path }, label = { Text(path) })
                    }
                }
            }

            OutlinedButton(
                onClick = {
                    showDirectoryPicker = true
                    scope.launch {
                        directoryLoading = true
                        directoryError = null
                        store.setEndpoint(url, token)
                        runCatching { store.listDirectories(startCwd) }
                            .onSuccess { listing ->
                                browsingPath = listing.path
                                browsingParent = listing.parent
                                directoryEntries = listing.entries.filter { it.isDir }
                            }
                            .onFailure { directoryError = it.message ?: it.toString() }
                        directoryLoading = false
                    }
                },
                enabled = url.isNotBlank() && token.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Browse directory") }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = { scanner.launch(Unit) },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.QrCodeScanner, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text("Scan QR")
                }
                OutlinedButton(
                    onClick = { showDiscoverSheet = true },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.Wifi, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text("On LAN")
                }
                OutlinedButton(
                    onClick = { showSshSheet = true },
                    modifier = Modifier.weight(1f),
                ) {
                    Icon(Icons.Default.Terminal, contentDescription = null)
                    Spacer(Modifier.width(6.dp))
                    Text("Via SSH")
                }
                Button(
                    onClick = {
                        store.setEndpoint(url, token)
                        store.upsertSavedServer(
                            name = Endpoint(url, token).displayHost,
                            endpoint = Endpoint(url, token),
                            makeDefault = true,
                        )
                        store.disconnect()
                        store.connect()
                        onDismiss()
                    },
                    enabled = url.isNotBlank() && token.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) { Text("Save & Connect") }
            }

            Row(horizontalArrangement = Arrangement.spacedBy(8.dp), modifier = Modifier.fillMaxWidth()) {
                OutlinedButton(
                    onClick = {
                        pendingAssistantAfterConnect = "claude"
                        store.setEndpoint(url, token)
                        store.upsertSavedServer(
                            name = Endpoint(url, token).displayHost,
                            endpoint = Endpoint(url, token),
                            makeDefault = true,
                        )
                        store.disconnect()
                        store.connect()
                    },
                    enabled = url.isNotBlank() && token.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) { Text("Connect + Claude") }

                Button(
                    onClick = {
                        pendingAssistantAfterConnect = "codex"
                        store.setEndpoint(url, token)
                        store.upsertSavedServer(
                            name = Endpoint(url, token).displayHost,
                            endpoint = Endpoint(url, token),
                            makeDefault = true,
                        )
                        store.disconnect()
                        store.connect()
                    },
                    enabled = url.isNotBlank() && token.isNotBlank(),
                    modifier = Modifier.weight(1f),
                ) { Text("Connect + Codex") }
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

    if (showDiscoverSheet) {
        DiscoveryScreen(store = store, onDismiss = { showDiscoverSheet = false })
    }

    if (showSshSheet) {
        SSHLoginSheet(store = store, onDismiss = { showSshSheet = false })
    }

    if (showDirectoryPicker) {
        AlertDialog(
            onDismissRequest = { showDirectoryPicker = false },
            title = { Text("Select Directory") },
            text = {
                Column(
                    modifier = Modifier.fillMaxWidth().heightIn(max = 420.dp).verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Text(browsingPath, style = MaterialTheme.typography.labelSmall)
                    if (directoryLoading) {
                        LinearProgressIndicator(modifier = Modifier.fillMaxWidth())
                    }
                    directoryError?.let {
                        Text(it, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodySmall)
                    }
                    TextButton(onClick = {
                        scope.launch {
                            directoryLoading = true
                            directoryError = null
                            runCatching { store.listDirectories(browsingParent) }
                                .onSuccess { listing ->
                                    browsingPath = listing.path
                                    browsingParent = listing.parent
                                    directoryEntries = listing.entries.filter { it.isDir }
                                }
                                .onFailure { directoryError = it.message ?: it.toString() }
                            directoryLoading = false
                        }
                    }) { Text(".. (up)") }
                    directoryEntries.forEach { entry ->
                        TextButton(onClick = {
                            scope.launch {
                                directoryLoading = true
                                directoryError = null
                                runCatching { store.listDirectories(entry.path) }
                                    .onSuccess { listing ->
                                        browsingPath = listing.path
                                        browsingParent = listing.parent
                                        directoryEntries = listing.entries.filter { it.isDir }
                                    }
                                    .onFailure { directoryError = it.message ?: it.toString() }
                                directoryLoading = false
                            }
                        }) { Text(entry.name) }
                    }
                }
            },
            confirmButton = {
                TextButton(onClick = {
                    startCwd = browsingPath
                    pendingAssistantAfterConnect?.let { assistant ->
                        store.createSession(assistant = assistant, startupCwd = browsingPath)
                        pendingAssistantAfterConnect = null
                        showDirectoryPicker = false
                        onDismiss()
                        return@TextButton
                    }
                    showDirectoryPicker = false
                }) { Text("Use This") }
            },
            dismissButton = {
                TextButton(onClick = { showDirectoryPicker = false }) { Text("Close") }
            },
        )
    }
}

@Composable
private fun SavedServerRow(
    server: SavedServer,
    onUse: () -> Unit,
    onRemove: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(server.name, style = MaterialTheme.typography.bodyMedium)
            Text(
                server.endpoint.displayHost,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (server.isDefault) {
            AssistChip(onClick = {}, enabled = false, label = { Text("Default") })
        }
        TextButton(onClick = onUse) { Text("Use") }
        TextButton(onClick = onRemove) { Text("Remove") }
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
