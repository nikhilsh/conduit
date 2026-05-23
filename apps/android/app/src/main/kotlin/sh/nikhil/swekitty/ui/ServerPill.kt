package sh.nikhil.swekitty.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.Endpoint
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SavedServer
import androidx.compose.foundation.background as composeBackground

/**
 * Compose mirror of `apps/ios/Sources/Views/ServerPill.swift` (iOS PR #47).
 * A glass-capsule pill row that represents one server — saved or discovered
 * — uniformly across the Home strip and the DiscoveryScreen. The
 * rendering, label formatting, and saved-vs-discovered prefix are lifted
 * into [ServerPillModel] so they're unit-testable without a Compose host
 * (same pattern as `InSessionBottomBarModel` / `ProjectHeaderModel`).
 *
 * Kind drives subtle visuals only:
 *  - `.Saved` — solid status dot, name as the headline, `host:port` caption.
 *  - `.Discovered` — soft "discovered · host:port" caption, optional version tag.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun ServerPill(
    model: ServerPillModel,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
    /**
     * Long-press affordance for saved pills — opens a dropdown with a
     * "Forget" item. `null` (the default) suppresses the menu, which is
     * what discovered rows pass since they aren't persisted.
     * Mirror of iOS PR #128's `onForget` wiring.
     */
    onForget: (() -> Unit)? = null,
) {
    val tint: Color = if (model.isActive) {
        SweKittyTheme.accentStrong().copy(alpha = 0.32f)
    } else {
        SweKittyTheme.surface().copy(alpha = 0.65f)
    }
    val nameColor = if (model.isActive) SweKittyTheme.textPrimary() else SweKittyTheme.textSecondary()

    var menuOpen by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .semantics { contentDescription = model.accessibilityLabel }
            .glassCapsule(interactive = true, tint = tint)
            .combinedClickable(
                onClick = onTap,
                onLongClick = if (onForget != null) {
                    { menuOpen = true }
                } else null,
            )
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Status dot — color comes from the pure model (theme-agnostic enum),
        // resolved here against the runtime palette.
        StatusDot(model.status)
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Text(
                text = model.displayName,
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = FontFamily.Monospace,
                fontWeight = FontWeight.SemiBold,
                color = nameColor,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            model.subtitle?.let { subtitle ->
                Text(
                    text = subtitle,
                    style = MaterialTheme.typography.labelSmall,
                    color = SweKittyTheme.textMuted(),
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
        if (onForget != null) {
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text("Forget") },
                    leadingIcon = {
                        Icon(
                            Icons.Filled.Delete,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error,
                        )
                    },
                    onClick = {
                        menuOpen = false
                        onForget()
                    },
                )
            }
        }
    }
}

@Composable
private fun StatusDot(status: ServerPillModel.Status) {
    val color = when (status) {
        ServerPillModel.Status.Live       -> SweKittyTheme.success()
        ServerPillModel.Status.Connecting -> SweKittyTheme.warning()
        ServerPillModel.Status.Idle       -> SweKittyTheme.textMuted().copy(alpha = 0.4f)
        ServerPillModel.Status.Failed     -> SweKittyTheme.danger()
    }
    androidx.compose.foundation.layout.Box(
        modifier = Modifier
            .size(7.dp)
            .clip(CircleShape)
            .composeBackground(color),
    )
}

/**
 * Pure-data model for [ServerPill]. Lifts the kind enum, status mapping,
 * caption formatting, and accessibility-label prefix out of the view body
 * so the visual contract can be pinned in JUnit-only unit tests. See
 * `ServerPillModelTest` for the wired assertions.
 */
data class ServerPillModel(
    /**
     * Stable identifier:
     *   - saved → `saved:<SavedServer.id>`
     *   - discovered → `discovered:<mDNS service-instance name>`
     * The kind prefix ensures a saved+discovered pair for the same
     * advertiser can coexist on screen with distinct LazyRow keys.
     */
    val id: String,
    val kind: Kind,
    val name: String,
    val host: String,
    val port: Int,
    val status: Status,
    /** True for the pill matching the currently-selected endpoint. */
    val isActive: Boolean,
    /** Optional version string (`txt["v"]`) surfaced only when present. */
    val version: String?,
) {
    /** Where this pill came from. Saved entries are user-curated and
     *  persist in EncryptedSharedPreferences; discovered entries flow in
     *  from the mDNS browser and disappear when the browser pauses. */
    enum class Kind { Saved, Discovered }

    /** Reachability hint. Drives the status dot — Live = green, Connecting
     *  = warning yellow, Idle = muted gray, Failed = danger red. Saved
     *  entries that aren't the active endpoint resolve to [Idle]. */
    enum class Status { Live, Connecting, Idle, Failed }

    /**
     * Caption shown under the monospaced name. `Discovered` entries
     * surface "discovered · host:port" so a glance distinguishes them
     * from saved rows. `Saved` entries just show `host:port` — the
     * surrounding context (the "Saved servers" header) already implies
     * "saved".
     */
    val caption: String
        get() {
            val hostPort = "$host:$port"
            return when (kind) {
                Kind.Saved      -> hostPort
                Kind.Discovered -> "discovered · $hostPort"
            }
        }

    /**
     * User-facing headline for line 1 of the pill. When the saved
     * server has no user-chosen label, `name` is seeded from
     * `endpoint.displayHost` ("host:port") in `SessionStore` — which,
     * combined with [caption] underneath, made the pill render the
     * same string twice (PR #47 polish bug). Collapse to host-only
     * here so line 1 reads `10.0.0.4` and [subtitle] falls away.
     */
    val displayName: String
        get() {
            val hostPort = "$host:$port"
            return if (name.isEmpty() || name == hostPort || name == caption) host else name
        }

    /**
     * Optional second line. `null` when the pill should collapse to a
     * single row because the user never picked a custom name — the
     * view drops the second `Text` when this is `null`. Mirrors iOS.
     */
    val subtitle: String?
        get() {
            val hostPort = "$host:$port"
            return if (name.isEmpty() || name == hostPort || name == caption) null else caption
        }

    /**
     * Compact TalkBack string. Keep this stable — the test pins the
     * "Saved server" / "Nearby server" prefix so a screen-reader
     * regression doesn't slip in with a future caption rewrite.
     */
    val accessibilityLabel: String
        get() {
            val prefix = when (kind) {
                Kind.Saved      -> "Saved server"
                Kind.Discovered -> "Nearby server"
            }
            val statusWord = when (status) {
                Status.Live       -> "live"
                Status.Connecting -> "connecting"
                Status.Idle       -> "idle"
                Status.Failed     -> "failed"
            }
            return "$prefix $name, $host:$port, status $statusWord"
        }

    companion object {
        /**
         * Lift from a [SavedServer] + current store state. The active
         * flag is computed externally so the model stays pure (no
         * SessionStore dependency) — that's what keeps the test path
         * trivial.
         *
         * Identity = endpoint URL only. Mirrors iOS PR #59 fix: the auth
         * token is a per-device secret, so two clients with different
         * tokens against the same broker URL are still pointing at the
         * same server. Comparing the full [Endpoint] (including token)
         * gives false negatives when a re-pair handed out a fresh token.
         */
        fun fromSaved(
            server: SavedServer,
            currentEndpoint: Endpoint,
            harness: HarnessState,
        ): ServerPillModel {
            val isActive = currentEndpoint.url == server.endpoint.url
            val status: Status = if (!isActive) {
                Status.Idle
            } else when (harness) {
                is HarnessState.Live, is HarnessState.Linked        -> Status.Live
                is HarnessState.Connecting, is HarnessState.Reconnecting -> Status.Connecting
                is HarnessState.Failed                              -> Status.Failed
                is HarnessState.Disconnected                        -> Status.Idle
            }
            val (host, port) = splitHostPort(server.endpoint.url)
                ?: (server.endpoint.displayHost to 0)
            return ServerPillModel(
                id = "saved:${server.id}",
                kind = Kind.Saved,
                name = server.name,
                host = host,
                port = port,
                status = status,
                isActive = isActive,
                version = null,
            )
        }

        /** Lift from a discovery row. `isActive` flips true when the user
         *  has connected via that advertiser since the browser started. */
        fun fromDiscovered(
            id: String,
            name: String,
            host: String,
            port: Int,
            version: String?,
            isActive: Boolean,
        ): ServerPillModel = ServerPillModel(
            id = "discovered:$id",
            kind = Kind.Discovered,
            name = name,
            host = host,
            port = port,
            // Discovered rows haven't been paired yet — treat them as idle
            // until the user taps and we transition through .Connecting.
            status = if (isActive) Status.Live else Status.Idle,
            isActive = isActive,
            version = version,
        )

        /**
         * Pull `host` / `port` out of a `ws://host:port` URL. The store
         * already has `displayHost` for the combined form, but the pill
         * caption needs them split so the port doesn't smush against
         * the glyph when the host is long. Returns null for malformed
         * URLs (e.g. missing port). IPv6 literals are accepted via the
         * standard `[::1]:port` form that `java.net.URI` understands.
         */
        fun splitHostPort(url: String): Pair<String, Int>? = runCatching {
            val u = java.net.URI(url.trim())
            val host = u.host ?: return@runCatching null
            val port = u.port
            if (port <= 0) null else host to port
        }.getOrNull()
    }
}
