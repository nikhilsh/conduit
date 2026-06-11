package sh.nikhil.conduit.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Icon
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
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

private const val INSTALL_ONELINER = "curl -fsSL https://conduit.nikhil.sh/install.sh | sh"

/**
 * Non-blocking banner shown on the home / box list when the broker is
 * outdated. SSH-paired boxes (endpoint == 127.0.0.1:*) get a one-tap
 * re-bootstrap; token-paired boxes get the install.sh one-liner to copy.
 *
 * "dev" / unparseable broker versions are NEVER shown (honest-state).
 * Mirror of iOS `ConduitUI.BrokerUpdateBanner`.
 */
@Composable
fun BrokerUpdateBanner(
    brokerVersion: String,
    isSshPaired: Boolean,
    onRebootstrap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    val clipboard = LocalClipboardManager.current
    var copyConfirmed by remember { mutableStateOf(false) }

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
                if (isSshPaired) {
                    // One-tap re-bootstrap.
                    Surface(
                        shape = RoundedCornerShape(99.dp),
                        color = neon.accent,
                        modifier = Modifier.clickable { onRebootstrap() },
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
                                clipboard.setText(AnnotatedString(INSTALL_ONELINER))
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
                        INSTALL_ONELINER,
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
    val fillColor = when (item.status) {
        ReadinessStatus.Ok          -> neon.surface
        ReadinessStatus.NotSignedIn -> neon.accent.copy(alpha = 0.07f)
        ReadinessStatus.NotInstalled -> neon.red.copy(alpha = 0.07f)
        ReadinessStatus.Absent      -> neon.accent.copy(alpha = 0.07f)
    }
    val borderColor = when (item.status) {
        ReadinessStatus.Ok          -> neon.border
        ReadinessStatus.NotSignedIn -> neon.accent.copy(alpha = 0.3f)
        ReadinessStatus.NotInstalled -> neon.red.copy(alpha = 0.3f)
        ReadinessStatus.Absent      -> neon.accent.copy(alpha = 0.3f)
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
            // Status icon.
            val (icon, tint) = when (item.status) {
                ReadinessStatus.Ok           -> Icons.Filled.CheckCircle   to neon.green
                ReadinessStatus.NotSignedIn  -> Icons.Outlined.Warning     to neon.accent
                ReadinessStatus.NotInstalled -> Icons.Filled.Cancel        to neon.red
                ReadinessStatus.Absent       -> Icons.Outlined.Warning     to neon.accent
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
                    Text("not installed", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
                ReadinessStatus.Absent ->
                    Text("missing", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
            }
        }
    }
}
