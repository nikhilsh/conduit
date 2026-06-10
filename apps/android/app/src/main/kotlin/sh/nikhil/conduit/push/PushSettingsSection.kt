package sh.nikhil.conduit.push

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Notifications
import androidx.compose.material.icons.filled.NotificationsOff
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.Endpoint
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.ui.LocalNeonTheme
import sh.nikhil.conduit.ui.SettingsRow
import sh.nikhil.conduit.ui.SettingsSection

/**
 * Push-notifications section for [sh.nikhil.conduit.ui.SettingsScreen].
 *
 * Honest-state rule (per the plan):
 *   - RegisteredUnifiedPush → "via your UnifiedPush distributor (ntfy)" +
 *     "Send test notification" button.
 *   - RegisteredFcm         → "via Conduit relay (FCM)" (stub; never shown
 *     until google-services.json + plugin land).
 *   - NoDistributor         → "no distributor installed — install ntfy"
 *     with link to ntfy.sh/app.
 *   - BrokerDoesNotSupportPush → hidden / "upgrade the broker".
 *   - NotRegistered         → "enable notifications" tap-to-register.
 *   - Registering / TestSending → transient labels.
 *   - Error                 → inline error + retry.
 *
 * [features] is the probe result from [SessionStore.fetchBoxFeatures]; null
 * means the probe hasn't finished yet (show section normally so the user
 * can attempt registration). When the broker explicitly says push = false,
 * show the "upgrade broker" row.
 */
@Composable
fun PushSettingsSection(
    pushStore: PushStore,
    endpoint: Endpoint,
    features: SessionStore.BoxFeatures?,
) {
    val state by pushStore.registrationState.collectAsState()
    val ctx = LocalContext.current
    val neon = LocalNeonTheme.current

    // When we have a confirmed probe that says push is NOT supported, show
    // a single honest row instead of the registration UI.
    if (features != null && !features.push) {
        SettingsSection("Notifications") {
            ListItem(
                leadingContent = {
                    Icon(Icons.Filled.NotificationsOff, contentDescription = null, tint = neon.textFaint)
                },
                headlineContent = { Text("Not available", color = neon.text, fontFamily = neon.sans) },
                supportingContent = {
                    Text(
                        "This box doesn't support push — upgrade the broker",
                        color = neon.textDim,
                        fontFamily = neon.sans,
                        fontSize = 12.sp,
                    )
                },
                colors = ListItemDefaults.colors(containerColor = Color.Transparent),
            )
        }
        return
    }

    SettingsSection("Notifications") {
        when (val s = state) {
            is PushRegistrationState.RegisteredUnifiedPush -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.Notifications, contentDescription = null, tint = neon.green)
                    },
                    headlineContent = {
                        Text("Push enabled", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(
                            "via your UnifiedPush distributor (${s.distributorLabel})",
                            color = neon.textDim,
                            fontFamily = neon.sans,
                            fontSize = 12.sp,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
                HorizontalDivider(color = neon.border)
                SettingsRow(
                    icon = Icons.Filled.Send,
                    title = "Send test notification",
                    subtitle = null,
                    onClick = { pushStore.sendTestNotification(endpoint) },
                )
            }

            is PushRegistrationState.RegisteredFcm -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.Notifications, contentDescription = null, tint = neon.green)
                    },
                    headlineContent = {
                        Text("Push enabled", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(
                            "via Google (FCM)",
                            color = neon.textDim,
                            fontFamily = neon.sans,
                            fontSize = 12.sp,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
                HorizontalDivider(color = neon.border)
                SettingsRow(
                    icon = Icons.Filled.Send,
                    title = "Send test notification",
                    subtitle = null,
                    onClick = { pushStore.sendTestNotification(endpoint) },
                )
            }

            is PushRegistrationState.NoDistributor -> {
                ListItem(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable {
                            val uri = Uri.parse("https://ntfy.sh/app")
                            ctx.startActivity(Intent(Intent.ACTION_VIEW, uri))
                        },
                    leadingContent = {
                        Icon(Icons.Filled.NotificationsOff, contentDescription = null, tint = neon.textFaint)
                    },
                    headlineContent = {
                        Text("No distributor installed", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(
                            "Install ntfy to receive notifications — tap to open ntfy.sh/app",
                            color = neon.textDim,
                            fontFamily = neon.sans,
                            fontSize = 12.sp,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }

            is PushRegistrationState.BrokerDoesNotSupportPush -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.NotificationsOff, contentDescription = null, tint = neon.textFaint)
                    },
                    headlineContent = {
                        Text("Not available", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(
                            "This box doesn't support push — upgrade the broker",
                            color = neon.textDim,
                            fontFamily = neon.sans,
                            fontSize = 12.sp,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }

            is PushRegistrationState.Registering -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.Notifications, contentDescription = null, tint = neon.accent)
                    },
                    headlineContent = {
                        Text("Registering…", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(
                            "Setting up push notifications",
                            color = neon.textDim,
                            fontFamily = neon.sans,
                            fontSize = 12.sp,
                        )
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }

            is PushRegistrationState.TestSending -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.Send, contentDescription = null, tint = neon.accent)
                    },
                    headlineContent = {
                        Text("Sending test…", color = neon.text, fontFamily = neon.sans)
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
            }

            is PushRegistrationState.Error -> {
                ListItem(
                    leadingContent = {
                        Icon(Icons.Filled.NotificationsOff, contentDescription = null, tint = neon.red)
                    },
                    headlineContent = {
                        Text("Push error", color = neon.text, fontFamily = neon.sans)
                    },
                    supportingContent = {
                        Text(s.message, color = neon.textDim, fontFamily = neon.sans, fontSize = 12.sp)
                    },
                    colors = ListItemDefaults.colors(containerColor = Color.Transparent),
                )
                HorizontalDivider(color = neon.border)
                SettingsRow(
                    icon = Icons.Filled.Notifications,
                    title = "Retry registration",
                    subtitle = null,
                    onClick = { pushStore.register(ctx, endpoint) },
                )
            }

            is PushRegistrationState.NotRegistered -> {
                SettingsRow(
                    icon = Icons.Filled.Notifications,
                    title = "Enable push notifications",
                    subtitle = "Get notified when your agent finishes or needs input",
                    onClick = { pushStore.register(ctx, endpoint) },
                )
            }
        }
    }
}
