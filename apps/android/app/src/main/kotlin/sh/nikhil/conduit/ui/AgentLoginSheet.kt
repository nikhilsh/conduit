package sh.nikhil.conduit.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
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
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
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
import kotlinx.coroutines.launch
import sh.nikhil.conduit.SessionStore
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
        try {
            store.sendAgentCredentials(cred)
            statusMessage = "Signed in. The broker now has your ${cred.provider.raw} credentials for future sessions."
            errorMessage = null
        } catch (t: Throwable) {
            // Token exchange succeeded; only the broker hand-off failed.
            // The local copy survives — surface a retry.
            statusMessage = null
            errorMessage = "Signed in, but couldn't reach the broker. Reconnect and try again — your login is saved locally."
        }
    }

    fun loginChatGPT() {
        isWorking = true
        statusMessage = "Opening ChatGPT sign-in…"
        errorMessage = null
        awaitingPaste = false
        scope.launch {
            try {
                val cred = OAuthClient(OAuthProvider.OPENAI).startLoopbackLogin(ctx)
                deliver(cred)
            } catch (e: OAuthClientError) {
                statusMessage = null; errorMessage = describe(e)
            } catch (t: Throwable) {
                statusMessage = null; errorMessage = "Sign-in failed: ${t.message ?: t}"
            } finally {
                isWorking = false
            }
        }
    }

    fun beginClaude() {
        isWorking = true
        errorMessage = null
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
        scope.launch {
            try {
                val cred = client.finishCodePaste(pastedCode, req)
                deliver(cred)
                awaitingPaste = false
                pastedCode = ""
                pasteClient = null
                pasteRequest = null
            } catch (e: OAuthClientError) {
                statusMessage = null; errorMessage = describe(e)
            } catch (t: Throwable) {
                statusMessage = null; errorMessage = "Sign-in failed: ${t.message ?: t}"
            } finally {
                isWorking = false
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            Text(
                "Agent accounts",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                "Sign in to the model providers you want to use through Conduit. " +
                    "You sign in in your own browser; Conduit ships the resulting credential " +
                    "to the broker so agents run on your account.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )

            Surface(
                shape = RoundedCornerShape(16.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 6.dp)) {
                    ProviderRow(
                        title = "Login with ChatGPT",
                        subtitle = "Codex / ChatGPT OAuth · auth.openai.com",
                        enabled = !isWorking,
                        onClick = { loginChatGPT() },
                    )
                    HorizontalDivider()
                    ProviderRow(
                        title = "Login with Claude",
                        subtitle = "Claude OAuth · claude.ai (paste code)",
                        enabled = !isWorking,
                        onClick = { beginClaude() },
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

@Composable
private fun ProviderRow(
    title: String,
    subtitle: String,
    enabled: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(enabled = enabled, onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            Icons.Filled.AccountCircle,
            contentDescription = null,
            tint = if (enabled) LocalNeonTheme.current.accent else MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.size(22.dp),
        )
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f).padding(end = 8.dp)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (!enabled) {
            CircularProgressIndicator(modifier = Modifier.size(18.dp))
        } else {
            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
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
