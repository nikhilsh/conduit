package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Terminal
import androidx.compose.material.icons.filled.Wifi
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.SessionNaming
import uniffi.conduit_core.ProjectSession

/**
 * Command palette (⌘K) surface — Conduit redesign (handoff §B.12, image 14).
 * Mirror of iOS `ConduitUI.CommandPaletteSheet`. A terminal-styled quick
 * switcher: a mono, prompt-styled (`>`) search field that filters live as
 * you type, three sections, and a keyboard-hints footer.
 *
 *   • Actions          — New session… · Pair a box.
 *   • Jump to session  — the live `store.sessions`, agent-tinted, filtered
 *                        by the typed query; selecting one calls
 *                        [onOpenSession].
 *   • Run on box       — one row that would run the typed command on the
 *                        box. There is NO "run on box" / new-session-with-
 *                        command path in the store today, so this is wired
 *                        to a no-op [onRunOnBox] closure the caller fills in
 *                        later.
 *
 * HOW TO PRESENT (the caller wires this — this file only defines the screen):
 * present it as a modal bottom sheet (it builds its own [ModalBottomSheet]),
 * e.g. behind a search affordance / a ⌘K key event:
 *
 *     if (showPalette) {
 *         CommandPaletteScreen(
 *             store = store,
 *             onNewSession = { /* open agent picker */ },
 *             onPairBox = { /* open add-server */ },
 *             onOpenSession = { id -> store.select(id) },
 *             onRunOnBox = { command -> /* TODO: run-on-box path */ },
 *             onDismiss = { showPalette = false },
 *         )
 *     }
 *
 * Reads only `store.sessions` + `store.displayNames` (+ the conversation
 * log for the friendly name) — never fabricates sessions. All callbacks
 * default to no-ops so it compiles + previews standalone. Uses `neon.*`
 * tokens only (no hardcoded hex).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CommandPaletteScreen(
    store: SessionStore,
    onNewSession: () -> Unit = {},
    onPairBox: () -> Unit = {},
    onOpenSession: (String) -> Unit = {},
    // No backing "run on box" / new-session-with-command path exists in the
    // store yet — defaults to a no-op TODO closure the caller wires later.
    onRunOnBox: (String) -> Unit = {},
    // "Fan out a task" action — caller presents the Fan-out surface
    // (`FanOutScreen`). Default no-op so the sheet compiles standalone.
    onFanOut: () -> Unit = {},
    // "New pipeline" action — caller presents PipelineBuilderScreen.
    onNewPipeline: () -> Unit = {},
    // "Pipelines" action — caller presents `PipelineListScreen` (the list of
    // running/past pipelines). Default no-op; only shown when
    // `store.pipelinesEnabled` is true (old brokers omit the flag).
    onPipelines: () -> Unit = {},
    onDismiss: () -> Unit = {},
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val neon = LocalNeonTheme.current
    val sessions by store.sessions.collectAsState()
    val displayNames by store.displayNames.collectAsState()
    val conversationLog by store.conversationLog.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val pipelinesEnabled by store.pipelinesEnabled.collectAsState()
    // Name the connected box in the "Run on box" header when we have one
    // (`RUN ON <host>`); fall back to the generic label otherwise.
    val runOnBoxHeader = if (endpoint.isComplete) "Run on ${endpoint.displayHost}" else "Run on box"

    var query by remember { mutableStateOf("") }
    val trimmed = query.trim()
    val q = trimmed.lowercase()

    // Friendly name resolver, identical to the home list / needs-you banner
    // (custom rename → first user message → broker label → "<agent> · time").
    fun friendly(session: ProjectSession): String = SessionNaming.friendlyFor(
        session = session,
        custom = displayNames[session.id],
        firstUserMessage = sh.nikhil.conduit.firstUserMessageOf(conversationLog[session.id]),
    )

    // Live sessions filtered by the query against the resolved name + agent +
    // branch. Never fabricates rows.
    val matches = remember(sessions, displayNames, conversationLog, q) {
        if (q.isEmpty()) sessions
        else sessions.filter { s ->
            friendly(s).lowercase().contains(q) ||
                s.assistant.lowercase().contains(q) ||
                (s.branch?.lowercase()?.contains(q) == true)
        }
    }

    val actions = remember(q, pipelinesEnabled) {
        buildList {
            add(PaletteActionSpec("new", "New session…", "⌘N"))
            add(PaletteActionSpec("pair", "Pair a box", null))
            add(PaletteActionSpec("fanout", "Fan out a task", null))
            add(PaletteActionSpec("pipeline", "New pipeline", null))
            if (pipelinesEnabled) add(PaletteActionSpec("pipelines", "Pipelines", null))
        }.filter { q.isEmpty() || it.title.lowercase().contains(q) }
    }

    fun runAction(id: String) {
        onDismiss()
        when (id) {
            "new" -> onNewSession()
            "pair" -> onPairBox()
            "fanout" -> onFanOut()
            "pipeline" -> onNewPipeline()
            "pipelines" -> onPipelines()
        }
    }

    // ⏎ primary intent: open the first matching session, else (with a query)
    // treat the line as a run-on-box command, else fall through to New session.
    fun runPrimary() {
        when {
            matches.isNotEmpty() -> {
                val id = matches.first().id
                onDismiss(); onOpenSession(id)
            }
            trimmed.isNotEmpty() -> { onDismiss(); onRunOnBox(trimmed) }
            else -> { onDismiss(); onNewSession() }
        }
    }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .windowInsetsPadding(WindowInsets.navigationBars),
        ) {
            // Search field (mono, prompt-styled `>`).
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 14.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Text(
                    ">",
                    fontFamily = neon.mono,
                    fontWeight = FontWeight.Bold,
                    fontSize = 16.sp,
                    color = if (neon.glow) neon.accent else neon.textDim,
                )
                Box(modifier = Modifier.weight(1f)) {
                    if (trimmed.isEmpty()) {
                        Text(
                            "Search actions, sessions, commands…",
                            fontFamily = neon.mono,
                            fontSize = 15.sp,
                            color = neon.textFaint,
                        )
                    }
                    BasicTextField(
                        value = query,
                        onValueChange = { query = it },
                        singleLine = true,
                        textStyle = TextStyle(
                            color = neon.text,
                            fontFamily = neon.mono,
                            fontSize = 15.sp,
                        ),
                        cursorBrush = SolidColor(neon.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Go),
                        keyboardActions = KeyboardActions(onGo = { runPrimary() }),
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
            }
            Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))

            // Sections.
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .heightIn(max = 420.dp)
                    .verticalScroll(rememberScrollState())
                    .padding(horizontal = 14.dp, vertical = 14.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp),
            ) {
                // 1 · Actions
                if (actions.isNotEmpty()) {
                    PaletteSection("Actions", neon) {
                        actions.forEach { action ->
                            PaletteRow(
                                neon = neon,
                                icon = if (action.id == "new") Icons.Default.Add else Icons.Default.Wifi,
                                avatarTint = null,
                                tint = neon.accent,
                                title = action.title,
                                titleMono = false,
                                trailing = action.shortcut,
                                onClick = { runAction(action.id) },
                            )
                        }
                    }
                }

                // 2 · Jump to session (live store.sessions, filtered + tinted)
                if (matches.isNotEmpty()) {
                    PaletteSection("Jump to session", neon) {
                        matches.forEach { session ->
                            val tint = neonAgentColor(session.assistant, neon)
                            PaletteRow(
                                neon = neon,
                                icon = null,
                                avatarTint = tint,
                                tint = tint,
                                title = friendly(session),
                                titleMono = false,
                                trailing = session.branch?.takeIf { it.isNotBlank() }
                                    ?: session.assistant.lowercase(),
                                onClick = {
                                    val id = session.id
                                    onDismiss(); onOpenSession(id)
                                },
                            )
                        }
                    }
                }

                // 3 · Run on box (only with a query; no backing path — onRunOnBox).
                if (trimmed.isNotEmpty()) {
                    PaletteSection(runOnBoxHeader, neon) {
                        PaletteRow(
                            neon = neon,
                            icon = Icons.Default.Terminal,
                            avatarTint = null,
                            tint = neon.green,
                            title = trimmed,
                            titleMono = true,
                            trailing = "↵",
                            onClick = {
                                val command = trimmed
                                onDismiss(); onRunOnBox(command)
                            },
                        )
                    }
                }
            }

            Box(Modifier.fillMaxWidth().height(1.dp).background(neon.border))

            // Keyboard hints footer.
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                PaletteHint("↑↓", "navigate", neon)
                PaletteHint("⏎", "open", neon)
                PaletteHint("⌘K", "toggle", neon)
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

private data class PaletteActionSpec(val id: String, val title: String, val shortcut: String?)

@Composable
private fun PaletteSection(title: String, neon: NeonTheme, content: @Composable () -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(
            title.uppercase(),
            fontFamily = neon.mono,
            fontWeight = FontWeight.Bold,
            fontSize = 10.5.sp,
            letterSpacing = 1.4.sp,
            color = neon.textFaint,
            modifier = Modifier.padding(start = 2.dp),
        )
        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) { content() }
    }
}

/**
 * A single palette row: a leading glyph (Material icon) OR an agent-tinted
 * [ConduitMark] avatar, a title (sans or mono), and an optional trailing
 * mono hint. Wrapped in a hairline neon card. Mirror of iOS `paletteRow`.
 */
@Composable
private fun PaletteRow(
    neon: NeonTheme,
    icon: ImageVector?,
    avatarTint: Color?,
    tint: Color,
    title: String,
    titleMono: Boolean,
    trailing: String?,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(11.dp), fill = neon.surface, borderColor = neon.border)
            .clickable(onClick = onClick)
            .padding(horizontal = 12.dp, vertical = 10.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(11.dp),
    ) {
        if (avatarTint != null) {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .background(avatarTint.copy(alpha = if (neon.dark) 0.14f else 0.10f), RoundedCornerShape(8.dp))
                    .border(1.dp, avatarTint.copy(alpha = 0.35f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) { ConduitMark(size = 18.dp, color = avatarTint) }
        } else {
            Box(
                modifier = Modifier
                    .size(30.dp)
                    .background(tint.copy(alpha = 0.12f), RoundedCornerShape(8.dp)),
                contentAlignment = Alignment.Center,
            ) {
                Icon(icon ?: Icons.Default.Add, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            }
        }
        Text(
            title,
            modifier = Modifier.weight(1f),
            style = if (titleMono) MaterialTheme.typography.bodyMedium else MaterialTheme.typography.bodyLarge,
            fontFamily = if (titleMono) neon.mono else neon.sans,
            fontWeight = if (titleMono) FontWeight.Normal else FontWeight.Medium,
            color = neon.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        if (!trailing.isNullOrEmpty()) {
            Text(
                trailing,
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textFaint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
    }
}

@Composable
private fun PaletteHint(key: String, label: String, neon: NeonTheme) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        Text(key, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = neon.textDim)
        Text(label, fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
    }
}
