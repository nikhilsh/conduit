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
import androidx.compose.material.icons.filled.Warning
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
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.SavedSshCredential
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SshBootstrapState
import sh.nikhil.conduit.SshCredentialStore
import sh.nikhil.conduit.Telemetry
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
                    keyboardOptions = KeyboardOptions(
                        keyboardType = KeyboardType.Uri,
                        capitalization = KeyboardCapitalization.None,
                        autoCorrect = false,
                    ),
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
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrect = false,
                ),
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
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            capitalization = KeyboardCapitalization.None,
                            autoCorrect = false,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                AuthMode.PrivateKey -> {
                    Text(
                        "Paste the PEM-encoded private key. The passphrase, if any, is encrypted at rest.",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    // No autocorrect/autocap/smart-quotes on the key field --
                    // those silently corrupt a pasted PEM key.
                    OutlinedTextField(
                        value = privateKey,
                        onValueChange = { privateKey = it },
                        label = { Text("PEM Private Key") },
                        minLines = 6,
                        maxLines = 12,
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Ascii,
                            capitalization = KeyboardCapitalization.None,
                            autoCorrect = false,
                            imeAction = ImeAction.Default,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                    // PEM sanity warnings (client-side only; no key body logged)
                    val trimmedKey = privateKey.trim()
                    if (trimmedKey.isNotEmpty()) {
                        if (!trimmedKey.contains("-----BEGIN") || !trimmedKey.contains("PRIVATE KEY-----")) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Icon(
                                    Icons.Default.Warning,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.width(16.dp),
                                )
                                Text(
                                    "This does not look like a PEM private key -- it should start with -----BEGIN ...PRIVATE KEY-----",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        } else if ((trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED")) && passphrase.isBlank()) {
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(4.dp),
                            ) {
                                Icon(
                                    Icons.Default.Warning,
                                    contentDescription = null,
                                    tint = MaterialTheme.colorScheme.error,
                                    modifier = Modifier.width(16.dp),
                                )
                                Text(
                                    "This key appears encrypted -- enter the passphrase below.",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                    }
                    OutlinedTextField(
                        value = passphrase,
                        onValueChange = { passphrase = it },
                        label = { Text("Passphrase (optional)") },
                        singleLine = true,
                        visualTransformation = PasswordVisualTransformation(),
                        keyboardOptions = KeyboardOptions(
                            keyboardType = KeyboardType.Password,
                            capitalization = KeyboardCapitalization.None,
                            autoCorrect = false,
                        ),
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
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrect = false,
                ),
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = openaiKey,
                onValueChange = { openaiKey = it },
                label = { Text("OPENAI_API_KEY") },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None,
                    autoCorrect = false,
                ),
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

            // Disabled-reason line so the user sees WHY the button is inactive
            // instead of a silent dead button.
            val reasons = connectDisabledReasons(host, port, username, mode, password, privateKey, bootstrap)
            if (reasons.isNotEmpty()) {
                Text(
                    reasons.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.error,
                )
            }

            Button(
                onClick = {
                    Telemetry.breadcrumb(
                        "ssh_addbox",
                        "connect tapped",
                        mapOf(
                            "enabled" to reasons.isEmpty().toString(),
                            "disabled_reason" to reasons.joinToString("; "),
                        ),
                    )
                    val portValue = port.toIntOrNull()
                        ?.takeIf { it in 1..65535 }
                        ?.toUShort()
                        ?: return@Button
                    val trimmedKey = privateKey.trim()

                    // Log key metadata only -- never the key body or passphrase.
                    if (mode == AuthMode.PrivateKey) {
                        val header = trimmedKey.lines().firstOrNull().orEmpty()
                        val looksLikePem = trimmedKey.contains("-----BEGIN") && trimmedKey.contains("PRIVATE KEY-----")
                        val looksEncrypted = trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED")
                        Telemetry.breadcrumb(
                            "ssh_addbox",
                            "key metadata",
                            mapOf(
                                "header" to header,
                                "length" to trimmedKey.length.toString(),
                                "looks_pem" to looksLikePem.toString(),
                                "looks_encrypted" to looksEncrypted.toString(),
                                "has_passphrase" to passphrase.isNotBlank().toString(),
                            ),
                        )
                    }

                    Telemetry.breadcrumb(
                        "ssh_addbox",
                        "connect() entry",
                        mapOf("host" to host.trim(), "port" to port, "mode" to mode.name),
                    )

                    val auth: SshAuth = when (mode) {
                        AuthMode.Password -> SshAuth.Password(password)
                        AuthMode.PrivateKey -> SshAuth.PrivateKey(
                            trimmedKey,
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
                                secret = if (mode == AuthMode.Password) password else trimmedKey,
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
                enabled = reasons.isEmpty(),
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

/**
 * Returns human-readable reasons the Connect button is disabled.
 * Empty list means all preconditions pass and the button should be enabled.
 */
private fun connectDisabledReasons(
    host: String,
    port: String,
    username: String,
    mode: AuthMode,
    password: String,
    privateKey: String,
    bootstrap: SshBootstrapState,
): List<String> {
    if (bootstrap is SshBootstrapState.Running) return listOf("Connecting...")
    val reasons = mutableListOf<String>()
    if (host.isBlank()) reasons.add("Enter host")
    if (username.isBlank()) reasons.add("Enter username")
    val p = port.toIntOrNull()
    if (p == null || p !in 1..65535) reasons.add("Port must be 1-65535")
    when (mode) {
        AuthMode.Password -> if (password.isEmpty()) reasons.add("Enter password")
        AuthMode.PrivateKey -> if (privateKey.isBlank()) reasons.add("Paste a private key")
    }
    return reasons
}

private fun canConnect(
    host: String,
    port: String,
    username: String,
    mode: AuthMode,
    password: String,
    privateKey: String,
    bootstrap: SshBootstrapState,
): Boolean = connectDisabledReasons(host, port, username, mode, password, privateKey, bootstrap).isEmpty()
