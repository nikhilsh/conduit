package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.SavedSshCredential
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SshBootstrapState
import sh.nikhil.conduit.SshCredentialStore
import sh.nikhil.conduit.Telemetry
import uniffi.conduit_core.SshAuth
import uniffi.conduit_core.SshCredentials

/**
 * Modal bottom sheet that drives the SSH-bootstrap flow. Restyled (Fix 3) to use
 * the Conduit card system: section labels, neon card surfaces, env keys collapsed
 * behind a disclosure, and an X close button replacing the old drag-to-dismiss
 * only cue. The bootstrap logic and telemetry are unchanged.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SSHLoginSheet(
    store: SessionStore,
    onDismiss: () -> Unit,
) {
    val context = LocalContext.current
    val focusManager = LocalFocusManager.current
    val neon = LocalNeonTheme.current
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
    // Fix 3: env keys collapsed by default behind a disclosure.
    var envKeysExpanded by remember { mutableStateOf(false) }

    val saved = remember { credStore.load() }

    LaunchedEffect(harness, bootstrap) {
        if (bootstrap is SshBootstrapState.Idle && harness.isReachable) {
            onDismiss()
        }
    }

    ModalBottomSheet(
        onDismissRequest = {
            store.clearSshBootstrap()
            onDismiss()
        },
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        // Fix 3: TopAppBar with X close (replaces drag-to-dismiss-only).
        TopAppBar(
            title = {
                Text(
                    "Add via SSH",
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
            },
            actions = {
                IconButton(onClick = {
                    store.clearSshBootstrap()
                    onDismiss()
                }) {
                    Icon(
                        Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = neon.textDim,
                    )
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = Color.Transparent),
        )

        Column(
            modifier = Modifier
                .padding(horizontal = 16.dp)
                .fillMaxWidth()
                .heightIn(max = 700.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            // RECENT section — tappable saved-credential cards.
            if (saved.isNotEmpty()) {
                SshSectionLabel("RECENT")
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = neon.surface,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column {
                        saved.forEachIndexed { idx, cred ->
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .clickable {
                                        host = cred.host
                                        port = cred.port.toInt().toString()
                                        username = cred.username
                                        mode = if (cred.kind == SavedSshCredential.Kind.Password)
                                            AuthMode.Password else AuthMode.PrivateKey
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
                                    }
                                    .padding(horizontal = 14.dp, vertical = 12.dp),
                                verticalAlignment = Alignment.CenterVertically,
                            ) {
                                Text(
                                    "${cred.username}@${cred.host}:${cred.port}",
                                    fontFamily = neon.mono,
                                    fontSize = 13.sp,
                                    color = neon.text,
                                    modifier = Modifier.weight(1f),
                                )
                                Icon(
                                    Icons.Filled.ChevronRight,
                                    contentDescription = null,
                                    tint = neon.textFaint,
                                    modifier = Modifier.size(18.dp),
                                )
                            }
                            if (idx < saved.lastIndex) {
                                HorizontalDivider(color = neon.border)
                            }
                        }
                    }
                }
            }

            // SERVER section — host + port inline, username row.
            SshSectionLabel("SERVER")
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = neon.surface,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        OutlinedTextField(
                            value = host,
                            onValueChange = { host = it },
                            label = { Text("Host", fontFamily = neon.mono) },
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
                            label = { Text("Port", fontFamily = neon.mono) },
                            singleLine = true,
                            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
                            modifier = Modifier.widthIn(min = 90.dp, max = 100.dp),
                        )
                    }
                    OutlinedTextField(
                        value = username,
                        onValueChange = { username = it },
                        label = { Text("Username", fontFamily = neon.mono) },
                        singleLine = true,
                        keyboardOptions = KeyboardOptions(
                            capitalization = KeyboardCapitalization.None,
                            autoCorrect = false,
                        ),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }

            // AUTHENTICATION section.
            SshSectionLabel("AUTHENTICATION")
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = neon.surface,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                        AuthMode.values().forEachIndexed { index, m ->
                            SegmentedButton(
                                shape = SegmentedButtonDefaults.itemShape(index = index, count = AuthMode.values().size),
                                onClick = { mode = m },
                                selected = mode == m,
                                label = { Text(m.label, fontFamily = neon.sans) },
                            )
                        }
                    }
                    when (mode) {
                        AuthMode.Password -> {
                            OutlinedTextField(
                                value = password,
                                onValueChange = { password = it },
                                label = { Text("Password", fontFamily = neon.mono) },
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
                            OutlinedTextField(
                                value = privateKey,
                                onValueChange = { privateKey = it },
                                label = { Text("PEM Private Key", fontFamily = neon.mono) },
                                minLines = 5,
                                maxLines = 10,
                                keyboardOptions = KeyboardOptions(
                                    keyboardType = KeyboardType.Ascii,
                                    capitalization = KeyboardCapitalization.None,
                                    autoCorrect = false,
                                    imeAction = ImeAction.Default,
                                ),
                                modifier = Modifier.fillMaxWidth(),
                            )
                            val trimmedKey = privateKey.trim()
                            if (trimmedKey.isNotEmpty()) {
                                if (!trimmedKey.contains("-----BEGIN") || !trimmedKey.contains("PRIVATE KEY-----")) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Icon(Icons.Default.Warning, null, tint = neon.red, modifier = Modifier.size(14.dp))
                                        Text("Does not look like a PEM private key", style = MaterialTheme.typography.bodySmall, color = neon.red)
                                    }
                                } else if ((trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED")) && passphrase.isBlank()) {
                                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                        Icon(Icons.Default.Warning, null, tint = neon.yellow, modifier = Modifier.size(14.dp))
                                        Text("Key appears encrypted — enter passphrase below", style = MaterialTheme.typography.bodySmall, color = neon.yellow)
                                    }
                                }
                            }
                            OutlinedTextField(
                                value = passphrase,
                                onValueChange = { passphrase = it },
                                label = { Text("Passphrase (optional)", fontFamily = neon.mono) },
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
                    HorizontalDivider(color = neon.border)
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text(
                            "Remember this box",
                            fontFamily = neon.sans,
                            color = neon.text,
                            modifier = Modifier.weight(1f),
                        )
                        Switch(checked = remember_, onCheckedChange = { remember_ = it })
                    }
                }
            }

            // AGENT API KEYS — collapsed behind a disclosure (Fix 3).
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { envKeysExpanded = !envKeysExpanded }
                    .padding(vertical = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "AGENT API KEYS (OPTIONAL)",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.textFaint,
                    modifier = Modifier.weight(1f),
                )
                Icon(
                    if (envKeysExpanded) Icons.Filled.KeyboardArrowDown else Icons.Filled.KeyboardArrowRight,
                    contentDescription = if (envKeysExpanded) "Collapse" else "Expand",
                    tint = neon.textFaint,
                    modifier = Modifier.size(18.dp),
                )
            }
            AnimatedVisibility(
                visible = envKeysExpanded,
                enter = expandVertically() + fadeIn(),
                exit = shrinkVertically() + fadeOut(),
            ) {
                Surface(
                    shape = RoundedCornerShape(14.dp),
                    color = neon.surface,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            "Forwarded into the broker so agents can sign in without you SSHing in first.",
                            style = MaterialTheme.typography.bodySmall,
                            fontFamily = neon.sans,
                            color = neon.textDim,
                        )
                        OutlinedTextField(
                            value = anthropicKey,
                            onValueChange = { anthropicKey = it },
                            label = { Text("ANTHROPIC_API_KEY", fontFamily = neon.mono) },
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
                            label = { Text("OPENAI_API_KEY", fontFamily = neon.mono) },
                            singleLine = true,
                            visualTransformation = PasswordVisualTransformation(),
                            keyboardOptions = KeyboardOptions(
                                capitalization = KeyboardCapitalization.None,
                                autoCorrect = false,
                            ),
                            modifier = Modifier.fillMaxWidth(),
                        )
                    }
                }
            }

            // Progress / error feedback.
            when (val s = bootstrap) {
                is SshBootstrapState.Running -> {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(20.dp), strokeWidth = 2.dp)
                        Text(s.message, fontFamily = neon.sans, fontSize = 14.sp, color = neon.textDim)
                    }
                }
                is SshBootstrapState.Failed -> {
                    Text(
                        s.reason,
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = neon.sans,
                        color = neon.red,
                    )
                }
                is SshBootstrapState.Idle -> Unit
            }

            val reasons = connectDisabledReasons(host, port, username, mode, password, privateKey, bootstrap)
            if (reasons.isNotEmpty() && host.isNotBlank()) {
                Text(
                    reasons.joinToString(" · "),
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
            } else if (host.isBlank()) {
                Text(
                    "Enter a host to continue",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.textFaint,
                )
            }

            // CTA — glowing Connect & install broker button.
            androidx.compose.material3.Button(
                onClick = {
                    focusManager.clearFocus()
                    Telemetry.breadcrumb(
                        "ssh_addbox",
                        "connect tapped",
                        mapOf("enabled" to reasons.isEmpty().toString()),
                    )
                    if (reasons.isNotEmpty()) return@Button

                    val portValue = port.toIntOrNull()
                        ?.takeIf { it in 1..65535 }
                        ?.toUShort()
                        ?: return@Button
                    val trimmedKey = privateKey.trim()

                    if (mode == AuthMode.PrivateKey) {
                        Telemetry.breadcrumb(
                            "ssh_addbox",
                            "key metadata",
                            mapOf(
                                "length" to trimmedKey.length.toString(),
                                "looks_pem" to (trimmedKey.contains("-----BEGIN") && trimmedKey.contains("PRIVATE KEY-----")).toString(),
                                "looks_encrypted" to (trimmedKey.contains("ENCRYPTED") || trimmedKey.contains("Proc-Type: 4,ENCRYPTED")).toString(),
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
                        AuthMode.PrivateKey -> SshAuth.PrivateKey(trimmedKey, passphrase.ifBlank { null })
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
                shape = RoundedCornerShape(14.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = neon.green,
                    contentColor = neon.accentText,
                ),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Default.Bolt, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(6.dp))
                Text("Connect & install broker", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
            }

            Spacer(Modifier.size(8.dp))
        }
    }
}

/** Mono uppercase section label — matches the Conduit card system. */
@Composable
private fun SshSectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(
        text,
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        fontSize = 11.sp,
        color = neon.textFaint,
        letterSpacing = 1.2.sp,
    )
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
