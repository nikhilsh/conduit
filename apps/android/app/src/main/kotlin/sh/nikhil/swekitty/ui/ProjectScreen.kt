package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.outlined.AccountTree
import androidx.compose.material.icons.outlined.Chat
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import kotlinx.coroutines.launch
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

enum class ProjectTab(val label: String) { Terminal("Terminal"), Chat("Chat"), Browser("Browser") }

@OptIn(ExperimentalMaterial3Api::class, androidx.compose.foundation.ExperimentalFoundationApi::class)
@Composable
fun ProjectScreen(
    store: SessionStore,
    session: ProjectSession,
    onOpenDrawer: () -> Unit,
) {
    val pagerState = rememberPagerState(initialPage = 0, pageCount = { ProjectTab.entries.size })
    val statuses by store.statusBySession.collectAsState()
    val status = statuses[session.id]
    var menuExpanded by remember { mutableStateOf(false) }
    var browserMode by remember { mutableStateOf(BrowserMode.Preview) }
    val scope = rememberCoroutineScope()

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        HealthDot(status?.health ?: "unknown")
                        Spacer(Modifier.width(8.dp))
                        Text(session.name)
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onOpenDrawer) { Icon(Icons.Default.Menu, contentDescription = "Sessions") }
                },
                actions = {
                    MemoryButton(
                        currentMode = browserMode,
                        onToggle = { browserMode = it },
                        onJumpToBrowser = { scope.launch { pagerState.animateScrollToPage(ProjectTab.Browser.ordinal) } },
                    )
                    Box {
                        AssistChip(
                            onClick = { menuExpanded = true },
                            label = { Text(session.assistant) },
                            leadingIcon = { Icon(Icons.Outlined.AccountTree, null) },
                        )
                        DropdownMenu(expanded = menuExpanded, onDismissRequest = { menuExpanded = false }) {
                            DropdownMenuItem(
                                text = { Text("Switch to Claude") },
                                enabled = session.assistant != "claude",
                                onClick = { menuExpanded = false; store.switchAgent(session.id, "claude") },
                            )
                            DropdownMenuItem(
                                text = { Text("Switch to Codex") },
                                enabled = session.assistant != "codex",
                                onClick = { menuExpanded = false; store.switchAgent(session.id, "codex") },
                            )
                            HorizontalDivider()
                            DropdownMenuItem(
                                text = { Text("End session") },
                                onClick = { menuExpanded = false; store.exit(session.id) },
                            )
                        }
                        Spacer(Modifier.width(8.dp))
                    }
                },
            )
        },
    ) { padding ->
        Column(modifier = Modifier.padding(padding).fillMaxSize()) {
            TabRow(selectedTabIndex = pagerState.currentPage) {
                ProjectTab.entries.forEachIndexed { i, t ->
                    Tab(
                        selected = pagerState.currentPage == i,
                        onClick = { scope.launch { pagerState.animateScrollToPage(i) } },
                        text = { Text(t.label) },
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
            HorizontalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize(),
            ) { page ->
                when (ProjectTab.entries[page]) {
                    ProjectTab.Terminal -> TerminalPage(store, session)
                    ProjectTab.Chat     -> ChatPage(store, session)
                    ProjectTab.Browser  -> BrowserPage(store, session, browserMode)
                }
            }
        }
    }
}
