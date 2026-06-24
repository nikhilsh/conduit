package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.outlined.Terminal
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.demo.DemoData
import uniffi.conduit_core.ConversationItem
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

    LaunchedEffect(Unit) {
        Telemetry.breadcrumb("demo", "home_appeared", mapOf("tablet" to isTablet.toString()))
    }

    if (isTablet) {
        DemoTabletLayout(onExitDemo = onExitDemo)
    } else {
        DemoPhoneLayout(onExitDemo = onExitDemo)
    }
}

// ---------------------------------------------------------------------------
// Phone layout: session list -> chat push
// ---------------------------------------------------------------------------

@Composable
private fun DemoPhoneLayout(onExitDemo: () -> Unit) {
    val neon = LocalNeonTheme.current
    var selectedSession by remember { mutableStateOf<ProjectSession?>(null) }

    Box(modifier = Modifier.fillMaxSize().background(neon.appBg)) {
        if (selectedSession == null) {
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .statusBarsPadding(),
            ) {
                DemoTopBar(
                    neon = neon,
                    title = ">conduit",
                    onExitDemo = onExitDemo,
                    showBack = false,
                    onBack = {},
                )
                DemoBanner(neon = neon)
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
                    showBack = true,
                    onBack = { selectedSession = null },
                )
                DemoChatContent(
                    neon = neon,
                    session = session,
                    modifier = Modifier.weight(1f),
                )
                DemoDisabledComposer(neon = neon)
            }
        }
    }
}

// ---------------------------------------------------------------------------
// Tablet layout: rail + detail
// ---------------------------------------------------------------------------

@Composable
private fun DemoTabletLayout(onExitDemo: () -> Unit) {
    val neon = LocalNeonTheme.current
    var selectedSession by remember { mutableStateOf(DemoData.sessions.firstOrNull()) }

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
            DemoBanner(neon = neon, compact = true)
            DemoSessionListContent(
                neon = neon,
                onSelect = { selectedSession = it },
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

        // Detail panel
        Column(modifier = Modifier.weight(1f).fillMaxSize()) {
            val session = selectedSession
            if (session != null) {
                DemoChatContent(
                    neon = neon,
                    session = session,
                    modifier = Modifier.weight(1f),
                    showHeader = true,
                )
                DemoDisabledComposer(neon = neon)
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
}

// ---------------------------------------------------------------------------
// Shared composables
// ---------------------------------------------------------------------------

@Composable
private fun DemoTopBar(
    neon: NeonTheme,
    title: String,
    onExitDemo: () -> Unit,
    showBack: Boolean,
    onBack: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (showBack) {
            Icon(
                imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = neon.textDim,
                modifier = Modifier
                    .size(34.dp)
                    .clip(CircleShape)
                    .background(neon.surface)
                    .border(1.dp, neon.border, CircleShape)
                    .clickable { onBack() }
                    .padding(7.dp),
            )
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

@Composable
private fun DemoChatContent(
    neon: NeonTheme,
    session: ProjectSession,
    modifier: Modifier = Modifier,
    showHeader: Boolean = false,
) {
    val items = DemoData.conversationBySession[session.id] ?: emptyList()

    LaunchedEffect(session.id) {
        Telemetry.breadcrumb("demo", "chat_appeared", mapOf("session" to session.id))
    }

    LazyColumn(
        modifier = modifier
            .fillMaxWidth()
            .background(neon.appBg),
        contentPadding = androidx.compose.foundation.layout.PaddingValues(
            horizontal = 14.dp,
            vertical = 8.dp,
        ),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (showHeader) {
            item {
                Text(
                    session.displayName ?: session.name,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 18.sp,
                    color = neon.text,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
        }
        items(items, key = { it.id }) { item ->
            DemoChatRow(neon = neon, item = item)
        }
    }
}

@Composable
private fun DemoChatRow(neon: NeonTheme, item: ConversationItem) {
    when (item.role.lowercase()) {
        "user" -> DemoUserRow(neon = neon, item = item)
        "tool" -> DemoToolRow(neon = neon, item = item)
        else -> DemoAssistantRow(neon = neon, item = item)
    }
}

@Composable
private fun DemoUserRow(neon: NeonTheme, item: ConversationItem) {
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
        Spacer(modifier = Modifier.weight(0.15f))
        Text(
            item.content,
            fontFamily = neon.sans,
            fontSize = 14.sp,
            color = neon.text,
            modifier = Modifier
                .clip(RoundedCornerShape(14.dp))
                .background(neon.codex.copy(alpha = 0.12f))
                .border(1.dp, neon.codex.copy(alpha = 0.25f), RoundedCornerShape(14.dp))
                .padding(horizontal = 12.dp, vertical = 9.dp),
        )
    }
}

@Composable
private fun DemoAssistantRow(neon: NeonTheme, item: ConversationItem) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.Top,
    ) {
        Box(
            modifier = Modifier
                .size(22.dp)
                .clip(CircleShape)
                .background(neon.claude.copy(alpha = 0.18f))
                .padding(top = 2.dp),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                "C",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 10.sp,
                color = neon.claude,
            )
        }
        Text(
            item.content,
            fontFamily = neon.sans,
            fontSize = 14.sp,
            color = neon.text,
            modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun DemoToolRow(neon: NeonTheme, item: ConversationItem) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(10.dp))
            .background(neon.codeBg)
            .border(1.dp, neon.border, RoundedCornerShape(10.dp))
            .padding(horizontal = 12.dp, vertical = 9.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            imageVector = Icons.Outlined.Terminal,
            contentDescription = null,
            tint = neon.green,
            modifier = Modifier.size(14.dp),
        )
        Column(modifier = Modifier.weight(1f)) {
            item.toolName?.let { name ->
                Text(
                    name,
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 11.sp,
                    color = neon.green,
                )
            }
            item.command?.let { cmd ->
                Text(
                    cmd,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            item.exitCode?.let { code ->
                Text(
                    "exit $code",
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = if (code == 0) neon.green else neon.accent,
                )
            }
        }
    }
}

@Composable
private fun DemoDisabledComposer(neon: NeonTheme) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(neon.surface)
            .navigationBarsPadding()
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Icon(
            imageVector = Icons.Filled.Lock,
            contentDescription = null,
            tint = neon.textFaint,
            modifier = Modifier.size(16.dp),
        )
        Text(
            "Connect a real server to start a session",
            fontFamily = neon.sans,
            fontSize = 14.sp,
            color = neon.textFaint,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            modifier = Modifier.weight(1f),
        )
    }
}
