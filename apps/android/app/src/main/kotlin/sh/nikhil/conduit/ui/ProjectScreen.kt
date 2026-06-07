package sh.nikhil.conduit.ui

import android.content.Intent
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import kotlinx.coroutines.launch
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SessionLifecycle
import sh.nikhil.conduit.SessionStore
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

// Order matches the design TabBar and iOS (`[chat, terminal, browser]`):
// Chat first, so a session lands on the conversation, not the raw terminal.
enum class ProjectTab(val label: String) { Chat("Chat"), Terminal("Terminal"), Browser("Browser") }

/**
 * Conduit Round-2 header (Android mirror of
 * `apps/ios/Sources/ConduitUI/Views/ConduitProjectView.swift`, handoff
 * images 01→02).
 *
 * Two rows wrapped in a single `glassRoundedRect` surface:
 *  - Row 1 [ControlsRow]: drawer toggle (phone) · identity title block
 *    (agent avatar · session name ▾ · mono `● agent · repo · branch`) ·
 *    one ⓘ. The identity block opens the title menu (identity header +
 *    Rename / Refresh / Export transcript / End session).
 *  - Row 2 [TabPickerRow]: Terminal / Chat / Browser tab picker.
 *
 * The old separate path row is gone — its information lives on the
 * identity block's context line. Pure data structure factored into
 * [ProjectHeaderModel] for unit tests — the rendered view body references
 * the same computed values (`identity`) so drift between the model and
 * the surface is loud.
 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ProjectScreen(
    store: SessionStore,
    session: ProjectSession,
    onOpenDrawer: () -> Unit,
    // Tablet 3-pane centre: chat only (no tab strip); Terminal/Browser/
    // Info live in the sibling NeonTabletRightPane. Phone/default = tabs.
    chatOnly: Boolean = false,
) {
    // `shell` sessions (Box health → Shell: the broker's hidden bash
    // adapter) are pure terminals — land on the Terminal tab instead of
    // Chat. Mirrors iOS `ProjectView.init`.
    val pagerState = rememberPagerState(
        initialPage = if (session.assistant.equals("shell", ignoreCase = true)) ProjectTab.Terminal.ordinal else 0,
        pageCount = { ProjectTab.entries.size },
    )
    val statuses by store.statusBySession.collectAsState()
    val lifecycleMap by store.sessionLifecycle.collectAsState()
    val status = statuses[session.id]
    val lifecycle = lifecycleMap[session.id]
    // READ-ONLY IS THE DEFAULT: a session is interactive only when the
    // store can positively confirm it is *currently live on the broker*
    // (a non-terminal lifecycle AND a running status phase). Everything
    // else — exited, failed, recovered-but-not-running, archived, or a
    // stale row we merely listed without a fresh running status — is
    // read-only, so we collapse the detail to the chat log alone: hide
    // the Terminal/Chat/Browser tab strip, the terminal extra-keys row,
    // and the in-session dock, and render `ChatPage` with no composer
    // (per the user's request: "clicking on archived session should just
    // show me the chat log"). Live sessions keep the full tab strip +
    // interactive surfaces. Reading `lifecycle`/`status` above keeps this
    // recomposing on the same flows, so a session that exits *while* open
    // collapses live. Mirrors iOS `ProjectView.isReadOnly` /
    // `SessionStore.isReadOnly` after PR #214.
    val isReadOnly = run {
        // Touch the observed values so recomposition tracks them; the
        // authoritative decision lives in the store's classifier.
        lifecycle; status
        store.isReadOnly(session.id)
    }
    var menuExpanded by remember { mutableStateOf(false) }
    var browserMode by remember { mutableStateOf(BrowserMode.Preview) }
    var showInfo by remember { mutableStateOf(false) }
    var showDiff by remember { mutableStateOf(false) }
    var showThreadSwitcher by remember { mutableStateOf(false) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    // Title-menu flows (Round-2 fix 2): rename dialog + End-session confirm.
    var showRename by remember { mutableStateOf(false) }
    var renameDraft by remember { mutableStateOf("") }
    var showEndConfirm by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()
    val context = androidx.compose.ui.platform.LocalContext.current

    val displayNames by store.displayNames.collectAsState()
    val modelAliases by store.modelBySession.collectAsState()
    // Whether the session has changes worth reviewing — gates the title
    // menu's "View changes" row. Reuses the exact signal the Diff surface
    // itself uses: a session-level linesAdded/Removed rollup, or a parseable
    // kind == "diff" item in the conversation log.
    val conversationLog by store.conversationLog.collectAsState()
    val hasChanges = remember(session, conversationLog) {
        (session.linesAdded?.toInt() ?: 0) > 0 ||
            (session.linesRemoved?.toInt() ?: 0) > 0 ||
            DiffReviewStats.hasInlineDiff(conversationLog[session.id].orEmpty())
    }

    // Friendly session title for the identity block — same resolution the
    // drawer rows / voice screen use (custom rename → broker displayName →
    // first user message → fallback).
    val headerTitle = remember(session, displayNames, conversationLog) {
        sh.nikhil.conduit.SessionNaming.friendlyFor(
            session = session,
            custom = displayNames[session.id],
            firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(conversationLog[session.id]),
        )
    }
    val headerModel = remember(session, status, lifecycle, headerTitle, modelAliases) {
        ProjectHeaderModel.from(
            session = session,
            status = status,
            lifecycleLabel = ProjectHeaderModel.lifecycleLabel(lifecycle),
            title = headerTitle,
            modelAlias = modelAliases[session.id],
        )
    }
    val agentAccent = neonAgentColor(session.assistant, LocalNeonTheme.current)
    val appearance = LocalAppearanceStore.current
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    // Map the active tab → InSessionContext so the dock knows whether
    // the centre mic FAB should route to voice or surface a toast.
    val activeContext = if (chatOnly) InSessionContext.Chat else InSessionContext.fromTab(ProjectTab.entries[pagerState.currentPage])

    // Device feedback v0.0.49 #3 (Android parity): clear focus + hide the
    // soft keyboard on every tab change. Without this, swiping/tapping
    // Terminal → Chat could leave the keyboard up (raised by the terminal
    // surface) so it covered the chat composer on return — the Android
    // analog of iOS device bug #31. The chat composer's `imePadding()`
    // re-lifts it the moment the user taps the field again.
    val focusManager = androidx.compose.ui.platform.LocalFocusManager.current
    val keyboardController = androidx.compose.ui.platform.LocalSoftwareKeyboardController.current
    LaunchedEffect(pagerState.currentPage) {
        focusManager.clearFocus(force = true)
        keyboardController?.hide()
    }

    Column(modifier = Modifier.fillMaxSize().statusBarsPadding().padding(horizontal = 10.dp).padding(top = 8.dp)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .glassRoundedRect()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ControlsRow(
                model = headerModel,
                chatOnly = chatOnly,
                agentAccent = agentAccent,
                menuExpanded = menuExpanded,
                onTitleTap = { menuExpanded = true },
                onMenuDismiss = { menuExpanded = false },
                onRename = {
                    menuExpanded = false
                    renameDraft = headerTitle
                    showRename = true
                },
                onReconnect = { menuExpanded = false; store.reconnect() },
                onExportTranscript = {
                    menuExpanded = false
                    // Same share path as Session Info's Export pill — the
                    // identical transcript markdown via the shared builder.
                    val transcript = buildTranscriptMarkdown(
                        headerTitle,
                        session.assistant,
                        session.branch,
                        conversationLog[session.id].orEmpty(),
                    )
                    val intent = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, transcript)
                    }
                    context.startActivity(Intent.createChooser(intent, "Export transcript"))
                },
                showChanges = hasChanges,
                onShowChanges = { menuExpanded = false; showDiff = true },
                browserMode = browserMode,
                onToggleMemory = {
                    menuExpanded = false
                    browserMode = if (browserMode == BrowserMode.Memory) BrowserMode.Preview else BrowserMode.Memory
                    scope.launch { pagerState.animateScrollToPage(ProjectTab.Browser.ordinal) }
                },
                onEndSession = { menuExpanded = false; showEndConfirm = true },
                onOpenDrawer = onOpenDrawer,
                onShowInfo = { showInfo = true },
                viewerCount = status?.viewers?.toInt(),
            )

            if (!isReadOnly && !chatOnly) {
                TabPickerRow(
                    selected = pagerState.currentPage,
                    onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } },
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        val neon = LocalNeonTheme.current
        Surface(
            shape = RoundedCornerShape(neon.radiusDp.dp),
            color = neon.surface,
            modifier = Modifier.weight(1f).fillMaxWidth(),
        ) {
            if (isReadOnly) {
                // Read-only: skip the pager (no tab strip to drive it) and
                // render the chat log alone, composer suppressed.
                ChatPage(store, session, readOnly = true)
            } else if (chatOnly) {
                ChatPage(store, session)
            } else {
                HorizontalPager(
                    state = pagerState,
                    modifier = Modifier.fillMaxSize(),
                ) { page ->
                    when (ProjectTab.entries[page]) {
                        ProjectTab.Terminal -> {
                            // Stage 0 of the Android terminal-renderer
                            // rewrite: flag-on = Termux native View
                            // scaffold; flag-off = production xterm.js.
                            // Off by default. See
                            // docs/PLAN-TERMINAL-REWRITE.md (Android).
                            if (experimentalNativeTerminal) {
                                TermuxTerminalView(store, session, modifier = Modifier.fillMaxSize())
                            } else {
                                TerminalPage(store, session)
                            }
                        }
                        ProjectTab.Chat     -> ChatPage(
                            store,
                            session,
                            onOpenTerminal = {
                                scope.launch { pagerState.animateScrollToPage(ProjectTab.Terminal.ordinal) }
                            },
                        )
                        ProjectTab.Browser  -> BrowserPage(store, session, browserMode)
                    }
                }
            }
        }

        // Interactive bottom region (terminal extra-keys + in-session
        // dock) is suppressed for read-only/archived sessions — there's
        // nothing to type into or switch between. It is ALSO suppressed in
        // the tablet `chatOnly` pane: the dock is a phone-only affordance for
        // switching Terminal/Chat/Browser + new-session/voice, but on tablet
        // the right pane already hosts Terminal/Browser/Info and the chat
        // composer carries its own mic/send — so the floating dock would just
        // hang, phone-styled, below the composer (device bug: "doesn't look
        // like tablet design below the keyboard").
        if (!isReadOnly && !chatOnly) {
            // Terminal extra-keys row — Android mirror of iOS
            // `TerminalAccessoryBar` (which iOS hosts via
            // `inputAccessoryView`). Android has no input-accessory hook,
            // so we float the same scrollable key row above the keyboard
            // ourselves, only on the Terminal tab. It sits directly above
            // the in-session dock in the Column, and the dock's own
            // `imePadding()` lifts this whole bottom region above the soft
            // keyboard — so this row needs no `imePadding` of its own (that
            // would double-count the inset). Bytes route through the same
            // `store.sendInput` path as keyboard input.
            if (activeContext == InSessionContext.Terminal) {
                TerminalAccessoryBar(
                    onSend = { bytes -> store.sendInput(session.id, bytes) },
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            // No floating in-session dock: the design and iOS have none in
            // session detail (device feedback: "make it match design + iOS").
            // Its functions live on the same surfaces iOS uses — voice is the
            // composer's inline mic, and new-session / parallel-session
            // switching are the session drawer (the list IS the switcher).
            // Only the Terminal extra-keys row (above) survives, which the
            // design's AccessoryBar also shows.
        }
    }

    if (showInfo) {
        SessionInfoScreen(store = store, session = session, onDismiss = { showInfo = false })
    }

    // Title-menu Rename (fix 2) — same local-rename semantics as Session
    // Info's dialog (store.renameSession; the broker name stays).
    if (showRename) {
        AlertDialog(
            onDismissRequest = { showRename = false },
            title = { Text("Rename session") },
            text = {
                OutlinedTextField(
                    value = renameDraft,
                    onValueChange = { renameDraft = it },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth(),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        store.renameSession(session.id, renameDraft.trim())
                        showRename = false
                    },
                    enabled = renameDraft.trim().isNotEmpty(),
                ) { Text("Rename") }
            },
            dismissButton = {
                TextButton(onClick = { showRename = false }) { Text("Cancel") }
            },
        )
    }

    // Title-menu End session (fix 2) — confirmed, destructive. Same
    // archive semantics as the Home swipe action.
    if (showEndConfirm) {
        AlertDialog(
            onDismissRequest = { showEndConfirm = false },
            title = { Text("End this session?") },
            text = { Text("The agent stops and the box is released. The transcript stays in History.") },
            confirmButton = {
                TextButton(onClick = {
                    showEndConfirm = false
                    store.archive(session.id)
                }) { Text("End session") }
            },
            dismissButton = {
                TextButton(onClick = { showEndConfirm = false }) { Text("Cancel") }
            },
        )
    }

    if (showDiff) {
        // Diff review for this session. Commit/PR CTAs stay default no-ops —
        // no backend action exists yet.
        DiffReviewScreen(store = store, session = session, onDismiss = { showDiff = false })
    }

    if (showThreadSwitcher) {
        ThreadSwitcherSheet(
            store = store,
            activeSession = session,
            onDismiss = { showThreadSwitcher = false },
            onNewSession = { showAgentPicker = true },
        )
    }

    if (showAgentPicker) {
        AgentPickerSheet(
            store = store,
            headerNote = null,
            onDismiss = { showAgentPicker = false },
        )
    }

    if (showVoice) {
        VoiceDictationScreen(
            onTranscript = { transcript -> store.sendChat(session.id, transcript) },
            onDismiss = { showVoice = false },
            agent = session.assistant,
            // Same friendly-name resolution as the identity block.
            sessionName = headerTitle,
        )
    }
}

/**
 * Single-row header (Round-2 fix 1, Conduit_Fixes_Handoff images 01→02):
 * drawer toggle (phone) · identity title block (agent avatar · session
 * name ▾ · mono `● agent · repo · branch`) · one ⓘ. The identity block is
 * the title-menu trigger (fix 2). Fork / Refresh / memory / changes are
 * NOT header circles anymore — Refresh, Export, View changes and the
 * memory toggle live in the title menu; Fork is its own flow in Session
 * Info. The old full-width path row is folded into the identity line.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ControlsRow(
    model: ProjectHeaderModel,
    chatOnly: Boolean = false,
    agentAccent: androidx.compose.ui.graphics.Color,
    menuExpanded: Boolean,
    onTitleTap: () -> Unit,
    onMenuDismiss: () -> Unit,
    onRename: () -> Unit,
    onReconnect: () -> Unit,
    onExportTranscript: () -> Unit,
    showChanges: Boolean = false,
    onShowChanges: () -> Unit = {},
    browserMode: BrowserMode,
    onToggleMemory: () -> Unit,
    onEndSession: () -> Unit,
    onOpenDrawer: () -> Unit,
    onShowInfo: () -> Unit,
    viewerCount: Int?,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        // Tablet 3-pane centre (chatOnly): the sessions rail is already
        // pinned on the left, so the drawer toggle is a dead button here —
        // hide it. Phone keeps it (the drawer is the only way to the rail).
        if (!chatOnly) {
            HeaderCircleButton(icon = Icons.Default.Menu, contentDescription = "Sessions", onClick = onOpenDrawer)
        }

        Box(modifier = Modifier.weight(1f)) {
            IdentityBlock(
                identity = model.identity,
                accent = agentAccent,
                onTap = onTitleTap,
            )
            DropdownMenu(expanded = menuExpanded, onDismissRequest = onMenuDismiss) {
                // Identity header (fix 2): agent avatar + agent name + the
                // honest model line, plus a mono repo·branch sub-line. No
                // more "Agent: claude / Model: claude".
                Column(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 10.dp),
                    verticalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(10.dp),
                    ) {
                        Box(
                            modifier = Modifier
                                .size(38.dp)
                                .background(agentAccent.copy(alpha = 0.14f), RoundedCornerShape(10.dp))
                                .border(1.dp, agentAccent.copy(alpha = 0.35f), RoundedCornerShape(10.dp)),
                            contentAlignment = Alignment.Center,
                        ) {
                            ConduitMark(size = 22.dp, color = agentAccent)
                        }
                        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                model.identity.agentDisplayName,
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.Bold,
                                fontSize = 15.sp,
                                color = neon.text,
                            )
                            Text(
                                model.identity.modelLabel,
                                fontFamily = neon.mono,
                                fontSize = 11.5.sp,
                                color = neon.textDim,
                            )
                        }
                    }
                    model.identity.contextLine?.let { contextLine ->
                        Text(
                            contextLine,
                            fontFamily = neon.mono,
                            fontSize = 11.sp,
                            color = neon.textFaint,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                        )
                    }
                }
                HorizontalDivider()
                DropdownMenuItem(text = { Text("Rename") }, onClick = onRename)
                DropdownMenuItem(text = { Text("Refresh") }, onClick = onReconnect)
                DropdownMenuItem(text = { Text("Export transcript") }, onClick = onExportTranscript)
                // Diff review + the browser memory toggle keep entry points
                // after losing their header circles (fix 1 allows only
                // drawer · identity · ⓘ up top). Hidden in the tablet
                // chat-only pane, where the right pane owns those surfaces.
                if (!chatOnly && showChanges) {
                    DropdownMenuItem(text = { Text("View changes") }, onClick = onShowChanges)
                }
                if (!chatOnly) {
                    DropdownMenuItem(
                        text = { Text(if (browserMode == BrowserMode.Memory) "Live preview" else "Session memory") },
                        onClick = onToggleMemory,
                    )
                }
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("End session", color = neon.red) },
                    onClick = onEndSession,
                )
            }
        }

        // sweswe-parity multi-viewer hint. Renders to nothing when count is
        // null / 0 / 1 — see ViewerCountBadge.
        ViewerCountBadge(count = viewerCount)

        // ONE trailing ⓘ → Session Info (hidden on tablet chat-only, where
        // the right pane owns Info).
        if (!chatOnly) {
            HeaderCircleButton(icon = Icons.Outlined.Info, contentDescription = "Session info", onClick = onShowInfo)
        }
    }
}

/**
 * Identity title block — THE title-menu trigger (fix 1/2): agent avatar
 * (daemon mark, agent-tinted rounded square) beside the session name with
 * a caret, over a one-line mono status: `● agent · repo · branch`.
 */
@Composable
private fun IdentityBlock(
    identity: ProjectHeaderModel.Identity,
    accent: androidx.compose.ui.graphics.Color,
    onTap: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Row(
        modifier = Modifier
            .clickable(onClick = onTap)
            .padding(vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(9.dp),
    ) {
        Box(
            modifier = Modifier
                .size(34.dp)
                .background(accent.copy(alpha = 0.14f), RoundedCornerShape(9.dp))
                .border(1.dp, accent.copy(alpha = 0.35f), RoundedCornerShape(9.dp)),
            contentAlignment = Alignment.Center,
        ) {
            ConduitMark(size = 20.dp, color = accent)
        }
        Column(verticalArrangement = Arrangement.spacedBy(1.dp)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                Text(
                    identity.title,
                    style = MaterialTheme.typography.titleSmall,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f, fill = false),
                )
                if (identity.showsChevron) {
                    Icon(
                        Icons.Default.ExpandMore,
                        contentDescription = null,
                        tint = neon.textFaint,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(5.dp),
            ) {
                HealthDot(identity.healthKey, size = 5.dp)
                Text(
                    identity.agentName,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 11.sp,
                    color = accent,
                )
                identity.contextLine?.let { contextLine ->
                    Text(
                        "· $contextLine",
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.textFaint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
    }
}

/**
 * Row 3 — Terminal / Chat / Browser tab picker, wrapped in its own
 * glass surface so it reads as the dominant affordance in the header
 * (plan: "this is the main idea per chat window").
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun TabPickerRow(
    selected: Int,
    onSelect: (Int) -> Unit,
) {
    // Neon underlined top tabs (Android idiom): a transparent TabRow over
    // the header surface, an accent-glow underline indicator on the
    // active tab, and neon-token text/icon tints. The default M3 divider
    // is replaced by a faint neon hairline so the strip reads as one rail.
    // Neon underlined top tabs (Android idiom): a transparent TabRow over
    // the header surface, the default M3 indicator recolored to
    // `neon.accent` (glow on the accent line is approximated by the
    // accent fill + the dark-mode wash behind it — Compose can't easily
    // glow the default indicator), and a faint neon hairline divider so
    // the strip reads as one rail.
    // The default M3 indicator already positions + animates itself under
    // the selected tab; we recolor it (and the tab content) to
    // `neon.accent` via `contentColor`, and replace the default divider
    // with a faint neon hairline so the strip reads as one rail. A
    // hand-rolled offset indicator needs `tabIndicatorOffset`, which isn't
    // exposed in this Compose Material3 version — fidelity gap: the neon
    // glow halo on the underline is not rendered (the accent fill + dark
    // wash behind it approximate the lit underline).
    val neon = LocalNeonTheme.current
    TabRow(
        selectedTabIndex = selected,
        containerColor = androidx.compose.ui.graphics.Color.Transparent,
        contentColor = neon.accent,
        modifier = Modifier.fillMaxWidth(),
        divider = {
            androidx.compose.material3.HorizontalDivider(color = neon.border, thickness = 1.dp)
        },
    ) {
        ProjectTab.entries.forEachIndexed { i, t ->
            val active = selected == i
            Tab(
                selected = active,
                onClick = { onSelect(i) },
                selectedContentColor = neon.accent,
                unselectedContentColor = neon.textDim,
                text = {
                    Text(
                        t.label,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = if (active) neon.accent else neon.textDim,
                    )
                },
                icon = {
                    Icon(
                        when (t) {
                            ProjectTab.Terminal -> Icons.Outlined.Terminal
                            ProjectTab.Chat     -> Icons.AutoMirrored.Outlined.Chat
                            ProjectTab.Browser  -> Icons.Outlined.Public
                        },
                        contentDescription = null,
                        tint = if (active) neon.accent else neon.textDim,
                    )
                },
            )
        }
    }
}

@Composable
private fun HeaderCircleButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit) {
    // `glassCircle` already clips to CircleShape; we add `clickable`
    // after so the ripple respects the rounded edge.
    val neon = LocalNeonTheme.current
    Box(
        modifier = Modifier
            .size(32.dp)
            .glassCircle()
            .clickable(onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(
            icon,
            contentDescription = contentDescription,
            modifier = Modifier.size(16.dp),
            tint = neon.accent,
        )
    }
}

/**
 * Pure-data description of the Round-2 Android header (handoff images
 * 01→02). Lifted out of the `ProjectScreen` composable so unit tests can
 * assert the single-row structure and the identity-block contents without
 * standing up a Compose host. Mirrors the iOS header in
 * `apps/ios/Sources/ConduitUI/Views/ConduitProjectView.swift` — same
 * identity payload, same `repo · branch` context join.
 */
data class ProjectHeaderModel(
    val identity: Identity,
) {
    /** Render order — ONE controls/identity row, then the tab picker.
     *  The old separate path row is gone (fix 1): its information lives
     *  on the identity block's context line. */
    enum class Row { Controls, TabPicker }

    /**
     * Identity title block payload — the whole block is the title-menu
     * trigger: session [title] (+ caret) over `● agent · repo · branch`,
     * plus the agent/model lines the menu's identity header shows.
     */
    data class Identity(
        val healthKey: String,
        /** Friendly session name (custom rename → broker displayName →
         *  first message — resolved by the caller via SessionNaming). */
        val title: String,
        /** Lowercase agent key for the status line ("claude"). */
        val agentName: String,
        /** Menu identity header title ("Claude"). */
        val agentDisplayName: String,
        /** Honest model line: the recorded `--model` alias, else
         *  "default model" (+ effort) — never the agent name repeated. */
        val modelLabel: String,
        /** `repo · branch` (+ exited/failed suffix) — null when unknown. */
        val contextLine: String?,
        val showsChevron: Boolean,
    )

    companion object {
        val rows: List<Row> = listOf(Row.Controls, Row.TabPicker)

        fun from(
            session: ProjectSession,
            status: SessionStatus?,
            lifecycleLabel: String?,
            title: String? = null,
            modelAlias: String? = null,
        ): ProjectHeaderModel {
            // Title precedence: caller-resolved friendly name (rename /
            // AI title / first message) → broker displayName → raw name.
            val resolvedTitle = title?.trim()?.takeIf { it.isNotEmpty() }
                ?: session.displayName?.trim()?.takeIf { it.isNotEmpty() }
                ?: session.name

            // `repo · branch`: the repo is the last path component of the
            // session cwd — the old full-width path row folded down to the
            // bit that identifies the project. An exited/failed lifecycle
            // stays visible as a suffix (honest read-only signal).
            val cwd = status?.cwd?.trim()?.takeIf { it.isNotEmpty() }
                ?: session.cwd?.trim()?.takeIf { it.isNotEmpty() }
            val repo = cwd?.trimEnd('/')?.substringAfterLast('/')?.takeIf { it.isNotEmpty() }
            val contextLine = listOfNotNull(
                repo,
                session.branch?.takeIf { it.isNotBlank() },
                lifecycleLabel,
            ).joinToString(" · ").takeIf { it.isNotEmpty() }

            val effort = session.reasoningEffort?.trim()?.takeIf { it.isNotEmpty() }
            val modelLabel = modelAlias?.trim()?.takeIf { it.isNotEmpty() }
                ?: if (effort != null) "default model · $effort" else "default model"

            return ProjectHeaderModel(
                identity = Identity(
                    healthKey = status?.health ?: "unknown",
                    title = resolvedTitle,
                    agentName = session.assistant.lowercase(),
                    agentDisplayName = when (session.assistant.lowercase()) {
                        "claude" -> "Claude"
                        "codex" -> "Codex"
                        else -> session.assistant.replaceFirstChar { it.uppercase() }
                    },
                    modelLabel = modelLabel,
                    contextLine = contextLine,
                    showsChevron = true,
                ),
            )
        }

        /** Match iOS `lifecycleLabel` — only `exited(N)` / `failed(msg)`
         *  surface; `creating` / `live` / `null` are dropped so the
         *  context line stays terse. */
        fun lifecycleLabel(lifecycle: SessionLifecycle?): String? = when (lifecycle) {
            is SessionLifecycle.Exited        -> "exited(${lifecycle.code})"
            is SessionLifecycle.FailedToStart  -> lifecycle.reason
            else                                -> null
        }
    }
}
