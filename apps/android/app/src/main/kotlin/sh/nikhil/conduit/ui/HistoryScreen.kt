package sh.nikhil.conduit.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.SavedSession
import sh.nikhil.conduit.SavedSessionStatus
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.SessionRecencyGrouping
import sh.nikhil.conduit.SessionStore

/**
 * "Resume an old thread" surface — Android mirror of iOS
 * `apps/ios/Sources/Shared/SessionsScreen.swift`. Pushed from the home
 * top-bar History button. Lists every persisted [SavedSession] (live +
 * exited, cross-server), grouped by recency, with search + swipe-to-
 * delete + a resume tap that opens either the live interactive session
 * or the read-only persisted transcript.
 *
 * The decision between interactive resume vs read-only transcript is
 * the same fail-closed rule as iOS [ResumeDecision]: we only attach
 * interactively when the row is positively confirmed live on the
 * currently-connected broker. Anything else (exited, unknown, stale
 * "live" on a different / not-listed server) falls through to the
 * read-only transcript. The persisted SavedSession.status lags reality,
 * so reattaching on a stale .live caused the "history opens interactive
 * for a dead session" bug iOS already fixed.
 */
sealed class ResumeDecision {
    object ReadOnlyTranscript : ResumeDecision()
    object AttachLive : ResumeDecision()

    companion object {
        fun decide(
            status: SavedSessionStatus,
            connectedToRowServer: Boolean,
            sessionIsListed: Boolean,
            storeSaysReadOnly: Boolean,
        ): ResumeDecision {
            val live = status == SavedSessionStatus.LIVE &&
                connectedToRowServer &&
                sessionIsListed &&
                !storeSaysReadOnly
            return if (live) AttachLive else ReadOnlyTranscript
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    store: SessionStore,
    onDismiss: () -> Unit,
    onOpenTranscript: (SavedSession) -> Unit,
    // Inline tablet section pane (no back chrome) when true.
    embedded: Boolean = false,
) {
    val savedSessions by store.savedSessions.collectAsState()
    val deletedIds by store.deletedIds.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val sessions by store.sessions.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val brokerTitles by store.brokerTitles.collectAsState()

    var query by remember { mutableStateOf("") }
    var pendingDelete by remember { mutableStateOf<SavedSession?>(null) }

    BackHandler { onDismiss() }

    // Filter out tombstoned ids + apply the search query. Mirror of
    // SessionsScreenModel.from on iOS — case-insensitive substring match
    // against summary, id, agent, and cwd.
    val visible = remember(savedSessions, deletedIds, query) {
        val tomb = deletedIds.toSet()
        val filtered = savedSessions.filter { it.id !in tomb }
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) filtered else filtered.filter { row ->
            row.summary.lowercase().contains(needle) ||
                row.id.lowercase().contains(needle) ||
                row.agent.lowercase().contains(needle) ||
                (row.cwd ?: "").lowercase().contains(needle)
        }
    }

    val groups = remember(visible) {
        SessionRecencyGrouping.group(visible) { it.lastSeen }
    }

    // Show the per-row server chip only when the persisted index spans
    // more than one server — otherwise the chip is redundant noise.
    val showServerChip = remember(visible) {
        visible.map { it.serverId }.distinct().size > 1
    }
    val serverNames = remember(savedServers) {
        savedServers.associate { it.id to it.name }
    }

    val neon = LocalNeonTheme.current
    Box(modifier = Modifier.fillMaxSize()) {
        GlassAppBackground()
    Scaffold(
        containerColor = Color.Transparent,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        "Sessions",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.text,
                    )
                },
                navigationIcon = {
                    if (!embedded) {
                        IconButton(onClick = onDismiss) {
                            Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back", tint = neon.accent)
                        }
                    }
                },
                colors = androidx.compose.material3.TopAppBarDefaults.topAppBarColors(
                    containerColor = Color.Transparent,
                ),
            )
        },
    ) { padding ->
        Column(modifier = Modifier.fillMaxSize().padding(padding)) {
            OutlinedTextField(
                value = query,
                onValueChange = { query = it },
                placeholder = { Text("Search by name or summary…", fontFamily = neon.sans, color = neon.textFaint) },
                leadingIcon = {
                    Icon(Icons.Filled.Search, contentDescription = null, tint = neon.textDim)
                },
                trailingIcon = if (query.isNotEmpty()) {
                    {
                        IconButton(onClick = { query = "" }) {
                            Icon(Icons.Filled.Cancel, contentDescription = "Clear", tint = neon.textDim)
                        }
                    }
                } else null,
                singleLine = true,
                colors = androidx.compose.material3.OutlinedTextFieldDefaults.colors(
                    focusedBorderColor = neon.accent,
                    unfocusedBorderColor = neon.border,
                    focusedTextColor = neon.text,
                    unfocusedTextColor = neon.text,
                    cursorColor = neon.accent,
                ),
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 8.dp),
            )

            when {
                savedSessions.isEmpty() -> EmptyHistoryState()
                groups.isEmpty() -> NoMatchesState()
                else -> LazyColumn(
                    modifier = Modifier.fillMaxSize(),
                    contentPadding = PaddingValues(horizontal = 14.dp, vertical = 6.dp),
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    groups.forEach { group ->
                        item(key = "header-${group.bucket.name}") {
                            HistorySectionHeader(
                                title = group.bucket.label,
                                count = group.rows.size,
                            )
                        }
                        items(group.rows, key = { it.compoundId }) { row ->
                            HistoryRow(
                                row = row,
                                title = titleFor(row, displayNames, brokerTitles),
                                serverChip = if (showServerChip) serverNames[row.serverId] ?: row.serverId else null,
                                onTap = {
                                    val server = savedServers.firstOrNull { it.id == row.serverId }
                                    val connectedToRowServer = server?.let { it.endpoint == endpoint } ?: true
                                    val listed = sessions.any { it.id == row.id }
                                    val readOnly = store.isReadOnly(row.id)
                                    val decision = ResumeDecision.decide(
                                        status = row.status,
                                        connectedToRowServer = connectedToRowServer,
                                        sessionIsListed = listed,
                                        storeSaysReadOnly = readOnly,
                                    )
                                    when (decision) {
                                        ResumeDecision.AttachLive -> {
                                            store.attachLiveSession(
                                                sessionID = row.id,
                                                assistant = row.agent,
                                            )
                                            onDismiss()
                                        }
                                        ResumeDecision.ReadOnlyTranscript ->
                                            onOpenTranscript(row)
                                    }
                                },
                                onLongPress = { pendingDelete = row },
                            )
                        }
                    }
                }
            }
        }
    }
    }

    pendingDelete?.let { row ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Delete permanently?") },
            text = {
                Text(
                    "Removes ${titleFor(row, displayNames, brokerTitles)} from History. This can't be undone.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    // History is the ONLY surface where permanent delete lives
                    // (two-tier model). Archiving from the home list keeps the
                    // row here; deletion here tombstones it forever and ends it
                    // on the broker (idempotent for already-exited rows).
                    store.deletePermanently(row.id)
                    pendingDelete = null
                }) {
                    Text("Delete", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

@Composable
private fun HistorySectionHeader(title: String, count: Int) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 4.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            title.uppercase(),
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            color = neon.accent,
        )
        Text(
            "·",
            style = MaterialTheme.typography.labelSmall,
            color = neon.textFaint,
        )
        Text(
            "$count session${if (count == 1) "" else "s"}",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = neon.textDim,
        )
    }
}

@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryRow(
    row: SavedSession,
    title: String,
    serverChip: String?,
    onTap: () -> Unit,
    onLongPress: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val statusColor = when (row.status) {
        SavedSessionStatus.LIVE -> neon.green
        SavedSessionStatus.EXITED -> neon.red.copy(alpha = 0.85f)
        SavedSessionStatus.UNKNOWN -> neon.textFaint
    }
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .combinedClickable(
                onClick = onTap,
                onLongClick = onLongPress,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .background(statusColor, CircleShape),
            )
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                Text(
                    title,
                    style = MaterialTheme.typography.titleSmall,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    Text(
                        row.agent,
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        color = neonAgentColor(row.agent, neon),
                    )
                    Text(
                        "·",
                        style = MaterialTheme.typography.labelSmall,
                        color = neon.textFaint,
                    )
                    val relative = SessionNaming.relativeAgo(row.lastSeen)
                    if (relative.isNotEmpty()) {
                        Text(
                            relative,
                            style = MaterialTheme.typography.labelSmall,
                            fontFamily = neon.mono,
                            color = neon.textFaint,
                        )
                    }
                    if (serverChip != null) {
                        Text(
                            "·",
                            style = MaterialTheme.typography.labelSmall,
                            color = neon.textFaint,
                        )
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Icon(
                                Icons.Filled.Storage,
                                contentDescription = null,
                                modifier = Modifier.size(11.dp),
                                tint = neon.textFaint,
                            )
                            Text(
                                serverChip,
                                style = MaterialTheme.typography.labelSmall,
                                fontFamily = neon.mono,
                                color = neon.textFaint,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyHistoryState() {
    val neon = LocalNeonTheme.current
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 36.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.Filled.History,
            contentDescription = null,
            modifier = Modifier.size(40.dp),
            tint = neon.accent,
        )
        Spacer(Modifier.height(14.dp))
        Text(
            "No sessions yet",
            style = MaterialTheme.typography.titleMedium,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            color = neon.text,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Start one from Home — it'll show up here so you can pick up later.",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = neon.sans,
            color = neon.textDim,
            textAlign = TextAlign.Center,
        )
    }
}

@Composable
private fun NoMatchesState() {
    val neon = LocalNeonTheme.current
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 36.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            Icons.AutoMirrored.Filled.HelpOutline,
            contentDescription = null,
            modifier = Modifier.size(36.dp),
            tint = neon.accent,
        )
        Spacer(Modifier.height(14.dp))
        Text(
            "No matches",
            style = MaterialTheme.typography.titleMedium,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            color = neon.text,
        )
        Spacer(Modifier.height(6.dp))
        Text(
            "Try a shorter query — we match against the session summary, id, agent, and cwd.",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = neon.sans,
            color = neon.textDim,
            textAlign = TextAlign.Center,
        )
    }
}

/**
 * Title resolution for a persisted history row. Mirrors the iOS
 * priority: custom rename → broker-AI title → first-user-message
 * summary → "agent · time" fallback. Never the raw UUID. Hoisted out
 * of the Composable so the math is straightforward to test.
 */
private fun titleFor(
    row: SavedSession,
    displayNames: Map<String, String>,
    brokerTitles: Map<String, String>,
): String {
    displayNames[row.id]
        ?.takeIf { it.isNotBlank() && it != row.id }
        ?.let { return it }
    brokerTitles[row.id]
        ?.trim()
        ?.takeIf { it.isNotBlank() && it != row.id }
        ?.let { return it }
    val summary = row.summary.trim()
    if (summary.isNotEmpty()) return summary
    return SessionNaming.fallbackName(agent = row.agent, startedAt = row.firstSeen)
}
