package sh.nikhil.swekitty.ui

import android.content.Context
import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
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
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.auth.AgentLoginCoordinator
import sh.nikhil.swekitty.auth.AgentLoginProvider
import sh.nikhil.swekitty.auth.SessionStoreAgentLoginTransport

/**
 * Android port of `apps/ios/Sources/LitterUI/Views/LitterAgentLoginSheet.swift`.
 *
 * v2 (litter-pattern, broker-driven) agent login. Two rows kick off the
 * `AgentLoginCoordinator` flow for OpenAI / Anthropic:
 *
 *   1. Sheet builds a [SessionStoreAgentLoginTransport] + an
 *      [AgentLoginCoordinator], registers it on
 *      [SessionStore.activeLoginCoordinator], and calls `start(provider)`.
 *   2. The broker mints an authorize URL + loopback port and emits an
 *      `agent_login_url` view_event; the core routes it back into the
 *      coordinator (via `SessionStore.routeAgentLoginViewEvent`), which
 *      binds the loopback and moves to `AwaitingBrowserRedirect`.
 *   3. This sheet observes that state and opens the authorize URL in a
 *      Chrome Custom Tab. The coordinator's loopback captures the
 *      redirect and ships `agent_login_callback`; the broker completes
 *      the CLI token exchange and emits `agent_login_complete`.
 *
 * The legacy client-side PKCE flow (`OAuthClient` + `swekitty://` deep
 * link) is replaced here; `OAuthClient` itself is deleted in Stage 4.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentLoginSheet(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()

    var coordinator by remember { mutableStateOf<AgentLoginCoordinator?>(null) }
    var isWorking by remember { mutableStateOf(false) }
    var statusMessage by remember { mutableStateOf<String?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    // Guards against re-opening the browser if the StateFlow replays
    // AwaitingBrowserRedirect to a fresh collector.
    var launchedToken by remember { mutableStateOf<String?>(null) }

    // Observe the active coordinator's state and drive UI + the browser
    // hand-off. Keyed on the coordinator instance so a new login attempt
    // re-subscribes cleanly.
    LaunchedEffect(coordinator) {
        val coord = coordinator ?: return@LaunchedEffect
        coord.state.collect { state ->
            when (state) {
                is AgentLoginCoordinator.State.Idle -> {}
                is AgentLoginCoordinator.State.WaitingForBrokerURL -> {
                    statusMessage = "Waiting for the broker to mint the login URL…"
                    errorMessage = null
                }
                is AgentLoginCoordinator.State.AwaitingBrowserRedirect -> {
                    statusMessage = "Complete the sign-in in the browser, then return here."
                    errorMessage = null
                    if (launchedToken != state.sessionToken) {
                        launchedToken = state.sessionToken
                        openAuthorizeUrl(ctx, state.authorizeUrl.toString())
                    }
                }
                is AgentLoginCoordinator.State.ForwardingCallback -> {
                    statusMessage = "Finishing sign-in with the broker…"
                }
                is AgentLoginCoordinator.State.Succeeded -> {
                    isWorking = false
                    statusMessage = "Signed in. The broker has your credentials for future sessions."
                    errorMessage = null
                }
                is AgentLoginCoordinator.State.Failed -> {
                    isWorking = false
                    statusMessage = null
                    errorMessage = "Sign-in failed: ${state.reason}"
                }
                is AgentLoginCoordinator.State.Cancelled -> {
                    isWorking = false
                    statusMessage = null
                }
            }
        }
    }

    // If the sheet leaves composition mid-flow, cancel so the broker
    // tears down the spawned CLI login subprocess.
    DisposableEffect(Unit) {
        onDispose {
            coordinator?.cancel()
            store.activeLoginCoordinator = null
        }
    }

    fun startLogin(provider: AgentLoginProvider) {
        isWorking = true
        statusMessage = "Asking the broker to start the ${provider.wireName} login flow…"
        errorMessage = null
        launchedToken = null
        val coord = AgentLoginCoordinator(transport = SessionStoreAgentLoginTransport(store))
        coordinator = coord
        store.activeLoginCoordinator = coord
        scope.launch {
            try {
                coord.start(provider)
            } catch (t: Throwable) {
                isWorking = false
                store.activeLoginCoordinator = null
                errorMessage = "Sign-in failed to start: ${t.message ?: t}"
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
                "Sign in on the broker host. The agent CLI's own login runs there; " +
                    "you just complete the browser step and the broker keeps the credentials.",
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
                        subtitle = "Codex / ChatGPT OAuth · runs `codex login` on the broker",
                        enabled = !isWorking,
                        onClick = { startLogin(AgentLoginProvider.OPENAI) },
                    )
                    HorizontalDivider()
                    ProviderRow(
                        title = "Login with Claude",
                        subtitle = "Claude OAuth · runs `claude` login on the broker",
                        enabled = !isWorking,
                        onClick = { startLogin(AgentLoginProvider.ANTHROPIC) },
                    )
                }
            }

            statusMessage?.let { StatusPill(text = it, isError = false) }
            errorMessage?.let { StatusPill(text = it, isError = true) }

            Spacer(Modifier.height(8.dp))
        }
    }
}

private fun openAuthorizeUrl(ctx: Context, url: String) {
    runCatching {
        CustomTabsIntent.Builder().build().launchUrl(ctx, Uri.parse(url))
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
