package sh.nikhil.conduit.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AccountCircle
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.rounded.Close
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.auth.OAuthClient
import sh.nikhil.conduit.auth.OAuthClientError
import sh.nikhil.conduit.auth.OAuthCredential
import sh.nikhil.conduit.auth.OAuthProvider
import sh.nikhil.conduit.auth.OAuthRequest
import sh.nikhil.conduit.auth.OAuthStore

/**
 * Android port of `apps/ios/Sources/ConduitUI/Views/ConduitAgentLoginSheet.swift`.
 *
 * Litter-faithful phone-side agent login: the phone runs PKCE + the
 * browser flow and exchanges the code itself, then ships the
 * provider-native credential blob to the broker via
 * `SessionStore.sendAgentCredentials`.
 *
 *   - ChatGPT/Codex: loopback redirect (`http://localhost:1455`) caught
 *     in-app by `AgentLoginLoopbackServer`; code captured automatically.
 *   - Claude/Anthropic: the code-display page on platform.claude.com;
 *     the user copies the shown `code#state` and pastes it here.
 *
 * The credential is also saved to EncryptedSharedPreferences so a
 * transient WS outage doesn't lose it.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentLoginSheet(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var isWorking by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var awaitingPaste by remember { mutableStateOf(false) }
    var pastedCode by remember { mutableStateOf("") }
    // Holds the in-flight Claude request (PKCE verifier/state) between
    // opening the browser and the user pasting the code.
    var pasteClient by remember { mutableStateOf<OAuthClient?>(null) }
    var pasteRequest by remember { mutableStateOf<OAuthRequest?>(null) }
    // Phone-local auth state per provider (line 1 of each row). Distinct from
    // the connected-box readiness (line 2): a credential on THIS device says
    // nothing about whether the connected box has it.
    var phoneAuth by remember { mutableStateOf<Map<OAuthProvider, PhoneAuthState>>(emptyMap()) }
    // Connected-box readiness, keyed by agent id ("claude"/"codex"). null
    // (old broker / not yet fetched) → hide line 2 entirely.
    val brokerReadiness by store.brokerReadiness.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    // Friendly connected-box name (SavedServer.name) when a box is connected.
    val boxName: String? = if (endpoint.isComplete) {
        savedServers.firstOrNull { it.endpoint == endpoint }?.name ?: endpoint.displayHost
    } else null

    fun refreshPhoneAuth() {
        scope.launch {
            phoneAuth = withContext(Dispatchers.IO) {
                OAuthProvider.values().associateWith { phoneAuthState(ctx, it) }
            }
        }
    }
    LaunchedEffect(Unit) { refreshPhoneAuth() }

    // Per-box clear: remove the pushed agent credential from the connected
    // box (best-effort), then refresh readiness so line 2 updates. Device-
    // local OAuthStore is untouched here. Only meaningful with a live box.
    fun clearFromBox(provider: OAuthProvider) {
        val ep = endpoint
        if (!ep.isComplete) return
        Telemetry.breadcrumb("agent-credentials", "clear from box tapped", mapOf("provider" to provider.raw, "host" to ep.displayHost))
        scope.launch {
            store.clearAgentCredential(provider.raw, ep)
            runCatching { store.refreshModelCatalog() }
        }
    }

    fun describe(e: OAuthClientError): String = when (e) {
        is OAuthClientError.UserCancelled -> "Sign-in cancelled."
        is OAuthClientError.MissingCallback -> "The browser didn't return a result."
        is OAuthClientError.MissingCode -> "No authorization code came back. If you pasted, check you copied the whole code."
        is OAuthClientError.TokenExchangeFailed -> "Token exchange failed (HTTP ${e.status})."
        is OAuthClientError.MalformedTokenResponse -> "The provider's token response was malformed."
        is OAuthClientError.Underlying -> "Sign-in failed: ${e.message}"
    }

    suspend fun deliver(cred: OAuthCredential) {
        runCatching { OAuthStore.save(ctx, cred) }
        refreshPhoneAuth()
        Telemetry.breadcrumb("agent_login", "shipping credential to broker", mapOf("provider" to cred.provider.raw))
        try {
            store.sendAgentCredentials(cred)
            // Pushed creds change the box's readiness; refresh so line 2 flips
            // to "Ready on <box>" without waiting for the next capabilities poll.
            runCatching { store.refreshModelCatalog() }
            statusMessage = "Signed in. The broker now has your ${cred.provider.raw} credentials for future sessions."
            errorMessage = null
            // Standalone visible event for every terminal outcome (a
            // breadcrumb alone is invisible unless a later event fires).
            Telemetry.debug("oauth_result", "shipped ${cred.provider.raw}", mapOf("provider" to cred.provider.raw))
        } catch (t: Throwable) {
            // Token exchange succeeded and the credential is saved locally.
            // The broker hand-off needs a live session (the core carries it
            // over an active session WS); if none is live yet, the store
            // resends it when the user starts a session — so this is NOT a
            // failure. Show a benign "saved" message, not a scary error.
            statusMessage = "Signed in — saved. It’ll sync to the broker when you start a session."
            errorMessage = null
            Telemetry.debug("oauth_result", "saved-deferred ${cred.provider.raw}", mapOf("provider" to cred.provider.raw, "reason" to (t.message ?: t.toString())))
        }
    }

    fun loginChatGPT() {
        isWorking = true
        statusMessage = "Opening ChatGPT sign-in…"
        errorMessage = null
        awaitingPaste = false
        Telemetry.breadcrumb("agent_login", "openai: start (loopback)")
        scope.launch {
            try {
                val cred = OAuthClient(OAuthProvider.OPENAI).startLoopbackLogin(ctx)
                Telemetry.breadcrumb("agent_login", "openai: token exchange ok")
                deliver(cred)
            } catch (e: OAuthClientError) {
                statusMessage = null; errorMessage = describe(e)
                Telemetry.capture(e, "agent login failed: openai", mapOf("flow" to "agent_login", "provider" to "openai"), mapOf("reason" to describe(e)))
            } catch (t: Throwable) {
                statusMessage = null; errorMessage = "Sign-in failed: ${t.message ?: t}"
                Telemetry.capture(t, "agent login failed: openai", mapOf("flow" to "agent_login", "provider" to "openai"))
            } finally {
                isWorking = false
            }
        }
    }

    fun beginClaude() {
        isWorking = true
        errorMessage = null
        Telemetry.breadcrumb("agent_login", "anthropic: begin code-paste, opening browser")
        scope.launch {
            try {
                val client = OAuthClient(OAuthProvider.ANTHROPIC)
                val req = client.beginCodePaste(ctx)
                pasteClient = client
                pasteRequest = req
                awaitingPaste = true
                statusMessage = "Sign in, copy the code Claude shows, then paste it below."
            } catch (t: Throwable) {
                statusMessage = null; errorMessage = "Could not start Claude sign-in: ${t.message ?: t}"
                Telemetry.capture(t, "agent login failed: anthropic begin", mapOf("flow" to "agent_login", "provider" to "anthropic"))
            } finally {
                isWorking = false
            }
        }
    }

    fun finishClaude() {
        val client = pasteClient
        val req = pasteRequest
        if (client == null || req == null) {
            errorMessage = "Start the Claude sign-in first."
            return
        }
        isWorking = true
        statusMessage = "Exchanging the Claude code…"
        errorMessage = null
        Telemetry.breadcrumb("agent_login", "anthropic: submit pasted code, exchanging")
        scope.launch {
            try {
                val cred = client.finishCodePaste(pastedCode, req)
                Telemetry.breadcrumb("agent_login", "anthropic: token exchange ok")
                deliver(cred)
                awaitingPaste = false
                pastedCode = ""
                pasteClient = null
                pasteRequest = null
            } catch (e: OAuthClientError) {
                statusMessage = null; errorMessage = describe(e)
                Telemetry.capture(e, "agent login failed: anthropic", mapOf("flow" to "agent_login", "provider" to "anthropic"), mapOf("reason" to describe(e)))
            } catch (t: Throwable) {
                statusMessage = null; errorMessage = "Sign-in failed: ${t.message ?: t}"
                Telemetry.capture(t, "agent login failed: anthropic", mapOf("flow" to "agent_login", "provider" to "anthropic"))
            } finally {
                isWorking = false
            }
        }
    }

    val neon = LocalNeonTheme.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        // Fix 2: TopAppBar with trailing X to close (replaces the old "Cancel" text).
        TopAppBar(
            title = {
                Text(
                    "Agent accounts",
                    style = MaterialTheme.typography.titleMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
            },
            actions = {
                IconButton(onClick = onDismiss) {
                    Icon(
                        Icons.Rounded.Close,
                        contentDescription = "Close",
                        tint = neon.textDim,
                    )
                }
            },
            colors = TopAppBarDefaults.topAppBarColors(containerColor = androidx.compose.ui.graphics.Color.Transparent),
        )
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(16.dp),
        ) {
            // Fix 2: one card, one row per provider with avatar tint, name,
            // signed-in status, and a Manage / Sign in trailing action.
            Surface(
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) {
                    // Claude row
                    ProviderRow(
                        agentId = "claude",
                        title = "Claude",
                        provider = OAuthProvider.ANTHROPIC,
                        phone = phoneAuth[OAuthProvider.ANTHROPIC] ?: PhoneAuthState.NOT_SIGNED_IN,
                        boxSignedIn = brokerReadiness?.agents?.get("claude")?.signedIn,
                        boxName = boxName,
                        enabled = !isWorking,
                        onReauthenticate = { beginClaude() },
                        onRemoveFromPhone = {
                            OAuthStore.clear(ctx, OAuthProvider.ANTHROPIC)
                            refreshPhoneAuth()
                        },
                        onClearFromBox = { clearFromBox(OAuthProvider.ANTHROPIC) },
                    )
                    HorizontalDivider(color = neon.border)
                    // ChatGPT / Codex row
                    ProviderRow(
                        agentId = "codex",
                        title = "ChatGPT",
                        provider = OAuthProvider.OPENAI,
                        phone = phoneAuth[OAuthProvider.OPENAI] ?: PhoneAuthState.NOT_SIGNED_IN,
                        boxSignedIn = brokerReadiness?.agents?.get("codex")?.signedIn,
                        boxName = boxName,
                        enabled = !isWorking,
                        onReauthenticate = { loginChatGPT() },
                        onRemoveFromPhone = {
                            OAuthStore.clear(ctx, OAuthProvider.OPENAI)
                            refreshPhoneAuth()
                        },
                        onClearFromBox = { clearFromBox(OAuthProvider.OPENAI) },
                    )
                }
            }

            if (awaitingPaste) {
                Surface(
                    shape = RoundedCornerShape(16.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Column(
                        modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
                        verticalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Text(
                            "After signing in, Claude shows a code. Copy it and paste it here.",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        OutlinedTextField(
                            value = pastedCode,
                            onValueChange = { pastedCode = it },
                            label = { Text("code#state") },
                            singleLine = true,
                            enabled = !isWorking,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        Button(
                            onClick = { finishClaude() },
                            enabled = !isWorking && pastedCode.trim().isNotEmpty(),
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            Text("Submit code")
                        }
                    }
                }
            }

            statusMessage?.let { StatusPill(text = it, isError = false) }
            errorMessage?.let { StatusPill(text = it, isError = true) }

            Spacer(Modifier.height(8.dp))
        }
    }
}

/**
 * Phone-local auth state for a provider (line 1 of [ProviderRow]). Derived
 * from the device-local [OAuthStore] only — independent of any box.
 */
internal enum class PhoneAuthState { NOT_SIGNED_IN, SIGNED_IN, EXPIRED }

/**
 * Read the device-local credential and classify it. EXPIRED is only inferred
 * for Anthropic (its blob carries an `expiresAt` ms timestamp); OpenAI's
 * on-device blob has no reliable wall-clock expiry, so a stored OpenAI
 * credential is reported SIGNED_IN rather than fabricating an expiry.
 */
internal fun phoneAuthState(ctx: android.content.Context, provider: OAuthProvider): PhoneAuthState {
    val cred = runCatching { OAuthStore.load(ctx, provider) }.getOrNull()
        ?: return PhoneAuthState.NOT_SIGNED_IN
    return when (cred) {
        is OAuthCredential.Anthropic -> {
            val exp = cred.blob.claudeAiOauth.expiresAt
            if (exp in 1 until System.currentTimeMillis()) PhoneAuthState.EXPIRED
            else PhoneAuthState.SIGNED_IN
        }
        is OAuthCredential.OpenAi -> PhoneAuthState.SIGNED_IN
    }
}

/**
 * Per-provider row: two-line status (line 1 = phone, line 2 = connected box)
 * plus an overflow menu for re-authenticate / remove-from-phone / remove-from-
 * box. Replaces the old single "Manage / Sign in" chevron. Plan badge omitted
 * — no plan source exists here; never invent it.
 */
@OptIn(androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
private fun ProviderRow(
    agentId: String,
    title: String,
    provider: OAuthProvider,
    phone: PhoneAuthState,
    /** Connected box readiness for this agent; null = no/old box → hide line 2. */
    boxSignedIn: Boolean?,
    /** Connected box display name (for line 2 wording); null when no box. */
    boxName: String?,
    enabled: Boolean,
    onReauthenticate: () -> Unit,
    onRemoveFromPhone: () -> Unit,
    onClearFromBox: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val tint = neonAgentColor(agentId, neon)
    var menuOpen by remember { mutableStateOf(false) }

    val (phoneText, phoneColor) = when (phone) {
        PhoneAuthState.SIGNED_IN -> "Signed in" to neon.green
        PhoneAuthState.EXPIRED -> "Signed in · expired" to neon.yellow
        PhoneAuthState.NOT_SIGNED_IN -> "Not signed in" to neon.textDim
    }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .combinedClickable(
                enabled = enabled,
                onClick = { if (phone == PhoneAuthState.NOT_SIGNED_IN) onReauthenticate() else menuOpen = true },
                onLongClick = { menuOpen = true },
            )
            .padding(vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        AgentAvatar(assistant = agentId, size = 36.dp)
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
            )
            // Line 1 — phone status.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                if (phone != PhoneAuthState.NOT_SIGNED_IN) {
                    androidx.compose.foundation.Canvas(Modifier.size(6.dp)) {
                        drawCircle(color = phoneColor.copy(alpha = 0.9f))
                    }
                }
                Text(
                    phoneText,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = phoneColor,
                )
            }
            // Line 2 — connected-box status. Hidden when readiness is null.
            if (boxSignedIn != null && boxName != null) {
                val (boxText, boxColor) = if (boxSignedIn) {
                    "Ready on $boxName" to neon.green
                } else {
                    "Not on $boxName · auto-pushes on connect" to neon.textDim
                }
                Text(
                    boxText,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = boxColor,
                )
            }
        }
        if (!enabled) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
        } else if (phone == PhoneAuthState.NOT_SIGNED_IN && boxSignedIn != true) {
            // Nothing to manage yet — show a plain Sign in affordance.
            Text(
                "Sign in",
                style = MaterialTheme.typography.labelMedium,
                fontFamily = neon.sans,
                color = tint,
            )
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = tint, modifier = Modifier.size(18.dp))
        } else {
            Box {
                IconButton(onClick = { menuOpen = true }, enabled = enabled) {
                    Icon(Icons.Filled.MoreVert, contentDescription = "Account options", tint = neon.textDim)
                }
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(
                        text = { Text("Re-authenticate") },
                        onClick = { menuOpen = false; onReauthenticate() },
                    )
                    if (phone != PhoneAuthState.NOT_SIGNED_IN) {
                        DropdownMenuItem(
                            text = { Text("Remove from phone", color = neon.red) },
                            onClick = { menuOpen = false; onRemoveFromPhone() },
                        )
                    }
                    if (boxSignedIn != null && boxName != null) {
                        DropdownMenuItem(
                            text = { Text("Remove pushed credential from this box", color = neon.red) },
                            onClick = { menuOpen = false; onClearFromBox() },
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun StatusPill(text: String, isError: Boolean) {
    Surface(
        shape = RoundedCornerShape(12.dp),
        color = if (isError)
            MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.6f)
        else
            MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text,
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
            style = MaterialTheme.typography.bodySmall,
            color = if (isError) MaterialTheme.colorScheme.onErrorContainer else MaterialTheme.colorScheme.onSurface,
        )
    }
}
