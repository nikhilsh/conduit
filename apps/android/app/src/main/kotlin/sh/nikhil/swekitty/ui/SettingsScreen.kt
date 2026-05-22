package sh.nikhil.swekitty.ui

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Code
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.outlined.Circle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.AppearanceStore
import sh.nikhil.swekitty.LocalAppearanceStore
import sh.nikhil.swekitty.SessionStore

/**
 * Settings — sectioned IA matching the litter reference: Support /
 * Appearance / Font / Conversation / Servers / Harness / About /
 * Experimental. Adding a server lives in [AddServerSheet], opened via
 * the "Add server" CTA inside the Servers section.
 *
 * Mirrors `apps/ios/Sources/Views/SettingsSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val appearance = LocalAppearanceStore.current
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val fontFamily by appearance.fontFamily.collectAsState()
    val themeMode by appearance.themeMode.collectAsState()
    val collapseTurns by appearance.collapseTurns.collectAsState()
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()

    var showAddServer by remember { mutableStateOf(false) }
    var showAppearance by remember { mutableStateOf(false) }
    var showAgentLogin by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(22.dp),
        ) {
            Text(
                "Settings",
                style = MaterialTheme.typography.titleLarge,
                fontWeight = FontWeight.SemiBold,
            )

            // Support
            SettingsSection("Support") {
                SettingsRow(
                    icon = Icons.Filled.Favorite,
                    title = "Sponsor on GitHub",
                    subtitle = "Help fund continued development",
                    onClick = {
                        ctx.startActivity(
                            Intent(Intent.ACTION_VIEW, Uri.parse("https://github.com/sponsors/nikhilsh"))
                        )
                    },
                )
            }

            // Appearance
            SettingsSection("Appearance") {
                SettingsRow(
                    icon = Icons.Filled.Palette,
                    title = "Theme",
                    subtitle = themeMode.label,
                    onClick = { showAppearance = true },
                )
            }

            // Font (inline)
            SettingsSection("Font") {
                AppearanceStore.FontFamily.values().forEachIndexed { idx, choice ->
                    PickerRow(
                        icon = if (choice == AppearanceStore.FontFamily.Monospaced) Icons.Filled.Code else Icons.Filled.TextFields,
                        title = choice.label,
                        isSelected = fontFamily == choice,
                        onClick = { appearance.setFontFamily(choice) },
                    )
                    if (idx < AppearanceStore.FontFamily.values().lastIndex) HorizontalDivider()
                }
            }

            // Conversation
            SettingsSection("Conversation") {
                ToggleRow(
                    icon = Icons.Filled.UnfoldLess,
                    title = "Collapse Turns",
                    subtitle = "Show only summaries; tap to expand",
                    isOn = collapseTurns,
                    onChange = { appearance.setCollapseTurns(it) },
                )
            }

            // Servers
            SettingsSection("Servers") {
                savedServers.forEachIndexed { idx, server ->
                    Row(
                        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(
                            Icons.Filled.Apps,
                            contentDescription = null,
                            tint = SweKittyTheme.accentStrong(),
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Column(modifier = Modifier.weight(1f)) {
                            Text(
                                server.name,
                                style = MaterialTheme.typography.bodyMedium,
                                fontWeight = FontWeight.SemiBold,
                            )
                            Text(
                                server.endpoint.displayHost,
                                style = MaterialTheme.typography.labelSmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (server.isDefault) {
                            Surface(
                                shape = RoundedCornerShape(50),
                                color = SweKittyTheme.accentStrong().copy(alpha = 0.22f),
                            ) {
                                Text(
                                    "Default",
                                    modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                    style = MaterialTheme.typography.labelSmall,
                                    fontWeight = FontWeight.Bold,
                                )
                            }
                            Spacer(Modifier.width(6.dp))
                        }
                        TextButton(onClick = { store.selectSavedServer(server.id, autoConnect = true) }) {
                            Text("Use")
                        }
                        IconButton(onClick = { store.removeSavedServer(server.id) }) {
                            Icon(Icons.Filled.Delete, contentDescription = "Remove")
                        }
                    }
                    HorizontalDivider()
                }
                SettingsRow(
                    icon = Icons.Filled.AddCircle,
                    title = "Add server",
                    subtitle = "QR · LAN discover · SSH · paste URL+token",
                    onClick = { showAddServer = true },
                )
            }

            // Harness (only when paired)
            if (endpoint.isComplete) {
                SettingsSection("Harness") {
                    Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                        Icon(
                            Icons.Filled.Link,
                            contentDescription = null,
                            tint = SweKittyTheme.accentStrong(),
                            modifier = Modifier.size(20.dp),
                        )
                        Spacer(Modifier.width(12.dp))
                        Text("Link", modifier = Modifier.weight(1f))
                        HarnessBadge(state = harness)
                    }
                    harness.failureReason?.let { reason ->
                        HorizontalDivider()
                        Text(
                            reason,
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.error,
                        )
                    }
                    val needsReconnect = endpoint.isComplete &&
                        (harness is sh.nikhil.swekitty.HarnessState.Disconnected ||
                            harness is sh.nikhil.swekitty.HarnessState.Failed)
                    if (needsReconnect) {
                        HorizontalDivider()
                        SettingsRow(
                            icon = Icons.Filled.Refresh,
                            title = "Reconnect",
                            subtitle = null,
                            onClick = { store.reconnect() },
                        )
                    }
                    HorizontalDivider()
                    SettingsRow(
                        icon = Icons.Filled.Delete,
                        title = "Forget harness",
                        subtitle = endpoint.displayHost,
                        iconTint = MaterialTheme.colorScheme.error,
                        titleColor = MaterialTheme.colorScheme.error,
                        onClick = {
                            store.setEndpoint("", "")
                            store.disconnect()
                        },
                    )
                }
            }

            // Agent accounts — per-user OAuth for Claude / ChatGPT.
            // Stage 0/1 spike per `docs/PLAN-AGENT-OAUTH.md` §F. Mirror
            // of the iOS "Agent accounts" entry that opens
            // `AgentLoginSheet`.
            SettingsSection("Agent accounts") {
                SettingsRow(
                    icon = Icons.Filled.Person,
                    title = "Manage logins",
                    subtitle = "Sign in to ChatGPT / Claude",
                    onClick = { showAgentLogin = true },
                )
            }

            // About
            SettingsSection("About") {
                KeyValueRow(label = "App", value = "SweKitty")
            }

            // Experimental
            SettingsSection("Experimental") {
                ToggleRow(
                    icon = Icons.Filled.Science,
                    title = "Native Terminal (Termux)",
                    subtitle = "Stage 0 — see PLAN-TERMINAL-REWRITE",
                    isOn = experimentalNativeTerminal,
                    onChange = { appearance.setExperimentalNativeTerminal(it) },
                )
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (showAddServer) {
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }
    if (showAppearance) {
        AppearanceSheet(appearance = appearance, onDismiss = { showAppearance = false })
    }
    if (showAgentLogin) {
        AgentLoginSheet(store = store, onDismiss = { showAgentLogin = false })
    }
}

@Composable
internal fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.SemiBold,
            fontFamily = FontFamily.Monospace,
            modifier = Modifier.padding(bottom = 6.dp, start = 4.dp),
        )
        Surface(
            shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                content()
            }
        }
    }
}

@Composable
internal fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    iconTint: Color = SweKittyTheme.accentStrong(),
    titleColor: Color = MaterialTheme.colorScheme.onSurface,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = iconTint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                color = titleColor,
                fontWeight = FontWeight.SemiBold,
            )
            if (!subtitle.isNullOrBlank()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
internal fun ToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    isOn: Boolean,
    onChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = SweKittyTheme.accentStrong(), modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
            if (!subtitle.isNullOrBlank()) {
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        }
        Switch(
            checked = isOn,
            onCheckedChange = onChange,
            colors = SwitchDefaults.colors(
                checkedThumbColor = SweKittyTheme.accentStrong(),
                checkedTrackColor = SweKittyTheme.accentStrong().copy(alpha = 0.35f),
            ),
        )
    }
}

@Composable
internal fun PickerRow(
    icon: ImageVector,
    title: String,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(icon, contentDescription = null, tint = SweKittyTheme.accentStrong(), modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(12.dp))
        Text(
            title,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.weight(1f),
        )
        if (isSelected) {
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = null,
                tint = SweKittyTheme.accentStrong(),
            )
        } else {
            Icon(
                Icons.Outlined.Circle,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun KeyValueRow(label: String, value: String) {
    Row(
        modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(label, style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Spacer(Modifier.weight(1f))
        Text(
            value,
            style = MaterialTheme.typography.bodyMedium,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}
