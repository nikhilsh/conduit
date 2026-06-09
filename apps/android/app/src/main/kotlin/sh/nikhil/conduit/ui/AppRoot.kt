package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.VerticalDivider
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import sh.nikhil.conduit.FeatureFlags
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SessionStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(store: SessionStore) {
    val drawerState = rememberDrawerState(DrawerValue.Closed)
    val scope = rememberCoroutineScopeCompat()
    var showSettings by remember { mutableStateOf(false) }
    var showSplash by remember { mutableStateOf(true) }
    var showAddServer by remember { mutableStateOf(false) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showSearch by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var showLicenses by remember { mutableStateOf(false) }
    var showBoxes by remember { mutableStateOf(false) }
    // Redesign surfaces reachable from Home: command palette (⌘K, from the
    // bottom search), fan-out (from the palette), approvals (from the
    // needs-you banner), and per-box health (from a Boxes-list tap).
    var showCommandPalette by remember { mutableStateOf(false) }
    var showFanOut by remember { mutableStateOf(false) }
    var showApprovals by remember { mutableStateOf(false) }
    var boxHealthTarget by remember { mutableStateOf<sh.nikhil.conduit.SavedServer?>(null) }
    // Read-only transcript drilldown from History. The full saved row
    // travels (not just the id) so the transcript can render the title,
    // agent, and timestamps without a second fetch.
    var transcriptTarget by remember {
        mutableStateOf<sh.nikhil.conduit.SavedSession?>(null)
    }

    val selectedId by store.selectedId.collectAsState()
    val sessions by store.sessions.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()

    // Onboarding gate (§5) — accounts-free, device-local. No sign-in wall:
    // show the wizard when this device holds no broker pairing key. `Full`
    // route ⇒ overlay; a paired-but-offline broker is Home + offline banner.
    var onboardingFinished by remember { mutableStateOf(false) }
    val needsOnboarding = !onboardingFinished &&
        FeatureFlags.onboardingRoute(
            pairedBrokers = savedServers.size,
            brokerReachable = harness is HarnessState.Live || harness is HarnessState.Linked,
        ) == FeatureFlags.OnboardingRoute.Full

    // Auto-connect a paired-but-disconnected broker on launch (no settings
    // takeover — onboarding handles the unpaired case).
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (endpoint.isComplete && harness is HarnessState.Disconnected) store.connect()
    }

    val onNewSession: () -> Unit = {
        if (harness is HarnessState.Live || harness is HarnessState.Linked) {
            showAgentPicker = true
        } else {
            showAddServer = true
        }
    }

    Box(modifier = Modifier) {
        GlassAppBackground()
        BoxWithConstraints(modifier = Modifier.fillMaxSize()) {
            // iPad / wide screen: a permanent activity-bar rail + section
            // content (Sessions = ProjectList rail + ProjectScreen). Phone
            // keeps the ModalNavigationDrawer. Mirrors iOS ConduitUI.TabletShell.
            if (maxWidth >= 840.dp) {
                val neon = LocalNeonTheme.current
                // Unified rail (design-reference tablet.jsx): no separate icon
                // activity bar — the rail owns brand + search (→ History) +
                // overflow (→ Settings/Boxes) + session lists + New session.
                // Home is the center empty-state when nothing is selected.
                Row(modifier = Modifier.fillMaxSize()) {
                    NeonTabletRail(
                        store = store,
                        onPick = { store.select(it) },
                        onNewSession = onNewSession,
                        onSearch = { showSearch = true },
                        onOpenSettings = { showSettings = true },
                        onOpenBoxes = { showBoxes = true },
                        onOpenTranscript = { row -> transcriptTarget = row },
                        onHome = { store.select(null) },
                    )
                    VerticalDivider(color = neon.border)
                    Box(modifier = Modifier.weight(1f).fillMaxHeight()) {
                        val selected = sessions.firstOrNull { it.id == selectedId }
                        if (selected != null) {
                            ProjectScreen(store = store, session = selected, onOpenDrawer = {}, chatOnly = true)
                        } else {
                            HomeScreen(
                                store = store,
                                onOpenSettings = { showSettings = true },
                                onOpenDrawer = {},
                                onOpenHistory = { showHistory = true },
                                onAddServer = { showAddServer = true },
                                onNewSession = onNewSession,
                                // The bottom search now opens the ⌘K palette.
                                onSearch = { showCommandPalette = true },
                                onVoice = { showVoice = true },
                                onOpenApprovals = { showApprovals = true },
                                onOpenBoxHealth = { server -> boxHealthTarget = server },
                                // The tablet rail header already shows a Settings
                                // gear — don't render a second one in the center.
                                showSettingsButton = false,
                            )
                        }
                    }
                    sessions.firstOrNull { it.id == selectedId }?.let { sel ->
                        VerticalDivider(color = neon.border)
                        Box(modifier = Modifier.width(392.dp).fillMaxHeight()) {
                            NeonTabletRightPane(store = store, session = sel)
                        }
                    }
                }
            } else {
                ModalNavigationDrawer(
                    drawerState = drawerState,
                    drawerContent = {
                        ProjectListScreen(
                            store = store,
                            onOpenSettings = { showSettings = true },
                            onCloseDrawer = { scope.launch { drawerState.close() } },
                        )
                    },
                ) {
                    val selected = sessions.firstOrNull { it.id == selectedId }
                    if (selected != null) {
                        ProjectScreen(
                            store = store,
                            session = selected,
                            onOpenDrawer = { scope.launch { drawerState.open() } },
                        )
                    } else {
                        HomeScreen(
                            store = store,
                            onOpenSettings = { showSettings = true },
                            onOpenDrawer = { scope.launch { drawerState.open() } },
                            onOpenHistory = { showHistory = true },
                            onAddServer = { showAddServer = true },
                            onNewSession = onNewSession,
                            // The bottom search now opens the ⌘K palette.
                            onSearch = { showCommandPalette = true },
                            onVoice = { showVoice = true },
                            onOpenApprovals = { showApprovals = true },
                            onOpenBoxHealth = { server -> boxHealthTarget = server },
                        )
                    }
                }
            }
        }
    }

    if (showSettings) {
        SettingsScreen(
            store = store,
            onDismiss = { showSettings = false },
            onOpenLicenses = { showLicenses = true },
        )
    }

    if (showLicenses) {
        LicensesScreen(onDismiss = { showLicenses = false })
    }

    if (showAddServer) {
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }

    if (showBoxes) {
        DiscoveryScreen(
            store = store,
            onDismiss = { showBoxes = false },
            onScanQR = { showBoxes = false; showAddServer = true },
            onManualAdd = { showBoxes = false; showAddServer = true },
        )
    }

    if (showAgentPicker) {
        AgentPickerSheet(
            store = store,
            headerNote = null,
            onDismiss = { showAgentPicker = false },
        )
    }

    if (showSearch) {
        SessionSearchScreen(store = store, onDismiss = { showSearch = false })
    }

    if (showCommandPalette) {
        // ⌘K quick switcher. Reuses the same new-session / add-server /
        // select-session paths the rest of the app uses; "Fan out a task"
        // chains into the Fan-out surface.
        CommandPaletteScreen(
            store = store,
            onNewSession = { showCommandPalette = false; onNewSession() },
            onPairBox = { showCommandPalette = false; showAddServer = true },
            onOpenSession = { id -> showCommandPalette = false; store.select(id) },
            onFanOut = { showCommandPalette = false; showFanOut = true },
            onDismiss = { showCommandPalette = false },
        )
    }

    if (showFanOut) {
        // One task → N parallel sessions, one per branch. Launch is real:
        // createSession per branch (no fan-out backend). Compare = no-op.
        FanOutScreen(
            store = store,
            onLaunch = { task, branches ->
                branches.forEach { branch ->
                    store.createSession(assistant = "claude", branch = branch, initialPrompt = task)
                }
            },
            onDismiss = { showFanOut = false },
        )
    }

    if (showApprovals) {
        // Approvals inbox — every action opens the session's chat (no
        // programmatic approve endpoint), so onOpenSession selects + dismisses.
        ApprovalsScreen(
            store = store,
            onOpenSession = { id -> showApprovals = false; store.select(id) },
            onDismiss = { showApprovals = false },
        )
    }

    boxHealthTarget?.let { server ->
        // Per-box health detail. Reconnect reuses the same select-server path
        // a Boxes-list tap used before.
        BoxHealthScreen(
            store = store,
            server = server,
            onReconnect = { store.selectSavedServer(server.id, autoConnect = true) },
            onDismiss = { boxHealthTarget = null },
        )
    }

    if (showHistory) {
        HistoryScreen(
            store = store,
            onDismiss = { showHistory = false },
            onOpenTranscript = { row ->
                showHistory = false
                transcriptTarget = row
            },
        )
    }

    transcriptTarget?.let { row ->
        SavedTranscriptScreen(
            store = store,
            session = row,
            onDismiss = { transcriptTarget = null },
        )
    }

    if (showVoice) {
        val voiceDisplayNames by store.displayNames.collectAsState()
        val voiceConversationLog by store.conversationLog.collectAsState()
        VoiceDictationScreen(
            onTranscript = { transcript ->
                // Push transcript into the active session if there is one;
                // otherwise spin up a new claude session seeded with it.
                val activeId = selectedId
                if (activeId != null) {
                    store.sendChat(activeId, transcript)
                } else if (harness is HarnessState.Live || harness is HarnessState.Linked) {
                    store.createSession(assistant = "claude", initialPrompt = transcript)
                }
            },
            onDismiss = { showVoice = false },
            agent = sessions.firstOrNull { it.id == selectedId }?.assistant ?: "claude",
            // When dictation routes to the active session, name it; the
            // "no active session" path seeds a brand-new session, so fall
            // back to the default `new session`.
            sessionName = run {
                val active = sessions.firstOrNull { it.id == selectedId }
                if (active != null) {
                    sh.nikhil.conduit.SessionNaming.friendlyFor(
                        session = active,
                        custom = voiceDisplayNames[active.id],
                        firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(voiceConversationLog[active.id]),
                    )
                } else {
                    "new session"
                }
            },
        )
    }

    val hostKey by store.pendingHostKey.collectAsState()
    hostKey?.let { prompt ->
        HostKeyPromptDialog(
            prompt = prompt,
            onAccept = { store.resolveHostKeyPrompt(true) },
            onReject = { store.resolveHostKeyPrompt(false) },
        )
    }

    val pendingPick by store.pendingAgentPick.collectAsState()
    pendingPick?.let { pick ->
        AgentPickerSheet(
            store = store,
            headerNote = pick.hostNote,
            onDismiss = { store.setPendingAgentPick(null) },
        )
    }

    // Onboarding takeover (§5). Full-screen over the app; dismisses itself
    // once a broker is paired (savedServers becomes non-empty → route flips
    // to None) or the user finishes.
    if (needsOnboarding) {
        OnboardingScreen(
            store = store,
            onFinish = { onboardingFinished = true },
        )
    }

    if (showSplash) {
        AnimatedSplash(onFinish = { showSplash = false })
    }
}

// Small shim so this file doesn't pull androidx.compose.runtime.rememberCoroutineScope
// at every call site. Inlined to keep imports tidy.
@Composable
private fun rememberCoroutineScopeCompat() = androidx.compose.runtime.rememberCoroutineScope()
