package sh.nikhil.swekitty.ui

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
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.auth.OAuthClient
import sh.nikhil.swekitty.auth.OAuthClientError
import sh.nikhil.swekitty.auth.OAuthCredential
import sh.nikhil.swekitty.auth.OAuthProvider
import sh.nikhil.swekitty.auth.OAuthRequest
import sh.nikhil.swekitty.auth.OAuthStore

/**
 * Android port of `apps/ios/Sources/Views/AgentLoginSheet.swift`. Two
 * rows:
 *
 * - "Login with ChatGPT" — kicks off OpenAI / Codex OAuth via
 *   `OAuthClient(provider = OPENAI).startLogin(ctx)`, persists the
 *   resulting `AuthDotJson` blob in [OAuthStore], hands the credential
 *   to [SessionStore.sendAgentCredentials] for the eventual broker
 *   round-trip.
 * - "Login with Claude" — same flow, provider `ANTHROPIC`, persists a
 *   `ClaudeCredentialsJson` blob. Anthropic's OAuth params were
 *   reverse-engineered from the `claude` CLI; if the authorize
 *   endpoint refuses the `swekitty://` redirect, the call fails at
 *   `/oauth/authorize` (documented risk; same one iOS PR #104 carries).
 *
 * The Custom Tabs handoff is asynchronous: the sheet kicks off the
 * browser tab, then [SessionStore.pendingOAuth] holds the
 * [OAuthRequest] (verifier + state). When `MainActivity.onNewIntent`
 * receives `swekitty://oauth/<provider>/callback?code=...`, it routes
 * the Uri back into [SessionStore.completeOAuthCallback], which calls
 * [OAuthClient.completeWithCallbackUri] and surfaces the result here
 * via the `pendingOAuth` flow.
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

    val callback by store.oauthCallback.collectAsState()

    // When MainActivity hands back a `swekitty://oauth/...` Uri, the
    // sheet drives the token exchange. We do it here (not in the
    // SessionStore) so the UI can show progress + errors without
    // re-plumbing state.
    LaunchedEffect(callback) {
        val c = callback ?: return@LaunchedEffect
        store.clearOAuthCallback()
        isWorking = true
        statusMessage = "Exchanging authorization code…"
        errorMessage = null
        scope.launch {
            try {
                val client = OAuthClient(provider = c.request.provider)
                val credential = withContext(Dispatchers.IO) {
                    client.completeWithCallbackUri(c.uri, c.request)
                }
                OAuthStore.save(ctx.applicationContext, credential)
                store.sendAgentCredentials(credential)
                statusMessage = "Signed in — credential saved."
                logCredentialToConsole(credential)
            } catch (e: OAuthClientError.UserCancelled) {
                statusMessage = null
                errorMessage = "Sign-in cancelled."
            } catch (t: Throwable) {
                statusMessage = null
                errorMessage = "Sign-in failed: ${t.message ?: t}"
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
                "Stage 0/1 spike — credential is stashed in EncryptedSharedPreferences " +
                    "and logged. Broker round-trip lands in a follow-up.",
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
                        onClick = {
                            scope.launch { startLogin(ctx.applicationContext, store, OAuthProvider.OPENAI) { working, status, error ->
                                isWorking = working
                                if (status != null) statusMessage = status
                                if (error != null) errorMessage = error
                            } }
                        },
                    )
                    HorizontalDivider()
                    ProviderRow(
                        title = "Login with Claude",
                        subtitle = "Claude OAuth · claude.ai",
                        enabled = !isWorking,
                        onClick = {
                            scope.launch { startLogin(ctx.applicationContext, store, OAuthProvider.ANTHROPIC) { working, status, error ->
                                isWorking = working
                                if (status != null) statusMessage = status
                                if (error != null) errorMessage = error
                            } }
                        },
                    )
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
            tint = if (enabled) SweKittyTheme.accentStrong() else MaterialTheme.colorScheme.onSurfaceVariant,
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

private suspend fun startLogin(
    appCtx: android.content.Context,
    store: SessionStore,
    provider: OAuthProvider,
    update: (working: Boolean, status: String?, error: String?) -> Unit,
) {
    update(true, "Opening sign-in browser…", null)
    try {
        val client = OAuthClient(provider = provider)
        val req: OAuthRequest = withContext(Dispatchers.Main) { client.startLogin(appCtx) }
        store.armOAuth(req)
        // The Custom Tabs intent is fire-and-forget. Keep `isWorking`
        // true here because the LaunchedEffect upstream will pick up
        // the callback Uri and finish the flow; if the user just
        // never returns we re-enable on cancel from the system back.
    } catch (t: Throwable) {
        update(false, null, "Couldn't open browser: ${t.message ?: t}")
        return
    }
    // We deliberately don't flip isWorking=false here — the
    // LaunchedEffect that observes the callback owns the next
    // transition. If the user backs out of Chrome without
    // completing, the AgentLoginSheet's own dismiss/cancel button
    // resets state.
}

/** Logs the credential JSON to logcat for the spike demo (mirrors iOS). */
private fun logCredentialToConsole(credential: OAuthCredential) {
    android.util.Log.i(
        "AgentLoginSheet",
        "credential blob (${credential.provider.raw}): ${credential.toJson()}",
    )
}
