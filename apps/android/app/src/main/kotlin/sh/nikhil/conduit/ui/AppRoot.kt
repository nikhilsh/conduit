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
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import sh.nikhil.conduit.FeatureFlags
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.push.PushRegistrationState
import sh.nikhil.conduit.push.PushStore
import java.net.HttpURLConnection
import java.net.URL

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
    // Stashed prompt from the command-palette "Run on box" path: the typed text
    // is held here until the agent picker consumes it as initialPrompt, seeding
    // the new session with that text as its first message. Cleared when the
    // agent picker dismisses. Mirrors iOS voicePrompt.
    var paletteInitialPrompt by remember { mutableStateOf<String?>(null) }
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
    // Fan-out compare: launched runs passed to FanOutScreen for compare call.
    var fanOutLaunchedRuns by remember { mutableStateOf<List<FanOutRun>>(emptyList()) }
    // FanOutCompareScreen state: compare results navigate here.
    var compareRuns by remember { mutableStateOf<List<FanOutCompareRun>?>(null) }
    // Pipeline screens
    var showPipelineBuilder by remember { mutableStateOf(false) }
    var showPipelineList by remember { mutableStateOf(false) }
    // Flow (pipeline v2) Start sheet + wizard -- replaces the old direct
    // `showAgentPicker` / `showPipelineBuilder` presentation at the "+"
    // entry points on PHONE. Tablet's `NeonTabletRail`/`HomeScreen` "New
    // pipeline" wiring below is UNCHANGED -- it keeps the old builder
    // (PR scope §6).
    var showFlowStart by remember { mutableStateOf(false) }
    var flowStartInitialTab by remember { mutableStateOf(FlowStartTab.SESSION) }
    var flowWizardPrefill by remember { mutableStateOf<FlowWizardPrefill?>(null) }
    var pipelineMonitorTarget by remember { mutableStateOf<Pair<String, String>?>(null) }
    // Home FLOWS device-feedback fix: bumped whenever a flow is created or
    // its wizard/builder/monitor overlay dismisses back to Home, so
    // HomeScreen's LaunchedEffect re-fetches immediately instead of waiting
    // for its periodic tick.
    var pipelineRefreshTick by remember { mutableStateOf(0) }
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
    val isDemoMode by store.isDemoMode.collectAsState()
    val scope = rememberCoroutineScope()

    // Onboarding gate (section 5) -- accounts-free, device-local. No sign-in wall:
    // show the wizard when this device holds no broker pairing key. `Full`
    // route => overlay; a paired-but-offline broker is Home + offline banner.
    var onboardingFinished by remember { mutableStateOf(false) }
    // Gate on !showSplash: onboarding must not render concurrently with the
    // splash. The splash is the last element in the tree (renders on top),
    // but allowing onboarding to compose underneath causes a visible flash
    // when the splash dismisses. Show onboarding only AFTER the splash has
    // finished (showSplash flips false after the cross-fade completes).
    // Also skip onboarding when demo mode is active -- the demo shell replaces it.
    val needsOnboarding = !showSplash && !onboardingFinished && !isDemoMode &&
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
            flowStartInitialTab = FlowStartTab.SESSION
            showFlowStart = true
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
                        onNewPipeline = { showPipelineBuilder = true },
                        onFanOut = { showFanOut = true },
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
                                onOpenPipelines = { showPipelineList = true },
                                onOpenPipeline = { id, title -> pipelineMonitorTarget = Pair(id, title) },
                                onNewPipeline = { showPipelineBuilder = true },
                                onFanOut = { showFanOut = true },
                                // The tablet rail header already shows a Settings
                                // gear -- don't render a second one in the center.
                                showSettingsButton = false,
                                onOpenOnboarding = {
                                    onboardingEntry = FeatureFlags.OnboardingEntry.replay
                                    showOnboarding = true
                                },
                                refreshPipelinesTick = pipelineRefreshTick,
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
                        onOpenPipelines = { showPipelineList = true },
                        onOpenPipeline = { id, title -> pipelineMonitorTarget = Pair(id, title) },
                        // "+ New flow" header -- straight to the wizard
                        // (blank), no Start-sheet detour (phone only; tablet
                        // above keeps the old builder).
                        onNewPipeline = {
                            Telemetry.breadcrumb("flow_wizard", "flows_header_new_flow_tapped", emptyMap())
                            flowWizardPrefill = FlowWizardPrefill.Blank
                        },
                        onFanOut = { showFanOut = true },
                        onOpenOnboarding = {
                            onboardingEntry = FeatureFlags.OnboardingEntry.replay
                            showOnboarding = true
                        },
                        refreshPipelinesTick = pipelineRefreshTick,
                    )
                }
            }
        }
    }

    if (showSettings) {
        SettingsScreen(
            store = store,
            onDismiss = { showSettings = false },
            onOpenLicenses = { showLicenses = true },
            // Fix 1: Settings passes the intent so replay/addMachine never
            // land on Done directly.
            onOpenOnboarding = { entry ->
                onboardingEntry = entry
                showSettings = false
                showOnboarding = true
            },
            // Close Settings so the demo shell (rendered behind ModalBottomSheet
            // overlays in AppRoot) is fully visible once isDemoMode flips true.
            onEnterDemo = { showSettings = false },
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
            initialPrompt = paletteInitialPrompt,
            onOpenPipelineBuilder = { showPipelineBuilder = true },
            onDismiss = {
                showAgentPicker = false
                paletteInitialPrompt = null
            },
        )
    }

    if (showSearch) {
        SessionSearchScreen(store = store, onDismiss = { showSearch = false })
    }

    if (showCommandPalette) {
        // Cmd-K quick switcher. Reuses the same new-session / add-server /
        // select-session paths the rest of the app uses; "Fan out a task"
        // chains into the Fan-out surface. "Run on box" seeds a new session
        // with the typed text as the first message via the agent picker, mirroring
        // iOS PR #719 (ConduitHomeView pendingRunOnBox + voicePrompt pattern).
        CommandPaletteScreen(
            store = store,
            onNewSession = { showCommandPalette = false; onNewSession() },
            onPairBox = { showCommandPalette = false; showAddServer = true },
            onOpenSession = { id -> showCommandPalette = false; store.select(id) },
            onFanOut = { showCommandPalette = false; showFanOut = true },
            onNewPipeline = {
                showCommandPalette = false
                flowStartInitialTab = FlowStartTab.FLOW
                showFlowStart = true
            },
            onPipelines = { showCommandPalette = false; showPipelineList = true },
            onRunOnBox = { text ->
                // CommandPaletteScreen always calls onDismiss() before onRunOnBox(),
                // so the palette is already in its dismiss-animation by the time this
                // fires. Stash the prompt and open the agent picker directly -- no
                // extra deferral needed on Android (no SwiftUI double-sheet issue).
                val trimmed = text.trim()
                if (trimmed.isNotEmpty()) {
                    Telemetry.breadcrumb(
                        "palette",
                        "run_on_box_tapped",
                        mapOf("has_text" to "true"),
                    )
                    if (harness is HarnessState.Live || harness is HarnessState.Linked) {
                        paletteInitialPrompt = trimmed
                        showAgentPicker = true
                    } else {
                        showAddServer = true
                    }
                }
            },
            onDismiss = { showCommandPalette = false },
        )
    }

    if (showFanOut) {
        // One task -> N parallel sessions, one per branch. Launch is real:
        // createSession per branch (no fan-out backend). Compare calls
        // POST /api/fanout/compare with the launched runs' session IDs.
        // Session IDs are resolved from store.sessions by branch at compare time.
        FanOutScreen(
            store = store,
            onLaunch = { task, branches ->
                // Record the launched branches; session IDs are populated
                // from store.sessions at compare time by branch match.
                fanOutLaunchedRuns = branches.map { FanOutRun(branch = it) }
                branches.forEach { branch ->
                    store.createSession(assistant = "claude", branch = branch, initialPrompt = task)
                }
            },
            runs = fanOutLaunchedRuns.map { run ->
                // Resolve session ID from live sessions by branch name.
                val matchedId = sessions.firstOrNull { it.branch == run.branch }?.id
                if (matchedId != null) run.copy(sessionId = matchedId) else run
            },
            onCompare = compareOnClick@{
                // Resolve session IDs from live store.sessions at compare time.
                val resolvedRuns = fanOutLaunchedRuns.map { run ->
                    val matchedId = sessions.firstOrNull { it.branch == run.branch }?.id
                    if (matchedId != null) run.copy(sessionId = matchedId) else run
                }
                if (resolvedRuns.isEmpty()) return@compareOnClick
                val base = endpoint.httpBaseUrl ?: return@compareOnClick
                Telemetry.breadcrumb(
                    "fanout",
                    "compare_start",
                    mapOf("run_count" to resolvedRuns.size.toString()),
                )
                scope.launch {
                    val runsJson = JSONArray().apply {
                        resolvedRuns.forEach { run ->
                            put(JSONObject().apply {
                                put("session_id", run.sessionId ?: "")
                                put("label", run.branch)
                            })
                        }
                    }
                    val body = JSONObject().apply {
                        put("base", "main")
                        put("runs", runsJson)
                    }
                    val result = withContext(Dispatchers.IO) {
                        runCatching {
                            val conn = (URL("$base/api/fanout/compare").openConnection() as HttpURLConnection).apply {
                                requestMethod = "POST"
                                doOutput = true
                                setRequestProperty("Authorization", "Bearer ${endpoint.token}")
                                setRequestProperty("Content-Type", "application/json")
                                connectTimeout = 10_000
                                readTimeout = 30_000
                            }
                            try {
                                conn.outputStream.use { it.write(body.toString().toByteArray(Charsets.UTF_8)) }
                                val code = conn.responseCode
                                val stream = if (code in 200..299) conn.inputStream else conn.errorStream
                                val text = stream?.bufferedReader()?.use { it.readText() } ?: "{}"
                                conn.disconnect()
                                JSONObject(text)
                            } catch (e: Exception) {
                                conn.disconnect()
                                throw e
                            }
                        }
                    }
                    result.onSuccess { json ->
                        val runsArr = json.optJSONArray("runs")
                        val parsed = mutableListOf<FanOutCompareRun>()
                        if (runsArr != null) {
                            for (i in 0 until runsArr.length()) {
                                val r = runsArr.getJSONObject(i)
                                parsed.add(
                                    FanOutCompareRun(
                                        sessionId = r.optString("session_id", ""),
                                        label = r.optString("label", ""),
                                        phase = r.optString("phase", ""),
                                        filesChanged = r.optInt("files_changed", 0),
                                        insertions = r.optInt("insertions", 0),
                                        deletions = r.optInt("deletions", 0),
                                        diffStat = r.optString("diff_stat", ""),
                                        agentSummary = r.optString("agent_summary", ""),
                                        error = r.optString("error", ""),
                                    ),
                                )
                            }
                        }
                        Telemetry.breadcrumb(
                            "fanout",
                            "compare_success",
                            mapOf("run_count" to parsed.size.toString()),
                        )
                        compareRuns = parsed
                        showFanOut = false
                    }.onFailure { e ->
                        Telemetry.capture(
                            error = e,
                            message = "fanout compare network error",
                            tags = mapOf("surface" to "android", "phase" to "fanout-compare"),
                        )
                    }
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

    // FanOut compare results screen (full screen, no bottom sheet).
    compareRuns?.let { runs ->
        BackHandler(enabled = true) { compareRuns = null }
        FanOutCompareScreen(
            store = store,
            runs = runs,
            onOpenSession = { id -> compareRuns = null; store.select(id) },
            onBack = { compareRuns = null },
        )
    }

    // Pipeline builder screen.
    if (showPipelineBuilder) {
        BackHandler(enabled = true) { showPipelineBuilder = false }
        PipelineBuilderScreen(
            store = store,
            onCreated = { id, title ->
                showPipelineBuilder = false
                pipelineMonitorTarget = Pair(id, title)
                pipelineRefreshTick++
            },
            onBack = { showPipelineBuilder = false },
        )
    }

    // Flow (pipeline v2) Start sheet -- Session/Flow segmented; Session tab
    // hosts the existing AgentPickerSheet, Flow tab picks a template/blank
    // flow and opens the wizard.
    if (showFlowStart) {
        FlowStartSheet(
            store = store,
            initialTab = flowStartInitialTab,
            onStartWizard = { prefill ->
                showFlowStart = false
                flowWizardPrefill = prefill
            },
            onDismiss = { showFlowStart = false },
        )
    }

    // Flow wizard (Task -> Steps) -- replaces PipelineBuilderScreen as the
    // phone create UX. Tablet keeps the old builder (PR scope §6).
    flowWizardPrefill?.let { prefill ->
        BackHandler(enabled = true) { flowWizardPrefill = null }
        FlowWizardScreen(
            store = store,
            prefill = prefill,
            onCreated = { id, title ->
                flowWizardPrefill = null
                pipelineMonitorTarget = Pair(id, title)
                // Home FLOWS device-feedback fix: refresh immediately so the
                // just-started flow's card is there the moment the user
                // backs out of the monitor, not up to 12s later.
                pipelineRefreshTick++
            },
            onBack = { flowWizardPrefill = null },
        )
    }

    // Pipeline monitor screen.
    pipelineMonitorTarget?.let { (id, title) ->
        BackHandler(enabled = true) { pipelineMonitorTarget = null; pipelineRefreshTick++ }
        PipelineMonitorScreen(
            store = store,
            pipelineId = id,
            pipelineTitle = title,
            onOpenSession = { sessionId -> pipelineMonitorTarget = null; store.select(sessionId) },
            onBack = { pipelineMonitorTarget = null; pipelineRefreshTick++ },
        )
    }

    // Pipeline list screen -- reopens the monitor for a running/past
    // pipeline. The fix for a pipeline becoming unreachable once its
    // creation sheet is dismissed (only the Builder's own post-create
    // navigation reached the monitor before this).
    if (showPipelineList) {
        BackHandler(enabled = true) { showPipelineList = false }
        PipelineListScreen(
            store = store,
            onOpenPipeline = { id, title ->
                showPipelineList = false
                pipelineMonitorTarget = Pair(id, title)
            },
            onDismiss = { showPipelineList = false },
        )
    }

    boxHealthTarget?.let { server ->
        // Per-box health detail. Reconnect reuses the same select-server path
        // a Boxes-list tap used before.
        //
        // Fix: system back on phone returns Home from the box-health/detail
        // page instead of exiting the app (parity with the chat screen back,
        // #642, and iOS nav back/edge-swipe on the box detail). This overlay is
        // composed after the BoxWithConstraints content, so this BackHandler is
        // registered last and wins over the session `selectedId` handler while
        // the box page is shown. Dismissing only clears boxHealthTarget; the
        // underlying Home/session state is untouched.
        BackHandler(enabled = true) {
            Telemetry.breadcrumb("nav", "box-health-back-to-home", mapOf("host" to server.endpoint.displayHost))
            boxHealthTarget = null
        }
        BoxHealthScreen(
            store = store,
            server = server,
            onReconnect = { store.selectSavedServer(server.id, autoConnect = true) },
            onBack = { boxHealthTarget = null },
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
            onDemoMode = {
                store.activateDemo()
                onboardingFinished = true
            },
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

    // Demo mode overlay: DemoHomeScreen renders over the real app content.
    // The real Box/BoxWithConstraints tree above is still composed but hidden
    // behind the demo shell. The splash still renders on top of everything.
    if (isDemoMode && !showSplash) {
        DemoHomeScreen(store = store, onExitDemo = { store.deactivateDemo() })
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
