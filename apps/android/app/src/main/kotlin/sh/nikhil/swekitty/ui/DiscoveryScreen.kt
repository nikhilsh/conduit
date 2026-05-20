package sh.nikhil.swekitty.ui

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.os.Handler
import android.os.Looper
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Wifi
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
 * LAN discovery sheet — mirrors `apps/ios/Sources/Views/DiscoveryView.swift`.
 * Browses `_swe-kitty._tcp.` advertisers via [NsdManager], resolves them
 * to host+port+TXT, and lets the user tap a row to upsert a saved
 * server and dial in.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun DiscoveryScreen(store: SessionStore, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val ctx = LocalContext.current
    val items = remember { mutableStateListOf<DiscoveredServer>() }

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
                val row = DiscoveredServer(
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
            // Surface as empty list — onAppear/empty-state copy explains
        }

        onDispose {
            try { nsd.stopServiceDiscovery(discoveryListener) } catch (_: Throwable) {}
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            Header()
            if (items.isEmpty()) {
                EmptyState()
            } else {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                    items(items, key = { it.id }) { row ->
                        DiscoveredRow(row) {
                            val hostStr = if (row.host.contains(':')) "[${row.host}]" else row.host
                            val endpoint = Endpoint(
                                url = "ws://$hostStr:${row.port}",
                                token = row.token,
                            )
                            store.setEndpoint(endpoint.url, endpoint.token)
                            store.upsertSavedServer(
                                name = row.name,
                                endpoint = endpoint,
                                makeDefault = true,
                            )
                            store.disconnect()
                            store.connect()
                            onDismiss()
                        }
                    }
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun Header() {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.45f),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                "SweKitty on your network",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.SemiBold,
            )
            Text(
                "Browsing for _swe-kitty._tcp advertisers. The harness must be running with --local on the same Wi-Fi.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun EmptyState() {
    Surface(
        shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.32f),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(strokeWidth = 2.dp, modifier = Modifier.size(16.dp))
                Spacer(Modifier.width(10.dp))
                Text(
                    "Looking for harnesses…",
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.SemiBold,
                )
            }
            Text(
                "Nothing yet. If you've just started the harness, give it a few seconds. mDNS doesn't cross subnets — phone and harness must share the LAN.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun DiscoveredRow(row: DiscoveredServer, onTap: () -> Unit) {
    Surface(
        shape = RoundedCornerShape(16.dp),
        color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.55f),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(16.dp))
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
                tint = SweKittyTheme.accentStrong(),
                modifier = Modifier.size(24.dp),
            )
            Spacer(Modifier.width(12.dp))
            Column(verticalArrangement = Arrangement.spacedBy(2.dp), modifier = Modifier.weight(1f)) {
                Text(row.name, style = MaterialTheme.typography.titleSmall, fontWeight = FontWeight.SemiBold)
                Text(
                    "${row.host}:${row.port}",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                if (!row.version.isNullOrBlank()) {
                    Text(
                        "v${row.version}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.outline,
                    )
                }
            }
        }
    }
}

private data class DiscoveredServer(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val token: String,
    val version: String?,
)
