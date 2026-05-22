package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SavedServer

/**
 * Compose mirror of iOS `ServerPillRow` from PR #47 — a horizontally
 * scrollable strip of [ServerPill]s. Saved servers come first (curated,
 * persistent), then discovered (transient mDNS rows). Both groups are
 * keyed on the model's id (`saved:` / `discovered:` prefix), so a
 * saved+discovered pair for the same advertiser can coexist without
 * LazyRow key collisions.
 *
 * Discovery wiring is deferred to a follow-up PR. The caller supplies
 * the discovered list — current callers can pass `emptyList()` until
 * NsdManager is hoisted up out of [DiscoveryScreen].
 */
@Composable
fun ServerPillRow(
    savedServers: List<SavedServer>,
    discoveredEntries: List<DiscoveredEntry>,
    currentEndpoint: Endpoint,
    harness: HarnessState,
    onSelectSaved: (SavedServer) -> Unit,
    onSelectDiscovered: (DiscoveredEntry) -> Unit,
    modifier: Modifier = Modifier,
) {
    val items: List<Pair<ServerPillModel, () -> Unit>> = buildList {
        // Saved first — the curated set should always be reachable
        // without scrolling past a transient mDNS list.
        savedServers.forEach { server ->
            val model = ServerPillModel.fromSaved(server, currentEndpoint, harness)
            add(model to { onSelectSaved(server) })
        }
        // Then discovered. Dedupe against saved by URL: if the user has
        // already saved this advertiser we don't need to show the
        // "discovered" twin.
        val savedUrls = savedServers.map { it.endpoint.url }.toSet()
        discoveredEntries
            .filterNot { it.url in savedUrls }
            .forEach { d ->
                val model = ServerPillModel.fromDiscovered(
                    id = d.id,
                    name = d.name,
                    host = d.host,
                    port = d.port,
                    version = d.version,
                    isActive = currentEndpoint.url == d.url,
                )
                add(model to { onSelectDiscovered(d) })
            }
    }

    LazyRow(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(horizontal = 16.dp),
    ) {
        items(items, key = { it.first.id }) { (model, onTap) ->
            ServerPill(model = model, onTap = onTap)
        }
    }
}

/**
 * Lightweight transport for a discovered LAN server. Lives separately
 * from [ServerPillModel] because the model is intentionally pure
 * (no token, no URL — just display fields), while callers need the
 * full pairing data to actually connect.
 *
 * Source: the NsdManager browser inside [DiscoveryScreen]. A future PR
 * hoists that browser into the store so the Home strip can stream rows
 * in too; until then [discoveredEntries] is wired as `emptyList()` from
 * Home callers.
 */
data class DiscoveredEntry(
    val id: String,
    val name: String,
    val host: String,
    val port: Int,
    val token: String,
    val version: String?,
) {
    /** Convenience: the ws:// URL the pairing would use. */
    val url: String
        get() {
            val hostStr = if (host.contains(':')) "[$host]" else host
            return "ws://$hostStr:$port"
        }
}
