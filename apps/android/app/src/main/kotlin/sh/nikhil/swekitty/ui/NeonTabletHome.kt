package sh.nikhil.swekitty.ui

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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Dns
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.swekitty.HarnessState
import sh.nikhil.swekitty.SessionNaming
import sh.nikhil.swekitty.SessionStore
import sh.nikhil.swekitty.firstUserMessageOf
import sh.nikhil.swekitty.latestActivityPreviewOf

// Android mirror of iOS LitterUI.TabletHome — the design bundle's tablet
// Home dashboard (tablet-sections.jsx → TabletHome): a 2-col grid of
// session cards + a 2-col Boxes grid, under a header with a connection
// chip. Reuses the home data + naming/preview helpers. Outcome chips are
// omitted (no diff/PR/test data to back them).

@Composable
fun NeonTabletHome(store: SessionStore, onOpenSession: (String) -> Unit) {
    val neon = LocalNeonTheme.current
    val sessions by store.sessions.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val connected = harness is HarnessState.Live || harness is HarnessState.Linked

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(horizontal = 24.dp, vertical = 18.dp),
    ) {
        // Header
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Home", fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 22.sp, color = neon.text)
            Spacer(Modifier.weight(1f))
            val (label, color) = when (harness) {
                is HarnessState.Live, is HarnessState.Linked -> (if (endpoint.isComplete) endpoint.displayHost else "online") to neon.green
                is HarnessState.Connecting, is HarnessState.Reconnecting -> "connecting" to neon.yellow
                else -> "offline" to neon.textFaint
            }
            Row(
                modifier = Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(neon.surface)
                    .border(1.dp, neon.border, RoundedCornerShape(99.dp))
                    .padding(horizontal = 13.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(7.dp),
            ) {
                Box(Modifier.size(6.dp).clip(RoundedCornerShape(99.dp)).background(color))
                Text(label, fontFamily = neon.mono, fontSize = 11.5.sp, color = color)
            }
        }
        Spacer(Modifier.size(16.dp))

        if (sessions.isEmpty()) {
            SectionLabel("Active sessions", neon)
            Text(
                if (connected) "No sessions yet — start one from the Sessions tab." else "Waiting for the server.",
                fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim,
                modifier = Modifier.padding(vertical = 20.dp),
            )
        } else {
            SectionLabel("Active sessions", neon)
            GridOf(sessions.map { it.id }) { id ->
                val session = sessions.first { it.id == id }
                val phase = statuses[id]?.phase
                val isRunning = connected && !(phase ?: "ready").startsWith("exited")
                val title = SessionNaming.friendlyFor(
                    session = session,
                    custom = displayNames[id],
                    firstUserMessage = firstUserMessageOf(conversationLog[id]),
                )
                val preview = latestActivityPreviewOf(conversationLog[id])
                SessionCard(neon, title, session.assistant, isRunning, preview, session) { onOpenSession(id) }
            }
            Spacer(Modifier.size(24.dp))
        }

        if (savedServers.isNotEmpty()) {
            SectionLabel("Boxes", neon)
            GridOf(savedServers.map { it.id }) { sid ->
                val server = savedServers.first { it.id == sid }
                val isActive = endpoint == server.endpoint
                val color = when {
                    !isActive -> neon.textFaint
                    connected -> neon.green
                    harness is HarnessState.Connecting || harness is HarnessState.Reconnecting -> neon.yellow
                    else -> neon.textFaint
                }
                BoxCard(neon, server.name, server.endpoint.displayHost, isActive, color) {
                    store.selectSavedServer(server.id, autoConnect = true)
                }
            }
        }
    }
}

/** 2-column grid laid out as chunked rows (avoids nested-scroll constraints). */
@Composable
private fun GridOf(ids: List<String>, item: @Composable (String) -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(14.dp)) {
        ids.chunked(2).forEach { pair ->
            Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.fillMaxWidth()) {
                pair.forEach { id ->
                    Box(Modifier.weight(1f)) { item(id) }
                }
                if (pair.size == 1) Spacer(Modifier.weight(1f))
            }
        }
    }
}

@Composable
private fun SectionLabel(text: String, neon: NeonTheme) {
    Text(
        text.uppercase(),
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        fontSize = 11.sp,
        color = neon.textDim,
        modifier = Modifier.padding(top = 4.dp, bottom = 10.dp),
    )
}

@Composable
private fun SessionCard(
    neon: NeonTheme,
    title: String,
    assistant: String,
    isRunning: Boolean,
    preview: String?,
    session: uniffi.swe_kitty_core.ProjectSession,
    onClick: () -> Unit,
) {
    val tint = neonAgentColor(assistant, neon)
    val shape = RoundedCornerShape((neon.radiusDp - 2).dp)
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onClick)
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(8.dp).clip(RoundedCornerShape(99.dp)).background(if (isRunning) neon.green else neon.textFaint))
            Text(title, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, color = neon.text, maxLines = 1)
        }
        Text(assistant, fontFamily = neon.mono, fontSize = 10.5.sp, color = tint)
        if (!preview.isNullOrBlank()) {
            Text(preview, fontFamily = neon.sans, fontSize = 12.5.sp, color = neon.textDim, maxLines = 2)
        }
        NeonOutcomeChips(
            neon = neon,
            linesAdded = session.linesAdded?.toInt(),
            linesRemoved = session.linesRemoved?.toInt(),
            commits = session.commits?.toInt(),
            prNumber = session.prNumber?.toInt(),
            prState = session.prState,
        )
    }
}

@Composable
private fun BoxCard(
    neon: NeonTheme,
    name: String,
    host: String,
    isActive: Boolean,
    color: Color,
    onClick: () -> Unit,
) {
    val shape = RoundedCornerShape((neon.radiusDp - 4).dp)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clip(shape)
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 15.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(13.dp),
    ) {
        Box(
            modifier = Modifier
                .size(40.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(color.copy(alpha = 0.11f))
                .border(1.dp, color.copy(alpha = 0.22f), RoundedCornerShape(11.dp)),
            contentAlignment = Alignment.Center,
        ) {
            Icon(Icons.Outlined.Dns, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 14.5.sp, color = neon.text, maxLines = 1)
            Text(host, fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint, maxLines = 1)
        }
        Text(if (isActive) "active" else "tap", fontFamily = neon.mono, fontSize = 11.sp, color = color)
    }
}
