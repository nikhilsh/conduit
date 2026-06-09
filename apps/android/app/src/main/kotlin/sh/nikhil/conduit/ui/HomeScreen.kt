package sh.nikhil.conduit.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.automirrored.filled.List
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.foundation.border
import androidx.compose.material.icons.filled.Storage
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.NeedsYouItem
import sh.nikhil.conduit.needsYouBanner

/**
 * Conduit-style home screen — shown when no session is selected, in
 * place of `EmptyDetail`. Top row (settings · title · list) +
 * ServerTabsStrip + sessions list + BottomActionBar (mic / + / search).
 * Mirrors `apps/ios/Sources/Views/HomeView.swift`.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun HomeScreen(
    store: SessionStore,
    onOpenSettings: () -> Unit,
    onOpenDrawer: () -> Unit,
    onOpenHistory: () -> Unit,
    onAddServer: () -> Unit,
    onNewSession: () -> Unit,
    onSearch: () -> Unit,
    onVoice: () -> Unit,
    // Redesign entry points (default no-ops so existing call sites that don't
    // wire them still compile): the needs-you banner's Review opens the
    // Approvals inbox; a Boxes-list tap opens that box's health detail.
    onOpenApprovals: () -> Unit = {},
    onOpenBoxHealth: (SavedServer) -> Unit = {},
    // On the 3-pane tablet the rail header already owns the Settings gear,
    // so the center home screen must not render a second one (two gears on
    // the tablet home — device feedback 2026-06-02). Phone keeps it: the
    // rail isn't present there, so this is the only Settings affordance.
    showSettingsButton: Boolean = true,
) {
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val sessions by store.sessions.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    // Collected so a row's friendly name recomposes the moment the first
    // user message lands in the conversation log.
    val conversationLog by store.conversationLog.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val selectedId by store.selectedId.collectAsState()

    // Pending exit target for the session-row long-press confirmation.
    // Mirror of iOS PR #128's `pendingDelete` on ConduitHomeView — we
    // keep the title alongside the id so the prompt can name the
    // session being ended without re-resolving displayNames.
    var pendingDelete by remember { mutableStateOf<SessionDeleteTarget?>(null) }

    // Round-2 fix 5: once the user is signed in to an agent, their own
    // device is a box too and is pinned first under BOXES. One credential-
    // store read per composition entry (not per recomposition).
    val context = androidx.compose.ui.platform.LocalContext.current
    val localDeviceListed = remember {
        sh.nikhil.conduit.auth.AgentAccountStatus.current(context).any { it.signedIn }
    }

    val neon = LocalNeonTheme.current

    // Read real insets top AND bottom (design handoff §4.1): statusBarsPadding
    // keeps the header off the status bar; navigationBarsPadding keeps the
    // bottom action bar + BOXES off the gesture pill / 3-button nav. The app is
    // edge-to-edge (the chat composer already does this), so without it the home
    // footer collided with the system nav.
    Column(modifier = Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding().padding(top = 8.dp)) {
        // Top row. Conduit parity put settings behind a hidden long-press
        // on the title — undiscoverable in practice (user feedback
        // 2026-05-23). Restore a visible gear in the leading slot; the
        // long-press stays as a secondary path. Trailing keeps the
        // sessions-drawer affordance (upstream has no remote multiplexer
        // so this is conduit-specific).
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            if (showSettingsButton) {
                CircleIconButton(Icons.Default.Settings, "Settings", onClick = onOpenSettings)
            }
            Spacer(Modifier.weight(1f))
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.combinedClickable(
                    onClick = {},
                    onLongClick = onOpenSettings,
                ),
            ) {
                // Brand lockup: daemon mark + `>conduit` wordmark (mono 700,
                // `>` tinted with the accent), matching iOS + the
                // design-reference home header.
                AnimatedBrandMark(size = 26.dp)
                Text(
                    buildAnnotatedString {
                        withStyle(SpanStyle(color = if (neon.glow) neon.accent else neon.textDim)) { append(">") }
                        withStyle(SpanStyle(color = neon.text)) { append("conduit") }
                    },
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    letterSpacing = 1.sp,
                )
            }
            Spacer(Modifier.weight(1f))
            // Trailing slot now carries both History (cross-server, includes
            // archived) and the live-sessions drawer. iOS only needs the
            // history entry because its home view IS the live list; Android
            // needs the drawer too for multi-project nav.
            CircleIconButton(Icons.Default.History, "History", onClick = onOpenHistory)
            CircleIconButton(Icons.AutoMirrored.Filled.List, "Sessions", onClick = onOpenDrawer)
        }

        // Ambient account-usage strip (design handoff §B.10) — per-agent plan
        // headroom (`claude 62% · codex 28%`) at a glance, above the session
        // list. Self-hides until some agent carries usage data so it never
        // dominates the list; gate the spacer too.
        if (accountUsageByAgent(sessions, statuses).any { it.hasData }) {
            Spacer(Modifier.height(12.dp))
            HomeUsageStrip(store, modifier = Modifier.padding(horizontal = 14.dp))
        }

        // "Needs you" banner (handoff §B.5 / §B.10) — appears ONLY when a real
        // signal exists: a session whose last transcript item is an unanswered
        // agent `pending_input` (approval prompt / options menu). Never a
        // fabricated count; hidden when none. Tapping it opens the first one.
        val needsYou = remember(sessions, conversationLog, displayNames) {
            needsYouBanner(
                sessions.map { s ->
                    NeedsYouItem(
                        id = s.id,
                        title = SessionNaming.friendlyFor(
                            session = s,
                            custom = displayNames[s.id],
                            firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(conversationLog[s.id]),
                        ),
                        agent = s.assistant,
                    ) to conversationLog[s.id]
                },
            )
        }
        if (!needsYou.isEmpty) {
            Spacer(Modifier.height(12.dp))
            NeedsYouBannerCard(
                neon = neon,
                banner = needsYou,
                modifier = Modifier.padding(horizontal = 14.dp),
                // Review opens the Approvals inbox (the queue of blocked
                // sessions) rather than jumping into the first session.
                onReview = onOpenApprovals,
            )
        }

        Spacer(Modifier.height(14.dp))

        // The connected machine is no longer a separate status card here — it's
        // the first, active-styled row of the BOXES list below the sessions
        // (design handoff §3a: one machine = one row). See HomeBoxRow.

        // ACTIVE SESSIONS section label (mono uppercase, cyan) + New session,
        // matching the design-reference home.
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "ACTIVE SESSIONS",
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                fontSize = 12.sp,
                letterSpacing = 2.sp,
                color = neon.accent,
                maxLines = 1,
                softWrap = false,
            )
            Spacer(Modifier.weight(1f))
            Row(
                modifier = Modifier.clickable { if (canIssueCommands(harness)) onNewSession() else onAddServer() },
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Icon(Icons.Default.Add, null, modifier = Modifier.size(14.dp), tint = neon.accent)
                Text(
                    "New session",
                    style = MaterialTheme.typography.titleSmall,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.accent,
                )
            }
        }
        Spacer(Modifier.height(8.dp))

        // Sessions list
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            if (sessions.isEmpty()) {
                // iOS ConduitHomeView empty-state parity: hero glyph
                // (sparkles when we can issue commands, cloud.slash when
                // waiting), headline title, footnote body. Sits a touch
                // above optical center so it doesn't feel marooned in
                // the middle of a tall, otherwise-blank tablet pane.
                val canCommand = canIssueCommands(harness)
                // Fresh install (nothing paired — no endpoint URL at all):
                // COPY_DECK.md's canonical onboarding empty state, not the
                // "waiting" copy (there is no server to wait FOR yet).
                // Mirrors iOS HomeViewModel.isUnpaired.
                val unpaired = !canCommand && endpoint.url.isBlank()
                Column(
                    modifier = Modifier.fillMaxSize().padding(horizontal = 36.dp),
                    verticalArrangement = Arrangement.Center,
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        if (canCommand || unpaired) Icons.Default.AutoAwesome else Icons.Default.CloudOff,
                        contentDescription = null,
                        modifier = Modifier.size(40.dp),
                        tint = neon.accent,
                    )
                    Spacer(Modifier.height(14.dp))
                    Text(
                        if (canCommand || unpaired) "No sessions yet" else "Waiting for server",
                        style = MaterialTheme.typography.titleMedium,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.text,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        when {
                            canCommand -> "Tap + below to spin up a new conversation."
                            unpaired -> "Pair a machine to begin."
                            else -> "Once we can reach the server, your sessions appear here."
                        },
                        style = MaterialTheme.typography.bodySmall,
                        fontFamily = neon.sans,
                        color = neon.textDim,
                        textAlign = TextAlign.Center,
                    )
                }
            } else {
                Column(
                    modifier = Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(horizontal = 14.dp),
                    // Breathing room between cards so the list doesn't read
                    // as one packed slab.
                    verticalArrangement = Arrangement.spacedBy(ConduitHomeRowMetrics.rowGap.dp),
                ) {
                    // Order rows most-recent-activity first. The timestamp
                    // priority mirrors iOS: (1) the last live conversation-log
                    // item's `ts` (the real last-message time), else (2) the
                    // session's own metadata; the reconnect-set status
                    // timestamp is deliberately NOT the primary source (on a
                    // cold-boot reconnect it's the CONNECTION time, which made
                    // every row read "just now" and broke the sort).
                    val sortedSessions = sh.nikhil.conduit.sortSessionsByActivity(sessions) { s ->
                        sh.nikhil.conduit.lastMessageTimestampOf(conversationLog[s.id])
                            ?: s.lastActivityAt
                            ?: s.startedAt
                    }
                    sortedSessions.forEach { session ->
                        val isSelected = selectedId == session.id
                        // device bug #9: dot tracks run state, not selection.
                        // device bug #30: and only green when actually
                        // connected — a stale "running" phase must not show
                        // green while the connection is down.
                        val connected = harness is HarnessState.Live || harness is HarnessState.Linked
                        val phase = statuses[session.id]?.phase
                        val exited = (phase ?: "ready").startsWith("exited")
                        // Amber "starting" until the broker confirms the
                        // session is interactive (~30s cold-boot window where
                        // the chat composer is gated). Green only when truly
                        // confirmed-live.
                        val confirmedLive = store.isConfirmedLive(session.id)
                        val isRunning = connected && !exited && confirmedLive
                        val isStarting = connected && !exited && !confirmedLive
                        // Friendly name (never the raw UUID): custom rename →
                        // first user message → broker label → "<agent> · time".
                        // Derived from the collected displayNames + conversation
                        // log so the row recomposes when either changes.
                        val rowTitle = SessionNaming.friendlyFor(
                            session = session,
                            custom = displayNames[session.id],
                            firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(
                                conversationLog[session.id],
                            ),
                        )
                        // One-line latest-activity preview (iOS #238
                        // parity): the most recent non-user item (assistant
                        // reply or tool action), condensed. Complements the
                        // title (the first user message) so active sessions
                        // are distinguishable at a glance. Null → no line.
                        val activityPreview = sh.nikhil.conduit.latestActivityPreviewOf(
                            conversationLog[session.id],
                        )
                        // Every row now sits on a real Material 3 card — a
                        // faint surfaceVariant fill, rounded corners, and the
                        // status dot brought inside the card rather than
                        // floating at the list's left edge. Selection bumps
                        // the fill so it still stands out without an icon swap.
                        // Neon session card: a neon surface fill, an
                        // agent-tinted hairline (brighter when selected),
                        // and the theme glow. Replaces the M3
                        // surfaceVariant slab.
                        val rowShape = RoundedCornerShape(ConduitHomeRowMetrics.cardCornerRadius.dp)
                        val agentTint = neonAgentColor(session.assistant, neon)
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .neonCardSurface(
                                    neon = neon,
                                    shape = rowShape,
                                    fill = neon.surface,
                                    borderColor = if (isSelected) agentTint.copy(alpha = 0.7f) else neon.border,
                                    glowTint = if (isSelected) agentTint else null,
                                )
                                .combinedClickable(
                                    onClick = { store.select(session.id) },
                                    onLongClick = {
                                        pendingDelete = SessionDeleteTarget(session.id, rowTitle)
                                    },
                                ),
                        ) {
                            Row(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    // Snug padding so the card hugs its two
                                    // lines instead of standing tall and empty.
                                    .padding(horizontal = 14.dp, vertical = 11.dp),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(11.dp),
                            ) {
                                // Daemon avatar: ConduitMark tinted with the
                                // agent color in a soft tinted rounded-square,
                                // with a small bottom-end run-state dot. Mirrors
                                // iOS + the design-reference SessionRow.
                                Box(modifier = Modifier.size(38.dp)) {
                                    Box(
                                        modifier = Modifier
                                            .matchParentSize()
                                            .background(agentTint.copy(alpha = 0.14f), RoundedCornerShape(9.dp))
                                            .border(1.dp, agentTint.copy(alpha = 0.35f), RoundedCornerShape(9.dp)),
                                        contentAlignment = Alignment.Center,
                                    ) {
                                        ConduitMark(size = 24.dp, color = agentTint)
                                    }
                                    Box(
                                        modifier = Modifier
                                            .align(Alignment.BottomEnd)
                                            .size(8.dp)
                                            .background(
                                                when {
                                                    isRunning -> neon.green
                                                    isStarting -> neon.yellow
                                                    else -> neon.textFaint
                                                },
                                                CircleShape,
                                            )
                                            .border(1.5.dp, neon.surface, CircleShape),
                                    )
                                }
                                Column(
                                    modifier = Modifier.weight(1f),
                                    verticalArrangement = Arrangement.spacedBy(4.dp),
                                ) {
                                    // Prominent friendly name, single line.
                                    Text(
                                        rowTitle,
                                        style = MaterialTheme.typography.titleSmall,
                                        fontFamily = neon.sans,
                                        fontWeight = FontWeight.SemiBold,
                                        color = neon.text,
                                        maxLines = 1,
                                        overflow = TextOverflow.Ellipsis,
                                    )
                                    // Secondary line: agent chip + status + relative time.
                                    SessionMetaRow(
                                        agent = session.assistant,
                                        statusLabel = sessionStatusLabel(connected, phase, confirmedLive),
                                        running = isRunning,
                                        starting = isStarting,
                                        // Last-MESSAGE time when the live log
                                        // carries one (the real activity), else
                                        // the session's own metadata — never the
                                        // reconnect-set status timestamp.
                                        relativeTime = SessionNaming.relativeAgo(
                                            sh.nikhil.conduit.lastMessageTimestampOf(conversationLog[session.id])
                                                ?: session.lastActivityAt
                                                ?: session.startedAt,
                                        ),
                                    )
                                    // Tertiary line: latest-activity preview
                                    // (iOS #238). Muted, single line, only
                                    // when there's non-user activity to show.
                                    activityPreview?.let { preview ->
                                        Text(
                                            preview,
                                            style = MaterialTheme.typography.labelSmall,
                                            fontFamily = neon.sans,
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
        }

        // BOXES — one row per saved machine, connected pinned first + ACTIVE
        // badge; folds in the old connection status card (design handoff §3a:
        // one machine = one row). Sits below the sessions, above the action bar
        // (canonical order: usage strip → active sessions → boxes). No quota
        // here — plan limits are per-account (§3b), not per box.
        if (savedServers.isNotEmpty() || localDeviceListed) {
            val boxes = savedServers.filter { it.endpoint == endpoint } +
                savedServers.filter { it.endpoint != endpoint }
            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp),
                verticalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        "BOXES",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 12.sp,
                        letterSpacing = 2.sp,
                        color = neon.accent,
                        maxLines = 1,
                        softWrap = false,
                    )
                    Spacer(Modifier.weight(1f))
                    Row(
                        modifier = Modifier.clickable { onAddServer() },
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(5.dp),
                    ) {
                        Icon(Icons.Default.Wifi, null, modifier = Modifier.size(14.dp), tint = neon.textDim)
                        Text(
                            "Pair box",
                            style = MaterialTheme.typography.titleSmall,
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            color = neon.textDim,
                        )
                    }
                }
                // Round-2 fix 5 (handoff images 09→10): "This device" pinned
                // first — the signed-in local device is itself a box.
                if (localDeviceListed) {
                    HomeLocalDeviceRow(neon)
                }
                boxes.forEach { server ->
                    HomeBoxRow(
                        neon = neon,
                        server = server,
                        isActive = server.endpoint == endpoint,
                        harness = harness,
                        // Sessions live on the connected endpoint, so the
                        // connected box's count is the whole session list.
                        sessionCount = sessions.size,
                        // Tap opens the box's health detail; reconnect now
                        // lives inside Box health (its onReconnect action).
                        onClick = { onOpenBoxHealth(server) },
                    )
                }
                if (localDeviceListed) {
                    Text(
                        "your local box is auto-listed once you're signed in.",
                        fontFamily = neon.mono,
                        fontSize = 10.sp,
                        color = neon.textFaint,
                        modifier = Modifier.padding(start = 2.dp),
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
        }

        // Bottom action bar — audit §A.1.5 / PR 3. Conduit uses 44dp
        // for ALL three controls (not 52/68); the prior 68dp filled
        // accent + plus over-built the FAB relative to the mic/search
        // peers. We keep the brand fill on the plus so it still reads
        // as the primary action, but the size now matches.
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(14.dp, Alignment.CenterHorizontally),
        ) {
            CircleActionButton(Icons.Default.Mic, "Voice", size = 44.dp, onClick = onVoice)
            Box(
                modifier = Modifier
                    .size(44.dp)
                    .then(neon.glowBox?.let { Modifier.neonGlowBox(it, CircleShape) } ?: Modifier)
                    .clip(CircleShape)
                    .background(neon.accent, CircleShape)
                    .clickable(onClick = onNewSession),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Add,
                    contentDescription = "New session",
                    tint = neon.accentText,
                    modifier = Modifier.size(22.dp),
                )
            }
            CircleActionButton(Icons.Default.Search, "Search", size = 44.dp, onClick = onSearch)
        }
    }

    pendingDelete?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingDelete = null },
            title = { Text("Archive session?") },
            text = {
                // Two-tier delete, tier 1: the active-list action archives
                // (ends the live session, keeps it read-only in History).
                // Permanent deletion lives in History.
                Text(
                    "Ends ${target.title} on the server. It stays in History (read-only) — delete it permanently from there.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    store.archive(target.id)
                    pendingDelete = null
                }) {
                    Text("Archive")
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingDelete = null }) { Text("Cancel") }
            },
        )
    }
}

/**
 * A paired-machine ("box") row on Home: tinted server glyph, name, endpoint
 * sub, and a status word. The active (connected) machine is pinned first and
 * styled active — an `ACTIVE` badge + `connected` and a green-tinted surface —
 * folding in what used to be a separate connection status card (design handoff
 * §3a). Mirrors iOS `ConduitHomeView.boxRow`. Never shows quota: plan limits are
 * per-account (§3b), surfaced via the usage strip, not per box.
 */
@Composable
private fun HomeBoxRow(
    neon: NeonTheme,
    server: SavedServer,
    isActive: Boolean,
    harness: HarnessState,
    sessionCount: Int,
    onClick: () -> Unit,
) {
    val connected = isActive && (harness is HarnessState.Live || harness is HarnessState.Linked)
    val (statusText, statusColor) = when {
        !isActive -> "tap to connect" to neon.textFaint
        connected -> "connected · $sessionCount ${if (sessionCount == 1) "session" else "sessions"}" to neon.green
        harness is HarnessState.Connecting -> "connecting…" to neon.yellow
        harness is HarnessState.Reconnecting -> "reconnecting…" to neon.yellow
        else -> "offline" to neon.textFaint
    }
    val glyphColor = if (connected) neon.green else if (isActive) neon.accent else neon.textFaint
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(12.dp),
                fill = if (connected) neon.green.copy(alpha = 0.07f) else neon.surface,
                borderColor = if (connected) neon.green.copy(alpha = 0.27f) else neon.border,
                glowTint = if (connected) neon.green else null,
            )
            .clickable(onClick = onClick)
            .padding(horizontal = 13.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(glyphColor.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Filled.Storage, null, modifier = Modifier.size(14.dp), tint = glyphColor)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                server.name,
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = if (connected) neon.green else neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                server.endpoint.displayHost,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textFaint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        if (isActive) {
            Text(
                "ACTIVE",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 9.sp,
                letterSpacing = 0.8.sp,
                color = neon.green,
                modifier = Modifier
                    .background(neon.green.copy(alpha = 0.14f), CircleShape)
                    .padding(horizontal = 6.dp, vertical = 2.dp),
            )
        }
        Box(modifier = Modifier.size(6.dp).background(statusColor, CircleShape))
        Text(
            statusText,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = statusColor,
        )
    }
}

/**
 * Pinned "This device" row: identity only. A phone can't host the broker, so
 * agents NEVER run here — every session runs on a paired box. The
 * subtitle/status say so plainly (the earlier `localhost:1977 · on-device` +
 * `● ready` read as a runnable target and had users trying to start a local
 * session). Not tappable. Mirror of iOS `ConduitHomeView.localDeviceRow`.
 */
@Composable
private fun HomeLocalDeviceRow(neon: NeonTheme) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface)
            .padding(horizontal = 13.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .background(neon.accent.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) {
            ConduitMark(size = 18.dp, color = neon.accent)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                "This device",
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                "signed in · agents run on a box",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textFaint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "LOCAL",
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 9.sp,
            letterSpacing = 0.8.sp,
            color = neon.accent,
            modifier = Modifier
                .background(neon.accent.copy(alpha = 0.14f), CircleShape)
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
        // No status dot: "● ready" implied this device was a runnable session
        // target. It isn't — it's a client.
        Text(
            "client",
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = neon.textFaint,
        )
    }
}

/**
 * The Home "needs you" banner (design handoff §B.10, image 12): an
 * amber-tinted card shown ONLY when a real signal exists — one or more
 * sessions whose agent is blocked on the user (an unanswered `pending_input`).
 * Title counts the waiting sessions; the sub names the agent/session;
 * `Review` opens the first one. The caller gates it on a non-empty banner, so
 * it never shows a fabricated count. Mirror of iOS `NeedsYouBanner`.
 */
@Composable
private fun NeedsYouBannerCard(
    neon: NeonTheme,
    banner: sh.nikhil.conduit.NeedsYouBanner,
    modifier: Modifier = Modifier,
    onReview: () -> Unit,
) {
    val title = if (banner.count == 1) "1 session waiting on you" else "${banner.count} sessions waiting on you"
    val sub = banner.sessions.firstOrNull()?.let { first ->
        if (banner.count == 1) "${first.agent} needs your input on ${first.title}" else "agents are blocked on your input"
    } ?: "agents are blocked on your input"
    Row(
        modifier = modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = RoundedCornerShape(12.dp),
                fill = neon.claude.copy(alpha = 0.07f),
                borderColor = neon.claude.copy(alpha = 0.27f),
                glowTint = neon.claude,
            )
            .clickable(onClick = onReview)
            .padding(horizontal = 13.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        Box(
            modifier = Modifier.size(34.dp).background(neon.claude.copy(alpha = 0.14f), RoundedCornerShape(9.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Default.Warning, null, modifier = Modifier.size(18.dp), tint = neon.claude)
        }
        Column(modifier = Modifier.weight(1f)) {
            Text(
                title,
                style = MaterialTheme.typography.titleSmall,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
            Text(
                sub,
                fontFamily = neon.mono,
                fontSize = 10.5.sp,
                color = neon.textDim,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Text(
            "Review",
            style = MaterialTheme.typography.titleSmall,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            color = neon.bg,
            modifier = Modifier
                .background(neon.claude, CircleShape)
                .padding(horizontal = 12.dp, vertical = 6.dp),
        )
    }
}

/**
 * Carrier for the long-press delete confirmation on the home sessions
 * list. Holds the session id (so we know what to call `store.exit` on)
 * plus its already-resolved title (so the prompt can name the session
 * without re-resolving `displayNames` at render time, and the row's
 * label can never disagree with the alert's body text).
 */
private data class SessionDeleteTarget(val id: String, val title: String)

/**
 * Row metrics for the upstream-faithful home list, mirror of iOS
 * `HomeRowMetrics`. Extracted as named constants so
 * `ConduitHomeRowMetricsTest` can pin them — silently regrowing any of
 * these would re-introduce the audit drift PR 3 is trying to stop
 * (audit §A.1.1 / §A.1.2 / §A.1.7).
 */
internal object ConduitHomeRowMetrics {
    const val titlePointSize: Float = 13f
    const val subtitlePointSize: Float = 11f
    const val leadingPadding: Float = 1f
    const val trailingPadding: Float = 8f
    const val verticalPadding: Float = 5f
    const val indicatorSize: Float = 7f
    const val activeRowCornerRadius: Float = 6f
    const val activeRowOpacity: Float = 0.55f

    // Card-style row polish: each row is its own Material 3 card with a
    // faint resting fill (so the status dot reads as inside the card) that
    // brightens on selection, larger corners than the bare active-rect, and
    // a small inter-card gap.
    const val cardCornerRadius: Float = 16f
    const val restingRowOpacity: Float = 0.30f
    const val selectedRowOpacity: Float = 0.60f
    const val rowGap: Float = 8f
}

private fun canIssueCommands(state: HarnessState): Boolean = when (state) {
    is HarnessState.Live, is HarnessState.Linked -> true
    else -> false
}

/**
 * Human-readable status word for a session row. When the connection is
 * down we say "idle" rather than echoing a stale "running" phase (device
 * bug #30 parity). A connected, non-exited session the broker hasn't
 * confirmed-live yet reads "starting" — the ~30s cold-boot reconnect window
 * where the chat composer is still gated; Home used to lie with the live
 * phase word here. Otherwise map the broker phase to a short word.
 */
private fun sessionStatusLabel(connected: Boolean, phase: String?, confirmedLive: Boolean = true): String {
    if (!connected) return "idle"
    val p = (phase ?: "ready").trim().lowercase()
    return when {
        p.isEmpty() -> "idle"
        p.startsWith("exited") -> "exited"
        p.startsWith("failed") || p.startsWith("dead") -> "exited"
        !confirmedLive -> "starting"
        p == "ready" || p == "idle" -> "idle"
        else -> p
    }
}

/**
 * Secondary line for a session row: an agent chip, a status word with a
 * matching dot, and a relative time, all in one tidy line. Replaces the
 * old monospace "<agent> · <phase>" plus the ugly ephemeral working dir.
 */
@Composable
private fun SessionMetaRow(
    agent: String,
    statusLabel: String,
    running: Boolean,
    relativeTime: String,
    starting: Boolean = false,
) {
    val neon = LocalNeonTheme.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Agent chip — neon-tinted capsule with the agent name.
        val tint = neonAgentColor(agent, neon)
        Surface(
            shape = RoundedCornerShape(50),
            color = tint.copy(alpha = 0.18f),
        ) {
            Text(
                agent,
                modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp),
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.SemiBold,
                color = tint,
                maxLines = 1,
            )
        }
        // Status word with a small dot: green (live) / amber (starting) /
        // dim (idle / exited).
        Box(
            modifier = Modifier
                .size(6.dp)
                .background(
                    color = when {
                        running -> neon.green
                        starting -> neon.yellow
                        else -> neon.textFaint
                    },
                    shape = CircleShape,
                ),
        )
        Text(
            statusLabel,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = neon.textDim,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (relativeTime.isNotEmpty()) {
            Text(
                "·",
                style = MaterialTheme.typography.labelSmall,
                color = neon.textFaint,
            )
            Text(
                relativeTime,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textFaint,
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun CircleIconButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit) {
    // Use the shared glass surface (translucent fill + highlight + stroke)
    // instead of a flat Surface so the header buttons read as glass over
    // the brand-tinted background washes — Android parallel of the iOS
    // Liquid Glass bump (#28).
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .size(40.dp)
            .glassCircle()
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = neon.accent,
            modifier = Modifier.size(18.dp),
        )
    }
}

@Composable
private fun CircleActionButton(icon: ImageVector, contentDescription: String, size: androidx.compose.ui.unit.Dp, onClick: () -> Unit) {
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .size(size)
            .glassCircle()
            .clip(CircleShape)
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            tint = neon.accent,
            modifier = Modifier.size(22.dp),
        )
    }
}
