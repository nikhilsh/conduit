package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.BuildConfig
import sh.nikhil.conduit.ReadinessCheckItem
import sh.nikhil.conduit.ReadinessStatus
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Warning

// ---------------------------------------------------------------------------
// WS-H.2: Broker-update banner
// WS-H.3: Post-pair readiness checklist
// ---------------------------------------------------------------------------

private fun installOneliner() =
    "curl -fsSL https://github.com/nikhilsh/conduit/releases/download/${BuildConfig.RELEASE_TAG}/install.sh | sh"

/**
 * Non-blocking banner shown on the home / box list when the broker is
 * outdated. SSH-paired boxes (endpoint == 127.0.0.1:*) get a one-tap
 * re-bootstrap (with a confirmation dialog when [liveCount] > 0);
 * token-paired boxes get the install.sh one-liner to copy.
 *
 * [liveCount]: pass 0 to skip the live-session warning; pass the real count
 * so the confirmation dialog names the exact number.
 *
 * "dev" / unparseable broker versions are NEVER shown (honest-state).
 * Mirror of iOS `ConduitUI.BrokerUpdateBanner`.
 */
@Composable
fun BrokerUpdateBanner(
    brokerVersion: String,
    isSshPaired: Boolean,
    liveCount: Int = 0,
    onRebootstrap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    val clipboard = LocalClipboardManager.current
    var copyConfirmed by remember { mutableStateOf(false) }
    var showConfirmDialog by remember { mutableStateOf(false) }

    if (showConfirmDialog) {
        val sessionWord = if (liveCount == 1) "session" else "sessions"
        AlertDialog(
            onDismissRequest = { showConfirmDialog = false },
            title = { Text("End $liveCount running $sessionWord to update?") },
            text = { Text("History is saved and sessions resume after the restart.") },
            confirmButton = {
                TextButton(onClick = {
                    showConfirmDialog = false
                    onRebootstrap()
                }) { Text("Update") }
            },
            dismissButton = {
                TextButton(onClick = { showConfirmDialog = false }) { Text("Cancel") }
            },
        )
    }

    Surface(
        shape = RoundedCornerShape(14.dp),
        color = neon.accent.copy(alpha = if (neon.glow) 0.08f else 0.06f),
        modifier = modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(14.dp),
                fill = neon.accent.copy(alpha = if (neon.glow) 0.08f else 0.06f),
                borderColor = neon.accent.copy(alpha = 0.35f),
            ),
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Icon(
                Icons.Filled.Refresh,
                contentDescription = null,
                tint = neon.accent,
                modifier = Modifier.size(18.dp).padding(top = 1.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(
                    "Broker update available",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    color = neon.text,
                )
                Text(
                    "This box runs conduit $brokerVersion. A newer version is available.",
                    fontFamily = neon.sans,
                    fontSize = 12.sp,
                    color = neon.textDim,
                )
                if (liveCount > 0) {
                    val plural = if (liveCount == 1) "session" else "sessions"
                    Text(
                        "Updating restarts the broker and ends $liveCount running $plural. Their history is saved — they'll resume automatically afterward.",
                        fontFamily = neon.sans,
                        fontSize = 12.sp,
                        color = neon.textDim,
                    )
                }
                if (isSshPaired) {
                    // One-tap re-bootstrap (with confirm when live sessions exist).
                    Surface(
                        shape = RoundedCornerShape(99.dp),
                        color = neon.accent,
                        modifier = Modifier.clickable {
                            if (liveCount > 0) showConfirmDialog = true else onRebootstrap()
                        },
                    ) {
                        Text(
                            "Update now",
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            fontSize = 12.sp,
                            color = neon.accentText,
                            modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                        )
                    }
                } else {
                    // Token-paired: copy the install.sh one-liner.
                    AnimatedContent(targetState = copyConfirmed, label = "copy") { confirmed ->
                        val scope = rememberCoroutineScope()
                        Surface(
                            shape = RoundedCornerShape(99.dp),
                            color = neon.accent,
                            modifier = Modifier.clickable {
                                clipboard.setText(AnnotatedString(installOneliner()))
                                copyConfirmed = true
                                scope.launch {
                                    kotlinx.coroutines.delay(2_000)
                                    copyConfirmed = false
                                }
                            },
                        ) {
                            Text(
                                if (confirmed) "Copied!" else "Copy install command",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 12.sp,
                                color = neon.accentText,
                                modifier = Modifier.padding(horizontal = 10.dp, vertical = 5.dp),
                            )
                        }
                    }
                    Text(
                        installOneliner(),
                        fontFamily = neon.mono,
                        fontSize = 10.5.sp,
                        color = neon.textFaint,
                        maxLines = 2,
                    )
                }
            }
        }
    }
}

/**
 * Compact checklist of per-agent and infra readiness. Informational,
 * never blocking. "Sign in" rows deep-link the existing AgentLoginSheet.
 * Mirror of iOS `ConduitUI.ReadinessChecklist`.
 */
@Composable
fun ReadinessChecklist(
    items: List<ReadinessCheckItem>,
    onSignIn: (provider: String) -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    Column(modifier = modifier, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        items.forEach { item ->
            ReadinessRow(item = item, onSignIn = onSignIn)
        }
    }
}

@Composable
private fun ReadinessRow(
    item: ReadinessCheckItem,
    onSignIn: (provider: String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val fillColor = when {
        item.status == ReadinessStatus.Ok           -> neon.surface
        item.status == ReadinessStatus.NotSignedIn  -> neon.accent.copy(alpha = 0.07f)
        item.status == ReadinessStatus.NotInstalled && item.autoInstalls -> neon.surface
        item.status == ReadinessStatus.NotInstalled -> neon.red.copy(alpha = 0.07f)
        else /* Absent */                           -> neon.accent.copy(alpha = 0.07f)
    }
    val borderColor = when {
        item.status == ReadinessStatus.Ok           -> neon.border
        item.status == ReadinessStatus.NotSignedIn  -> neon.accent.copy(alpha = 0.3f)
        item.status == ReadinessStatus.NotInstalled && item.autoInstalls -> neon.border
        item.status == ReadinessStatus.NotInstalled -> neon.red.copy(alpha = 0.3f)
        else /* Absent */                           -> neon.accent.copy(alpha = 0.3f)
    }
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(12.dp),
                fill = fillColor,
                borderColor = borderColor,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            // Status icon: auto-install agent CLIs use a neutral download
            // icon (informational), non-auto-installed tools use warning/error.
            val (icon, tint) = when {
                item.status == ReadinessStatus.Ok          -> Icons.Filled.CheckCircle to neon.green
                item.status == ReadinessStatus.NotSignedIn -> Icons.Outlined.Warning   to neon.accent
                item.status == ReadinessStatus.NotInstalled && item.autoInstalls ->
                    Icons.Outlined.Warning to neon.textDim
                item.status == ReadinessStatus.NotInstalled -> Icons.Filled.Cancel     to neon.red
                else /* Absent */                          -> Icons.Outlined.Warning   to neon.accent
            }
            Icon(
                icon,
                contentDescription = null,
                tint = tint,
                modifier = Modifier.size(18.dp),
            )
            Spacer(Modifier.width(10.dp))
            Text(
                item.label,
                fontFamily = neon.sans,
                fontWeight = FontWeight.Medium,
                fontSize = 13.sp,
                color = if (item.status == ReadinessStatus.Ok) neon.text else neon.textDim,
                modifier = Modifier.weight(1f),
            )
            // Action label. iOS shows a green checkmark for Ok rows.
            when (item.status) {
                ReadinessStatus.Ok -> {
                    Icon(
                        Icons.Filled.CheckCircle,
                        contentDescription = null,
                        tint = neon.green,
                        modifier = Modifier.size(16.dp),
                    )
                }
                ReadinessStatus.NotSignedIn -> {
                    if (!item.loginProvider.isNullOrEmpty()) {
                        Surface(
                            shape = RoundedCornerShape(99.dp),
                            color = neon.accent,
                            modifier = Modifier.clickable { onSignIn(item.loginProvider) },
                        ) {
                            Text(
                                "Sign in",
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                fontSize = 11.5.sp,
                                color = neon.accentText,
                                modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                            )
                        }
                    } else {
                        Text(
                            "not signed in",
                            fontFamily = neon.mono,
                            fontSize = 10.5.sp,
                            color = neon.textFaint,
                        )
                    }
                }
                ReadinessStatus.NotInstalled ->
                    Text(
                        if (item.autoInstalls) "installs on first use" else "not installed",
                        fontFamily = neon.mono,
                        fontSize = 10.5.sp,
                        color = neon.textFaint,
                    )
                ReadinessStatus.Absent ->
                    Text("missing", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
            }
        }
    }
}
