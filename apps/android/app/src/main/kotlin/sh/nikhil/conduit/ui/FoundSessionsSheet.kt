package sh.nikhil.conduit.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material.icons.outlined.ForkRight
import androidx.compose.material.icons.outlined.Visibility
import androidx.compose.ui.platform.LocalContext
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.SnackbarDuration
import androidx.compose.material3.SnackbarResult
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry

/**
 * 4-state gate for the "Branch a copy" capability.
 *
 * Distinguishes in-flight probe from transient failure vs. confirmed-old-broker
 * so the UI can show a retry path instead of the dead-end "unavailable" copy.
 *
 * States:
 *   Checking -- probe in flight; show spinner + "Checking this box..."
 *   Failed   -- probe returned null (network error, 401, unreachable); show retry
 *   Ready    -- probe returned a parsed features object; sessionFork drives enable/disable
 *               Ready(true)  -> "Branch a copy" enabled
 *               Ready(false) -> broker old; show "needs a newer broker" (no retry)
 */
sealed interface ForkProbeState {
    object Checking : ForkProbeState
    object Failed : ForkProbeState
    data class Ready(val sessionFork: Boolean) : ForkProbeState
}

/**
 * Found Sessions -- discovery sheet for sessions started outside Conduit.
 *
 * Presented as a ModalBottomSheet from BoxHealthScreen when the box
 * advertises session_discovery. Named FoundSessionsSheet (NOT DiscoveryScreen,
 * which is already taken by LAN/mDNS server discovery).
 *
 * Screens covered:
 *  02 -- Discovery sheet (browse, search, filter by recent/folder/all)
 *  03 -- Branch a copy sheet
 *  04 -- View transcript (read-only)
 *  05 -- Row overflow menu
 *  06 -- Resume progress
 *  07 -- Error states (resume-failed / branch-failed / session-vanished)
 *  08 -- Empty and offline states
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FoundSessionsSheet(
    store: SessionStore,
    server: SavedServer,
    forkProbe: ForkProbeState,
    onRetryForkProbe: () -> Unit,
    sessionWatch: Boolean,
    onDismiss: () -> Unit,
    onOpenSession: (sessionId: String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val snackbarHostState = remember { SnackbarHostState() }

    // -- Discovery state --
    var discoveryState by remember { mutableStateOf<FoundDiscoveryState>(FoundDiscoveryState.Scanning) }
    var allSessions by remember { mutableStateOf<List<SessionStore.DiscoveredSession>>(emptyList()) }
    var totalOnDisk by remember { mutableStateOf(0) }
    var query by remember { mutableStateOf("") }
    var filter by remember { mutableStateOf(FoundFilter.RECENT) }

    val hiddenIds = store.hiddenFoundIds(server.id)

    // -- Sheet-level navigation --
    var shownBranch by remember { mutableStateOf<SessionStore.DiscoveredSession?>(null) }
    var shownTranscript by remember { mutableStateOf<SessionStore.DiscoveredSession?>(null) }
    var shownWatch by remember { mutableStateOf<SessionStore.DiscoveredSession?>(null) }
    var resumeState by remember { mutableStateOf<ResumeUiState?>(null) }

    // Fetch discovered sessions on open and when filter/query changes
    LaunchedEffect(server.id) {
        Telemetry.breadcrumb("found_sessions", "sheet open", mapOf("host" to server.endpoint.displayHost))
        discoveryState = FoundDiscoveryState.Scanning
        val page = store.fetchDiscoveredSessions(server.endpoint, q = query)
        if (page == null) {
            discoveryState = FoundDiscoveryState.Offline
        } else {
            allSessions = page.sessions
            totalOnDisk = page.totalOnDisk
            discoveryState = if (page.sessions.isEmpty()) FoundDiscoveryState.Empty else FoundDiscoveryState.Loaded
        }
    }

    // Re-fetch when query changes (debounced)
    LaunchedEffect(query) {
        if (query.isBlank()) return@LaunchedEffect
        delay(300)
        discoveryState = FoundDiscoveryState.Scanning
        val page = store.fetchDiscoveredSessions(server.endpoint, q = query)
        if (page == null) {
            discoveryState = FoundDiscoveryState.Offline
        } else {
            allSessions = page.sessions
            totalOnDisk = page.totalOnDisk
            discoveryState = if (page.sessions.isEmpty()) FoundDiscoveryState.Empty else FoundDiscoveryState.Loaded
        }
    }

    val snapshot = FoundSessionsSnapshot(
        boxId = server.id,
        sessions = allSessions.map { d ->
            FoundSession(
                externalId = d.externalId,
                agent = d.agent,
                title = d.title,
                cwd = d.cwd,
                gitBranch = d.gitBranch,
                turnCount = d.turnCount,
                lastActivityAtMs = d.lastActivityAtMs,
                state = when {
                    d.isRunning -> FoundSessionState.RUNNING
                    else -> FoundSessionState.IDLE
                },
            )
        },
        hiddenIds = hiddenIds,
        query = query,
        filter = filter,
        discoveryState = discoveryState,
        totalOnDisk = totalOnDisk,
    )
    val rows = FoundSessionsModel.rows(snapshot)
    val folderKeys = FoundSessionsModel.folderKeys(rows)

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
        containerColor = neon.surfaceSolid,
        dragHandle = null,
    ) {
        Box(Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
            when {
                shownBranch != null -> {
                    val branch = shownBranch ?: return@Box
                    BranchCopySheet(
                        session = branch,
                        forkProbe = forkProbe,
                        onRetryForkProbe = onRetryForkProbe,
                        neon = neon,
                        store = store,
                        server = server,
                        onBack = { shownBranch = null },
                        onOpenSession = onOpenSession,
                    )
                }
                shownTranscript != null -> {
                    val transcript = shownTranscript ?: return@Box
                    TranscriptViewSheet(
                        session = transcript,
                        forkProbe = forkProbe,
                        onRetryForkProbe = onRetryForkProbe,
                        neon = neon,
                        store = store,
                        server = server,
                        onBack = { shownTranscript = null },
                        onResume = { sess ->
                            shownTranscript = null
                            resumeState = ResumeUiState.Resuming(sess)
                        },
                        onBranch = { sess ->
                            shownTranscript = null
                            shownBranch = sess
                        },
                    )
                }
                resumeState != null -> {
                    val resumeStateVal = resumeState ?: return@Box
                    ResumeProgressSheet(
                        state = resumeStateVal,
                        neon = neon,
                        store = store,
                        server = server,
                        onCancel = { resumeState = null },
                        onDone = { sessionId ->
                            resumeState = null
                            onOpenSession(sessionId)
                        },
                        onError = { reason ->
                            resumeState = ResumeUiState.Failed(
                                session = (resumeState as? ResumeUiState.Resuming)?.session
                                    ?: (resumeState as? ResumeUiState.Failed)?.session,
                                reason = reason,
                            )
                        },
                        onViewTranscript = { sess ->
                            resumeState = null
                            if (sess != null) shownTranscript = sess
                        },
                    )
                }
                shownWatch != null -> {
                    val watchSession = shownWatch ?: return@Box
                    WatchLiveSheet(
                        session = watchSession,
                        forkProbe = forkProbe,
                        onRetryForkProbe = onRetryForkProbe,
                        neon = neon,
                        store = store,
                        server = server,
                        onBack = { shownWatch = null },
                        onBranch = { sess ->
                            shownWatch = null
                            shownBranch = sess
                        },
                    )
                }
                else -> {
                    // Main discovery list
                    DiscoveryListContent(
                        neon = neon,
                        server = server,
                        store = store,
                        snapshot = snapshot,
                        rows = rows,
                        folderKeys = folderKeys,
                        query = query,
                        filter = filter,
                        totalOnDisk = totalOnDisk,
                        snackbarHostState = snackbarHostState,
                        onQueryChange = { query = it },
                        onFilterChange = { filter = it },
                        onResume = { sess ->
                            resumeState = ResumeUiState.Resuming(sess)
                        },
                        onBranch = { sess -> shownBranch = sess },
                        onView = { sess -> shownTranscript = sess },
                        onWatch = { sess -> shownWatch = sess },
                        sessionWatch = sessionWatch,
                        onRefresh = {
                            scope.launch {
                                discoveryState = FoundDiscoveryState.Scanning
                                val page = store.fetchDiscoveredSessions(server.endpoint, q = query)
                                if (page == null) {
                                    discoveryState = FoundDiscoveryState.Offline
                                } else {
                                    allSessions = page.sessions
                                    totalOnDisk = page.totalOnDisk
                                    discoveryState = if (page.sessions.isEmpty()) FoundDiscoveryState.Empty else FoundDiscoveryState.Loaded
                                }
                            }
                        },
                        onHide = { sess ->
                            store.hideFound(server.id, sess.externalId)
                            scope.launch {
                                val result = snackbarHostState.showSnackbar(
                                    message = "Hidden",
                                    actionLabel = "Undo",
                                    withDismissAction = false,
                                    duration = SnackbarDuration.Short,
                                )
                                if (result == SnackbarResult.ActionPerformed) {
                                    store.unhideFound(server.id, sess.externalId)
                                }
                            }
                        },
                        onReconnect = {
                            store.selectSavedServer(server.id, autoConnect = true)
                        },
                    )
                }
            }

            SnackbarHost(
                hostState = snackbarHostState,
                modifier = Modifier
                    .align(Alignment.BottomCenter)
                    .windowInsetsPadding(WindowInsets.navigationBars)
                    .padding(bottom = 8.dp),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Resume UI state (for ResumeProgressSheet)
// ---------------------------------------------------------------------------

sealed class ResumeUiState {
    data class Resuming(val session: SessionStore.DiscoveredSession?) : ResumeUiState()
    data class Failed(
        val session: SessionStore.DiscoveredSession?,
        val reason: String,
    ) : ResumeUiState()
}

// ---------------------------------------------------------------------------
// Screen 02: Main discovery list
// ---------------------------------------------------------------------------

@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
private fun DiscoveryListContent(
    neon: NeonTheme,
    server: SavedServer,
    store: SessionStore,
    snapshot: FoundSessionsSnapshot,
    rows: List<FoundSessionRow>,
    folderKeys: List<String>,
    query: String,
    filter: FoundFilter,
    totalOnDisk: Int,
    snackbarHostState: SnackbarHostState,
    onQueryChange: (String) -> Unit,
    onFilterChange: (FoundFilter) -> Unit,
    onResume: (SessionStore.DiscoveredSession) -> Unit,
    onBranch: (SessionStore.DiscoveredSession) -> Unit,
    onView: (SessionStore.DiscoveredSession) -> Unit,
    onWatch: (SessionStore.DiscoveredSession) -> Unit,
    onHide: (SessionStore.DiscoveredSession) -> Unit,
    sessionWatch: Boolean,
    onRefresh: () -> Unit,
    onReconnect: () -> Unit,
) {
    val lazyState = rememberLazyListState()
    val visibleCount = snapshot.sessions.count { it.externalId !in snapshot.hiddenIds }
    val filterLabels = listOf("Recent", "By folder", "All $totalOnDisk")

    Column(Modifier.fillMaxSize()) {
        // Header
        Column(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 20.dp)
                .padding(top = 20.dp, bottom = 4.dp),
        ) {
            Text(
                "Found on ${server.name}",
                fontFamily = neon.sans,
                fontWeight = FontWeight.Bold,
                fontSize = 20.sp,
                color = neon.text,
            )
            Spacer(Modifier.height(4.dp))
            // Provenance banner
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Icon(
                    Icons.Default.Terminal,
                    contentDescription = null,
                    tint = neon.textFaint,
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    "Started by hand in your terminal -- not in Conduit",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textFaint,
                )
            }
        }

        // Search bar
        OutlinedTextField(
            value = query,
            onValueChange = onQueryChange,
            placeholder = {
                Text(
                    "Search title, repo or branch...",
                    fontFamily = neon.mono,
                    fontSize = 13.sp,
                    color = neon.textFaint,
                )
            },
            singleLine = true,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )

        // Segmented filter: Recent / By folder / All N
        SingleChoiceSegmentedButtonRow(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 4.dp),
        ) {
            FoundFilter.values().forEachIndexed { idx, f ->
                SegmentedButton(
                    selected = filter == f,
                    onClick = { onFilterChange(f) },
                    shape = SegmentedButtonDefaults.itemShape(index = idx, count = FoundFilter.values().size),
                    label = {
                        Text(
                            filterLabels[idx],
                            fontFamily = neon.mono,
                            fontSize = 12.sp,
                        )
                    },
                )
            }
        }

        Spacer(Modifier.height(4.dp))

        // Main list
        when (snapshot.discoveryState) {
            is FoundDiscoveryState.Offline -> {
                OfflineEmptyState(
                    neon = neon,
                    isOffline = true,
                    onAction = onReconnect,
                )
            }
            is FoundDiscoveryState.Empty -> {
                if (query.isNotBlank()) {
                    // Search returned nothing
                    Column(
                        Modifier.fillMaxWidth().padding(32.dp),
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            "No sessions match \"$query\"",
                            fontFamily = neon.sans,
                            fontSize = 14.sp,
                            color = neon.textDim,
                        )
                        OutlinedButton(onClick = { onQueryChange("") }) {
                            Text("Clear", fontFamily = neon.sans)
                        }
                    }
                } else {
                    OfflineEmptyState(neon = neon, isOffline = false, onAction = onRefresh)
                }
            }
            is FoundDiscoveryState.Scanning -> {
                Box(Modifier.fillMaxWidth().padding(32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = neon.accent, modifier = Modifier.size(32.dp))
                }
            }
            is FoundDiscoveryState.Error -> {
                FoundSessionErrorComposable(
                    neon = neon,
                    title = "Could not scan",
                    message = (snapshot.discoveryState as FoundDiscoveryState.Error).reason,
                    primaryLabel = "Rescan",
                    onPrimary = onRefresh,
                    secondaryLabel = null,
                    onSecondary = null,
                )
            }
            is FoundDiscoveryState.Loaded -> {
                if (rows.isEmpty()) {
                    OfflineEmptyState(neon = neon, isOffline = false, onAction = onRefresh)
                } else {
                    LazyColumn(
                        state = lazyState,
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxWidth(),
                        contentPadding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
                        verticalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        when (filter) {
                            FoundFilter.RECENT -> {
                                items(rows) { row ->
                                    val ds = row.session.toDiscoveredSession()
                                    FoundSessionRowItem(
                                        session = row.session,
                                        neon = neon,
                                        sessionWatch = sessionWatch,
                                        onResume = { onResume(ds) },
                                        onBranch = { onBranch(ds) },
                                        onView = { onView(ds) },
                                        onWatch = { onWatch(ds) },
                                        onHide = { onHide(ds) },
                                    )
                                }
                            }
                            FoundFilter.BY_FOLDER, FoundFilter.ALL -> {
                                folderKeys.forEach { folder ->
                                    val folderRows = rows.filter { it.folderKey == folder }
                                    stickyHeader(key = "header_$folder") {
                                        FolderHeader(neon = neon, folder = folder, count = folderRows.size)
                                    }
                                    items(folderRows, key = { it.session.externalId }) { row ->
                                        val ds = row.session.toDiscoveredSession()
                                        FoundSessionRowItem(
                                            session = row.session,
                                            neon = neon,
                                            sessionWatch = sessionWatch,
                                            onResume = { onResume(ds) },
                                            onBranch = { onBranch(ds) },
                                            onView = { onView(ds) },
                                            onWatch = { onWatch(ds) },
                                            onHide = { onHide(ds) },
                                        )
                                    }
                                }
                            }
                        }
                        item {
                            // Honest volume footer
                            val recentN = visibleCount.coerceAtMost(8)
                            Text(
                                "$recentN recent · $totalOnDisk on disk -- search to find older",
                                fontFamily = neon.mono,
                                fontSize = 10.sp,
                                color = neon.textFaint,
                                modifier = Modifier.padding(vertical = 8.dp),
                            )
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Helper: map FoundSession back to DiscoveredSession for store calls
// ---------------------------------------------------------------------------

private fun FoundSession.toDiscoveredSession() = SessionStore.DiscoveredSession(
    agent = agent,
    externalId = externalId,
    title = title,
    cwd = cwd,
    gitBranch = gitBranch,
    turnCount = turnCount,
    lastActivityAtMs = lastActivityAtMs,
    isRunning = state == FoundSessionState.RUNNING,
)

// ---------------------------------------------------------------------------
// Screen 08: Empty & offline
// ---------------------------------------------------------------------------

@Composable
private fun OfflineEmptyState(
    neon: NeonTheme,
    isOffline: Boolean,
    onAction: () -> Unit,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Icon(
            if (isOffline) Icons.Default.ErrorOutline else Icons.Default.Terminal,
            contentDescription = null,
            tint = neon.textFaint,
            modifier = Modifier.size(40.dp),
        )
        Text(
            if (isOffline) "Offline -- can't scan for sessions" else "No sessions found",
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 15.sp,
            color = neon.text,
        )
        Text(
            if (isOffline)
                "Session discovery needs a live connection to the box."
            else
                "Claude & Codex sessions started by hand in your terminal will appear here.",
            fontFamily = neon.mono,
            fontSize = 12.sp,
            color = neon.textFaint,
        )
        FilledTonalButton(onClick = onAction) {
            Icon(
                if (isOffline) Icons.Default.Refresh else Icons.Default.Refresh,
                contentDescription = null,
                modifier = Modifier.size(16.dp),
            )
            Spacer(Modifier.size(6.dp))
            Text(
                if (isOffline) "Reconnect" else "Scan again",
                fontFamily = neon.sans,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Screen 07: Parametrised error composable
// ---------------------------------------------------------------------------

@Composable
fun FoundSessionErrorComposable(
    neon: NeonTheme,
    title: String,
    message: String,
    primaryLabel: String,
    onPrimary: () -> Unit,
    secondaryLabel: String?,
    onSecondary: (() -> Unit)?,
    details: String? = null,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .padding(32.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(
            Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(16.dp))
                .background(neon.red.copy(alpha = 0.13f)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = neon.red, modifier = Modifier.size(36.dp))
        }
        Text(
            title,
            fontFamily = neon.sans,
            fontWeight = FontWeight.Bold,
            fontSize = 17.sp,
            color = neon.text,
        )
        Text(
            message,
            fontFamily = neon.mono,
            fontSize = 12.sp,
            color = neon.textDim,
        )
        if (!details.isNullOrBlank()) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(8.dp), fill = neon.surface, borderColor = neon.border)
                    .padding(10.dp),
            ) {
                Text(details, fontFamily = neon.mono, fontSize = 10.sp, color = neon.textFaint, maxLines = 3, overflow = TextOverflow.Ellipsis)
            }
        }
        FilledTonalButton(
            onClick = onPrimary,
            modifier = Modifier.fillMaxWidth(),
        ) {
            Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
            Spacer(Modifier.size(6.dp))
            Text(primaryLabel, fontFamily = neon.sans)
        }
        if (secondaryLabel != null && onSecondary != null) {
            OutlinedButton(
                onClick = onSecondary,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(secondaryLabel, fontFamily = neon.sans)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Folder sticky header
// ---------------------------------------------------------------------------

@Composable
private fun FolderHeader(neon: NeonTheme, folder: String, count: Int) {
    Row(
        Modifier
            .fillMaxWidth()
            .background(neon.surfaceSolid)
            .padding(horizontal = 4.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(Icons.Default.Terminal, contentDescription = null, tint = neon.textFaint, modifier = Modifier.size(12.dp))
        Text(
            folder,
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 11.sp,
            color = neon.textDim,
            modifier = Modifier.weight(1f),
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            count.toString(),
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
        )
    }
}

// ---------------------------------------------------------------------------
// Row (screen 02): one discovered session
// ---------------------------------------------------------------------------

@Composable
private fun FoundSessionRowItem(
    session: FoundSession,
    neon: NeonTheme,
    sessionWatch: Boolean,
    onResume: () -> Unit,
    onBranch: () -> Unit,
    onView: () -> Unit,
    onWatch: () -> Unit,
    onHide: () -> Unit,
) {
    val tint = neonAgentColor(session.agent, neon)
    val stateColor = when (session.state) {
        FoundSessionState.RUNNING -> neon.yellow
        FoundSessionState.IDLE -> neon.textFaint
        FoundSessionState.ADOPTED -> neon.accent
    }
    val stateLabel = when (session.state) {
        FoundSessionState.RUNNING -> "Running"
        FoundSessionState.IDLE -> "Idle"
        FoundSessionState.ADOPTED -> "In Conduit"
    }
    var overflowOpen by remember { mutableStateOf(false) }
    val clipboardManager = LocalClipboardManager.current
    val dimmed = session.state == FoundSessionState.ADOPTED
    val alpha = if (dimmed) 0.5f else 1f

    Column(
        Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(13.dp),
                fill = tint.copy(alpha = if (neon.dark) 0.05f else 0.03f),
                borderColor = tint.copy(alpha = 0.18f),
            )
            .padding(12.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        // Row header: agent avatar + title + state chip + overflow
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            // Agent avatar
            Box(
                Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(tint.copy(alpha = 0.15f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    session.agent.take(1).uppercase(),
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                    color = tint.copy(alpha = alpha),
                )
            }
            // Title
            Text(
                session.title,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                color = neon.text.copy(alpha = alpha),
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier.weight(1f),
            )
            // State chip
            StateChip(label = stateLabel, color = stateColor, isRunning = session.state == FoundSessionState.RUNNING)

            // Overflow menu
            Box {
                IconButton(onClick = { overflowOpen = true }, modifier = Modifier.size(24.dp)) {
                    Icon(Icons.Default.MoreVert, contentDescription = "More", tint = neon.textFaint, modifier = Modifier.size(16.dp))
                }
                DropdownMenu(
                    expanded = overflowOpen,
                    onDismissRequest = { overflowOpen = false },
                ) {
                    DropdownMenuItem(
                        text = { Text("View transcript", fontFamily = neon.sans, fontSize = 13.sp) },
                        onClick = { overflowOpen = false; onView() },
                    )
                    if (session.state == FoundSessionState.RUNNING && sessionWatch) {
                        DropdownMenuItem(
                            text = { Text("Watch live", fontFamily = neon.sans, fontSize = 13.sp) },
                            leadingIcon = {
                                Icon(
                                    Icons.Outlined.Visibility,
                                    contentDescription = null,
                                    tint = neon.yellow,
                                    modifier = Modifier.size(16.dp),
                                )
                            },
                            onClick = { overflowOpen = false; onWatch() },
                        )
                    }
                    DropdownMenuItem(
                        text = { Text("Copy resume command", fontFamily = neon.sans, fontSize = 13.sp) },
                        onClick = {
                            overflowOpen = false
                            val cmd = when (session.agent.lowercase()) {
                                "claude" -> "claude --resume ${session.externalId}"
                                else -> "conduit resume ${session.externalId}"
                            }
                            clipboardManager.setText(AnnotatedString(cmd))
                        },
                    )
                    DropdownMenuItem(
                        text = { Text("Hide", fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim) },
                        leadingIcon = { Icon(Icons.Default.VisibilityOff, contentDescription = null, tint = neon.textDim, modifier = Modifier.size(16.dp)) },
                        onClick = { overflowOpen = false; onHide() },
                    )
                }
            }
        }

        // Meta line: branch * time * turns
        val relativeTime = relativeTime(session.lastActivityAtMs)
        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(session.gitBranch, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint.copy(alpha = alpha), maxLines = 1, overflow = TextOverflow.Ellipsis)
            Text("· $relativeTime · ${session.turnCount} turns", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint.copy(alpha = alpha))
        }

        // Action buttons
        if (!dimmed) {
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                when (session.state) {
                    FoundSessionState.IDLE -> {
                        FilledTonalButton(
                            onClick = onResume,
                            modifier = Modifier.weight(1f),
                        ) {
                            Text("Resume", fontFamily = neon.sans, fontSize = 12.sp)
                        }
                        OutlinedButton(onClick = onView, modifier = Modifier.weight(1f)) {
                            Text("View", fontFamily = neon.sans, fontSize = 12.sp)
                        }
                    }
                    FoundSessionState.RUNNING -> {
                        FilledTonalButton(
                            onClick = onBranch,
                            modifier = Modifier.weight(1f),
                        ) {
                            Icon(Icons.Outlined.ForkRight, contentDescription = null, modifier = Modifier.size(14.dp))
                            Spacer(Modifier.size(4.dp))
                            Text("Branch a copy", fontFamily = neon.sans, fontSize = 12.sp)
                        }
                        if (sessionWatch) {
                            OutlinedButton(onClick = onWatch, modifier = Modifier.weight(1f)) {
                                Icon(
                                    Icons.Outlined.Visibility,
                                    contentDescription = null,
                                    tint = neon.yellow,
                                    modifier = Modifier.size(13.dp),
                                )
                                Spacer(Modifier.size(4.dp))
                                Text("Watch live", fontFamily = neon.sans, fontSize = 12.sp)
                            }
                        } else {
                            OutlinedButton(onClick = onView, modifier = Modifier.weight(1f)) {
                                Text("View", fontFamily = neon.sans, fontSize = 12.sp)
                            }
                        }
                    }
                    FoundSessionState.ADOPTED -> {
                        OutlinedButton(onClick = onView, modifier = Modifier.fillMaxWidth()) {
                            Text("Open in Conduit", fontFamily = neon.sans, fontSize = 12.sp)
                        }
                    }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Screen 03: Branch a copy sheet
// ---------------------------------------------------------------------------

@Composable
private fun BranchCopySheet(
    session: SessionStore.DiscoveredSession,
    forkProbe: ForkProbeState,
    onRetryForkProbe: () -> Unit,
    neon: NeonTheme,
    store: SessionStore,
    server: SavedServer,
    onBack: () -> Unit,
    onOpenSession: (String) -> Unit,
) {
    val scope = rememberCoroutineScope()
    var branching by remember { mutableStateOf(false) }
    var errorMsg by remember { mutableStateOf<String?>(null) }

    Column(
        Modifier
            .fillMaxSize()
            .padding(20.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // Back nav
        Row(
            Modifier.fillMaxWidth(),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.Close, contentDescription = "Back", tint = neon.textFaint)
            }
            Text(
                "Branch a copy",
                fontFamily = neon.sans,
                fontWeight = FontWeight.Bold,
                fontSize = 18.sp,
                color = neon.text,
            )
        }

        // Session header
        Row(
            Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(13.dp), fill = neon.surface, borderColor = neon.border)
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            val tint = neonAgentColor(session.agent, neon)
            Box(
                Modifier.size(34.dp).clip(RoundedCornerShape(9.dp)).background(tint.copy(alpha = 0.14f)),
                contentAlignment = Alignment.Center,
            ) {
                Text(session.agent.take(1).uppercase(), fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 14.sp, color = tint)
            }
            Column(Modifier.weight(1f)) {
                Text(session.title, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 14.sp, color = neon.text, maxLines = 1, overflow = TextOverflow.Ellipsis)
                Text("${session.cwd} · ${session.gitBranch} · ${session.turnCount} turns", fontFamily = neon.mono, fontSize = 10.sp, color = neon.textFaint)
            }
            StateChip(label = "Running", color = neon.yellow, isRunning = true)
        }

        // Amber honesty card
        Row(
            Modifier
                .fillMaxWidth()
                .neonCardSurface(
                    neon = neon,
                    shape = RoundedCornerShape(12.dp),
                    fill = neon.yellow.copy(alpha = 0.07f),
                    borderColor = neon.yellow.copy(alpha = 0.28f),
                )
                .padding(12.dp),
            horizontalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Icon(Icons.Default.ErrorOutline, contentDescription = null, tint = neon.yellow, modifier = Modifier.size(18.dp))
            Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
                Text(
                    "This session is live in your terminal",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 13.sp,
                    color = neon.yellow,
                )
                Text(
                    "Conduit can't take over a running session. It branches a copy from the latest saved point -- your terminal session keeps running, untouched.",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                )
            }
        }

        // "The copy starts with" list
        Column(
            Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface, borderColor = neon.border)
                .padding(12.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            Text("The copy starts with", fontFamily = neon.mono, fontSize = 11.sp, color = neon.accent, fontWeight = FontWeight.SemiBold)
            CopyStartsWithRow(neon, "Full transcript", "${session.turnCount} turns restored")
            CopyStartsWithRow(neon, "Working directory", "new worktree")
            CopyStartsWithRow(neon, "Model & settings", session.agent)
        }

        Spacer(Modifier.weight(1f))

        // Error (if any)
        val currentError = errorMsg
        if (currentError != null) {
            FoundSessionErrorComposable(
                neon = neon,
                title = "Branch failed",
                message = currentError,
                primaryLabel = "Try again",
                onPrimary = { errorMsg = null },
                secondaryLabel = null,
                onSecondary = null,
            )
        }

        // CTA -- 4-state gate: Checking / Failed / Ready(false) / Ready(true)
        when (forkProbe) {
            is ForkProbeState.Checking -> {
                FilledTonalButton(
                    onClick = {},
                    enabled = false,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                    Spacer(Modifier.size(8.dp))
                    Text("Checking this box...", fontFamily = neon.sans, fontSize = 13.sp)
                }
            }
            is ForkProbeState.Failed -> {
                FilledTonalButton(
                    onClick = {
                        Telemetry.breadcrumb("found_sessions", "fork probe retry", mapOf("surface" to "branch_sheet"))
                        onRetryForkProbe()
                    },
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.size(6.dp))
                    Text("Couldn't check this box -- Retry", fontFamily = neon.sans, fontSize = 13.sp)
                }
            }
            is ForkProbeState.Ready -> {
                val forkEnabled = forkProbe.sessionFork
                FilledTonalButton(
                    onClick = {
                        if (!forkEnabled) return@FilledTonalButton
                        scope.launch {
                            branching = true
                            Telemetry.breadcrumb("found_sessions", "branch attempt", mapOf("external_id" to session.externalId))
                            val sessionId = store.adoptFound(
                                endpoint = server.endpoint,
                                agent = session.agent,
                                externalId = session.externalId,
                                cwd = session.cwd,
                                mode = "fork",
                            )
                            branching = false
                            if (sessionId != null) {
                                // Stamp box ownership then join over WS so the resumed
                                // agent streams in and chat send works (mirrors iOS fix).
                                Telemetry.breadcrumb("found_sessions", "adopt attach",
                                    mapOf("session_id" to sessionId, "mode" to "fork", "box" to server.id))
                                store.stampSessionBox(sessionId, server.id)
                                store.attachLiveSession(sessionId, session.agent)
                                onOpenSession(sessionId)
                            } else {
                                errorMsg = "The box dropped while forking. Your terminal session keeps running, untouched."
                            }
                        }
                    },
                    enabled = forkEnabled && !branching,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    if (branching) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.size(8.dp))
                        Text("Forking ${session.turnCount} turns into a Conduit copy...", fontFamily = neon.sans, fontSize = 13.sp)
                    } else if (!forkEnabled) {
                        Icon(Icons.Outlined.ForkRight, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Branching needs a newer broker on this box. Update it to enable.", fontFamily = neon.sans, fontSize = 13.sp)
                    } else {
                        Icon(Icons.Outlined.ForkRight, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Branch a copy & open", fontFamily = neon.sans, fontSize = 13.sp)
                    }
                }
            }
        }

        Text(
            "Nothing on your box is changed or deleted",
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
            modifier = Modifier.align(Alignment.CenterHorizontally),
        )
    }
}

@Composable
private fun CopyStartsWithRow(neon: NeonTheme, label: String, value: String) {
    Row(
        Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(Icons.Default.Check, contentDescription = null, tint = neon.green, modifier = Modifier.size(14.dp))
        Text(label, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 13.sp, color = neon.text, modifier = Modifier.weight(1f))
        Text(value, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
    }
}

// ---------------------------------------------------------------------------
// Screen 04: View transcript (read-only)
// ---------------------------------------------------------------------------

@Composable
private fun TranscriptViewSheet(
    session: SessionStore.DiscoveredSession,
    forkProbe: ForkProbeState,
    onRetryForkProbe: () -> Unit,
    neon: NeonTheme,
    store: SessionStore,
    server: SavedServer,
    onBack: () -> Unit,
    onResume: (SessionStore.DiscoveredSession) -> Unit,
    onBranch: (SessionStore.DiscoveredSession) -> Unit,
) {
    var items by remember { mutableStateOf<List<SessionStore.FoundTranscriptItem>?>(null) }
    var loadError by remember { mutableStateOf(false) }
    val lazyListState = rememberLazyListState()

    LaunchedEffect(session.externalId) {
        Telemetry.breadcrumb("found_sessions", "transcript view open", mapOf("id" to session.externalId))
        val result = store.fetchDiscoveredTranscript(server.endpoint, session.agent, session.externalId)
        if (result == null) {
            loadError = true
        } else {
            items = result
        }
    }

    // Anchor to the latest message once the transcript loads -- otherwise the
    // list opens at the top and the user watches it churn down to the newest.
    LaunchedEffect(items) {
        val loaded = items
        if (!loaded.isNullOrEmpty()) {
            lazyListState.scrollToItem(loaded.size - 1)
        }
    }

    Column(Modifier.fillMaxSize()) {
        // Header with read-only chip
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.Close, contentDescription = "Back", tint = neon.textFaint)
            }
            Column(Modifier.weight(1f)) {
                Text(
                    session.title,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // Persistent read-only chip
            Box(
                Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(neon.textFaint.copy(alpha = 0.1f))
                    .border(1.dp, neon.border, RoundedCornerShape(99.dp))
                    .padding(horizontal = 9.dp, vertical = 4.dp),
            ) {
                Text(
                    "Read-only · not resumed",
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
            }
        }

        // Transcript content
        when {
            loadError -> {
                FoundSessionErrorComposable(
                    neon = neon,
                    title = "Could not load transcript",
                    message = "The box dropped or the file was unreadable.",
                    primaryLabel = "Go back",
                    onPrimary = onBack,
                    secondaryLabel = null,
                    onSecondary = null,
                )
            }
            items == null -> {
                Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = neon.accent, modifier = Modifier.size(32.dp))
                }
            }
            else -> {
                val transcriptItems = items ?: emptyList()
                LazyColumn(
                    state = lazyListState,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(transcriptItems) { item ->
                        TranscriptItemRow(neon = neon, item = item)
                    }
                    if (transcriptItems.isEmpty()) {
                        item {
                            Text(
                                "No messages in this transcript.",
                                fontFamily = neon.mono,
                                fontSize = 12.sp,
                                color = neon.textFaint,
                                modifier = Modifier.padding(16.dp),
                            )
                        }
                    }
                }
            }
        }

        // Pinned bottom CTA
        Column(
            Modifier
                .fillMaxWidth()
                .background(neon.surfaceSolid)
                .padding(16.dp)
                .windowInsetsPadding(WindowInsets.navigationBars),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            when {
                session.isRunning -> {
                    when (forkProbe) {
                        is ForkProbeState.Checking -> {
                            FilledTonalButton(
                                onClick = {},
                                enabled = false,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                                Spacer(Modifier.size(6.dp))
                                Text("Checking this box...", fontFamily = neon.sans)
                            }
                        }
                        is ForkProbeState.Failed -> {
                            FilledTonalButton(
                                onClick = {
                                    Telemetry.breadcrumb("found_sessions", "fork probe retry", mapOf("surface" to "transcript_sheet"))
                                    onRetryForkProbe()
                                },
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.size(6.dp))
                                Text("Couldn't check this box -- Retry", fontFamily = neon.sans)
                            }
                        }
                        is ForkProbeState.Ready -> {
                            FilledTonalButton(
                                onClick = { onBranch(session) },
                                enabled = forkProbe.sessionFork,
                                modifier = Modifier.fillMaxWidth(),
                            ) {
                                Icon(Icons.Outlined.ForkRight, contentDescription = null, modifier = Modifier.size(16.dp))
                                Spacer(Modifier.size(6.dp))
                                Text(
                                    if (forkProbe.sessionFork) "Branch a copy"
                                    else "Branching needs a newer broker on this box. Update it to enable.",
                                    fontFamily = neon.sans,
                                )
                            }
                        }
                    }
                }
                else -> {
                    FilledTonalButton(
                        onClick = { onResume(session) },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Resume in Conduit with full context", fontFamily = neon.sans)
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptItemRow(neon: NeonTheme, item: SessionStore.FoundTranscriptItem) {
    val isUser = item.role == "user"
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = if (isUser) Arrangement.End else Arrangement.Start,
    ) {
        Column(
            Modifier
                .fillMaxWidth(0.88f)
                .neonCardSurface(
                    neon = neon,
                    shape = RoundedCornerShape(
                        topStart = if (isUser) 12.dp else 4.dp,
                        topEnd = if (isUser) 4.dp else 12.dp,
                        bottomStart = 12.dp,
                        bottomEnd = 12.dp,
                    ),
                    fill = if (isUser) neon.accent.copy(alpha = 0.08f) else neon.surface,
                    borderColor = if (isUser) neon.accent.copy(alpha = 0.18f) else neon.border,
                )
                .padding(10.dp),
        ) {
            Text(
                item.content,
                fontFamily = neon.mono,
                fontSize = 12.sp,
                color = neon.text,
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Screen 06: Resume progress + screen 07 error (within same composable)
// ---------------------------------------------------------------------------

@Composable
private fun ResumeProgressSheet(
    state: ResumeUiState,
    neon: NeonTheme,
    store: SessionStore,
    server: SavedServer,
    onCancel: () -> Unit,
    onDone: (String) -> Unit,
    onError: (String) -> Unit,
    onViewTranscript: (SessionStore.DiscoveredSession?) -> Unit,
) {
    when (state) {
        is ResumeUiState.Resuming -> {
            val session = state.session
            var progress by remember { mutableStateOf(0f) }
            var currentStep by remember { mutableStateOf(0) }
            val steps = listOf(
                "Reading saved transcript",
                "Re-ingesting ${session?.turnCount ?: "?"} turns of context",
                "Restoring working tree · ${session?.gitBranch ?: ""}",
                "Handing off to ${session?.agent ?: "agent"}",
            )
            val scope = rememberCoroutineScope()

            LaunchedEffect(session) {
                if (session == null) {
                    onError("No session selected.")
                    return@LaunchedEffect
                }
                Telemetry.breadcrumb("found_sessions", "resume start", mapOf("external_id" to session.externalId))
                // Kick off adopt with mode=resume
                val sessionId = store.adoptFound(
                    endpoint = server.endpoint,
                    agent = session.agent,
                    externalId = session.externalId,
                    cwd = session.cwd,
                    mode = "resume",
                )
                // Simulate stepped progress while adopt call is in flight
                // (no separate broker events; drive off adopt + connect milestones)
                if (sessionId != null) {
                    currentStep = steps.size
                    progress = 1f
                    Telemetry.breadcrumb("found_sessions", "resume done", mapOf("session_id" to sessionId))
                    // Stamp box ownership then join over WS so the resumed
                    // agent streams in and chat send works (mirrors iOS fix).
                    Telemetry.breadcrumb("found_sessions", "adopt attach",
                        mapOf("session_id" to sessionId, "mode" to "resume", "box" to server.id))
                    store.stampSessionBox(sessionId, server.id)
                    store.attachLiveSession(sessionId, session.agent)
                    onDone(sessionId)
                } else {
                    Telemetry.breadcrumb("found_sessions", "resume failed", mapOf("external_id" to session.externalId))
                    onError("The box dropped while re-ingesting the transcript. Your session on disk is untouched -- try again.")
                }
            }

            // Simulate step advancement for UX while waiting for adopt response
            LaunchedEffect(Unit) {
                steps.indices.forEach { idx ->
                    delay(600L)
                    if (idx < steps.size) {
                        currentStep = idx
                        progress = (idx + 1).toFloat() / steps.size
                    }
                }
            }

            Column(
                Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    "Resuming session",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    fontSize = 18.sp,
                    color = neon.text,
                )
                session?.let { s ->
                    Text(
                        s.title,
                        fontFamily = neon.mono,
                        fontSize = 12.sp,
                        color = neon.textDim,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }

                // Progress ring with %
                Box(Modifier.size(96.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(
                        progress = progress,
                        modifier = Modifier.size(96.dp),
                        color = neon.accent,
                        strokeWidth = 7.dp,
                    )
                    Text(
                        "${(progress * 100).toInt()}%",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 16.sp,
                        color = neon.text,
                    )
                }

                // Checklist
                Column(
                    Modifier.fillMaxWidth().neonCardSurface(neon = neon, shape = RoundedCornerShape(13.dp), fill = neon.surface, borderColor = neon.border).padding(14.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    steps.forEachIndexed { idx, step ->
                        val done = idx <= currentStep
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            if (done) {
                                Icon(Icons.Default.Check, contentDescription = null, tint = neon.green, modifier = Modifier.size(14.dp))
                            } else {
                                Box(Modifier.size(14.dp).clip(RoundedCornerShape(99.dp)).background(neon.border))
                            }
                            Text(step, fontFamily = neon.mono, fontSize = 12.sp, color = if (done) neon.text else neon.textFaint)
                        }
                    }
                }

                Spacer(Modifier.weight(1f))

                OutlinedButton(onClick = onCancel, modifier = Modifier.fillMaxWidth()) {
                    Text("Cancel", fontFamily = neon.sans)
                }
            }
        }

        is ResumeUiState.Failed -> {
            val session = state.session
            Column(
                Modifier.fillMaxSize().padding(24.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                IconButton(onClick = { onViewTranscript(null) }) {
                    Icon(Icons.Default.Close, contentDescription = "Back", tint = neon.textFaint)
                }
                FoundSessionErrorComposable(
                    neon = neon,
                    title = "Couldn't restore the session",
                    message = state.reason,
                    primaryLabel = "Retry resume",
                    onPrimary = {
                        if (session != null) {
                            onViewTranscript(session) // goes back to transcript which has Resume CTA
                        }
                    },
                    secondaryLabel = "View transcript instead",
                    onSecondary = { onViewTranscript(session) },
                    details = session?.let { "${it.gitBranch} · failed" },
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// State chip (RUNNING pulse / IDLE hollow / IN CONDUIT)
// ---------------------------------------------------------------------------

@Composable
private fun StateChip(label: String, color: Color, isRunning: Boolean) {
    val infiniteTransition = rememberInfiniteTransition(label = "pulse")
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 0.3f,
        animationSpec = infiniteRepeatable(
            animation = tween(800),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "dot_pulse",
    )

    Row(
        Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(color.copy(alpha = 0.12f))
            .border(1.dp, color.copy(alpha = 0.28f), RoundedCornerShape(99.dp))
            .padding(horizontal = 7.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            Modifier
                .size(6.dp)
                .clip(RoundedCornerShape(99.dp))
                .background(color.copy(alpha = if (isRunning) pulseAlpha else 1f)),
        )
        Text(label, fontFamily = LocalNeonTheme.current.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.sp, color = color)
    }
}

// ---------------------------------------------------------------------------
// Relative time helper
// ---------------------------------------------------------------------------

private fun relativeTime(ms: Long): String {
    if (ms == 0L) return "unknown"
    val diff = System.currentTimeMillis() - ms
    val mins = diff / 60_000
    val hours = mins / 60
    val days = hours / 24
    return when {
        days > 0 -> "${days}d ago"
        hours > 0 -> "${hours}h ago"
        mins > 0 -> "${mins}m ago"
        else -> "just now"
    }
}

// ---------------------------------------------------------------------------
// Screen 09: Watch live -- read-only tail of a running session
// ---------------------------------------------------------------------------

/**
 * Read-only live-tail screen for a RUNNING discovered session.
 * Polls GET /api/sessions/discovered/transcript?since_ts=<cursor> every 2.5s,
 * appending new items and advancing the cursor.
 *
 * States:
 *  - Polling normally: transcript grows; pulse dot animates.
 *  - Poll failure (box drop): "stream paused -- reconnecting" banner;
 *    frames kept; retrying continues automatically.
 *  - Session ended (no new items and latest_ts stable): "session ended" notice
 *    + View full transcript + Branch from last point.
 *  - Cancelled: coroutine scope cancellation stops the loop cleanly.
 *
 * Reduced-motion: pulse dot becomes static when the system animator scale is 0.
 * The ONE looping animation in this feature is the pulse dot -- everything else
 * is instant state transitions.
 */
@Composable
private fun WatchLiveSheet(
    session: SessionStore.DiscoveredSession,
    forkProbe: ForkProbeState,
    onRetryForkProbe: () -> Unit,
    neon: NeonTheme,
    store: SessionStore,
    server: SavedServer,
    onBack: () -> Unit,
    onBranch: (SessionStore.DiscoveredSession) -> Unit,
) {
    // Reduced-motion: system animator scale 0 means no looping animation.
    val context = LocalContext.current
    val reduceMotion = remember {
        android.provider.Settings.Global.getFloat(
            context.contentResolver,
            android.provider.Settings.Global.ANIMATOR_DURATION_SCALE,
            1f,
        ) == 0f
    }

    val lazyState = rememberLazyListState()

    // Full transcript items (initial load + incremental poll appended).
    var watchItems by remember { mutableStateOf<List<SessionStore.FoundTranscriptItem>>(emptyList()) }
    // Polling cursor -- advances to latest_ts on each successful poll.
    var cursorMs by remember { mutableStateOf(0L) }
    // Pause/error banner when the last poll failed.
    var streamPaused by remember { mutableStateOf(false) }
    // True once we confirm the session has ended (no growth after two consecutive polls).
    var sessionEnded by remember { mutableStateOf(false) }
    // Track stable-ts rounds to detect session end.
    var stableRounds by remember { mutableStateOf(0) }
    // Initial load state.
    var initialLoading by remember { mutableStateOf(true) }
    var loadError by remember { mutableStateOf(false) }

    // Initial full-transcript load (no since_ts), then start poll loop.
    LaunchedEffect(session.externalId) {
        Telemetry.breadcrumb(
            "found_sessions",
            "watch opened",
            mapOf("agent" to session.agent, "id" to session.externalId),
        )
        val initial = store.fetchDiscoveredTranscript(server.endpoint, session.agent, session.externalId)
        if (initial == null) {
            initialLoading = false
            loadError = true
            Telemetry.breadcrumb("found_sessions", "watch initial load failed", mapOf("id" to session.externalId))
            return@LaunchedEffect
        }
        watchItems = initial
        // Seed the cursor from the last item's ts converted to ms; fall back to now.
        cursorMs = initial.lastOrNull()?.let {
            try { java.time.Instant.parse(it.ts).toEpochMilli() } catch (_: Exception) { 0L }
        } ?: System.currentTimeMillis()
        initialLoading = false

        // Auto-scroll to the true bottom after initial load. A single
        // animateScrollToItem lands short while rows are still measuring, so use
        // the shared 3-retry + final-snap helper (parity with ChatPage).
        if (initial.isNotEmpty()) {
            scrollToTrueBottom(lazyState)
        }

        // Poll loop: runs until the coroutine is cancelled (navigation away).
        while (true) {
            delay(2_500L)
            if (sessionEnded) break

            val result = store.fetchDiscoveredTranscriptSince(
                endpoint = server.endpoint,
                agent = session.agent,
                externalId = session.externalId,
                sinceMs = cursorMs,
            )
            if (result == null) {
                // Transient failure: show paused banner; keep retrying.
                if (!streamPaused) {
                    streamPaused = true
                    Telemetry.breadcrumb("found_sessions", "watch paused", mapOf("id" to session.externalId))
                }
                continue
            }
            streamPaused = false
            val (newItems, latestTs) = result
            if (newItems.isNotEmpty()) {
                watchItems = watchItems + newItems
                cursorMs = latestTs
                stableRounds = 0
                // Auto-scroll to the newly appended items.
                withContext(Dispatchers.Main) {
                    lazyState.animateScrollToItem(watchItems.size - 1)
                }
            } else {
                // No new items this round. After two consecutive stable rounds assume session ended.
                stableRounds++
                if (stableRounds >= 2) {
                    sessionEnded = true
                    Telemetry.breadcrumb("found_sessions", "watch session ended", mapOf("id" to session.externalId))
                }
            }
        }
    }

    Column(Modifier.fillMaxSize()) {
        // -- Header --
        Row(
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            IconButton(onClick = onBack) {
                Icon(Icons.Default.Close, contentDescription = "Back", tint = neon.textFaint)
            }
            Column(Modifier.weight(1f)) {
                Text(
                    session.title,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Text(
                    "${session.cwd} · ${session.gitBranch}",
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            // "Watching live" chip with pulse dot
            WatchingChip(neon = neon, reduceMotion = reduceMotion, ended = sessionEnded)
        }

        // -- Persistent "You're watching -- not driving" banner --
        Row(
            Modifier
                .fillMaxWidth()
                .background(neon.yellow.copy(alpha = 0.08f))
                .padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Outlined.Visibility,
                contentDescription = null,
                tint = neon.yellow,
                modifier = Modifier.size(14.dp),
            )
            Text(
                "You're watching -- not driving",
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.yellow,
                fontWeight = FontWeight.SemiBold,
            )
        }

        // -- Stream paused banner --
        if (streamPaused && !sessionEnded) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(neon.red.copy(alpha = 0.07f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Default.ErrorOutline,
                    contentDescription = null,
                    tint = neon.red,
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    "Stream paused -- reconnecting",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.red,
                )
            }
        }

        // -- Session ended banner --
        if (sessionEnded) {
            Row(
                Modifier
                    .fillMaxWidth()
                    .background(neon.textFaint.copy(alpha = 0.06f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Icon(
                    Icons.Default.Terminal,
                    contentDescription = null,
                    tint = neon.textFaint,
                    modifier = Modifier.size(13.dp),
                )
                Text(
                    "Session ended",
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textFaint,
                )
            }
        }

        // -- Transcript body --
        when {
            initialLoading -> {
                Box(Modifier.weight(1f).fillMaxWidth(), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = neon.accent, modifier = Modifier.size(32.dp))
                }
            }
            loadError -> {
                FoundSessionErrorComposable(
                    neon = neon,
                    title = "Could not load transcript",
                    message = "The connection dropped before the transcript could load.",
                    primaryLabel = "Go back",
                    onPrimary = onBack,
                    secondaryLabel = null,
                    onSecondary = null,
                )
            }
            else -> {
                LazyColumn(
                    state = lazyState,
                    modifier = Modifier.weight(1f).fillMaxWidth(),
                    contentPadding = PaddingValues(horizontal = 16.dp, vertical = 8.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    items(watchItems) { item ->
                        TranscriptItemRow(neon = neon, item = item)
                    }
                    if (watchItems.isEmpty()) {
                        item {
                            Text(
                                "Waiting for messages...",
                                fontFamily = neon.mono,
                                fontSize = 12.sp,
                                color = neon.textFaint,
                                modifier = Modifier.padding(16.dp),
                            )
                        }
                    }
                    // Live updates footer
                    if (!sessionEnded) {
                        item {
                            Row(
                                Modifier.padding(vertical = 8.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                Box(
                                    Modifier
                                        .size(6.dp)
                                        .clip(RoundedCornerShape(99.dp))
                                        .background(if (streamPaused) neon.red else neon.green),
                                )
                                Text(
                                    if (streamPaused) "reconnecting..." else "live -- updates as it runs",
                                    fontFamily = neon.mono,
                                    fontSize = 10.sp,
                                    color = neon.textFaint,
                                )
                            }
                        }
                    }
                }
            }
        }

        // -- Pinned bottom CTA: Branch a copy to take control -- 4-state gate
        Column(
            Modifier
                .fillMaxWidth()
                .background(neon.surfaceSolid)
                .padding(16.dp)
                .windowInsetsPadding(WindowInsets.navigationBars),
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            when (forkProbe) {
                is ForkProbeState.Checking -> {
                    FilledTonalButton(
                        onClick = {},
                        enabled = false,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
                        Spacer(Modifier.size(6.dp))
                        Text("Checking this box...", fontFamily = neon.sans, fontSize = 13.sp)
                    }
                }
                is ForkProbeState.Failed -> {
                    FilledTonalButton(
                        onClick = {
                            Telemetry.breadcrumb("found_sessions", "fork probe retry", mapOf("surface" to "watch_sheet"))
                            onRetryForkProbe()
                        },
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Default.Refresh, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text("Couldn't check this box -- Retry", fontFamily = neon.sans, fontSize = 13.sp)
                    }
                }
                is ForkProbeState.Ready -> {
                    FilledTonalButton(
                        onClick = {
                            Telemetry.breadcrumb(
                                "found_sessions",
                                "watch branch",
                                mapOf("id" to session.externalId),
                            )
                            onBranch(session)
                        },
                        enabled = forkProbe.sessionFork,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Icon(Icons.Outlined.ForkRight, contentDescription = null, modifier = Modifier.size(16.dp))
                        Spacer(Modifier.size(6.dp))
                        Text(
                            if (forkProbe.sessionFork) "Branch a copy to take control"
                            else "Branching needs a newer broker on this box. Update it to enable.",
                            fontFamily = neon.sans,
                            fontSize = 13.sp,
                        )
                    }
                }
            }
            Text(
                "Watching never changes the session -- branch to drive your own copy",
                fontFamily = neon.mono,
                fontSize = 10.sp,
                color = neon.textFaint,
                modifier = Modifier.align(Alignment.CenterHorizontally),
            )
        }
    }
}

// ---------------------------------------------------------------------------
// Watching chip (live pulse or static dot when reduced-motion)
// ---------------------------------------------------------------------------

@Composable
private fun WatchingChip(neon: NeonTheme, reduceMotion: Boolean, ended: Boolean) {
    val infiniteTransition = rememberInfiniteTransition(label = "watch_pulse")
    val pulseAlpha by infiniteTransition.animateFloat(
        initialValue = 1f,
        targetValue = 0.25f,
        animationSpec = infiniteRepeatable(
            animation = tween(900),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "watch_dot_pulse",
    )
    val dotAlpha = when {
        ended -> 1f
        reduceMotion -> 1f
        else -> pulseAlpha
    }
    val chipColor = if (ended) neon.textFaint else neon.yellow

    Row(
        Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(chipColor.copy(alpha = 0.12f))
            .border(1.dp, chipColor.copy(alpha = 0.28f), RoundedCornerShape(99.dp))
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(
            Modifier
                .size(6.dp)
                .clip(RoundedCornerShape(99.dp))
                .background(chipColor.copy(alpha = dotAlpha)),
        )
        Text(
            if (ended) "Ended" else "Watching live",
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 10.sp,
            color = chipColor,
        )
    }
}
