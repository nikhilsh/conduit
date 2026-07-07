package sh.nikhil.conduit.ui

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.outlined.Chat
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.ui.viewinterop.AndroidView
import sh.nikhil.conduit.ui.components.NeonPillSegment
import sh.nikhil.conduit.ui.components.NeonSegmentedPill
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.outlined.Difference
import sh.nikhil.conduit.AppearanceStore
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.demo.DemoData
import sh.nikhil.conduit.ui.components.FlowCard
import uniffi.conduit_core.ProjectSession

// ---------------------------------------------------------------------------
// DemoHomeScreen
//
// Self-contained demo shell for the App Store reviewer demo mode. Shows two
// fake sessions and a scripted conversation with no network calls or real
// broker. Phone: flat session list + chat push. Tablet: rail + detail side by
// side. "Exit Demo" calls store.deactivateDemo() returning to onboarding.
// ---------------------------------------------------------------------------

@Composable
fun DemoHomeScreen(store: SessionStore, onExitDemo: () -> Unit) {
    val config = LocalConfiguration.current
    val isTablet = config.smallestScreenWidthDp >= 600
    val appearance = LocalAppearanceStore.current

    // Snapshot appearance on entry; restore on exit so theme/font changes
    // made by the App Store reviewer do not persist after leaving demo mode.
    // Mirrors iOS DemoHomeView.onAppear / onDisappear + AppearanceStore.Snapshot.
    DisposableEffect(Unit) {
        val snap = appearance.snapshot()
        Telemetry.breadcrumb("demo", "appearance_snapshot_captured")
        onDispose {
            appearance.applySnapshot(snap)
            Telemetry.breadcrumb("demo", "appearance_snapshot_restored")
        }
    }

    LaunchedEffect(Unit) {
        Telemetry.breadcrumb("demo", "home_appeared", mapOf("tablet" to isTablet.toString()))
    }

    if (isTablet) {
        DemoTabletLayout(store = store, onExitDemo = onExitDemo)
    } else {
        DemoPhoneLayout(store = store, onExitDemo = onExitDemo)
    }
}

// ---------------------------------------------------------------------------
// Phone layout: session list -> chat push
// ---------------------------------------------------------------------------

@Composable
private fun DemoPhoneLayout(store: SessionStore, onExitDemo: () -> Unit) {
    val neon = LocalNeonTheme.current
    val appearance = LocalAppearanceStore.current
    var selectedSession by remember { mutableStateOf<ProjectSession?>(null) }
    var selectedFlowId by remember { mutableStateOf<String?>(null) }
    var showingAppearance by remember { mutableStateOf(false) }

    Box(modifier = Modifier.fillMaxSize().background(neon.appBg)) {
        val flowId = selectedFlowId
        val flowStatus = flowId?.let { DemoData.pipelineStatus(it) }
        if (flowId != null && flowStatus != null) {
            BackHandler(enabled = true) { selectedFlowId = null }
            PipelineMonitorScreen(
                store = store,
                pipelineId = flowId,
                pipelineTitle = flowStatus.title,
                onOpenSession = {},
                onBack = { selectedFlowId = null },
                demoStatus = flowStatus,
            )
        } else if (selectedSession == null) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
            ) {
                DemoTopBar(
                    neon = neon,
                    title = ">conduit",
                    onExitDemo = onExitDemo,
                    showExitDemo = true,
                    showBack = false,
                    onBack = {},
                    onAppearance = {
                        Telemetry.breadcrumb("demo", "appearance_opened")
                        showingAppearance = true
                    },
                )
                DemoBanner(neon = neon)
                DemoFlowsSection(neon = neon, onOpenFlow = { selectedFlowId = it })
                DemoSessionListContent(
                    neon = neon,
                    onSelect = { selectedSession = it },
                )
            }
        } else {
            val session = selectedSession!!
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
            ) {
                DemoTopBar(
                    neon = neon,
                    title = session.displayName ?: session.name,
                    onExitDemo = onExitDemo,
                    // iOS's chat view has no Exit Demo (it lives on home only).
                    showExitDemo = false,
                    showBack = true,
                    onBack = { selectedSession = null },
                    onAppearance = null,
                )
                // Phase-2: route through DemoProjectScreen (Chat/Terminal/Browser tabs).
                DemoProjectScreen(store = store, session = session)
            }
        }
    }

    if (showingAppearance) {
        AppearanceSheet(
            appearance = appearance,
            onDismiss = { showingAppearance = false },
        )
    }
}

// ---------------------------------------------------------------------------
// Tablet layout: rail + detail
// ---------------------------------------------------------------------------

@Composable
private fun DemoTabletLayout(store: SessionStore, onExitDemo: () -> Unit) {
    val neon = LocalNeonTheme.current
    val appearance = LocalAppearanceStore.current
    var selectedSession by remember { mutableStateOf(DemoData.sessions.firstOrNull()) }
    var selectedFlowId by remember { mutableStateOf<String?>(null) }
    var showingAppearance by remember { mutableStateOf(false) }

    Row(modifier = Modifier.fillMaxSize().background(neon.appBg).statusBarsPadding()) {
        // Rail / sidebar
        Column(
            modifier = Modifier
                .width(272.dp)
                .fillMaxSize()
                .background(neon.surface),
        ) {
            // Sidebar header
            Row(
                modifier = Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
            ) {
                Text(
                    ">conduit",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.ExtraBold,
                    fontSize = 16.sp,
                    color = neon.text,
                )
                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    IconButton(
                        onClick = {
                            Telemetry.breadcrumb("demo", "appearance_opened")
                            showingAppearance = true
                        },
                        modifier = Modifier.size(32.dp),
                    ) {
                        Icon(
                            Icons.Outlined.Settings,
                            contentDescription = "Appearance",
                            tint = neon.textDim,
                            modifier = Modifier.size(18.dp),
                        )
                    }
                    Text(
                        "Exit Demo",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 11.sp,
                        color = neon.codex,
                        modifier = Modifier
                            .clip(RoundedCornerShape(99.dp))
                            .clickable { onExitDemo() }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                    )
                }
            }
            DemoBanner(neon = neon, compact = true)
            DemoFlowsSection(neon = neon, onOpenFlow = { selectedFlowId = it })
            DemoSessionListContent(
                neon = neon,
                onSelect = { selectedSession = it; selectedFlowId = null },
                selectedId = selectedSession?.id,
            )
        }

        // Vertical divider
        Box(
            modifier = Modifier
                .width(1.dp)
                .fillMaxSize()
                .background(neon.border),
        )

        // Detail panel — Phase-2: tab switcher (Chat / Terminal / Browser),
        // or the flow Monitor when a FLOWS card was tapped.
        Column(modifier = Modifier.weight(1f).fillMaxSize()) {
            val flowId = selectedFlowId
            val flowStatus = flowId?.let { DemoData.pipelineStatus(it) }
            val session = selectedSession
            if (flowId != null && flowStatus != null) {
                PipelineMonitorScreen(
                    store = store,
                    pipelineId = flowId,
                    pipelineTitle = flowStatus.title,
                    onOpenSession = {},
                    onBack = { selectedFlowId = null },
                    demoStatus = flowStatus,
                )
            } else if (session != null) {
                DemoProjectScreen(store = store, session = session)
            } else {
                Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        "Select a session",
                        fontFamily = neon.mono,
                        fontSize = 14.sp,
                        color = neon.textFaint,
                    )
                }
            }
        }
    }

    if (showingAppearance) {
        AppearanceSheet(
            appearance = appearance,
            onDismiss = { showingAppearance = false },
        )
    }
}

// ---------------------------------------------------------------------------
// Shared composables
// ---------------------------------------------------------------------------

@Composable
private fun DemoTopBar(
    neon: NeonTheme,
    title: String,
    onExitDemo: () -> Unit,
    showExitDemo: Boolean,
    showBack: Boolean,
    onBack: () -> Unit,
    /** Non-null on the home/session-list screen; null inside a chat view. */
    onAppearance: (() -> Unit)?,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showBack) {
            // Chevron in a circle — matches iOS's back affordance and the app's
            // own onboarding back button (not a Material arrow).
            Box(
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(neon.surface)
                    .border(1.dp, neon.border, CircleShape)
                    .clickable { onBack() },
                contentAlignment = Alignment.Center,
            ) {
                Text("‹", color = neon.textDim, fontFamily = neon.mono, fontSize = 18.sp)
            }
        } else if (onAppearance != null) {
            // Gear icon on the home bar — mirrors iOS .navigationBarLeading gear button.
            IconButton(
                onClick = onAppearance,
                modifier = Modifier.size(34.dp),
            ) {
                Icon(
                    Icons.Outlined.Settings,
                    contentDescription = "Appearance",
                    tint = neon.textDim,
                    modifier = Modifier.size(18.dp),
                )
            }
        } else {
            Spacer(modifier = Modifier.size(34.dp))
        }
        Spacer(modifier = Modifier.weight(1f))
        Text(
            title,
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 15.sp,
            color = neon.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Spacer(modifier = Modifier.weight(1f))
        // iOS shows Exit Demo only on the home/session-list, not in the chat
        // header — keep a 34dp placeholder there so the title stays centered.
        if (showExitDemo) {
            Text(
                "Exit Demo",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                color = neon.codex,
                modifier = Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(neon.codex.copy(alpha = 0.12f))
                    .border(1.dp, neon.codex.copy(alpha = 0.35f), RoundedCornerShape(99.dp))
                    .clickable { onExitDemo() }
                    .padding(horizontal = 10.dp, vertical = 5.dp),
            )
        } else {
            Spacer(modifier = Modifier.size(34.dp))
        }
    }
}

@Composable
private fun DemoBanner(neon: NeonTheme, compact: Boolean = false) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = if (compact) 4.dp else 6.dp)
            .clip(RoundedCornerShape(10.dp))
            .background(neon.codex.copy(alpha = 0.08f))
            .border(1.dp, neon.codex.copy(alpha = 0.25f), RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "DEMO",
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 10.sp,
            color = neon.codex,
        )
        Text(
            "--",
            fontFamily = neon.mono,
            fontSize = 10.sp,
            color = neon.textFaint,
        )
        Text(
            "connect a real server to run AI agents",
            fontFamily = neon.mono,
            fontSize = if (compact) 10.sp else 11.sp,
            color = neon.textDim,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}

// ---------------------------------------------------------------------------
// Flows section (demo)
//
// Routes through the REAL FlowCard component + the real home's "FLOWS"
// section-header style (HomeScreen.kt) -- same seam pattern as the demo
// ChatPage (readOnlyItems): compose from the shared library, never a
// hand-rolled demo-only card. Placed above the demo session list on both
// phone and tablet layouts.
// ---------------------------------------------------------------------------

@Composable
private fun DemoFlowsSection(neon: NeonTheme, onOpenFlow: (String) -> Unit) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 6.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Text(
            "FLOWS",
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 12.sp,
            letterSpacing = 2.sp,
            color = neon.accent,
            maxLines = 1,
        )
        DemoData.pipelines.forEach { flow ->
            FlowCard(
                summary = flow,
                onOpen = {
                    Telemetry.breadcrumb(
                        "demo",
                        "flow_card_opened",
                        mapOf("pipeline_id" to flow.id, "state" to flow.state),
                    )
                    onOpenFlow(flow.id)
                },
                onContinue = {
                    // No network in demo mode -- the monitor's own
                    // static-fixture seam gates the same action.
                    Telemetry.breadcrumb("demo", "flow_card_continue_no_op", mapOf("pipeline_id" to flow.id))
                },
            )
        }
    }
}

@Composable
private fun DemoSessionListContent(
    neon: NeonTheme,
    onSelect: (ProjectSession) -> Unit,
    selectedId: String? = null,
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 14.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Text(
            "ACTIVE SESSIONS",
            fontFamily = neon.mono,
            fontWeight = FontWeight.SemiBold,
            fontSize = 11.sp,
            color = neon.codex,
            letterSpacing = 2.sp,
            modifier = Modifier.padding(bottom = 4.dp),
        )
        DemoData.sessions.forEach { session ->
            DemoSessionRow(
                neon = neon,
                session = session,
                isSelected = session.id == selectedId,
                onClick = { onSelect(session) },
            )
        }
    }
}

@Composable
private fun DemoSessionRow(
    neon: NeonTheme,
    session: ProjectSession,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val bgColor = if (isSelected) neon.codex.copy(alpha = 0.10f) else neon.surface
    val borderColor = if (isSelected) neon.codex.copy(alpha = 0.40f) else neon.border

    val lastMessage = DemoData.conversationBySession[session.id]
        ?.lastOrNull { it.role.lowercase() != "user" }
        ?.let { item ->
            if (item.role == "tool") {
                item.toolName?.let { "[$it]" } ?: "[tool]"
            } else {
                val c = item.content
                if (c.length > 60) c.take(60) + "..." else c
            }
        }

    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(bgColor)
            .border(1.dp, borderColor, RoundedCornerShape(12.dp))
            .clickable { onClick() }
            .padding(horizontal = 12.dp, vertical = 12.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        // Status dot
        Box(
            modifier = Modifier
                .size(8.dp)
                .clip(CircleShape)
                .background(neon.green)
                .padding(top = 2.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    session.displayName ?: session.name,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 14.sp,
                    color = neon.text,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    modifier = Modifier.weight(1f),
                )
                Spacer(modifier = Modifier.width(8.dp))
                // Agent badge
                Text(
                    session.assistant.lowercase(),
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 10.sp,
                    color = neon.claude,
                    modifier = Modifier
                        .clip(RoundedCornerShape(99.dp))
                        .background(neon.claude.copy(alpha = 0.12f))
                        .border(0.5.dp, neon.claude.copy(alpha = 0.30f), RoundedCornerShape(99.dp))
                        .padding(horizontal = 6.dp, vertical = 2.dp),
                )
            }
            if (lastMessage != null) {
                Spacer(modifier = Modifier.height(2.dp))
                Text(
                    lastMessage,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            session.cwd?.let { cwd ->
                Spacer(modifier = Modifier.height(1.dp))
                Text(
                    cwd,
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

// ---------------------------------------------------------------------------
// DemoProjectScreen — phase-2 tab shell (Chat / Terminal / Browser)
//
// Android mirror of iOS DemoProjectView: a NeonSegmentedPill tab switcher
// above the content. Chat = the real read-only ChatPage; Terminal = a static
// faux terminal (no PTY / libghostty); Browser = a WebView loading the
// bundled preview.html. No broker.
// ---------------------------------------------------------------------------

@Composable
private fun DemoProjectScreen(store: SessionStore, session: ProjectSession) {
    val neon = LocalNeonTheme.current
    var tab by remember { mutableStateOf(0) }
    var showInfo by remember { mutableStateOf(false) }
    var showChanges by remember { mutableStateOf(false) }
    val segments = listOf(
        NeonPillSegment("Chat", Icons.AutoMirrored.Outlined.Chat),
        NeonPillSegment("Terminal", Icons.Outlined.Terminal),
        NeonPillSegment("Browser", Icons.Outlined.Public),
    )
    LaunchedEffect(session.id) {
        Telemetry.breadcrumb("demo", "project_appeared", mapOf("session" to session.id))
    }
    Column(modifier = Modifier.fillMaxSize()) {
        // Tab pill centred above the content; info icon at the trailing edge.
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .background(neon.surfaceSolid)
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clickable {
                        showChanges = true
                        Telemetry.breadcrumb("demo", "changes_opened", mapOf("session" to session.id))
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.Difference,
                    contentDescription = "Changes",
                    tint = neon.textDim,
                    modifier = Modifier.size(20.dp),
                )
            }
            Row(modifier = Modifier.weight(1f), horizontalArrangement = Arrangement.Center) {
                NeonSegmentedPill(
                    segments = segments,
                    selected = tab,
                    onSelect = { i ->
                        tab = i
                        Telemetry.breadcrumb(
                            "demo",
                            "tab_switched",
                            mapOf("tab" to i.toString(), "session" to session.id),
                        )
                    },
                )
            }
            Box(
                modifier = Modifier
                    .size(32.dp)
                    .clickable {
                        showInfo = true
                        Telemetry.breadcrumb("demo", "session_info_opened", mapOf("session" to session.id))
                    },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Info,
                    contentDescription = "Session Info",
                    tint = neon.textDim,
                    modifier = Modifier.size(20.dp),
                )
            }
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
        Box(modifier = Modifier.weight(1f).fillMaxWidth()) {
            when (tab) {
                0 -> ChatPage(
                    store = store,
                    session = session,
                    readOnly = true,
                    readOnlyItems = DemoData.conversationBySession[session.id],
                )
                1 -> DemoTerminalPage()
                else -> DemoBrowserPage()
            }
        }
    }
    if (showInfo) {
        SessionInfoScreen(
            store = store,
            session = session,
            onDismiss = { showInfo = false },
            readOnly = true,
        )
    }
    if (showChanges) {
        DiffReviewScreen(
            store = store,
            session = session,
            onDismiss = { showChanges = false },
            readOnly = true,
        )
    }
}

@Composable
private fun DemoTerminalPage() {
    val neon = LocalNeonTheme.current
    val listState = rememberLazyListState()
    LaunchedEffect(Unit) {
        Telemetry.breadcrumb("demo", "terminal_appeared")
        if (DemoData.terminalLines.isNotEmpty()) {
            listState.scrollToItem(DemoData.terminalLines.size - 1)
        }
    }
    LazyColumn(
        state = listState,
        modifier = Modifier
            .fillMaxSize()
            .background(neon.codeBg)
            .padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        items(DemoData.terminalLines) { line ->
            if (line.isPrompt) {
                Row {
                    Text(
                        "$ ",
                        fontFamily = neon.mono,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.green,
                    )
                    Text(
                        line.text,
                        fontFamily = neon.mono,
                        fontSize = 13.sp,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.green,
                    )
                }
            } else {
                Text(
                    "  ${line.text}",
                    fontFamily = neon.mono,
                    fontSize = 13.sp,
                    color = neon.textDim,
                )
            }
        }
    }
}

@Composable
private fun DemoBrowserPage() {
    val neon = LocalNeonTheme.current
    LaunchedEffect(Unit) { Telemetry.breadcrumb("demo", "browser_appeared") }
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(neon.surfaceSolid),
    ) {
        // Chrome bar: globe + mono URL pill (matches BrowserPage chrome).
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Outlined.Public,
                contentDescription = null,
                tint = neon.accent,
                modifier = Modifier.size(14.dp),
            )
            Text(
                "https://todo.demo.local",
                fontFamily = neon.mono,
                fontSize = 12.sp,
                color = neon.codeText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
                modifier = Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(99.dp))
                    .background(neon.codeBg)
                    .border(1.dp, neon.border, RoundedCornerShape(99.dp))
                    .padding(horizontal = 10.dp, vertical = 7.dp),
            )
        }
        Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    webViewClient = WebViewClient()
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    loadUrl("file:///android_asset/demo/preview.html")
                }
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

