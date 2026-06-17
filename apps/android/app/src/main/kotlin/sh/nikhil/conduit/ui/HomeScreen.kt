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
import androidx.compose.material.icons.filled.CloudOff
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberSwipeToDismissBoxState
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
import androidx.compose.ui.draw.alpha
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
import androidx.compose.material3.CircularProgressIndicator
import sh.nikhil.conduit.BrokerVersionStatus
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.MINIMUM_BROKER_VERSION
import sh.nikhil.conduit.NeedsYouItem
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.VisibleSession
import sh.nikhil.conduit.brokerVersionStatus
import sh.nikhil.conduit.needsYouBanner

/**
 * Conduit-style home screen — shown when no session is selected, in
 * place of `EmptyDetail`. Top row (settings · title · list) +
 * ServerTabsStrip + sessions list + BottomActionBar (mic / + / search).
 * Mirrors `apps/ios/Sources/Views/HomeView.swift`.
 */
@OptIn(ExperimentalFoundationApi::class, ExperimentalMaterial3Api::class)
@Composable
fun HomeScreen(
    store: SessionStore,
    onOpenSettings: () -> Unit,
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
    // Opens the onboarding guide from the no-boxes CTA. Default no-op so
    // existing call sites compile without change.
    onOpenOnboarding: () -> Unit = {},
) {
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val sessions by store.sessions.collectAsState()
    val sessionBox by store.sessionBox.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    // Collected so a row's friendly name recomposes the moment the first
    // user message lands in the conversation log.
    val conversationLog by store.conversationLog.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val selectedId by store.selectedId.collectAsState()
    // visibleSessions() merges real sessions + Creating placeholders so the
    // phone home mirrors the tablet rail's in-flight feedback.
    val visible = remember(sessions, lifecycle) { store.visibleSessions() }
    val sessionCreationError by store.sessionCreationError.collectAsState()
    // Broker-update banner (parity with ProjectListScreen + iOS HomeView):
    // shown on both phone and tablet so the update prompt is never lost on
    // the tablet path where the phone drawer (ProjectListScreen) is absent.
    val brokerReadiness by store.brokerReadiness.collectAsState()

    // Pending exit target for the session-row long-press confirmation.
    // Mirror of iOS PR #128's `pendingDelete` on ConduitHomeView — we
    // keep the title alongside the id so the prompt can name the
    // session being ended without re-resolving displayNames.
    var pendingDelete by remember { mutableStateOf<SessionDeleteTarget?>(null) }
    // SSH re-bootstrap sheet (same pattern as ProjectListScreen).
    var showSshReBoot by remember { mutableStateOf(false) }
    // Fix 2: snackbar for archive failures.
    val snackbarHostState = remember { SnackbarHostState() }
    val archiveError by store.archiveError.collectAsState()
    LaunchedEffect(archiveError) {
        val err = archiveError ?: return@LaunchedEffect
        Telemetry.breadcrumb("session", "archive error surfaced", mapOf("error" to err))
        snackbarHostState.showSnackbar(err)
        store.clearArchiveError()
    }
    LaunchedEffect(sessionCreationError) {
        val err = sessionCreationError ?: return@LaunchedEffect
        Telemetry.breadcrumb("session", "creation error surfaced on home", mapOf("error" to err))
        snackbarHostState.showSnackbar(err)
        store.clearSessionCreationError()
    }
    // Fix 4: rename dialog state.
    var renameTarget by remember { mutableStateOf<SavedServer?>(null) }
    var renameDraft by remember { mutableStateOf("") }
    // Fix 4: reachability state for non-active saved servers. Probed once per
    // composition via GET <endpoint>/api/capabilities with a short timeout.
    // null = not yet probed, true = reachable, false = offline.
    val reachabilityMap = remember { mutableStateMapOf<String, Boolean>() }
    val scope = rememberCoroutineScope()
    val endpoint_ by store.endpoint.collectAsState()
    LaunchedEffect(savedServers) {
        savedServers.forEach { server ->
            if (server.endpoint == endpoint_) return@forEach // active box uses harness state
            // v151 ITEM C: SSH boxes persist a loopback ws://127.0.0.1:<port> that
            // only listens while THAT box's russh tunnel is up. Probing it at rest
            // always fails -> misleading "offline". Skip the probe; the row renders
            // a neutral "SSH - tap Connect" instead.
            if (server.ssh != null) return@forEach
            if (reachabilityMap.containsKey(server.id)) return@forEach // already probed
            scope.launch(Dispatchers.IO) {
                val reachable = withTimeoutOrNull(4_000L) {
                    runCatching {
                        val base = server.endpoint.httpBaseUrl ?: return@runCatching false
                        val conn = java.net.URL("$base/api/capabilities").openConnection() as java.net.HttpURLConnection
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
                    Telemetry.breadcrumb("boxes", "reachability probe offline", mapOf("server" to server.name))
                }
            }
        }
    }

    val neon = LocalNeonTheme.current

    // Read real insets top AND bottom (design handoff §4.1): statusBarsPadding
    // keeps the header off the status bar; navigationBarsPadding keeps the
    // bottom action bar + BOXES off the gesture pill / 3-button nav. The app is
    // edge-to-edge (the chat composer already does this), so without it the home
    // footer collided with the system nav.
    Box(modifier = Modifier.fillMaxSize()) {
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
            // Trailing slot carries History (cross-server, includes archived).
            // The legacy live-sessions side drawer was removed (user feedback
            // 2026-06-16): Home already lists active/archived sessions, the
            // BOXES section, and the broker-update banner, so the drawer was
            // redundant. Matches iOS, whose home view IS the live list.
            CircleIconButton(Icons.Default.History, "History", onClick = onOpenHistory)
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

        // Broker-update banner (parity: iOS HomeView shows it for all form
        // factors; on Android the phone drawer has it in ProjectListScreen
        // but the tablet never showed it — this surfaces it on HomeScreen so
        // the tablet path is covered too). Same guard logic as ProjectListScreen.
        brokerReadiness?.brokerVersion?.let { bv ->
            val vStatus = brokerVersionStatus(bv, MINIMUM_BROKER_VERSION)
            if (vStatus is BrokerVersionStatus.UpdateAvailable) {
                val sshPaired = endpoint.url.contains("127.0.0.1")
                Spacer(Modifier.height(8.dp))
                BrokerUpdateBanner(
                    brokerVersion = bv,
                    isSshPaired = sshPaired,
                    onRebootstrap = { showSshReBoot = true },
                    modifier = Modifier.padding(horizontal = 14.dp),
                )
            }
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
            val hasCreating = visible.any { it is VisibleSession.Creating }
            if (sessions.isEmpty() && !hasCreating) {
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
                    // Current box ID for cross-box detection. Mirrors iOS
                    // SessionStore.savedHistoryServerID, which returns the
                    // UUID of the connected box (or host string as fallback).
                    val currentBoxId = remember(savedServers, endpoint) {
                        savedServers.firstOrNull { it.endpoint == endpoint }?.id
                            ?: endpoint.displayHost
                    }
                    // Creating placeholders at the TOP of the list (phone parity
                    // with tablet rail + iOS "Starting session..." row).
                    visible.filterIsInstance<VisibleSession.Creating>().forEach { _ ->
                        CreatingSessionRow(neon = neon)
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
                        // Box-scoped session: determine if this session is on
                        // the currently connected box. Sessions stamped to
                        // another box are dimmed + show a box-name badge.
                        // Tapping a cross-box session switches boxes first.
                        val stampedBoxId = sessionBox[session.id]
                        val isCurrentBox = stampedBoxId == null || stampedBoxId == currentBoxId
                        val crossBoxServer = if (!isCurrentBox) {
                            savedServers.firstOrNull { it.id == stampedBoxId }
                        } else null
                        val crossBoxName = crossBoxServer?.name ?: stampedBoxId
                        // Box-name badge for EVERY active row (removes the
                        // "which session belongs to which box" ambiguity): the
                        // stamped box's name, falling back to the current box
                        // when unstamped. Cross-box rows still tint with accent
                        // (+ dimming above); current-box rows show a quieter
                        // capsule. Mirrors the iOS de-suppression.
                        val rowBoxId = stampedBoxId ?: currentBoxId
                        val rowBoxName = savedServers.firstOrNull { it.id == rowBoxId }?.name
                            ?: crossBoxName
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
                        // Fix 2: swipe-left to archive (iOS .swipeActions parity).
                        // The dismiss state resets after the confirm dialog dismisses
                        // so the row snaps back if the user cancels.
                        val swipeState = rememberSwipeToDismissBoxState(
                            confirmValueChange = { value ->
                                if (value == SwipeToDismissBoxValue.EndToStart) {
                                    pendingDelete = SessionDeleteTarget(session.id, rowTitle)
                                }
                                false // never auto-dismiss; the dialog handles it
                            },
                        )
                        SwipeToDismissBox(
                            state = swipeState,
                            enableDismissFromStartToEnd = false,
                            enableDismissFromEndToStart = true,
                            backgroundContent = {
                                // Red "Archive" reveal background (trailing swipe)
                                Box(
                                    modifier = Modifier
                                        .fillMaxSize()
                                        .background(neon.red.copy(alpha = 0.85f), rowShape)
                                        .padding(horizontal = 20.dp),
                                    contentAlignment = Alignment.CenterEnd,
                                ) {
                                    Text(
                                        "Archive",
                                        color = neon.accentText,
                                        fontFamily = neon.sans,
                                        fontWeight = androidx.compose.ui.text.font.FontWeight.SemiBold,
                                    )
                                }
                            },
                        ) {
                        Box(
                            modifier = Modifier
                                .fillMaxWidth()
                                .alpha(if (isCurrentBox) 1f else 0.55f)
                                // OPAQUE fill (surfaceSolid, not the translucent
                                // `surface`): the SwipeToDismissBox renders the
                                // red Archive reveal (neon.red #FF5C72 coral)
                                // behind the FULL row, and a translucent card
                                // lets it bleed through — navy@66% over coral
                                // composites to a muddy purple/magenta wash over
                                // the whole card during swipe (device feedback).
                                // An opaque fill keeps the red in the swiped gap
                                // only; the card body stays navy.
                                .neonCardSurface(
                                    neon = neon,
                                    shape = rowShape,
                                    fill = neon.surfaceSolid,
                                    borderColor = if (isSelected) agentTint.copy(alpha = 0.7f) else neon.border,
                                    glowTint = if (isSelected) agentTint else null,
                                )
                                .combinedClickable(
                                    onClick = {
                                        if (isCurrentBox) {
                                            store.select(session.id)
                                        } else {
                                            // Cross-box tap: switch to the
                                            // session's box first, then select
                                            // the session. Mirrors iOS
                                            // store.selectSavedServer + selectedSessionID.
                                            Telemetry.breadcrumb(
                                                "session",
                                                "cross_box_tap_switch",
                                                mapOf(
                                                    "session_id" to session.id,
                                                    "target_box" to (stampedBoxId ?: ""),
                                                ),
                                            )
                                            crossBoxServer?.let { store.selectSavedServer(it.id, autoConnect = true) }
                                            store.select(session.id)
                                        }
                                    },
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
                                    val rowStatus = statuses[session.id]
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
                                        gitBranch = rowStatus?.gitBranch?.takeIf { it.isNotBlank() }
                                            ?: session.gitBranch?.takeIf { it.isNotBlank() },
                                        gitDirty = rowStatus?.gitDirty ?: session.gitDirty,
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
                                    // Box-name badge on EVERY row so each active
                                    // session shows which box it belongs to.
                                    // Cross-box rows use the accent tint; the
                                    // current box uses a quieter dim tint.
                                    // Mirrors iOS HomeRowView box-name capsule.
                                    if (rowBoxName != null) {
                                        val badgeTint = if (isCurrentBox) neon.textDim else neon.accent
                                        Row(
                                            verticalAlignment = Alignment.CenterVertically,
                                            horizontalArrangement = Arrangement.spacedBy(4.dp),
                                        ) {
                                            Icon(
                                                Icons.Filled.Storage,
                                                contentDescription = null,
                                                modifier = Modifier.size(9.dp),
                                                tint = badgeTint,
                                            )
                                            Text(
                                                rowBoxName,
                                                style = MaterialTheme.typography.labelSmall,
                                                fontFamily = neon.mono,
                                                fontWeight = FontWeight.SemiBold,
                                                color = badgeTint,
                                                maxLines = 1,
                                                overflow = TextOverflow.Ellipsis,
                                                modifier = Modifier
                                                    .background(
                                                        badgeTint.copy(alpha = 0.12f),
                                                        RoundedCornerShape(50),
                                                    )
                                                    .padding(horizontal = 5.dp, vertical = 2.dp),
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        } // end SwipeToDismissBox content
                    }
                }
            }
        }

        // No-boxes CTA: surface the onboarding guide for first-run users
        // who land here without any paired boxes.
        if (savedServers.isEmpty()) {
            Column(modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp)) {
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
                Spacer(Modifier.height(8.dp))
                // No-boxes CTA card.
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(
                            neon = neon,
                            shape = RoundedCornerShape(12.dp),
                            fill = neon.accent.copy(alpha = 0.07f),
                            borderColor = neon.accent.copy(alpha = 0.27f),
                            glowTint = neon.accent,
                        )
                        .clickable {
                            Telemetry.breadcrumb("home", "no_boxes_cta_tapped")
                            onOpenOnboarding()
                        }
                        .padding(horizontal = 13.dp, vertical = 9.dp),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(11.dp),
                ) {
                    Box(
                        modifier = Modifier.size(34.dp).background(neon.accent.copy(alpha = 0.14f), RoundedCornerShape(9.dp)),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(Icons.Default.AutoAwesome, null, modifier = Modifier.size(18.dp), tint = neon.accent)
                    }
                    Column(modifier = Modifier.weight(1f)) {
                        Text(
                            "New here? See how it works",
                            style = MaterialTheme.typography.titleSmall,
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            color = neon.text,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                        Text(
                            "Add a box to start running agents on your machines",
                            fontFamily = neon.mono,
                            fontSize = 10.5.sp,
                            color = neon.textDim,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                    Text(
                        "Open guide",
                        style = MaterialTheme.typography.titleSmall,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.accentText,
                        modifier = Modifier
                            .background(neon.accent, RoundedCornerShape(50))
                            .padding(horizontal = 11.dp, vertical = 6.dp),
                    )
                }
            }
            Spacer(Modifier.height(10.dp))
        }

        // BOXES — one row per saved machine, connected pinned first + ACTIVE
        // badge; folds in the old connection status card (design handoff §3a:
        // one machine = one row). Sits below the sessions, above the action bar
        // (canonical order: usage strip → active sessions → boxes). No quota
        // here — plan limits are per-account (§3b), not per box.
        if (savedServers.isNotEmpty()) {
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
                boxes.forEach { server ->
                    // Per-box count: only sessions attributed to THIS box (by
                    // stable stamp) and live — not the whole mixed list. Keyed
                    // on the collected session/stamp/status state so it
                    // recomposes as sessions come and go on any box.
                    val boxSessionCount = remember(server.id, sessions, sessionBox, statuses) {
                        store.liveSessionCount(server.id)
                    }
                    HomeBoxRow(
                        neon = neon,
                        server = server,
                        isActive = server.endpoint == endpoint,
                        harness = harness,
                        sessionCount = boxSessionCount,
                        // Fix 4: non-active reachability from probe.
                        reachable = reachabilityMap[server.id],
                        onClick = { onOpenBoxHealth(server) },
                        // Long-press to rename (kept as a secondary path).
                        onLongClick = {
                            renameTarget = server
                            renameDraft = server.name
                        },
                        // Discoverable rename: overflow (3-dot) menu -> Rename.
                        // Mirrors iOS Settings box rename (ConduitSettingsView).
                        onRename = {
                            renameTarget = server
                            renameDraft = server.name
                        },
                        // Fix 4: per-row Connect (switches to this box).
                        onConnect = {
                            Telemetry.breadcrumb("boxes", "connect tapped", mapOf("server" to server.name))
                            store.selectSavedServer(server.id, autoConnect = true)
                        },
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
    // Fix 2: snackbar overlay for archive failures (e.g. network error after
    // optimistic removal). Floats above the session list content.
    SnackbarHost(
        hostState = snackbarHostState,
        modifier = Modifier.align(Alignment.BottomCenter).navigationBarsPadding(),
    )
    } // end Box

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

    if (showSshReBoot) {
        SSHLoginSheet(store = store, onDismiss = { showSshReBoot = false })
    }

    // Fix 4: rename dialog — long-press on a box row.
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

/**
 * A paired-machine ("box") row on Home: tinted server glyph, name, endpoint
 * sub, and a status word. The active (connected) machine is pinned first and
 * styled active — an `ACTIVE` badge + `connected` and a green-tinted surface —
 * folding in what used to be a separate connection status card (design handoff
 * §3a). Mirrors iOS `ConduitHomeView.boxRow`. Never shows quota: plan limits are
 * per-account (§3b), surfaced via the usage strip, not per box.
 */
/**
 * A paired-machine ("box") row on Home. Fix 4: supports long-press rename,
 * per-row Connect (switches to the box), and reachability probe for non-active
 * boxes (null = not yet probed). Active box reads harness state; others read
 * the probe result.
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun HomeBoxRow(
    neon: NeonTheme,
    server: SavedServer,
    isActive: Boolean,
    harness: HarnessState,
    sessionCount: Int,
    // Fix 4: reachability probe result for non-active boxes; null = pending.
    reachable: Boolean? = null,
    onClick: () -> Unit,
    // Fix 4: long-press opens rename dialog (secondary path).
    onLongClick: () -> Unit = {},
    // Discoverable rename via the overflow (3-dot) menu.
    onRename: () -> Unit = {},
    // Fix 4: per-row Connect switches to this box.
    onConnect: () -> Unit = {},
) {
    var menuOpen by remember { mutableStateOf(false) }
    val connected = isActive && (harness is HarnessState.Live || harness is HarnessState.Linked)
    // Real per-box session count suffix — shown for any box that has live
    // sessions attributed to it, so non-active boxes surface their count too.
    val countSuffix = if (sessionCount > 0) {
        " · $sessionCount ${if (sessionCount == 1) "session" else "sessions"}"
    } else ""
    val (statusText, statusColor) = when {
        isActive && connected -> "connected$countSuffix" to neon.green
        isActive && harness is HarnessState.Connecting -> "connecting…" to neon.yellow
        isActive && harness is HarnessState.Reconnecting -> "reconnecting…" to neon.yellow
        isActive -> "offline" to neon.textFaint
        // v151 ITEM C: SSH/tunnel boxes have no at-rest reachability (loopback
        // listens only while connected). Show a neutral cue + keep Connect rather
        // than a misleading "offline".
        server.ssh != null -> "SSH · tap Connect$countSuffix" to neon.textFaint
        reachable == null -> "probing…" to neon.textFaint
        reachable == true -> "reachable$countSuffix" to neon.green
        else -> "offline$countSuffix" to neon.textFaint
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
            .combinedClickable(onClick = onClick, onLongClick = onLongClick)
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
                server.ssh?.let { "${it.host}:${it.port}" } ?: server.endpoint.displayHost,
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
        } else {
            // Fix 4: per-row Connect button for non-active boxes.
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
        Box(modifier = Modifier.size(6.dp).background(statusColor, CircleShape))
        Text(
            statusText,
            style = MaterialTheme.typography.labelSmall,
            fontFamily = neon.mono,
            color = statusColor,
        )
        // Discoverable affordance: an overflow (3-dot) menu with Rename. The
        // long-press path is undiscoverable on its own (user feedback
        // 2026-06-16); this surfaces rename as a visible control. Mirrors iOS
        // Settings box rename.
        Box {
            IconButton(onClick = { menuOpen = true }, modifier = Modifier.size(28.dp)) {
                Icon(
                    Icons.Filled.MoreVert,
                    contentDescription = "Box options",
                    modifier = Modifier.size(18.dp),
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
 * Placeholder card shown at the TOP of the phone home session list while a
 * new session is being created (WS round-trip in flight). Matches the tablet
 * rail's Creating row (ProjectListScreen.kt:506-511) and iOS
 * "Starting session..." visual treatment — neon.accent spinner + mono label.
 */
@Composable
private fun CreatingSessionRow(neon: NeonTheme, modifier: Modifier = Modifier) {
    val rowShape = RoundedCornerShape(ConduitHomeRowMetrics.cardCornerRadius.dp)
    Box(
        modifier = modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = rowShape,
                fill = neon.surface,
                borderColor = neon.accent.copy(alpha = 0.4f),
                glowTint = neon.accent,
            ),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
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
}

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
    gitBranch: String? = null,
    gitDirty: UInt? = null,
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
        // Live git branch + dirty dot. Hidden when branch is unknown
        // (old broker or non-git workspace).
        if (!gitBranch.isNullOrBlank()) {
            Text("·", style = MaterialTheme.typography.labelSmall, color = neon.textFaint)
            val branchLabel = if ((gitDirty ?: 0u) > 0u) "$gitBranch ●$gitDirty" else gitBranch
            Text(
                branchLabel,
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                color = neon.textDim,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
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
