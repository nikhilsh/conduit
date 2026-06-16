package sh.nikhil.conduit.ui

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.width
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.VerticalDivider
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.FeatureFlags
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.push.PushRegistrationState
import sh.nikhil.conduit.push.PushStore

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppRoot(
    store: SessionStore,
    pushStore: PushStore,
    /** Called once when sessions first appear and push isn't yet registered.
     *  The Activity uses this to request the notification permission + register. */
    onFirstSessionForPush: (() -> Unit)? = null,
) {
    var showSettings by remember { mutableStateOf(false) }
    var showSplash by remember { mutableStateOf(true) }
    var showAddServer by remember { mutableStateOf(false) }
    var showOnboarding by remember { mutableStateOf(false) }
    // Fix 1: track which entry intent opened the manual onboarding sheet.
    var onboardingEntry by remember { mutableStateOf(FeatureFlags.OnboardingEntry.replay) }
    var showAgentPicker by remember { mutableStateOf(false) }
    var showSearch by remember { mutableStateOf(false) }
    var showVoice by remember { mutableStateOf(false) }
    var showHistory by remember { mutableStateOf(false) }
    var showLicenses by remember { mutableStateOf(false) }
    var showBoxes by remember { mutableStateOf(false) }
    // Redesign surfaces reachable from Home: command palette (Cmd-K, from the
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

    // Onboarding gate (section 5) -- accounts-free, device-local. No sign-in wall:
    // show the wizard when this device holds no broker pairing key. `Full`
    // route => overlay; a paired-but-offline broker is Home + offline banner.
    var onboardingFinished by remember { mutableStateOf(false) }
    // Gate on !showSplash: onboarding must not render concurrently with the
    // splash. The splash is the last element in the tree (renders on top),
    // but allowing onboarding to compose underneath causes a visible flash
    // when the splash dismisses. Show onboarding only AFTER the splash has
    // finished (showSplash flips false after the cross-fade completes).
    val needsOnboarding = !showSplash && !onboardingFinished &&
        FeatureFlags.onboardingRoute(
            pairedBrokers = savedServers.size,
            brokerReachable = harness is HarnessState.Live || harness is HarnessState.Linked,
        ) == FeatureFlags.OnboardingRoute.Full

    // Auto-connect a paired-but-disconnected broker on launch (no settings
    // takeover -- onboarding handles the unpaired case).
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (endpoint.isComplete && harness is HarnessState.Disconnected) store.connect()
    }

    // Push registration trigger (WS-P.3): attempt registration after the
    // first session exists -- matches iOS timing (post-onboarding, never at
    // app launch before the user has paired). Only fires once per install
    // (when the push state is NotRegistered and sessions transitions 0 -> >=1).
    val pushRegistrationState by pushStore.registrationState.collectAsState()
    androidx.compose.runtime.LaunchedEffect(sessions.isNotEmpty()) {
        if (sessions.isNotEmpty() &&
            pushRegistrationState is PushRegistrationState.NotRegistered &&
            endpoint.isComplete
        ) {
            // The actual permission request + register is performed on the
            // Activity (not a composable) because it needs the permission
            // launcher. We delegate via a side-channel callback.
            onFirstSessionForPush?.invoke()
        }
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
            // renders Home / ProjectScreen directly (no side drawer). Mirrors
            // iOS ConduitUI.TabletShell.
            // Gate on a TRUE tablet: smallest-width >= 600dp (sw600dp, the
            // Android tablet breakpoint) AND maxWidth >= 840dp. A phone in
            // landscape can exceed 840dp but its sw is ~360-480dp, so it stays
            // in the phone layout. Mirrors iOS which gates on .regular size class
            // (iPad / Plus-Max) only, never a regular phone in landscape.
            val isTabletForm = LocalConfiguration.current.smallestScreenWidthDp >= 600 && maxWidth >= 840.dp
            if (isTabletForm) {
                val neon = LocalNeonTheme.current
                // Unified rail (design-reference tablet.jsx): no separate icon
                // activity bar -- the rail owns brand + search (-> History) +
                // overflow (-> Settings/Boxes) + session lists + New session.
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
                            ProjectScreen(store = store, session = selected, chatOnly = true)
                        } else {
                            HomeScreen(
                                store = store,
                                onOpenSettings = { showSettings = true },
                                onOpenHistory = { showHistory = true },
                                onAddServer = { showAddServer = true },
                                onNewSession = onNewSession,
                                // The bottom search now opens the Cmd-K palette.
                                onSearch = { showCommandPalette = true },
                                onVoice = { showVoice = true },
                                onOpenApprovals = { showApprovals = true },
                                onOpenBoxHealth = { server -> boxHealthTarget = server },
                                // The tablet rail header already shows a Settings
                                // gear -- don't render a second one in the center.
                                showSettingsButton = false,
                                onOpenOnboarding = {
                                    onboardingEntry = FeatureFlags.OnboardingEntry.replay
                                    showOnboarding = true
                                },
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
                // Fix 1: system back on phone returns Home from a session instead
                // of exiting the app. Mirrors iOS NavigationStack back chevron +
                // edge-swipe behaviour (ConduitHomeView/ConduitProjectView).
                BackHandler(enabled = selectedId != null) {
                    Telemetry.breadcrumb("nav", "back-to-home", mapOf("from" to (selectedId ?: "")))
                    store.select(null)
                }
                // The legacy ModalNavigationDrawer (ProjectListScreen) was
                // removed (user feedback 2026-06-16): Home already lists
                // active/archived sessions, the BOXES section, the broker-update
                // banner, and the Settings entry, so the side drawer was
                // redundant. Render the phone content directly. Matches iOS,
                // whose home view IS the live session list.
                val selected = sessions.firstOrNull { it.id == selectedId }
                if (selected != null) {
                    ProjectScreen(
                        store = store,
                        session = selected,
                        onBack = { store.select(null) },
                    )
                } else {
                    HomeScreen(
                        store = store,
                        // Fix: on a fresh install (no saved servers), onboarding owns
                        // first-run -- don't auto-open Settings before the user has
                        // paired a box. User-tapped Settings still works after pairing.
                        onOpenSettings = {
                            if (savedServers.isNotEmpty()) showSettings = true
                        },
                        onOpenHistory = { showHistory = true },
                        onAddServer = { showAddServer = true },
                        onNewSession = onNewSession,
                        // The bottom search now opens the Cmd-K palette.
                        onSearch = { showCommandPalette = true },
                        onVoice = { showVoice = true },
                        onOpenApprovals = { showApprovals = true },
                        onOpenBoxHealth = { server -> boxHealthTarget = server },
                        onOpenOnboarding = {
                            onboardingEntry = FeatureFlags.OnboardingEntry.replay
                            showOnboarding = true
                        },
                    )
                }
            }
        }
    }

    if (showSettings) {
        SettingsScreen(
            store = store,
            pushStore = pushStore,
            onDismiss = { showSettings = false },
            onOpenLicenses = { showLicenses = true },
            // Fix 1: Settings passes the intent so replay/addMachine never
            // land on Done directly.
            onOpenOnboarding = { entry ->
                onboardingEntry = entry
                showSettings = false
                showOnboarding = true
            },
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
        // Cmd-K quick switcher. Reuses the same new-session / add-server /
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
        // One task -> N parallel sessions, one per branch. Launch is real:
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
        // Approvals inbox -- every action opens the session's chat (no
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
    val sshLoginSheetActive by store.sshLoginSheetActive.collectAsState()
    // Part A: suppress root-level TOFU dialog while the SSH add sheet is up --
    // the sheet shows an inline host-key section instead.
    if (hostKey != null && !sshLoginSheetActive) {
        HostKeyPromptDialog(
            prompt = hostKey!!,
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

    // Onboarding takeover (section 5). Full-screen over the app; dismisses itself
    // once a broker is paired (savedServers becomes non-empty -> route flips
    // to None) or the user finishes. Only shown after the splash has dismissed
    // (needsOnboarding is gated on !showSplash above).
    if (needsOnboarding) {
        OnboardingScreen(
            store = store,
            onFinish = { onboardingFinished = true },
        )
    }

    // Re-opened onboarding guide (from no-boxes CTA or Settings "How it works").
    // Shown over the main app without gating on the pairing state; dismiss sends
    // the user back to Home with all their existing sessions intact.
    // Fix 1: pass the entry intent so replay/addMachine never land on Done.
    if (showOnboarding) {
        OnboardingScreen(
            store = store,
            onFinish = { showOnboarding = false },
            entry = onboardingEntry,
        )
    }

    if (showSplash) {
        // Fresh install (no saved servers): use the short timeout so onboarding
        // follows the splash promptly without a 1500ms wait for a harness that
        // will never connect. Paired users keep the full timeout + harness-dismiss
        // so the splash drops as soon as the broker responds.
        val isFreshInstall = savedServers.isEmpty()
        AnimatedSplash(
            harnessState = harness,
            freshInstall = isFreshInstall,
            onFinish = {
                Telemetry.breadcrumb(
                    "launch",
                    "splash dismissed",
                    mapOf(
                        "fresh_install" to isFreshInstall.toString(),
                        "saved_servers" to savedServers.size.toString(),
                        "timeout_ms" to if (isFreshInstall) {
                            AnimatedSplashModel.freshInstallTimeoutMillis.toString()
                        } else {
                            AnimatedSplashModel.hardTimeoutMillis.toString()
                        },
                    ),
                )
                showSplash = false
            },
        )
    }
}
