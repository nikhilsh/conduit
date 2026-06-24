package sh.nikhil.conduit.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.rememberScrollState
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
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.automirrored.filled.HelpOutline
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.pulltorefresh.PullToRefreshBox
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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.launch
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

/**
 * History filter chip (handoff §A.3): All / Running / claude / codex.
 * Mirror of iOS `SessionsScreenModel.Filter`. `RUNNING` keys off the
 * persisted lifecycle (`status == LIVE`); the agent chips match `agent`
 * case-insensitively. Pure so JUnit ([HistoryFilterTest]) can pin each
 * predicate without a live store.
 */
enum class HistoryFilter(val label: String) {
    ALL("All"),
    RUNNING("Running"),
    CLAUDE("claude"),
    CODEX("codex");

    fun matches(row: SavedSession): Boolean = when (this) {
        ALL -> true
        RUNNING -> row.status == SavedSessionStatus.LIVE
        CLAUDE -> row.agent.lowercase() == "claude"
        CODEX -> row.agent.lowercase() == "codex"
    }
}

/**
 * A row's at-a-glance result (handoff §A.3). Mirror of iOS
 * `SessionsScreenModel.Outcome`. The persisted index only carries a
 * [SavedSessionStatus] (live / exited / unknown) — there is NO PR /
 * merged / needs-you signal on [SavedSession], so we never fabricate
 * those. A live row reads RUNNING; everything terminal or unknown reads
 * the honest neutral ENDED. The richer cases stay in the enum so the
 * chip vocabulary matches the design and a future data source can light
 * them up without a re-skin.
 */
enum class SessionOutcome {
    RUNNING,
    PR,
    MERGED,
    NEEDS_YOU,
    ENDED,
    FAILED;

    companion object {
        fun from(row: SavedSession): SessionOutcome = when (row.status) {
            SavedSessionStatus.LIVE -> RUNNING
            SavedSessionStatus.EXITED -> ENDED
            SavedSessionStatus.UNKNOWN -> ENDED
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
    var filter by remember { mutableStateOf(HistoryFilter.ALL) }
    var pendingDelete by remember { mutableStateOf<SavedSession?>(null) }
    var isRefreshing by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    BackHandler { onDismiss() }

    // The de-tombstoned source set drives the empty-state branch: the
    // "no sessions yet" splash shows only when this is empty (never just
    // because a filter/search excluded everything).
    val source = remember(savedSessions, deletedIds) {
        val tomb = deletedIds.toSet()
        savedSessions.filter { it.id !in tomb }
    }

    // Filter chip first, then the search query. Mirror of
    // SessionsScreenModel.from on iOS — case-insensitive substring match
    // against summary, id, agent, and cwd.
    val visible = remember(source, filter, query) {
        val chipped = if (filter == HistoryFilter.ALL) source else source.filter { filter.matches(it) }
        val needle = query.trim().lowercase()
        if (needle.isEmpty()) chipped else chipped.filter { row ->
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

            HistoryFilterBar(selected = filter, onSelect = { filter = it })

            PullToRefreshBox(
                isRefreshing = isRefreshing,
                onRefresh = {
                    scope.launch {
                        isRefreshing = true
                        store.refreshLiveSessions()
                        isRefreshing = false
                    }
                },
                modifier = Modifier.fillMaxSize(),
            ) {
            when {
                source.isEmpty() -> EmptyHistoryState()
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
            } // PullToRefreshBox
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
    val tint = neonAgentColor(row.agent, neon)
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
                .padding(horizontal = 12.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(11.dp),
        ) {
            // Agent-tinted avatar (Conduit mark), mirroring Session Info.
            Box(
                modifier = Modifier
                    .size(38.dp)
                    .background(tint.copy(alpha = if (neon.dark) 0.14f else 0.10f), RoundedCornerShape(10.dp))
                    .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(10.dp)),
                contentAlignment = Alignment.Center,
            ) {
                ConduitMark(size = 21.dp, color = tint)
            }
            Column(
                modifier = Modifier.weight(1f),
                verticalArrangement = Arrangement.spacedBy(3.dp),
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
                        row.agent.lowercase(),
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        color = tint,
                    )
                    val relative = SessionNaming.relativeAgo(row.lastSeen)
                    if (relative.isNotEmpty()) {
                        Text(
                            "·",
                            style = MaterialTheme.typography.labelSmall,
                            color = neon.textFaint,
                        )
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
            OutcomeChip(SessionOutcome.from(row))
        }
    }
}

/**
 * Outcome chip (handoff §A.3). Color + label come from the persisted
 * status via [SessionOutcome]; the richer PR/merged/needs-you cases are
 * honored in the `when` for when a data source lights them up, but
 * [SessionOutcome.from] only emits RUNNING / ENDED today.
 */
@Composable
private fun OutcomeChip(outcome: SessionOutcome) {
    val neon = LocalNeonTheme.current
    // Label + color + leading icon, mirroring the iOS `outcomeChip`
    // mapping (running / PR / merged / needs-you / ended / failed) so the
    // chips read the same across platforms. `ended` is icon-less on both.
    val label: String
    val color: Color
    val icon: ImageVector?
    when (outcome) {
        SessionOutcome.RUNNING -> { label = "running"; color = neon.green; icon = Icons.Default.Bolt }
        SessionOutcome.PR -> { label = "PR"; color = neon.blue; icon = Icons.Default.Link }
        SessionOutcome.MERGED -> { label = "merged"; color = neon.purple; icon = Icons.Default.CheckCircle }
        SessionOutcome.NEEDS_YOU -> { label = "needs you"; color = neon.yellow; icon = Icons.Outlined.Warning }
        SessionOutcome.ENDED -> { label = "ended"; color = neon.textDim; icon = null }
        SessionOutcome.FAILED -> { label = "failed"; color = neon.red; icon = Icons.Default.Cancel }
    }
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
            .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(50))
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        if (icon != null) {
            Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(11.dp))
        }
        Text(
            label,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            color = color,
        )
    }
}

/**
 * Filter chips row (handoff §A.3): All / Running / claude / codex. The
 * active chip fills with its tint (agent chips use the agent hue, the
 * rest the palette accent); the rest are quiet hairline capsules.
 * Horizontally scrollable so they never wrap on a narrow device.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HistoryFilterBar(selected: HistoryFilter, onSelect: (HistoryFilter) -> Unit) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 2.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        HistoryFilter.entries.forEach { chip ->
            val active = chip == selected
            val tint = when (chip) {
                HistoryFilter.CLAUDE -> neonAgentColor("claude", neon)
                HistoryFilter.CODEX -> neonAgentColor("codex", neon)
                else -> neon.accent
            }
            Box(
                modifier = Modifier
                    .clip(RoundedCornerShape(50))
                    .background(if (active) tint else neon.surface)
                    .border(
                        1.dp,
                        if (active) Color.Transparent else neon.border,
                        RoundedCornerShape(50),
                    )
                    .combinedClickable(onClick = { onSelect(chip) })
                    .padding(horizontal = 13.dp, vertical = 6.dp),
            ) {
                Text(
                    chip.label,
                    style = MaterialTheme.typography.labelMedium,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    color = if (active) neon.accentText else neon.textDim,
                )
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
