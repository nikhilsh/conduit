package sh.nikhil.swekitty.ui

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.QrCodeScanner
import androidx.compose.material.icons.outlined.Tune
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.foundation.clickable
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.SessionStore

/**
 * LAN discovery sheet — mirrors `apps/ios/Sources/Views/DiscoveryView.swift`
 * (iOS PR #47). Browses `_swe-kitty._tcp.` advertisers via [NsdManager],
 * resolves them to host+port+TXT, and lets the user tap a row to upsert a
 * saved server and dial in.
 *
 * Layout mirrors iOS:
 *  1. Top — [ServerPillRow] strip of saved + discovered pills.
 *  2. "Saved servers" section (full-width rows for tap-to-select).
 *  3. "Nearby" section — full-width discovered rows or an empty card
 *     with QR + manual-add CTAs.
 *
 * The mDNS browser lives here (not in the store) — hoisting it is
 * deferred to a follow-up PR. For now [ServerPillRow] is fed by the
 * same local list so both sections stay in sync.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiscoveryScreen(
    store: SessionStore,
    onDismiss: () -> Unit,
    onScanQR: () -> Unit = {},
    onManualAdd: () -> Unit = {},
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val items = remember { mutableStateListOf<DiscoveredEntry>() }
    val savedServers by store.savedServers.collectAsState()
    val currentEndpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()

    DisposableEffect(Unit) {
        val nsd = ctx.applicationContext.getSystemService(Context.NSD_SERVICE) as NsdManager
        val main = Handler(Looper.getMainLooper())
        val pending = ConcurrentLinkedQueue<NsdServiceInfo>()
        val resolving = AtomicBoolean(false)

        lateinit var resolveListener: NsdManager.ResolveListener
        fun pumpNext() {
            if (!resolving.compareAndSet(false, true)) return
            val next = pending.poll()
            if (next == null) {
                resolving.set(false)
                return
            }
            try {
                nsd.resolveService(next, resolveListener)
            } catch (_: Throwable) {
                resolving.set(false)
                pumpNext()
            }
        }

        resolveListener = object : NsdManager.ResolveListener {
            override fun onServiceResolved(svc: NsdServiceInfo) {
                val host = svc.host?.hostAddress
                val port = svc.port
                if (host.isNullOrBlank() || port <= 0) {
                    resolving.set(false); pumpNext(); return
                }
                @Suppress("DEPRECATION")
                val attrs: Map<String, ByteArray?> = svc.attributes ?: emptyMap()
                val token = attrs["token"]?.toString(Charsets.UTF_8) ?: ""
                if (token.isBlank()) {
                    resolving.set(false); pumpNext(); return
                }
                val version = attrs["v"]?.toString(Charsets.UTF_8)
                val row = DiscoveredEntry(
                    id = svc.serviceName,
                    name = svc.serviceName,
                    host = host,
                    port = port,
                    token = token,
                    version = version,
                )
                main.post {
                    if (items.none { it.id == row.id }) items.add(row)
                }
                resolving.set(false)
                pumpNext()
            }

            override fun onResolveFailed(svc: NsdServiceInfo, errorCode: Int) {
                resolving.set(false)
                pumpNext()
            }
        }

        val discoveryListener = object : NsdManager.DiscoveryListener {
            override fun onDiscoveryStarted(serviceType: String) {}
            override fun onDiscoveryStopped(serviceType: String) {}
            override fun onStartDiscoveryFailed(serviceType: String, errorCode: Int) {}
            override fun onStopDiscoveryFailed(serviceType: String, errorCode: Int) {}

            override fun onServiceFound(svc: NsdServiceInfo) {
                pending.add(svc)
                pumpNext()
            }

            override fun onServiceLost(svc: NsdServiceInfo) {
                main.post { items.removeAll { it.id == svc.serviceName } }
            }
        }

        try {
            nsd.discoverServices("_swe-kitty._tcp.", NsdManager.PROTOCOL_DNS_SD, discoveryListener)
        } catch (_: Throwable) {
            // Surface as empty list — the "No nearby servers" card explains the situation.
        }

        onDispose {
            try { nsd.stopServiceDiscovery(discoveryListener) } catch (_: Throwable) {}
        }
    }

    // Tap behaviour shared between the pill row and the per-row CTA —
    // upsert + connect + dismiss is the same flow either way.
    fun pairWith(entry: DiscoveredEntry) {
        val endpoint = Endpoint(url = entry.url, token = entry.token)
        store.setEndpoint(endpoint.url, endpoint.token)
        store.upsertSavedServer(
            name = entry.name,
            endpoint = endpoint,
            makeDefault = true,
        )
        store.disconnect()
        store.connect()
        onDismiss()
    }

    val neon = LocalNeonTheme.current
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        LazyColumn(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            item { Header() }

            // Pill strip — saved + discovered in one horizontally
            // scrollable lane, mirroring iOS Home/Discovery parity.
            if (savedServers.isNotEmpty() || items.isNotEmpty()) {
                item {
                    ServerPillRow(
                        savedServers = savedServers,
                        discoveredEntries = items.toList(),
                        currentEndpoint = currentEndpoint,
                        harness = harness,
                        onSelectSaved = { server ->
                            store.selectSavedServer(server.id, autoConnect = true)
                            onDismiss()
                        },
                        onSelectDiscovered = { entry -> pairWith(entry) },
                        onForgetSaved = { server -> store.forgetServer(server.id) },
                    )
                }
            }

            if (savedServers.isNotEmpty()) {
                item { SectionLabel("Saved servers") }
                items(savedServers, key = { it.id }) { server ->
                    SavedServerRow(
                        name = server.name,
                        host = server.endpoint.displayHost,
                        isActive = server.endpoint.url == currentEndpoint.url,
                        onTap = {
                            store.selectSavedServer(server.id, autoConnect = true)
                            onDismiss()
                        },
                    )
                }
            }

            item { SectionLabel("Nearby") }
            if (items.isEmpty()) {
                item { NearbyEmptyState(onScanQR = onScanQR, onManualAdd = onManualAdd) }
            } else {
                items(items, key = { it.id }) { row ->
                    DiscoveredRow(row) { pairWith(row) }
                }
            }

            item { Spacer(Modifier.height(8.dp)) }
        }
    }
}

@Composable
private fun Header() {
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "SweKitty on your network",
                style = MaterialTheme.typography.titleMedium,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
            )
            Text(
                "Browsing for _swe-kitty._tcp advertisers. The broker must be running with --local on the same Wi-Fi.",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = neon.sans,
                color = neon.textDim,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(
        text = text,
        style = MaterialTheme.typography.labelLarge,
        fontFamily = neon.sans,
        fontWeight = FontWeight.SemiBold,
        color = neon.textDim,
        modifier = Modifier.padding(start = 4.dp, top = 4.dp),
    )
}

@Composable
private fun SavedServerRow(
    name: String,
    host: String,
    isActive: Boolean,
    onTap: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = shape,
                fill = if (isActive) neon.accent.copy(alpha = 0.14f) else neon.surface,
                borderColor = if (isActive) neon.accent.copy(alpha = 0.6f) else neon.border,
                glowTint = if (isActive) neon.accent else null,
            )
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                Text(name, style = MaterialTheme.typography.titleSmall, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.text)
                Text(
                    host,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
            }
            if (isActive) {
                Text(
                    "Active",
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.accent,
                )
            }
        }
    }
}

@Composable
private fun NearbyEmptyState(
    onScanQR: () -> Unit,
    onManualAdd: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp), color = neon.accent)
                Spacer(Modifier.width(10.dp))
                Text(
                    "No nearby servers — scan QR or add manually",
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
            }
            Text(
                "mDNS doesn't cross subnets — phone and broker must share the LAN. If you've just started the broker, give it a few seconds.",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = neon.sans,
                color = neon.textDim,
            )
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.fillMaxWidth(),
            ) {
                FilledTonalButton(onClick = onScanQR, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Outlined.QrCodeScanner, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Scan QR")
                }
                OutlinedButton(onClick = onManualAdd, modifier = Modifier.weight(1f)) {
                    Icon(Icons.Outlined.Tune, contentDescription = null, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Add manually")
                }
            }
        }
    }
}

@Composable
private fun DiscoveredRow(row: DiscoveredEntry, onTap: () -> Unit) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.Outlined.Wifi,
                contentDescription = null,
                tint = neon.accent,
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                Text(row.name, style = MaterialTheme.typography.titleSmall, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.text)
                Text(
                    "${row.host}:${row.port}",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                )
                if (!row.version.isNullOrBlank()) {
                    Text(
                        "v${row.version}",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = neon.textFaint,
                    )
                }
            }
        }
    }
}
