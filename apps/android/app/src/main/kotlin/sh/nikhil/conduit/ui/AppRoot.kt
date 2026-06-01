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

    // First-launch settings prompt.
    androidx.compose.runtime.LaunchedEffect(Unit) {
        if (!endpoint.isComplete) showSettings = true
        else if (harness is HarnessState.Disconnected) store.connect()
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
                                onSearch = { showSearch = true },
                                onVoice = { showVoice = true },
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
                            onSearch = { showSearch = true },
                            onVoice = { showVoice = true },
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

    if (showSplash) {
        AnimatedSplash(onFinish = { showSplash = false })
    }
}

// Small shim so this file doesn't pull androidx.compose.runtime.rememberCoroutineScope
// at every call site. Inlined to keep imports tidy.
@Composable
private fun rememberCoroutineScopeCompat() = androidx.compose.runtime.rememberCoroutineScope()
