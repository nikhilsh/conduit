package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
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
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import sh.nikhil.conduit.SavedSshCredential
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SshBootstrapState
import sh.nikhil.conduit.SshCredentialStore
import sh.nikhil.conduit.SshLoginPrefill
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
    prefill: SshLoginPrefill? = null,
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
    // Captured when Connect is tapped — used as the title in the install-progress modal.
    var boxName by remember { mutableStateOf("") }

    val pendingHostKey by store.pendingHostKey.collectAsState()
    val saved = remember { credStore.load() }

    // Apply prefill from a retry request (Part B). Run once on composition.
    LaunchedEffect(prefill) {
        prefill ?: return@LaunchedEffect
        host = prefill.host
        port = prefill.port.toInt().toString()
        username = prefill.username
        boxName = prefill.serverName
    }

    // Signal to AppRoot that the SSH login sheet is on screen so it suppresses
    // the root-level HostKeyPromptDialog in favour of our inline TOFU section.
    DisposableEffect(Unit) {
        store.setSshLoginSheetActive(true)
        onDispose { store.setSshLoginSheetActive(false) }
    }

    LaunchedEffect(harness, bootstrap, pendingHostKey) {
        // Do NOT auto-dismiss while a host-key decision is pending -- the
        // inline TOFU section needs to stay up so the user can respond.
        if (pendingHostKey != null) return@LaunchedEffect
        if (bootstrap is SshBootstrapState.Idle && harness.isReachable) {
            onDismiss()
        }
    }

    // Blocking install-progress modal — shows while bootstrap is running or failed.
    if (bootstrap !is SshBootstrapState.Idle || pendingHostKey != null) {
        InstallProgressDialog(
            bootstrap = bootstrap,
            boxName = boxName,
            pendingHostKey = pendingHostKey,
            onTrustHostKey = {
                Telemetry.breadcrumb("ssh_addbox", "inline host-key trusted", mapOf("box" to boxName))
                store.resolveHostKeyPrompt(true)
            },
            onCancelHostKey = {
                Telemetry.breadcrumb("ssh_addbox", "inline host-key cancelled", mapOf("box" to boxName))
                store.resolveHostKeyPrompt(false)
            },
            onRetry = {
                Telemetry.breadcrumb("ssh_install_modal", "retry tapped", mapOf("box" to boxName))
                // Re-invoke connect with the same credentials still held in state.
                val portValue = port.toIntOrNull()
                    ?.takeIf { it in 1..65535 }
                    ?.toUShort()
                if (portValue != null) {
                    val trimmedKey = privateKey.trim()
                    val auth: SshAuth = when (mode) {
                        AuthMode.Password -> SshAuth.Password(password)
                        AuthMode.PrivateKey -> SshAuth.PrivateKey(trimmedKey, passphrase.ifBlank { null })
                    }
                    store.connectViaSSH(
                        credentials = SshCredentials(
                            host = host.trim(),
                            port = portValue,
                            username = username.trim(),
                            auth = auth,
                        ),
                        serverName = "${username.trim()}@${host.trim()}",
                        anthropicApiKey = anthropicKey,
                        openaiApiKey = openaiKey,
                        imageRef = null,
                    )
                }
            },
            onCancel = {
                Telemetry.breadcrumb("ssh_install_modal", "cancel tapped after failure", mapOf("box" to boxName))
                store.clearSshBootstrap()
            },
        )
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
                    val trimmedHost = host.trim()
                    val trimmedUser = username.trim()

                    // Capture box name for the install-progress modal title.
                    boxName = "$trimmedUser@$trimmedHost"

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
                        mapOf("host" to trimmedHost, "port" to port, "mode" to mode.name),
                    )

                    val auth: SshAuth = when (mode) {
                        AuthMode.Password -> SshAuth.Password(password)
                        AuthMode.PrivateKey -> SshAuth.PrivateKey(trimmedKey, passphrase.ifBlank { null })
                    }
                    val creds = SshCredentials(
                        host = trimmedHost,
                        port = portValue,
                        username = trimmedUser,
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

/** Stage steps matching remote-bootstrap.sh STEP markers, in order. */
private val BOOTSTRAP_STAGES = listOf(
    "Connecting" to "Connecting",
    "Securing connection" to "Securing",
    "Authenticating" to "Authenticating",
    "Opening tunnel" to "Opening",
    "Checking existing install" to "Checking",
    "Downloading broker" to "Downloading",
    "Starting service" to "Starting",
    "Installing agent" to "Installing",
    "Verifying readiness" to "Waiting",
)

private fun bootstrapStageIndex(message: String): Int {
    for ((i, stage) in BOOTSTRAP_STAGES.withIndex()) {
        if (message.startsWith(stage.second)) return i
    }
    return 0
}

/**
 * Blocking install-progress dialog. Shows while SSH bootstrap is running or has
 * failed. Non-dismissible during running to prevent user confusion; on failure
 * shows Retry and Cancel buttons with the specific error reason.
 *
 * Stages are driven by the STEP markers in remote-bootstrap.sh surfaced via
 * [SshBootstrapState.Running.message]:
 *   Connecting → Securing connection → Authenticating → Opening tunnel →
 *   Checking existing install → Downloading broker → Starting service →
 *   Installing agent → Verifying readiness
 *
 * Failure modes surfaced as clear messages (mapped in SessionStore.describeSsh):
 *   auth_failed, host_key_rejected, broker_install_failed, harness_start_timeout,
 *   curl_missing, unsupported_platform, broker_exec_failed, port_conflict, io, etc.
 */
@Composable
private fun InstallProgressDialog(
    bootstrap: SshBootstrapState,
    boxName: String,
    pendingHostKey: sh.nikhil.conduit.HostKeyPrompt?,
    onTrustHostKey: () -> Unit,
    onCancelHostKey: () -> Unit,
    onRetry: () -> Unit,
    onCancel: () -> Unit,
) {
    val neon = LocalNeonTheme.current

    LaunchedEffect(Unit) {
        Telemetry.breadcrumb("ssh_install_modal", "dialog shown", mapOf("box" to boxName))
    }

    Dialog(
        onDismissRequest = { /* non-dismissible while running */ },
        properties = DialogProperties(
            dismissOnBackPress = bootstrap is SshBootstrapState.Failed || pendingHostKey != null,
            dismissOnClickOutside = false,
            usePlatformDefaultWidth = false,
        ),
    ) {
        // Scrim + centred card
        Box(
            modifier = Modifier
                .fillMaxSize()
                .background(Color.Black.copy(alpha = 0.55f)),
            contentAlignment = Alignment.Center,
        ) {
            Surface(
                modifier = Modifier
                    .padding(horizontal = 24.dp)
                    .fillMaxWidth()
                    .shadow(elevation = 24.dp, shape = RoundedCornerShape(20.dp)),
                shape = RoundedCornerShape(20.dp),
                color = neon.surfaceSolid,
            ) {
                Column(
                    modifier = Modifier.padding(20.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    // Title row
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Icon(
                            Icons.Default.Bolt,
                            contentDescription = null,
                            tint = neon.codex,
                            modifier = Modifier.size(22.dp),
                        )
                        Column {
                            Text(
                                "Setting up ${boxName.ifBlank { "server" }}",
                                fontFamily = neon.mono,
                                fontWeight = FontWeight.Bold,
                                fontSize = 14.sp,
                                color = neon.text,
                                maxLines = 1,
                            )
                            Text(
                                "INSTALLING CONDUIT BROKER",
                                fontFamily = neon.mono,
                                fontWeight = FontWeight.Bold,
                                fontSize = 10.sp,
                                color = neon.textFaint,
                                letterSpacing = 1.2.sp,
                            )
                        }
                    }

                    // Part A: inline host-key verify section. Shown while the TOFU
                    // decision is pending so the sheet never needs to be dismissed.
                    if (pendingHostKey != null) {
                        LaunchedEffect(Unit) {
                            Telemetry.breadcrumb(
                                "ssh_addbox",
                                "inline host-key shown",
                                mapOf("host" to (pendingHostKey?.host ?: ""), "box" to boxName),
                            )
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                            Text(
                                "VERIFY HOST KEY",
                                fontFamily = neon.mono,
                                fontWeight = FontWeight.Bold,
                                fontSize = 10.sp,
                                color = neon.yellow,
                                letterSpacing = 1.2.sp,
                            )
                            Text(
                                "First time connecting to ${pendingHostKey?.host}:${pendingHostKey?.port}",
                                fontFamily = neon.sans,
                                fontSize = 13.sp,
                                color = neon.text,
                            )
                            Text(
                                "SHA-256 Fingerprint",
                                fontFamily = neon.mono,
                                fontSize = 10.sp,
                                color = neon.textFaint,
                            )
                            Surface(
                                color = neon.surface,
                                shape = RoundedCornerShape(8.dp),
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Text(
                                    pendingHostKey?.fingerprint ?: "",
                                    fontFamily = neon.mono,
                                    fontSize = 11.sp,
                                    color = neon.text,
                                    modifier = Modifier.padding(10.dp),
                                )
                            }
                            Text(
                                "Verify this fingerprint before trusting. If it does not match your server's ssh-keyscan output, something may be intercepting your connection.",
                                style = MaterialTheme.typography.bodySmall,
                                fontFamily = neon.sans,
                                color = neon.textDim,
                            )
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Button(
                                    onClick = onTrustHostKey,
                                    shape = RoundedCornerShape(11.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = neon.green,
                                        contentColor = neon.accentText,
                                    ),
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Text("Trust & continue", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
                                }
                                OutlinedButton(
                                    onClick = onCancelHostKey,
                                    shape = RoundedCornerShape(11.dp),
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Text("Cancel", fontFamily = neon.sans, color = neon.textDim)
                                }
                            }
                        }
                    }

                    when (bootstrap) {
                        is SshBootstrapState.Running -> {
                            val activeIdx = bootstrapStageIndex(bootstrap.message)

                            // Stage dots
                            Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                                BOOTSTRAP_STAGES.forEachIndexed { idx, (label, _) ->
                                    Row(
                                        verticalAlignment = Alignment.CenterVertically,
                                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                                    ) {
                                        Box(modifier = Modifier.size(14.dp), contentAlignment = Alignment.Center) {
                                            // Outer glow ring for active stage
                                            if (idx == activeIdx) {
                                                Box(
                                                    modifier = Modifier
                                                        .size(14.dp)
                                                        .clip(CircleShape)
                                                        .background(neon.codex.copy(alpha = 0.25f)),
                                                )
                                            }
                                            Box(
                                                modifier = Modifier
                                                    .size(8.dp)
                                                    .clip(CircleShape)
                                                    .background(
                                                        when {
                                                            idx < activeIdx -> neon.green
                                                            idx == activeIdx -> neon.codex
                                                            else -> neon.border
                                                        }
                                                    ),
                                            )
                                        }
                                        Text(
                                            label,
                                            fontFamily = neon.mono,
                                            fontSize = 12.sp,
                                            fontWeight = if (idx == activeIdx) FontWeight.SemiBold else FontWeight.Normal,
                                            color = if (idx <= activeIdx) neon.text else neon.textFaint,
                                        )
                                    }
                                }
                            }

                            // Current message + spinner
                            Row(
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                CircularProgressIndicator(
                                    modifier = Modifier.size(18.dp),
                                    strokeWidth = 2.dp,
                                    color = neon.codex,
                                )
                                Text(
                                    bootstrap.message,
                                    fontFamily = neon.mono,
                                    fontSize = 13.sp,
                                    color = neon.text,
                                )
                            }
                        }

                        is SshBootstrapState.Failed -> {
                            // Error message
                            Row(
                                verticalAlignment = Alignment.Top,
                                horizontalArrangement = Arrangement.spacedBy(8.dp),
                            ) {
                                Icon(
                                    Icons.Default.Warning,
                                    contentDescription = null,
                                    tint = neon.red,
                                    modifier = Modifier.size(16.dp).padding(top = 2.dp),
                                )
                                Text(
                                    bootstrap.reason,
                                    style = MaterialTheme.typography.bodySmall,
                                    fontFamily = neon.sans,
                                    color = neon.red,
                                )
                            }

                            // Retry + Cancel
                            Row(
                                modifier = Modifier.fillMaxWidth(),
                                horizontalArrangement = Arrangement.spacedBy(10.dp),
                            ) {
                                Button(
                                    onClick = onRetry,
                                    shape = RoundedCornerShape(11.dp),
                                    colors = ButtonDefaults.buttonColors(
                                        containerColor = neon.codex,
                                        contentColor = neon.accentText,
                                    ),
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(15.dp))
                                    Spacer(Modifier.width(6.dp))
                                    Text("Retry", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
                                }
                                OutlinedButton(
                                    onClick = onCancel,
                                    shape = RoundedCornerShape(11.dp),
                                    modifier = Modifier.weight(1f),
                                ) {
                                    Text("Cancel", fontFamily = neon.sans, color = neon.textDim)
                                }
                            }
                        }

                        is SshBootstrapState.Idle -> Unit
                    }
                }
            }
        }
    }
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
