package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.outlined.Search
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.SavedSession
import sh.nikhil.conduit.SessionNaming
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.VisibleSession
import sh.nikhil.conduit.firstUserMessageOf

/**
 * Unified tablet left rail — the design-reference `tablet.jsx` `TabletRail`.
 * Replaces the old 84dp icon activity bar + separate list: a single ~272dp
 * column that owns brand + connected-server chip, a Search button (which also
 * covers History), an overflow menu for Settings/Boxes, ACTIVE / RECENT
 * session lists, and a full-width "New session" button pinned at the bottom.
 * Home is the center empty-state when no session is selected.
 */
@Composable
fun NeonTabletRail(
    store: SessionStore,
    onPick: (String) -> Unit,
    onNewSession: () -> Unit,
    onSearch: () -> Unit,
    onOpenSettings: () -> Unit,
    onOpenBoxes: () -> Unit,
    onOpenTranscript: (SavedSession) -> Unit,
    onHome: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val sessions by store.sessions.collectAsState()
    val lifecycle by store.sessionLifecycle.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val selectedId by store.selectedId.collectAsState()
    val harness by store.harness.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()

    val savedAll by store.savedSessions.collectAsState()

    val active = remember(sessions, lifecycle) { store.visibleSessions() }
    // RECENT = saved/archived sessions not currently live. Capped so the rail
    // stays a quick-jump list, not the full History screen (that's Search).
    val activeIds = active.mapNotNull { (it as? VisibleSession.Real)?.session?.id }.toSet()
    val recent = remember(savedAll, activeIds) {
        store.savedSessionsRecent(limit = 8).filter { it.id !in activeIds }
    }
    var menuOpen by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .width(272.dp)
            .fillMaxHeight()
            .background(if (neon.dark) Color(0xFF060A14).copy(alpha = 0.4f) else Color.White.copy(alpha = 0.5f))
            .statusBarsPadding()
            // Keep the bottom "New session" button clear of the system gesture
            // bar — without this the rail's last child collides with the nav
            // bar on tablets (device bug).
            .navigationBarsPadding(),
    ) {
        // ── brand + server chip + overflow ──
        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 14.dp, end = 8.dp, top = 14.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            // Brand lockup doubles as "home": tapping it deselects the current
            // session and drops back to the home empty-state. On the 3-pane
            // tablet the rail has no other back affordance, and a user on a
            // session couldn't find the way back to the main screen (device
            // feedback 2026-06-01).
            Row(
                modifier = Modifier.clip(RoundedCornerShape(8.dp)).clickable { onHome() }.padding(end = 2.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                ConduitMark(size = 24.dp)
                Row(verticalAlignment = Alignment.Bottom) {
                    Text(">", fontFamily = neon.mono, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = if (neon.glow) neon.accent else neon.textDim)
                    Text("conduit", fontFamily = neon.mono, fontSize = 15.sp, fontWeight = FontWeight.Bold, color = neon.text)
                }
            }
            // The chip lives in the *weighted* slot so it's measured after the
            // fixed-width gear reserves its space — otherwise a long endpoint
            // (e.g. 103.107.51.48:1977) eats the rail width and clips the gear
            // off the 272dp edge (device feedback: "missing settings icon on
            // tablet"). End-aligned so it still hugs the gear; ellipsizes when tight.
            Box(modifier = Modifier.weight(1f), contentAlignment = Alignment.CenterEnd) {
                ServerChip(harness = harness, host = endpoint.displayHost, neon = neon)
            }
            Box {
                // A gear, not a `•••`: the dim ellipsis was undiscoverable as the
                // route to Settings on tablet (device feedback 2026-06-01).
                // Settings is the primary item; Boxes stays as the secondary entry.
                Icon(
                    Icons.Outlined.Settings,
                    contentDescription = "Settings and more",
                    tint = neon.textDim,
                    modifier = Modifier.size(22.dp).clip(RoundedCornerShape(8.dp)).clickable { menuOpen = true },
                )
                DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                    DropdownMenuItem(text = { Text("Settings") }, onClick = { menuOpen = false; onOpenSettings() })
                    DropdownMenuItem(text = { Text("Boxes") }, onClick = { menuOpen = false; onOpenBoxes() })
                }
            }
        }

        // ── search → palette / history ──
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp)
                .clip(RoundedCornerShape(11.dp))
                .background(if (neon.dark) Color.White.copy(alpha = 0.05f) else Color.White)
                .border(1.dp, if (neon.glow) neon.accent.copy(alpha = 0.23f) else neon.border, RoundedCornerShape(11.dp))
                .clickable { onSearch() }
                .padding(horizontal = 11.dp, vertical = 9.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Icon(Icons.Outlined.Search, contentDescription = null, tint = if (neon.glow) neon.accent else neon.textDim, modifier = Modifier.size(16.dp))
            Text("Search…", fontFamily = neon.sans, fontSize = 12.5.sp, color = neon.textFaint, modifier = Modifier.weight(1f))
        }

        Spacer(Modifier.size(8.dp))

        // ── lists ──
        LazyColumn(modifier = Modifier.weight(1f).padding(horizontal = 8.dp)) {
            if (active.isNotEmpty()) {
                item { RailGroupLabel("Active", neon) }
                items(active, key = { it.id }) { entry ->
                    val real = (entry as? VisibleSession.Real)?.session
                    val friendly = real?.let { s ->
                        SessionNaming.friendlyFor(
                            session = s,
                            custom = displayNames[s.id],
                            firstUserMessage = firstUserMessageOf(conversationLog[s.id]),
                        )
                    }
                    val health = real?.let { statuses[it.id]?.health }
                    NeonRailRow(
                        title = friendly ?: (real?.id?.take(8) ?: "Starting…"),
                        agent = real?.assistant ?: "claude",
                        subtitle = real?.let { "${it.assistant} · ${shortCwd(it.cwd)}" } ?: "starting…",
                        dotColor = railDot(health, neon),
                        selected = entry.id == selectedId,
                        neon = neon,
                        onClick = { real?.let { onPick(it.id) } },
                    )
                }
            }
            if (recent.isNotEmpty()) {
                item { RailGroupLabel("Recent", neon) }
                items(recent, key = { "saved-" + it.compoundId }) { saved ->
                    NeonRailRow(
                        title = saved.summary.ifBlank { "${saved.agent} session" },
                        agent = saved.agent,
                        subtitle = "${saved.agent} · ${shortCwd(saved.cwd)}",
                        dotColor = neon.textFaint,
                        selected = false,
                        neon = neon,
                        onClick = { onOpenTranscript(saved) },
                    )
                }
            }
        }

        // ── new session ──
        Box(modifier = Modifier.fillMaxWidth().padding(12.dp)) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(12.dp))
                    .background(if (neon.glow) neon.accent else neon.accent)
                    .clickable { onNewSession() }
                    .padding(vertical = 11.dp),
                horizontalArrangement = Arrangement.Center,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(Icons.Filled.Add, contentDescription = null, tint = neon.accentText, modifier = Modifier.size(16.dp))
                Spacer(Modifier.size(8.dp))
                Text("New session", fontFamily = neon.sans, fontSize = 13.5.sp, fontWeight = FontWeight.Bold, color = neon.accentText)
            }
        }
    }
}

@Composable
private fun ServerChip(harness: HarnessState, host: String, neon: NeonTheme) {
    val (label, color) = when (harness) {
        is HarnessState.Live, is HarnessState.Linked -> host to neon.green
        is HarnessState.Connecting, is HarnessState.Reconnecting -> "connecting" to neon.yellow
        else -> "offline" to neon.textFaint
    }
    Row(
        modifier = Modifier
            .clip(RoundedCornerShape(99.dp))
            .background(neon.surface)
            .border(1.dp, neon.border, RoundedCornerShape(99.dp))
            .padding(horizontal = 9.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Box(Modifier.size(5.dp).clip(RoundedCornerShape(99.dp)).background(color))
        Text(label, fontFamily = neon.mono, fontSize = 10.sp, color = color, maxLines = 1, overflow = TextOverflow.Ellipsis)
    }
}

@Composable
private fun RailGroupLabel(text: String, neon: NeonTheme) {
    Text(
        text.uppercase(),
        fontFamily = neon.mono,
        fontSize = 9.5.sp,
        fontWeight = FontWeight.Medium,
        color = neon.textFaint,
        modifier = Modifier.padding(start = 11.dp, top = 10.dp, bottom = 5.dp),
    )
}

@Composable
private fun NeonRailRow(
    title: String,
    agent: String,
    subtitle: String,
    dotColor: Color,
    selected: Boolean,
    neon: NeonTheme,
    onClick: () -> Unit,
) {
    val c = neonAgentColor(agent, neon)
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 1.5.dp)
            .clip(RoundedCornerShape(12.dp))
            .background(if (selected) c.copy(alpha = 0.12f) else Color.Transparent)
            .border(1.dp, if (selected) c.copy(alpha = 0.4f) else Color.Transparent, RoundedCornerShape(12.dp))
            .clickable { onClick() }
            .padding(horizontal = 11.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Box(
            modifier = Modifier.size(30.dp).clip(RoundedCornerShape(8.dp)).background(c.copy(alpha = 0.10f)).border(1.dp, c.copy(alpha = 0.2f), RoundedCornerShape(8.dp)),
            contentAlignment = Alignment.Center,
        ) { ConduitMark(size = 18.dp, color = c) }
        Column(modifier = Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Text(title, fontFamily = neon.sans, fontSize = 13.sp, fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Medium, color = neon.text, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.weight(1f))
                Box(Modifier.size(6.dp).clip(RoundedCornerShape(99.dp)).background(dotColor))
            }
            Text(subtitle, fontFamily = neon.mono, fontSize = 9.5.sp, color = neon.textFaint, maxLines = 1, overflow = TextOverflow.Ellipsis, modifier = Modifier.padding(top = 2.dp))
        }
    }
}

private fun railDot(health: String?, neon: NeonTheme): Color = when (health) {
    "green" -> neon.green
    "yellow" -> neon.yellow
    "red" -> Color(0xFFEF4444)
    else -> neon.textFaint
}

private fun shortCwd(cwd: String?): String {
    val c = cwd?.trim().orEmpty()
    if (c.isEmpty()) return "~"
    return c.substringAfterLast('/').ifBlank { c }
}
