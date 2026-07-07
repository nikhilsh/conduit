package sh.nikhil.conduit.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.VisibleSession
import sh.nikhil.conduit.ui.components.FlowCard
import sh.nikhil.conduit.firstUserMessageOf
import sh.nikhil.conduit.latestActivityPreviewOf

// Android mirror of iOS ConduitUI.TabletHome — the design bundle's tablet
// Home dashboard (tablet-sections.jsx → TabletHome): a 2-col grid of
// session cards + a 2-col Boxes grid, under a header with a connection
// chip. Reuses the home data + naming/preview helpers. Outcome chips are
// omitted (no diff/PR/test data to back them).

@OptIn(ExperimentalFoundationApi::class)
@Composable
fun NeonTabletHome(
    store: SessionStore,
    onOpenSession: (String) -> Unit,
    onOpenPipelines: () -> Unit = {},
    // FLOWS section: a card tap opens that flow's monitor directly (id +
    // title); "+ New flow" opens the builder. Defaults are no-ops so this
    // (currently unreferenced -- AppRoot's tablet path reuses `HomeScreen`)
    // composable still compiles for any future caller.
    onOpenPipeline: (id: String, title: String) -> Unit = { _, _ -> },
    onNewPipeline: () -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val sessions by store.sessions.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val visible = remember(sessions, lifecycle) { store.visibleSessions() }
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    // Change 4: display-only harness with grace-window suppression.
    val visibleHarness by store.visibleHarness.collectAsState()
    val connected = harness is HarnessState.Live || harness is HarnessState.Linked

    // Pipeline affordance (#907, tablet-parity fix for the gap #905
    // flagged): mirrors HomeScreen's phone-only banner -- refresh on
    // appear / box switch only, gated on the broker's `pipeline`
    // capability. Never a fabricated count; hidden when none qualify.
    val pipelinesEnabled by store.pipelinesEnabled.collectAsState()
    var pipelineSummaries by remember { mutableStateOf<List<PipelineSummary>>(emptyList()) }
    LaunchedEffect(endpoint.displayHost, pipelinesEnabled) {
        if (pipelinesEnabled && endpoint.isComplete) {
            pipelineSummaries = store.refreshPipelines()
        }
    }
    val activePipelines = remember(pipelineSummaries) {
        pipelineSummaries.filter { PipelineListViewModel.isActiveForHomeAffordance(it.state) }
    }
    val recentTerminalPipelines = remember(pipelineSummaries) {
        pipelineSummaries.filter { PipelineListViewModel.isRecentTerminal(it) }
    }
    val homeFlows = remember(activePipelines, recentTerminalPipelines) {
        PipelineListViewModel.sorted(activePipelines + recentTerminalPipelines)
    }
    val continuingFlowIds = remember { mutableStateMapOf<String, Boolean>() }

    // Rename dialog state (hoisted above the grid so the AlertDialog floats
    // over the full NeonTabletHome surface, not buried inside a grid cell).
    var renameTarget by remember { mutableStateOf<SavedServer?>(null) }
    var renameDraft by remember { mutableStateOf("") }

    // Reachability probe: absent key = pending, true = reachable, false = offline.
    // SSH boxes skip the probe (loopback only listens while the tunnel is up).
    // Mirrors HomeBoxRow / ServerSwitcherSheet logic from HomeScreen.kt / SettingsScreen.kt.
    val reachabilityMap = remember { mutableStateMapOf<String, Boolean>() }
    val scope = rememberCoroutineScope()
    LaunchedEffect(savedServers) {
        savedServers.forEach { server ->
            if (server.endpoint == endpoint) return@forEach // active box uses harness state
            // SSH boxes persist a loopback ws://127.0.0.1:<port> that only
            // listens while THAT box's russh tunnel is up. Probing at rest
            // always fails → misleading "offline". Skip; render neutral label.
            if (server.ssh != null) return@forEach
            if (reachabilityMap.containsKey(server.id)) return@forEach // already probed
            scope.launch(Dispatchers.IO) {
                val reachable = withTimeoutOrNull(4_000L) {
                    runCatching {
                        val base = server.endpoint.httpBaseUrl ?: return@runCatching false
                        val conn = java.net.URL("$base/api/capabilities").openConnection()
                            as java.net.HttpURLConnection
                        conn.setRequestProperty("Authorization", "Bearer ${server.endpoint.token}")
                        conn.connectTimeout = 3000
                        conn.readTimeout = 3000
                        val code = conn.responseCode
                        conn.disconnect()
                        code in 200..299
                    }.getOrDefault(false)
                } ?: false
                reachabilityMap[server.id] = reachable
                if (!reachable) {
                    Telemetry.breadcrumb(
                        "tablet_boxes", "reachability probe offline",
                        mapOf("server" to server.name),
                    )
                }
            }
        }
    }

    // Inline "Continue" (gate approval) from a tablet FlowCard -- same
    // endpoint + approve-as-is semantics as the phone Home / monitor
    // Continue (PipelineMonitorScreen).
    fun continueFlow(flow: PipelineSummary) {
        if (continuingFlowIds.containsKey(flow.id)) return
        val base = endpoint.httpBaseUrl ?: return
        continuingFlowIds[flow.id] = true
        Telemetry.breadcrumb("pipeline", "flow card continue tapped", mapOf("pipeline_id" to flow.id))
        scope.launch {
            val result = withContext(Dispatchers.IO) {
                runCatching {
                    val conn = (java.net.URL("$base/api/pipeline/${flow.id}/continue").openConnection() as java.net.HttpURLConnection).apply {
                        requestMethod = "POST"
                        doOutput = true
                        setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                        setRequestProperty("Content-Type", "application/json")
                        connectTimeout = 10_000
                        readTimeout = 20_000
                    }
                    conn.outputStream.use { it.write("{}".toByteArray(Charsets.UTF_8)) }
                    val code = conn.responseCode
                    conn.disconnect()
                    if (code !in 200..299) error("HTTP $code")
                }
            }
            continuingFlowIds.remove(flow.id)
            if (result.isSuccess) {
                Telemetry.breadcrumb("pipeline", "flow card continue ok", mapOf("pipeline_id" to flow.id))
                pipelineSummaries = store.refreshPipelines()
            } else {
                Telemetry.capture(
                    error = result.exceptionOrNull() ?: Exception("flow card continue failed"),
                    message = "flow card continue error",
                    tags = mapOf("surface" to "android", "phase" to "pipeline-home"),
                    extras = mapOf("pipeline_id" to flow.id),
                )
            }
        }
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 18.dp),
    ) {
        // Header
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Home", fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 22.sp, color = neon.text)
            Spacer(Modifier.weight(1f))
            // Use visibleHarness for status label: suppresses "reconnecting" during grace window (Change 4).
            val (label, color) = when (visibleHarness) {
                is HarnessState.Live, is HarnessState.Linked -> (if (endpoint.isComplete) endpoint.displayHost else "online") to neon.green
                is HarnessState.Connecting, is HarnessState.Reconnecting -> "connecting" to neon.yellow
                else -> "offline" to neon.textFaint
            }
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(neon.surface)
                    .border(1.dp, neon.border, RoundedCornerShape(99.dp))
                    .padding(horizontal = 13.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Box(Modifier.size(6.dp).clip(RoundedCornerShape(99.dp)).background(color))
                Text(label, fontFamily = neon.mono, fontSize = 11.5.sp, color = color)
            }
        }
        Spacer(Modifier.size(16.dp))

        // FLOWS: same slot as phone Home -- above "Active sessions", below
        // the header. Never a fabricated count -- hidden when no flow
        // qualifies.
        if (homeFlows.isNotEmpty()) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "FLOWS".uppercase(),
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.accent,
                    maxLines = 1,
                    softWrap = false,
                    modifier = Modifier.clickable {
                        Telemetry.breadcrumb("pipeline", "flows section label tapped")
                        onOpenPipelines()
                    },
                )
                Spacer(Modifier.weight(1f))
                Row(
                    modifier = Modifier.clickable(onClick = onNewPipeline),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(5.dp),
                ) {
                    Icon(Icons.Filled.Add, null, modifier = Modifier.size(14.dp), tint = neon.accent)
                    Text(
                        "New flow",
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.5.sp,
                        color = neon.accent,
                    )
                }
            }
            Spacer(Modifier.size(10.dp))
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                homeFlows.forEach { flow ->
                    FlowCard(
                        summary = flow,
                        isContinuing = continuingFlowIds.containsKey(flow.id),
                        onOpen = {
                            Telemetry.breadcrumb(
                                "pipeline",
                                "flow card opened",
                                mapOf("pipeline_id" to flow.id, "state" to flow.state),
                            )
                            onOpenPipeline(flow.id, flow.title)
                        },
                        onContinue = { continueFlow(flow) },
                    )
                }
            }
            Spacer(Modifier.size(16.dp))
        }

        val creatingItems = visible.filterIsInstance<VisibleSession.Creating>()
        if (sessions.isEmpty() && creatingItems.isEmpty()) {
            SectionLabel("Active sessions", neon)
            Text(
                if (connected) "No sessions yet — start one from the Sessions tab." else "Waiting for the server.",
                fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim,
                modifier = Modifier.padding(vertical = 20.dp),
            )
        } else {
            SectionLabel("Active sessions", neon)
            // Creating placeholders at the TOP (parity with phone home + iOS).
            creatingItems.forEach { _ ->
                TabletCreatingSessionRow(neon = neon, modifier = Modifier.padding(bottom = 8.dp))
            }
            GridOf(sessions.map { it.id }) { id ->
                val session = sessions.first { it.id == id }
                val phase = statuses[id]?.phase
                val isRunning = connected && !(phase ?: "ready").startsWith("exited")
                val title = SessionNaming.friendlyFor(
                    session = session,
                    custom = displayNames[id],
                    firstUserMessage = firstUserMessageOf(conversationLog[id]),
                )
                val preview = latestActivityPreviewOf(conversationLog[id])
                val cardStatus = statuses[id]
                val cardBranch = cardStatus?.gitBranch?.takeIf { it.isNotBlank() }
                    ?: session.gitBranch?.takeIf { it.isNotBlank() }
                val cardDirty = cardStatus?.gitDirty ?: session.gitDirty
                SessionCard(neon, title, session.assistant, isRunning, preview, session, cardBranch, cardDirty) { onOpenSession(id) }
            }
            Spacer(Modifier.size(24.dp))
        }

        if (savedServers.isNotEmpty()) {
            SectionLabel("Boxes", neon)
            GridOf(savedServers.map { it.id }) { sid ->
                val server = savedServers.first { it.id == sid }
                val isActive = endpoint == server.endpoint
                // v151 ITEM C: SSH boxes persist a loopback endpoint; show the real
                // ssh host:port instead of 127.0.0.1:<ephemeral port>.
                val sub = server.ssh?.let { "${it.host}:${it.port}" } ?: server.endpoint.displayHost
                BoxCard(
                    neon = neon,
                    server = server,
                    host = sub,
                    isActive = isActive,
                    harness = visibleHarness,
                    reachable = reachabilityMap[server.id],
                    onConnect = {
                        Telemetry.breadcrumb(
                            "tablet_boxes", "connect tapped",
                            mapOf("server" to server.name),
                        )
                        store.selectSavedServer(server.id, autoConnect = true)
                    },
                    onRename = {
                        renameTarget = server
                        renameDraft = server.name
                    },
                )
            }
        }
    }

    // Rename dialog — hoisted above the grid so it overlays correctly.
    renameTarget?.let { target ->
        AlertDialog(
            onDismissRequest = { renameTarget = null },
            title = { Text("Rename box") },
            text = {
                OutlinedTextField(
                    value = renameDraft,
                    onValueChange = { renameDraft = it },
                    label = { Text("Name") },
                    singleLine = true,
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    if (renameDraft.isNotBlank()) {
                        store.renameSavedServer(target.id, renameDraft)
                    }
                    renameTarget = null
                }) { Text("Rename") }
            },
            dismissButton = {
                TextButton(onClick = { renameTarget = null }) { Text("Cancel") }
            },
        )
    }
}

/** 2-column grid laid out as chunked rows (avoids nested-scroll constraints). */
@Composable
private fun GridOf(ids: List<String>, item: @Composable (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        ids.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.fillMaxWidth()) {
                pair.forEach { id ->
                    Box(Modifier.weight(1f)) { item(id) }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String, neon: NeonTheme) {
    Text(
        text.uppercase(),
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        fontSize = 11.sp,
        color = neon.textDim,
        maxLines = 1,
        softWrap = false,
        modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
    )
}

@Composable
private fun SessionCard(
    neon: NeonTheme,
    title: String,
    assistant: String,
    isRunning: Boolean,
    preview: String?,
    session: uniffi.conduit_core.ProjectSession,
    gitBranch: String? = null,
    gitDirty: UInt? = null,
    onClick: () -> Unit,
) {
    val tint = neonAgentColor(assistant, neon)
    val shape = RoundedCornerShape((neon.radiusDp - 2).dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(99.dp)).background(if (isRunning) neon.green else neon.textFaint))
            Text(title, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = neon.text, maxLines = 1)
        }
        // Agent chip + live branch (when available).
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            Text(assistant, fontFamily = neon.mono, fontSize = 10.5.sp, color = tint)
            if (!gitBranch.isNullOrBlank()) {
                Text("·", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
                val branchLabel = if ((gitDirty ?: 0u) > 0u) "$gitBranch ●$gitDirty" else gitBranch
                Text(branchLabel, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textDim, maxLines = 1, overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis)
            }
        }
        if (!preview.isNullOrBlank()) {
            Text(preview, fontFamily = neon.sans, fontSize = 12.5.sp, color = neon.textDim, maxLines = 2)
        }
        NeonOutcomeChips(
            neon = neon,
            linesAdded = session.linesAdded?.toInt(),
            linesRemoved = session.linesRemoved?.toInt(),
            commits = session.commits?.toInt(),
            prNumber = session.prNumber?.toInt(),
            prState = session.prState,
            prUrl = session.prUrl,
        )
    }
}

/**
 * Tablet box card with full ServerSwitcher parity:
 *   - loopback display-host substitution (already present, retained)
 *   - reachability status dot + label (probing / reachable / offline / SSH · tap Connect)
 *   - active vs Connect distinction (checkmark + non-tappable active; Connect badge + tappable inactive)
 *   - rename via long-press + overflow (3-dot) menu
 * Mirrors HomeBoxRow from HomeScreen.kt and ServerSwitcherSheet from SettingsScreen.kt.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun BoxCard(
    neon: NeonTheme,
    server: SavedServer,
    host: String,
    isActive: Boolean,
    harness: HarnessState,
    // Reachability probe result for non-active boxes; null = pending.
    reachable: Boolean? = null,
    onConnect: () -> Unit,
    onRename: () -> Unit,
) {
    var menuOpen by remember { mutableStateOf(false) }
    val connected = isActive && (harness is HarnessState.Live || harness is HarnessState.Linked)

    // Status dot color + label — mirrors HomeBoxRow / ServerSwitcherSheet.
    val (statusText, statusColor) = when {
        isActive && connected -> "connected" to neon.green
        isActive && harness is HarnessState.Connecting -> "connecting..." to neon.yellow
        isActive && harness is HarnessState.Reconnecting -> "reconnecting..." to neon.yellow
        isActive -> "offline" to neon.textFaint
        // SSH/tunnel boxes: loopback only listens while connected.
        server.ssh != null -> "SSH - tap Connect" to neon.textFaint
        reachable == null -> "probing..." to neon.textFaint
        reachable == true -> "reachable" to neon.green
        else -> "offline" to neon.textFaint
    }

    val glyphColor = when {
        connected -> neon.green
        isActive -> neon.accent
        else -> neon.textFaint
    }
    val cardFill = if (connected) neon.green.copy(alpha = 0.06f) else neon.surface
    val borderColor = if (connected) neon.green.copy(alpha = 0.25f) else neon.border
    val shape = RoundedCornerShape((neon.radiusDp - 4).dp)

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = cardFill, borderColor = borderColor)
            // Active box: non-tappable for connect (already connected).
            // Inactive box: tap opens rename on long-press; short tap handled via Connect button.
            .combinedClickable(
                enabled = !isActive,
                onClick = onConnect,
                onLongClick = onRename,
            )
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(glyphColor.copy(alpha = 0.11f))
                .border(1.dp, glyphColor.copy(alpha = 0.22f), RoundedCornerShape(11.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Outlined.Dns, contentDescription = null, tint = glyphColor, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                server.name,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 14.5.sp,
                color = if (connected) neon.green else neon.text,
                maxLines = 1,
            )
            Text(
                host,
                fontFamily = neon.mono,
                fontSize = 10.5.sp,
                color = neon.textFaint,
                maxLines = 1,
            )
            // Status line: dot + label.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(5.dp)
                        .background(statusColor, CircleShape),
                )
                Text(
                    statusText,
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = statusColor,
                    maxLines = 1,
                )
            }
        }
        // Active: green checkmark (non-tappable; card itself is disabled).
        // Inactive: Connect badge (tappable; triggers box switch).
        if (isActive) {
            Icon(
                Icons.Filled.Check,
                contentDescription = "Active box",
                tint = neon.green,
                modifier = Modifier.size(18.dp),
            )
        } else {
            Text(
                "Connect",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 10.sp,
                color = neon.accent,
                modifier = Modifier
                    .clickable(onClick = onConnect)
                    .background(neon.accent.copy(alpha = 0.13f), CircleShape)
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
        }
        // Overflow (3-dot) menu: Rename. Long-press is the secondary path.
        Box {
            IconButton(
                onClick = { menuOpen = true },
                modifier = Modifier.size(28.dp),
            ) {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = "Box options",
                    modifier = Modifier.size(16.dp),
                    tint = neon.textFaint,
                )
            }
            DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                DropdownMenuItem(
                    text = { Text("Rename") },
                    onClick = {
                        menuOpen = false
                        onRename()
                    },
                )
            }
        }
    }
}

/**
 * Full-width placeholder row shown in the tablet Home "Active sessions" section
 * while a new session create is in-flight. Mirrors CreatingSessionRow in
 * HomeScreen.kt (phone) and the tablet rail's CircularProgressIndicator in
 * ProjectListScreen.kt. Wording matches iOS: "Starting session...".
 */
@Composable
private fun TabletCreatingSessionRow(neon: NeonTheme, modifier: Modifier = Modifier) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(neon.surface)
            .border(1.dp, neon.accent.copy(alpha = 0.4f), RoundedCornerShape(12.dp))
            .padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        CircularProgressIndicator(
            modifier = Modifier.size(14.dp),
            strokeWidth = 2.dp,
            color = neon.accent,
        )
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Text(
                "Starting session…",
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
                maxLines = 1,
            )
            Text(
                "asking server for a session…",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = neon.mono,
                color = neon.textDim,
                maxLines = 1,
            )
        }
    }
}
