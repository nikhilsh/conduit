package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material3.AssistChip
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.SavedSshCredential
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SshBootstrapState
import sh.nikhil.conduit.SshCredentialStore
import uniffi.conduit_core.SshAuth
import uniffi.conduit_core.SshCredentials

/**
 * Modal bottom sheet that drives the SSH-bootstrap flow. The user supplies
 * host/port + username + password OR PEM key (+ optional passphrase); on
 * Connect we kick off [SessionStore.connectViaSSH], which handles the
 * docker-run + tunnel + endpoint swap. Progress + errors render inline.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SSHLoginSheet(
    store: SessionStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val credStore = remember { SshCredentialStore.forContext(context.applicationContext) }
    val bootstrap by store.sshBootstrap.collectAsState()
    val harness by store.harness.collectAsState()

    var host by remember { mutableStateOf("") }
    var port by remember { mutableStateOf("22") }
    var username by remember { mutableStateOf("root") }
    var mode by remember { mutableStateOf(AuthMode.Password) }
    var password by remember { mutableStateOf("") }
    var privateKey by remember { mutableStateOf("") }
    var passphrase by remember { mutableStateOf("") }
    var remember_ by remember { mutableStateOf(true) }
    var anthropicKey by remember { mutableStateOf("") }
    var openaiKey by remember { mutableStateOf("") }

    val saved = remember { credStore.load() }

    // Auto-dismiss once the harness handshake actually succeeds.
    LaunchedEffect(harness, bootstrap) {
        if (bootstrap is SshBootstrapState.Idle && harness.isReachable) {
            onDismiss()
        }
    }

    ModalBottomSheet(onDismissRequest = {
        store.clearSshBootstrap()
        onDismiss()
    }) {
        Column(
            modifier = Modifier
                .padding(16.dp)
                .fillMaxWidth()
                .heightIn(max = 720.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add via SSH", style = MaterialTheme.typography.titleLarge)

            if (saved.isNotEmpty()) {
                Text("Recent Servers", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
                saved.forEach { cred ->
                    TextButton(onClick = {
                        host = cred.host
                        port = cred.port.toInt().toString()
                        username = cred.username
                        mode = if (cred.kind == SavedSshCredential.Kind.Password) AuthMode.Password else AuthMode.PrivateKey
                        when (cred.kind) {
                            SavedSshCredential.Kind.Password -> {
                                password = cred.secret
                                privateKey = ""
                                passphrase = ""
                            }
                            SavedSshCredential.Kind.PrivateKey -> {
                                privateKey = cred.secret
                                passphrase = cred.passphrase.orEmpty()
                                password = ""
                            }
                        }
                    }) {
                        Text("${cred.username}@${cred.host}:${cred.port}")
                    }
                }
                HorizontalDivider()
            }

            Text("Server", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                OutlinedTextField(
                    value = host,
                    onValueChange = { host = it },
                    label = { Text("hostname or IP") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Uri),
                    modifier = Modifier.weight(1f),
                )
                OutlinedTextField(
                    value = port,
                    onValueChange = { port = it.filter { ch -> ch.isDigit() }.take(5) },
                    label = { Text("Port") },
                    singleLine = true,
                    keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                    modifier = Modifier.widthIn(min = 100.dp, max = 110.dp),
                )
            }
            OutlinedTextField(
                value = username,
                onValueChange = { username = it },
                label = { Text("Username") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )

            Text("Authentication", style = MaterialTheme.typography.labelLarge, color = MaterialTheme.colorScheme.primary)
            SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                AuthMode.values().forEachIndexed { index, m ->
                    SegmentedButton(
                        shape = SegmentedButtonDefaults.itemShape(index = index, count = AuthMode.values().size),
                        onClick = { mode = m },
                        selected = mode == m,
                    ) { Text(m.label) }
                }
            }
            when (mode) {
                AuthMode.Password -> {
                    OutlinedTextField(
                        value = password,
                        onValueChange = { password = it },
                        label = { Text("Password") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                AuthMode.PrivateKey -> {
                    Text(
                        "Paste the PEM-encoded private key. The passphrase, if any, is encrypted at rest.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    OutlinedTextField(
                        value = privateKey,
                        onValueChange = { privateKey = it },
                        label = { Text("PEM Private Key") },
                        minLines = 6,
                        maxLines = 12,
                        modifier = Modifier.fillMaxWidth(),
                    )
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passphrase (optional)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically) {
                Switch(checked = remember_, onCheckedChange = { remember_ = it })
                Spacer(Modifier.width(8.dp))
                Text("Remember this server", style = MaterialTheme.typography.bodyMedium)
            }

            HorizontalDivider()
            Text(
                "Agent API Keys (optional)",
                style = MaterialTheme.typography.labelLarge,
                color = MaterialTheme.colorScheme.primary,
            )
            Text(
                "Forwarded into the broker container so first launch can sign in without you SSHing in.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            OutlinedTextField(
                value = anthropicKey,
                onValueChange = { anthropicKey = it },
                label = { Text("ANTHROPIC_API_KEY") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = openaiKey,
                onValueChange = { openaiKey = it },
                label = { Text("OPENAI_API_KEY") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                modifier = Modifier.fillMaxWidth(),
            )

            when (val s = bootstrap) {
                is SshBootstrapState.Running -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.width(20.dp), strokeWidth = 2.dp)
                        Text(s.message, style = MaterialTheme.typography.bodyMedium)
                    }
                }
                is SshBootstrapState.Failed -> {
                    Text(
                        s.reason,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error,
                    )
                }
                is SshBootstrapState.Idle -> Unit
            }

            Button(
                onClick = {
                    val portValue = port.toIntOrNull()
                        ?.takeIf { it in 1..65535 }
                        ?.toUShort()
                        ?: return@Button
                    val auth: SshAuth = when (mode) {
                        AuthMode.Password -> SshAuth.Password(password)
                        AuthMode.PrivateKey -> SshAuth.PrivateKey(
                            privateKey,
                            passphrase.ifBlank { null },
                        )
                    }
                    val creds = SshCredentials(
                        host = host.trim(),
                        port = portValue,
                        username = username.trim(),
                        auth = auth,
                    )

                    if (remember_) {
                        credStore.save(
                            SavedSshCredential(
                                host = creds.host,
                                port = creds.port,
                                username = creds.username,
                                kind = if (mode == AuthMode.Password)
                                    SavedSshCredential.Kind.Password
                                else
                                    SavedSshCredential.Kind.PrivateKey,
                                secret = if (mode == AuthMode.Password) password else privateKey,
                                passphrase = if (mode == AuthMode.PrivateKey && passphrase.isNotEmpty()) passphrase else null,
                            )
                        )
                    }

                    store.connectViaSSH(
                        credentials = creds,
                        serverName = "${creds.username}@${creds.host}",
                        anthropicApiKey = anthropicKey,
                        openaiApiKey = openaiKey,
                        imageRef = null,
                    )
                },
                enabled = canConnect(host, port, username, mode, password, privateKey, bootstrap),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.Bolt, contentDescription = null)
                Spacer(Modifier.width(6.dp))
                Text("Connect")
            }
        }
    }
}

private enum class AuthMode(val label: String) {
    Password("Password"),
    PrivateKey("SSH Key"),
}

private fun canConnect(
    host: String,
    port: String,
    username: String,
    mode: AuthMode,
    password: String,
    privateKey: String,
    bootstrap: SshBootstrapState,
): Boolean {
    if (bootstrap is SshBootstrapState.Running) return false
    if (host.isBlank() || username.isBlank()) return false
    val p = port.toIntOrNull() ?: return false
    if (p !in 1..65535) return false
    return when (mode) {
        AuthMode.Password -> password.isNotEmpty()
        AuthMode.PrivateKey -> privateKey.isNotEmpty()
    }
}
