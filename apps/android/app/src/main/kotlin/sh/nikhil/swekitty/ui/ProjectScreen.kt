package sh.nikhil.swekitty.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Chat
import androidx.compose.material.icons.outlined.Info
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import android.widget.Toast
import androidx.compose.ui.platform.LocalContext
import kotlinx.coroutines.launch
import sh.nikhil.swekitty.LocalAppearanceStore
import sh.nikhil.swekitty.SessionLifecycle
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession
import uniffi.swe_kitty_core.SessionStatus

enum class ProjectTab(val label: String) { Terminal("Terminal"), Chat("Chat"), Browser("Browser") }

/**
 * Litter Stage 2 header (Android mirror of `apps/ios/Sources/Views/ProjectView.swift`).
 *
 * Three explicit rows wrapped in a single `glassRoundedRect` surface:
 *  - Row 1 [ControlsRow]: drawer toggle (left) · centered compound agent
 *    dropdown (health dot · agent · reasoning effort · chevron) · memory
 *    toggle + refresh + info (right).
 *  - Row 2 [PathRow]: single-line mono caption joining
 *    `path · branch · running · lifecycle` — middle-truncated, muted.
 *  - Row 3 [TabPickerRow]: Terminal / Chat / Browser tab picker wrapped
 *    in its own glass surface so it reads as the dominant affordance.
 *
 * Pure data structure factored into [ProjectHeaderModel] for unit
 * tests — the rendered view body references the same computed values
 * (`captionLabel`, `agentPill`) so drift between the model and the
 * surface is loud.
 */
@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ProjectScreen(
    store: SessionStore,
    session: ProjectSession,
    onOpenDrawer: () -> Unit,
) {
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { ProjectTab.entries.size })
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
    var showThreadSwitcher by remember { mutableStateOf(false) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    val scope = rememberCoroutineScope()

    val headerModel = remember(session, status, lifecycle) {
        ProjectHeaderModel.from(session, status, ProjectHeaderModel.lifecycleLabel(lifecycle))
    }
    val agentAccent = SweKittyTheme.accent(forAgent = session.assistant)
    val ctx = LocalContext.current
    val appearance = LocalAppearanceStore.current
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    // Map the active tab → InSessionContext so the dock knows whether
    // the centre mic FAB should route to voice or surface a toast.
    val activeContext = InSessionContext.fromTab(ProjectTab.entries[pagerState.currentPage])

    Column(modifier = Modifier.fillMaxSize().padding(horizontal = 10.dp).padding(top = 8.dp)) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .glassRoundedRect()
                .padding(horizontal = 12.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ControlsRow(
                model = headerModel,
                agentAccent = SweKittyTheme.accent(forAgent = session.assistant),
                menuExpanded = menuExpanded,
                onAgentTap = { menuExpanded = true },
                onMenuDismiss = { menuExpanded = false },
                onSwitchToClaude = { menuExpanded = false; store.switchAgent(session.id, "claude") },
                onSwitchToCodex  = { menuExpanded = false; store.switchAgent(session.id, "codex") },
                onEndSession    = { menuExpanded = false; store.archive(session.id) },
                browserMode = browserMode,
                onBrowserModeChange = { browserMode = it },
                onJumpToBrowser = {
                    scope.launch { pagerState.animateScrollToPage(ProjectTab.Browser.ordinal) }
                },
                onOpenDrawer = onOpenDrawer,
                onReconnect = { store.reconnect() },
                onShowInfo = { showInfo = true },
                disableSwitchClaude = session.assistant == "claude",
                disableSwitchCodex = session.assistant == "codex",
                viewerCount = status?.viewers?.toInt(),
            )

            PathRow(model = headerModel)

            if (!isReadOnly) {
                TabPickerRow(
                    selected = pagerState.currentPage,
                    onSelect = { i -> scope.launch { pagerState.animateScrollToPage(i) } },
                )
            }
        }

        Spacer(Modifier.height(10.dp))

        Surface(
            shape = RoundedCornerShape(SweKittyTheme.cardCornerRadiusDp.dp),
            color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.35f),
            modifier = Modifier.weight(1f).fillMaxWidth(),
        ) {
            if (isReadOnly) {
                // Read-only: skip the pager (no tab strip to drive it) and
                // render the chat log alone, composer suppressed.
                ChatPage(store, session, readOnly = true)
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
                                TermuxTerminalView(store, session)
                            } else {
                                TerminalPage(store, session)
                            }
                        }
                        ProjectTab.Chat     -> ChatPage(store, session)
                        ProjectTab.Browser  -> BrowserPage(store, session, browserMode)
                    }
                }
            }
        }

        // Interactive bottom region (terminal extra-keys + in-session
        // dock) is suppressed for read-only/archived sessions — there's
        // nothing to type into or switch between.
        if (!isReadOnly) {
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

            // Persistent in-session dock — mirrors iOS PR #42's
            // `InSessionBottomBar`. `imePadding()` keeps it above the
            // soft keyboard the same way the iOS `safeAreaInset(.bottom)`
            // floats above the keyboard guide.
            InSessionBottomBar(
                context = activeContext,
                onThreads = { showThreadSwitcher = true },
                onVoice = {
                    // v1: chat-only voice; other tabs surface a toast via
                    // the dock's own inline note + a system toast as
                    // backup so the cue is visible even with reduced
                    // motion / animations off.
                    if (activeContext == InSessionContext.Chat) {
                        showVoice = true
                    } else {
                        Toast.makeText(
                            ctx,
                            InSessionBottomBarModel.voiceUnsupportedMessage(activeContext),
                            Toast.LENGTH_SHORT,
                        ).show()
                    }
                },
                onNewSession = { showAgentPicker = true },
                modifier = Modifier
                    .fillMaxWidth()
                    .imePadding()
                    .navigationBarsPadding()
                    .padding(bottom = 4.dp),
            )
        }
    }

    if (showInfo) {
        SessionInfoScreen(store = store, session = session, onDismiss = { showInfo = false })
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
        )
    }
}

/**
 * Row 1 — drawer toggle + centered compound agent dropdown + trailing
 * glass-capsule icon circles. Mirrors `controlsRow` in iOS ProjectView:
 * the agent pill is one compound control (HealthDot · agent · effort ·
 * chevron) rather than four sibling chips.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ControlsRow(
    model: ProjectHeaderModel,
    agentAccent: androidx.compose.ui.graphics.Color,
    menuExpanded: Boolean,
    onAgentTap: () -> Unit,
    onMenuDismiss: () -> Unit,
    onSwitchToClaude: () -> Unit,
    onSwitchToCodex: () -> Unit,
    onEndSession: () -> Unit,
    browserMode: BrowserMode,
    onBrowserModeChange: (BrowserMode) -> Unit,
    onJumpToBrowser: () -> Unit,
    onOpenDrawer: () -> Unit,
    onReconnect: () -> Unit,
    onShowInfo: () -> Unit,
    disableSwitchClaude: Boolean,
    disableSwitchCodex: Boolean,
    viewerCount: Int?,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        HeaderCircleButton(icon = Icons.Default.Menu, contentDescription = "Sessions", onClick = onOpenDrawer)

        Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.Center) {
            AgentPill(
                pill = model.agentPill,
                accent = agentAccent,
                onTap = onAgentTap,
            )
            DropdownMenu(expanded = menuExpanded, onDismissRequest = onMenuDismiss) {
                DropdownMenuItem(
                    text = { Text("Switch to Claude") },
                    enabled = !disableSwitchClaude,
                    onClick = onSwitchToClaude,
                )
                DropdownMenuItem(
                    text = { Text("Switch to Codex") },
                    enabled = !disableSwitchCodex,
                    onClick = onSwitchToCodex,
                )
                HorizontalDivider()
                DropdownMenuItem(
                    text = { Text("End session") },
                    onClick = onEndSession,
                )
            }
        }

        // sweswe-parity multi-viewer hint. Slots between the centered
        // agent pill and the trailing icon circles so a shared session
        // is visible without crowding the action buttons. Renders to
        // nothing when count is null / 0 / 1 — see ViewerCountBadge.
        ViewerCountBadge(count = viewerCount)

        MemoryButton(
            currentMode = browserMode,
            onToggle = onBrowserModeChange,
            onJumpToBrowser = onJumpToBrowser,
        )
        HeaderCircleButton(icon = Icons.Default.Refresh, contentDescription = "Reconnect", onClick = onReconnect)
        HeaderCircleButton(icon = Icons.Outlined.Info, contentDescription = "Session info", onClick = onShowInfo)
    }
}

/**
 * Centered compound agent dropdown. HealthDot · agent name · reasoning
 * effort · chevron, all wrapped in a glassCapsule tinted with the
 * per-agent accent — mirrors iOS `agentPill`.
 */
@Composable
private fun AgentPill(
    pill: ProjectHeaderModel.AgentPill,
    accent: androidx.compose.ui.graphics.Color,
    onTap: () -> Unit,
) {
    Row(
        modifier = Modifier
            .glassCapsule(interactive = true, tint = accent.copy(alpha = 0.32f))
            .clickable(onClick = onTap)
            .padding(horizontal = 12.dp, vertical = 6.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        HealthDot(pill.healthKey, size = 8.dp)
        Text(
            pill.agentName,
            style = MaterialTheme.typography.titleSmall,
            fontWeight = FontWeight.SemiBold,
            color = SweKittyTheme.textPrimary(),
        )
        Text(
            pill.reasoningEffort,
            style = MaterialTheme.typography.labelMedium,
            fontWeight = FontWeight.Medium,
            color = SweKittyTheme.textSecondary(),
        )
        if (pill.showsChevron) {
            Icon(
                Icons.Default.ExpandMore,
                contentDescription = null,
                tint = SweKittyTheme.textSecondary(),
                modifier = Modifier.size(14.dp),
            )
        }
    }
}

/**
 * Row 2 — single-line mono caption combining `path · branch · running
 * · lifecycle`. Middle-truncation isn't available pre-Compose 1.7, so
 * we fall back to `TextOverflow.Ellipsis` (end) — same visual goal:
 * one line, muted, mono.
 */
@Composable
private fun PathRow(model: ProjectHeaderModel) {
    Text(
        model.captionLabel,
        style = MaterialTheme.typography.labelSmall,
        fontFamily = FontFamily.Monospace,
        color = SweKittyTheme.textMuted(),
        maxLines = 1,
        overflow = TextOverflow.Ellipsis,
        textAlign = TextAlign.Center,
        modifier = Modifier.fillMaxWidth(),
    )
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
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .glassRoundedRect(cornerRadiusDp = SweKittyTheme.smallCornerRadiusDp)
            .padding(horizontal = 8.dp, vertical = 4.dp),
    ) {
        TabRow(
            selectedTabIndex = selected,
            containerColor = androidx.compose.ui.graphics.Color.Transparent,
        ) {
            ProjectTab.entries.forEachIndexed { i, t ->
                Tab(
                    selected = selected == i,
                    onClick = { onSelect(i) },
                    text = { Text(t.label, fontWeight = FontWeight.SemiBold) },
                    icon = {
                        Icon(
                            when (t) {
                                ProjectTab.Terminal -> Icons.Outlined.Terminal
                                ProjectTab.Chat     -> Icons.Outlined.Chat
                                ProjectTab.Browser  -> Icons.Outlined.Public
                            },
                            contentDescription = null,
                        )
                    },
                )
            }
        }
    }
}

@Composable
private fun HeaderCircleButton(icon: ImageVector, contentDescription: String, onClick: () -> Unit) {
    // `glassCircle` already clips to CircleShape; we add `clickable`
    // after so the ripple respects the rounded edge.
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
            tint = SweKittyTheme.accentStrong(),
        )
    }
}

/**
 * Pure-data description of the litter Stage 2 Android header. Lifted
 * out of the `ProjectScreen` composable so unit tests can assert the
 * three-row structure and the compound-dropdown contents without
 * standing up a Compose host. Mirrors `ProjectHeaderModel` in
 * `apps/ios/Sources/Views/ProjectView.swift` — same Row enum, same
 * AgentPill payload, same captionLabel join order.
 */
data class ProjectHeaderModel(
    val agentPill: AgentPill,
    val pathLabel: String,
    val captionLabel: String,
) {
    /** Three rows, in render order — matches iOS and the spec in
     *  `docs/PLAN-LITTER-UI.md` Stage 2. */
    enum class Row { Controls, Path, TabPicker }

    /** Centered compound-dropdown payload — asserts the one-compound-
     *  control shape (status dot · agent name · reasoning effort ·
     *  chevron) in tests. */
    data class AgentPill(
        val healthKey: String,
        val agentName: String,
        val reasoningEffort: String,
        val showsChevron: Boolean,
    )

    companion object {
        val rows: List<Row> = listOf(Row.Controls, Row.Path, Row.TabPicker)

        fun from(
            session: ProjectSession,
            status: SessionStatus?,
            lifecycleLabel: String?,
        ): ProjectHeaderModel {
            // Path label still tracks the real cwd when present, but a
            // user-supplied display name (rename_session, protocol §3.3)
            // wins over both — matches iOS `navTitle` precedence so the
            // two shells render the same friendly label for a renamed
            // session. Fallback chain: displayName → cwd → name.
            val displayLabel = session.displayName?.trim()?.takeIf { it.isNotEmpty() }
            val pathLabel = displayLabel
                ?: session.cwd?.trim()?.takeIf { it.isNotEmpty() }
                ?: session.name

            val reasoning = session.reasoningEffort?.trim()?.takeIf { it.isNotEmpty() } ?: "medium"

            val caption = listOfNotNull(
                pathLabel,
                session.branch?.takeIf { it.isNotBlank() } ?: "no branch",
                status?.phase ?: "ready",
                lifecycleLabel,
            ).joinToString(" · ")

            return ProjectHeaderModel(
                agentPill = AgentPill(
                    healthKey = status?.health ?: "unknown",
                    agentName = session.assistant,
                    reasoningEffort = reasoning,
                    showsChevron = true,
                ),
                pathLabel = pathLabel,
                captionLabel = caption,
            )
        }

        /** Match iOS `lifecycleLabel` — only `exited(N)` / `failed(msg)`
         *  surface; `creating` / `live` / `null` are dropped so the
         *  caption stays terse. */
        fun lifecycleLabel(lifecycle: SessionLifecycle?): String? = when (lifecycle) {
            is SessionLifecycle.Exited        -> "exited(${lifecycle.code})"
            is SessionLifecycle.FailedToStart  -> lifecycle.reason
            else                                -> null
        }
    }
}
