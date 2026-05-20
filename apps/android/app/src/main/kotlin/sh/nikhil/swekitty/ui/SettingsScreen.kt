package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
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
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.SessionStore

/**
 * Settings — manage existing servers + inspect harness state.
 * Adding a new server (any of QR / mDNS / SSH / manual) lives in
 * [AddServerSheet] now, opened via the "Add server" CTA.
 *
 * Mirrors `apps/ios/Sources/Views/SettingsSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    var showAddServer by remember { mutableStateOf(false) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text("Settings", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)

            if (savedServers.isNotEmpty()) {
                Section("Saved Servers") {
                    savedServers.forEachIndexed { idx, server ->
                        Row(
                            modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f)) {
                                Text(server.name, style = MaterialTheme.typography.bodyMedium)
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
                        if (idx != savedServers.lastIndex) HorizontalDivider()
                    }
                }
            }

            // The "Add server" entry — replaces the long pairing form
            // that used to live here.
            Surface(
                shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
                color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp))
                    .clickable { showAddServer = true },
            ) {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(14.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(
                        Icons.Filled.AddCircle,
                        contentDescription = null,
                        tint = SweKittyTheme.accentStrong(),
                        modifier = Modifier.size(28.dp),
                    )
                    Spacer(Modifier.width(12.dp))
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Add server", style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                        Text(
                            "QR · LAN discover · SSH · paste URL+token",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }

            if (endpoint.isComplete) {
                Section("Paired Harness") {
                    KeyValueRow(label = "Host", value = endpoint.displayHost)
                    HorizontalDivider()
                    KeyValueRow(label = "Token", value = "Stored in EncryptedSharedPreferences")
                    HorizontalDivider()
                    TextButton(
                        onClick = {
                            store.setEndpoint("", "")
                            store.disconnect()
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Forget harness", color = MaterialTheme.colorScheme.error)
                    }
                }
            }

            Section("Harness Status") {
                Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
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
                // Only show manual Reconnect when the link actually needs
                // intervention — surfacing it while Live reads as broken.
                val needsReconnect = endpoint.isComplete &&
                    (harness is sh.nikhil.swekitty.HarnessState.Disconnected ||
                     harness is sh.nikhil.swekitty.HarnessState.Failed)
                if (needsReconnect) {
                    HorizontalDivider()
                    Row(
                        modifier = Modifier
                            .fillMaxWidth()
                            .clickable { store.reconnect() }
                            .padding(vertical = 8.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.Refresh, null)
                        Spacer(Modifier.width(8.dp))
                        Text("Reconnect", modifier = Modifier.weight(1f))
                        Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }

            Section("About") {
                KeyValueRow(label = "App", value = "SweKitty")
            }
            Spacer(Modifier.height(12.dp))
        }
    }

    if (showAddServer) {
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }
}

@Composable
private fun Section(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(modifier = Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            fontWeight = FontWeight.SemiBold,
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
private fun KeyValueRow(label: String, value: String) {
    Row(modifier = Modifier.fillMaxWidth().padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
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
