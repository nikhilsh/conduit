package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.material3.DrawerValue
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ModalNavigationDrawer
import androidx.compose.material3.rememberDrawerState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import kotlinx.coroutines.launch
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SessionStore

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
    // Read-only transcript drilldown from History. The full saved row
    // travels (not just the id) so the transcript can render the title,
    // agent, and timestamps without a second fetch.
    var transcriptTarget by remember {
        mutableStateOf<sh.nikhil.swekitty.SavedSession?>(null)
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

    Box(modifier = Modifier) {
        GlassAppBackground()
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
                    onNewSession = {
                        if (harness is HarnessState.Live || harness is HarnessState.Linked) {
                            showAgentPicker = true
                        } else {
                            showAddServer = true
                        }
                    },
                    onSearch = { showSearch = true },
                    onVoice = { showVoice = true },
                )
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
