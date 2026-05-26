package sh.nikhil.swekitty.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.QrCodeScanner
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
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
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.PairingURL
import sh.nikhil.swekitty.SessionStore

/**
 * Compose mirror of `apps/ios/Sources/Views/AddServerSheet.swift`.
 * Four entry-method cards — Scan QR / Discover LAN / SSH / Manual.
 * Replaces the giant pairing form in Settings.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AddServerSheet(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    var showScanner by remember { mutableStateOf(false) }
    var showDiscover by remember { mutableStateOf(false) }
    var showSsh by remember { mutableStateOf(false) }
    var showManual by remember { mutableStateOf(false) }

    val endpoint by store.endpoint.collectAsState()

    val scanner = androidx.activity.compose.rememberLauncherForActivityResult(
        contract = SweKittyScanContract(),
    ) { code ->
        if (!code.isNullOrBlank()) {
            val parsed = PairingURL.parse(code)
            if (parsed != null) {
                val ep = Endpoint(parsed.endpoint, parsed.token)
                store.setEndpoint(ep.url, ep.token)
                store.upsertSavedServer(ep.displayHost, ep, makeDefault = true)
                store.disconnect()
                store.connect()
                onDismiss()
            }
        }
    }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Add server", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            Text(
                "Pick how this device should reach the swe-kitty server. You can switch servers later from Settings.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            EntryCard(
                icon = { Icon(Icons.Filled.QrCodeScanner, null, tint = Color.White) },
                tint = SweKittyTheme.accentStrong(),
                title = "Scan pairing QR",
                subtitle = "Camera-scan the QR from the broker terminal.",
            ) { scanner.launch(Unit) }
            EntryCard(
                icon = { Icon(Icons.Filled.Wifi, null, tint = Color.White) },
                tint = SweKittyTheme.codexAccent(),
                title = "Discover on LAN",
                subtitle = "Find a broker advertising via mDNS on the same Wi-Fi.",
            ) { showDiscover = true }
            EntryCard(
                icon = { Icon(Icons.Filled.Terminal, null, tint = Color.White) },
                tint = SweKittyTheme.claudeAccent(),
                title = "SSH bootstrap",
                subtitle = "Cold-start a broker on a remote box you can SSH to.",
            ) { showSsh = true }
            EntryCard(
                icon = { Icon(Icons.Filled.Link, null, tint = Color.White) },
                tint = SweKittyTheme.warning(),
                title = "Paste URL + token",
                subtitle = "If you already have ws://… + a bearer token.",
            ) { showManual = true }
            Spacer(Modifier.height(8.dp))
        }
    }

    if (showDiscover) {
        DiscoveryScreen(store, onDismiss = {
            showDiscover = false
            if (endpoint.isComplete) onDismiss()
        })
    }
    if (showSsh) {
        SSHLoginSheet(store, onDismiss = {
            showSsh = false
            if (endpoint.isComplete) onDismiss()
        })
    }
    if (showManual) {
        ManualPairSheet(store, onDismiss = {
            showManual = false
            if (endpoint.isComplete) onDismiss()
        })
    }
}

@Composable
private fun EntryCard(
    icon: @Composable () -> Unit,
    tint: Color,
    title: String,
    subtitle: String,
    onTap: () -> Unit,
) {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = tint.copy(alpha = 0.12f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp))
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier.size(42.dp).clip(CircleShape).background(tint),
                contentAlignment = Alignment.Center,
            ) { icon() }
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(title, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(subtitle, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            }
            Icon(Icons.Filled.ChevronRight, null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

/**
 * Plain URL+token manual entry — extracted from the old SettingsScreen.
 * Only the bare-minimum fields; the post-pair agent picker covers
 * "start a session" so no Connect+Start triple here.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ManualPairSheet(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val endpoint by store.endpoint.collectAsState()
    var url by remember { mutableStateOf(endpoint.url) }
    var token by remember { mutableStateOf(endpoint.token) }

    ModalBottomSheet(onDismissRequest = onDismiss, sheetState = sheetState) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Text("Paste URL + token", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
            OutlinedTextField(
                value = url,
                onValueChange = { url = it },
                label = { Text("ws:// URL") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            OutlinedTextField(
                value = token,
                onValueChange = { token = it },
                label = { Text("Bearer token") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth(),
            )
            Button(
                onClick = {
                    val ep = Endpoint(url.trim(), token.trim())
                    if (ep.isComplete) {
                        store.setEndpoint(ep.url, ep.token)
                        store.upsertSavedServer(ep.displayHost, ep, makeDefault = true)
                        store.disconnect()
                        store.connect()
                        onDismiss()
                    }
                },
                enabled = url.isNotBlank() && token.isNotBlank(),
                modifier = Modifier.fillMaxWidth(),
            ) { Text("Save & connect") }
            Spacer(Modifier.height(8.dp))
        }
    }
}
