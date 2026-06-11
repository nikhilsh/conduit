package sh.nikhil.conduit.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ArrowOutward
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
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
import sh.nikhil.conduit.AgentDescriptor
import sh.nikhil.conduit.RemoteDirectoryListing
import sh.nikhil.conduit.RemoteHarnessStatus
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.descriptorFor
import sh.nikhil.conduit.readinessCheckItems

/**
 * Ordered agent list for the picker cards row. Known agents (claude, codex)
 * come first in declaration order; extra agents from the broker are appended
 * alphabetically. Falls back to [claude, codex] when no live descriptors are
 * available. Internal so [AgentDescriptorTest] can exercise it.
 */
internal fun agentListFor(descriptors: Map<String, AgentDescriptor>): List<String> {
    if (descriptors.isEmpty()) return listOf("claude", "codex")
    val known = listOf("claude", "codex").filter { it in descriptors }
    val extras = (descriptors.keys - known.toSet()).sorted()
    return known + extras
}

/**
 * Compose mirror of `apps/ios/Sources/ConduitUI/Views/ConduitAgentPickerSheet.swift`.
 * Two-step new-session flow:
 *   1. Pick an agent (Claude / Codex).
 *   2. Pick a working directory — a "Recent" shortcut list plus a live
 *      browser over `store.listDirectories(path:)` (tap a folder to
 *      descend, the up button to go back). "Use this folder" cd's into
 *      the current path; "Start without a folder" preserves the old
 *      no-cwd behavior. (upstream parity, task #36.)
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AgentPickerSheet(
    store: SessionStore,
    headerNote: String? = null,
    onDismiss: () -> Unit,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val harness by store.harness.collectAsState()
    val neon = LocalNeonTheme.current
    var pickedAgent by remember { mutableStateOf<String?>(null) }
    // WS-H.3: agent-login sheet launched from "Sign in" on a not-signed-in
    // readiness row (informational, never blocking).
    var showAgentLogin by remember { mutableStateOf(false) }
    // Box the session should run on (round 3: "I can't choose where to
    // start the session in"). null = the currently connected box; an
    // explicit pick of a different box routes the create through
    // `store.connectAndStart` (switch endpoint → connect → create).
    // Mirror of iOS ConduitAgentPickerSheet.
    val savedServers by store.savedServers.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    var selectedServerId by remember { mutableStateOf<String?>(null) }
    val resolvedServerId = selectedServerId
        ?: savedServers.firstOrNull { it.endpoint == endpoint }?.id

    // §6: the new-session surface is a centered modal over the dimmed
    // two-pane on tablet (≥840dp), and a bottom sheet on phone.
    val wide = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 840

    // Pull the live per-agent model catalog (broker-discovered from the
    // agent CLIs) so the cards' model line and the directory step's
    // model/effort options reflect what the box actually serves. Failure =
    // keep static fallbacks.
    LaunchedEffect(Unit) {
        store.refreshModelCatalog()
        // Funnel: agent picker opened (new-session flow or post-pair deep link).
        val isFirstSession = store.sessions.value.isEmpty()
        Telemetry.breadcrumb("onboarding", OnboardingStep.AGENT_PICKER_OPENED,
            mapOf("first_session" to isFirstSession.toString(),
                  "host" to store.endpoint.value.displayHost))
    }

    // Container-agnostic content — both presentations render the same flow.
    val content: @Composable () -> Unit = {
        val agent = pickedAgent
        if (agent == null) {
            AgentStep(
                store = store,
                headerNote = headerNote,
                canIssue = harness.canIssueCommands,
                servers = savedServers,
                selectedServerId = resolvedServerId,
                onSelectServer = { selectedServerId = it },
                onPick = { pickedAgent = it },
                onSignIn = { showAgentLogin = true },
            )
        } else {
            DirectoryStep(
                store = store,
                assistant = agent,
                agentTint = neonAgentColor(agent, neon),
                onCreate = { cwd, model, effort, permissionMode, seedPrompt ->
                    val target = savedServers.firstOrNull { it.id == resolvedServerId }
                    if (target != null && target.endpoint != endpoint) {
                        // Session targeted at a different box: switch
                        // endpoint → connect → create.
                        store.connectAndStart(target.id, assistant = agent, cwd = cwd, reasoningEffort = effort, model = model, permissionMode = permissionMode, initialPrompt = seedPrompt)
                    } else {
                        store.createSession(assistant = agent, startupCwd = cwd, reasoningEffort = effort, model = model, permissionMode = permissionMode, initialPrompt = seedPrompt)
                    }
                    onDismiss()
                },
            )
        }
    }

    if (wide) {
        androidx.compose.ui.window.Dialog(onDismissRequest = onDismiss) {
            androidx.compose.material3.Surface(
                shape = RoundedCornerShape(22.dp),
                color = neon.surfaceSolid,
                modifier = Modifier.width(620.dp).heightIn(max = 760.dp),
            ) {
                content()
            }
        }
    } else {
        ModalBottomSheet(
            onDismissRequest = onDismiss,
            sheetState = sheetState,
            containerColor = neon.surfaceSolid,
            shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
        ) {
            content()
        }
    }

    // WS-H.3: agent-login sheet launched from a readiness "Sign in" tap.
    if (showAgentLogin) {
        AgentLoginSheet(store = store, onDismiss = { showAgentLogin = false })
    }
}

@Composable
private fun AgentStep(
    store: SessionStore,
    headerNote: String?,
    canIssue: Boolean,
    servers: List<sh.nikhil.conduit.SavedServer>,
    selectedServerId: String?,
    onSelectServer: (String) -> Unit,
    onPick: (String) -> Unit,
    onSignIn: (provider: String) -> Unit = {},
) {
    val neon = LocalNeonTheme.current
    val appearance = sh.nikhil.conduit.LocalAppearanceStore.current
    val useCards by appearance.newSessionAgentCards.collectAsState()
    // Cards mode (§3): the selected agent tints the whole sheet + the Continue
    // button before the user commits. Defaults to Claude (first card).
    var selectedAgent by remember { mutableStateOf("claude") }
    val sheetTint = neonAgentColor(selectedAgent, neon)
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Text(
            "New session",
            style = MaterialTheme.typography.titleMedium,
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            color = neon.text,
        )
        if (!headerNote.isNullOrBlank()) {
            Box(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
            ) {
                Column(modifier = Modifier.fillMaxWidth().padding(14.dp)) {
                    Text(
                        "Paired with",
                        style = MaterialTheme.typography.labelSmall,
                        fontFamily = neon.mono,
                        color = neon.textDim,
                        fontWeight = FontWeight.SemiBold,
                    )
                    Text(
                        headerNote,
                        style = MaterialTheme.typography.titleSmall,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        color = neon.text,
                    )
                }
            }
        }
        // Hoist state collection unconditionally (Compose scoping rule:
        // collectAsState must not move in/out of conditional blocks).
        val catalogs by store.modelCatalog.collectAsState()
        val descriptors by store.agentDescriptors.collectAsState()
        if (useCards) {
            // Live default-model names from the discovered catalog
            // ("GPT-5.5", "Opus 4.8") — the static strings are only the
            // offline fallback, so the cards never pin a stale model name.
            // Unknown agents (e.g. "opencode") get a generic card.
            val agentList = agentListFor(descriptors)
            Row(horizontalArrangement = Arrangement.spacedBy(11.dp), modifier = Modifier.fillMaxWidth()) {
                agentList.forEach { agent ->
                    AgentCardForAssistant(
                        assistant = agent,
                        descriptor = descriptors[agent],
                        catalog = catalogs[agent],
                        selected = selectedAgent == agent,
                        enabled = canIssue,
                        onTap = { selectedAgent = agent },
                        modifier = Modifier.weight(1f),
                    )
                }
            }
        } else {
            AgentTile(
                assistant = "claude",
                label = "Claude",
                subtitle = "Powered by Anthropic",
                tint = neon.claude,
                enabled = canIssue,
                onTap = { onPick("claude") },
            )
            AgentTile(
                assistant = "codex",
                label = "Codex",
                subtitle = "Powered by OpenAI",
                tint = neon.codex,
                enabled = canIssue,
                onTap = { onPick("codex") },
            )
        }
        // Box choice — always shown so the user can see where the session
        // will run (device feedback round 4: gated on >1 servers, a
        // single-box user "can't choose the box" and can't tell local vs
        // server). "This device" on the home Boxes list is display-only (a
        // phone can't host the broker), so it is deliberately not a target
        // here; the single-box footnote says so. Mirror of iOS boxSection.
        if (servers.isNotEmpty()) {
            Text(
                "BOX",
                style = MaterialTheme.typography.labelSmall,
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                color = neon.textFaint,
            )
            servers.forEach { server ->
                BoxRow(
                    name = server.name,
                    host = server.endpoint.displayHost,
                    selected = server.id == selectedServerId,
                    onTap = { onSelectServer(server.id) },
                )
            }
            if (servers.size == 1) {
                Text(
                    "Sessions run on a paired box — this device can't host them. Pair another box in Settings.",
                    fontFamily = neon.mono,
                    fontSize = 10.5.sp,
                    color = neon.textFaint,
                )
            }
        }
        if (!canIssue) {
            Text(
                "Connect to a server first — open Settings to pair.",
                style = MaterialTheme.typography.bodySmall,
                fontFamily = neon.sans,
                color = neon.textDim,
            )
        }
        // Cards mode commits with a tinted Continue button (§3); tiles mode
        // drills in on tap, so no button there.
        if (useCards && canIssue) {
            Button(
                onClick = { onPick(selectedAgent) },
                shape = RoundedCornerShape(14.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = sheetTint,
                    contentColor = neon.accentText,
                ),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(
                    "Continue with ${descriptors[selectedAgent]?.displayName ?: selectedAgent.replaceFirstChar { it.uppercaseChar() }}",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                )
            }
        }
        // WS-H.3: post-pair readiness checklist — informational, never blocking.
        // Only shown when the broker sent a readiness block (null = old broker).
        val readiness by store.brokerReadiness.collectAsState()
        readiness?.let { r ->
            val items = readinessCheckItems(r, descriptors)
            if (items.isNotEmpty()) {
                SectionLabel("Box readiness")
                ReadinessChecklist(items = items, onSignIn = onSignIn)
            }
        }
        Spacer(Modifier.height(8.dp))
    }
}

/**
 * Dispatches to the branded [AgentCard] for known agents (claude/codex) or
 * a generic card for any other assistant the broker reports. Descriptor-
 * driven so a third agent ("opencode") renders without a code change.
 */
@Composable
private fun AgentCardForAssistant(
    assistant: String,
    descriptor: AgentDescriptor?,
    catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?,
    selected: Boolean,
    enabled: Boolean,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    val name = descriptor?.displayName ?: assistant.replaceFirstChar { it.uppercaseChar() }
    val model = defaultModelTitle(catalog) ?: ""
    val tint = neonAgentColor(assistant, neon)
    val blurb = when (assistant.lowercase()) {
        "claude" -> "Careful, conversational — best for ambiguous work."
        "codex"  -> "Terse and fast on well-scoped code tasks."
        else     -> descriptor?.displayName?.let { "Powered by $it." } ?: "A third-party agent."
    }
    AgentCard(
        assistant = assistant,
        name = name,
        model = model,
        blurb = blurb,
        tint = tint,
        selected = selected,
        enabled = enabled,
        onTap = onTap,
        modifier = modifier,
    )
}

/**
 * Side-by-side agent card (§3, `02-ns`): brand-tinted, with the model name
 * and a one-line character note. Selecting tints the sheet + Continue button.
 * Mirrors iOS `agentCard`.
 */
@Composable
private fun AgentCard(
    assistant: String,
    name: String,
    model: String,
    blurb: String,
    tint: Color,
    selected: Boolean,
    enabled: Boolean,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(15.dp)
    Column(
        modifier = modifier
            .neonCardSurface(
                neon = neon,
                shape = shape,
                fill = if (selected) tint.copy(alpha = 0.14f) else neon.surface,
                borderColor = if (selected) tint else neon.border,
                glowTint = if (selected) tint else null,
            )
            .clickable(enabled = enabled, onClick = onTap)
            .padding(13.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.Top, modifier = Modifier.fillMaxWidth()) {
            AgentAvatar(assistant = assistant, size = 34.dp)
            Spacer(Modifier.weight(1f))
            if (selected) {
                Icon(
                    Icons.Filled.CheckCircle,
                    contentDescription = null,
                    tint = tint,
                    modifier = Modifier.size(20.dp),
                )
            } else {
                Box(
                    modifier = Modifier.size(20.dp).clip(CircleShape)
                        .border(1.5.dp, neon.border, CircleShape),
                )
            }
        }
        Text(name, fontFamily = neon.sans, fontWeight = FontWeight.Bold, fontSize = 16.sp, color = neon.text)
        if (model.isNotEmpty()) {
            Text(model, fontFamily = neon.mono, fontSize = 11.5.sp, color = if (selected) tint else neon.textFaint)
        }
        Text(blurb, fontFamily = neon.sans, fontSize = 12.5.sp, color = neon.textDim)
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun DirectoryStep(
    store: SessionStore,
    assistant: String,
    agentTint: Color,
    // cwd, model, effort, permissionMode, seedPrompt. seedPrompt is the Part B
    // "Set up agent harness" bootstrap prompt (null on the normal start paths).
    onCreate: (String?, String?, String?, String?, String?) -> Unit,
) {
    val appearance = sh.nikhil.conduit.LocalAppearanceStore.current
    val useDial by appearance.newSessionEffortDial.collectAsState()
    val useLaunch by appearance.newSessionLaunchLine.collectAsState()
    val lastEffort by appearance.newSessionLastEffort.collectAsState()
    val recent by store.recentDirectories.collectAsState()
    var currentPath by remember { mutableStateOf<String?>(null) }
    var listing by remember { mutableStateOf<RemoteDirectoryListing?>(null) }
    var isLoading by remember { mutableStateOf(false) }
    var loadError by remember { mutableStateOf<String?>(null) }
    // Part B: whether the browsed dir already has CLAUDE.md / AGENTS.md
    // (null = unknown / not yet checked → don't nag). Dismissible per session.
    var harnessStatus by remember { mutableStateOf<RemoteHarnessStatus?>(null) }
    var harnessChipDismissed by remember { mutableStateOf(false) }
    // Selected model alias. forkModelInherit ("") = no override / agent
    // default, which is the default and keeps the start path unchanged.
    var model by remember(assistant) { mutableStateOf(forkModelInherit) }
    // The model handed to onCreate: the sentinel maps to null.
    val selectedModel = model.trim().ifEmpty { null }
    // Reasoning effort. Options come from the broker's live catalog for the
    // SELECTED model when available (per-model: sonnet lacks xhigh, haiku
    // has none — empty list hides the effort UI and sends no override);
    // static per-assistant fallback otherwise. Also gated on the agent-level
    // `supports.effort` descriptor (PR #440 WS-3.2).
    val catalogs by store.modelCatalog.collectAsState()
    val catalog = catalogs[assistant]
    val descriptorsForEffort by store.agentDescriptors.collectAsState()
    val agentSupportsEffort = descriptorFor(assistant, descriptorsForEffort).supportsEffort
    val modelEffortOptions = forkEffortOptions(assistant, model, catalog)
    val effortOptions = if (agentSupportsEffort) modelEffortOptions else emptyList()
    var effort by remember(assistant) {
        // Honour the last dial choice if this agent supports it (§3), else
        // the agent default ("medium" when offered).
        val initial = lastEffort.takeIf { it.isNotEmpty() && effortOptions.contains(it) }
            ?: forkDefaultEffort(assistant, model, catalog)
        mutableStateOf(initial)
    }
    // A model switch (or a late catalog arrival) can change the supported
    // effort range — snap an out-of-range selection back to the default.
    LaunchedEffect(model, catalog) {
        if (effortOptions.isNotEmpty() && effort !in effortOptions) {
            effort = forkDefaultEffort(assistant, model, catalog)
        }
    }
    // The effort handed to onCreate: null when the model has no effort
    // control so the spawn carries no override.
    val selectedEffort = effort.trim().ifEmpty { null }?.takeIf { effortOptions.isNotEmpty() }
    // Permission mode. "" = Auto (full-auto default, broker spawns with
    // --dangerously-skip-permissions); "plan" = read-only planning. The
    // sentinel "" maps to null on the way to onCreate, mirroring model.
    var permissionMode by remember { mutableStateOf("") }
    val selectedMode = permissionMode.trim().ifEmpty { null }

    LaunchedEffect(currentPath) {
        isLoading = true
        loadError = null
        runCatching { store.listDirectories(currentPath) }
            .onSuccess {
                listing = it
                // Part B: refresh the harness check for the resolved path the
                // broker listed. Best-effort — null leaves the chip hidden.
                harnessStatus = store.harnessStatus(it.path)
            }
            .onFailure { e ->
                // Surface the real broker error (truncated) instead of a bare
                // generic line so folder-list failures are diagnosable
                // on-device. listDirectories now checks the HTTP status, so
                // e.message carries the broker's actual reply.
                val detail = e.message?.takeIf { it.isNotBlank() }?.take(200)
                loadError = if (detail != null) "Couldn't list this folder. $detail" else "Couldn't list this folder."
            }
        isLoading = false
    }

    val neon = LocalNeonTheme.current
    // Bound the sheet height so the scrollable browse list takes the
    // available space and the action bar stays pinned to the bottom.
    Column(modifier = Modifier.fillMaxWidth().fillMaxHeight(0.92f)) {
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Text(
                "Working directory",
                style = MaterialTheme.typography.titleMedium,
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                color = neon.text,
            )

            ModelPicker(
                assistant = assistant,
                model = model,
                catalog = catalog,
                onSelect = { model = it },
            )

            // Effort + Mode: side by side on a wide (tablet) modal, stacked
            // on phone (§6 "two columns"). A model with no effort control
            // (haiku) drops the effort block entirely.
            val wide = androidx.compose.ui.platform.LocalConfiguration.current.screenWidthDp >= 840
            val effortBlock: @Composable () -> Unit = {
                if (useDial) {
                    EffortDial(
                        options = effortOptions,
                        effort = effort,
                        tint = agentTint,
                        onSelect = { effort = it; appearance.setNewSessionLastEffort(it) },
                    )
                } else {
                    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                        SectionLabel("Reasoning effort")
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            effortOptions.forEach { level ->
                                FilterChip(
                                    selected = effort == level,
                                    onClick = { effort = level },
                                    label = { Text(effortLabel(level)) },
                                )
                            }
                        }
                    }
                }
            }
            val modeBlock: @Composable () -> Unit = {
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    SectionLabel("Mode")
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        FilterChip(
                            selected = permissionMode == "",
                            onClick = { permissionMode = "" },
                            label = { Text("Auto") },
                        )
                        FilterChip(
                            selected = permissionMode == "plan",
                            onClick = { permissionMode = "plan" },
                            label = { Text("Plan") },
                        )
                    }
                    Text(
                        "Plan = read-only; agent explores and proposes without editing.",
                        fontFamily = neon.mono,
                        fontSize = 10.5.sp,
                        color = neon.textFaint,
                    )
                }
            }
            if (effortOptions.isEmpty()) {
                modeBlock()
            } else if (wide) {
                Row(horizontalArrangement = Arrangement.spacedBy(14.dp), modifier = Modifier.fillMaxWidth()) {
                    Box(Modifier.weight(1f)) { effortBlock() }
                    Box(Modifier.weight(1f)) { modeBlock() }
                }
            } else {
                effortBlock()
                modeBlock()
            }

            if (recent.isNotEmpty()) {
                SectionLabel("Recent")
                Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                    recent.take(3).forEach { path ->
                        RecentRow(path = path, onTap = { onCreate(path, selectedModel, selectedEffort, selectedMode, null) })
                    }
                }
            }

            SectionLabel("Browse")
            Breadcrumb(
                listing = listing,
                onUp = { parent -> currentPath = parent },
            )

            when {
                isLoading -> Box(
                    modifier = Modifier.fillMaxWidth().padding(vertical = 24.dp),
                    contentAlignment = Alignment.Center,
                ) { CircularProgressIndicator(modifier = Modifier.size(22.dp)) }

                loadError != null -> Text(
                    loadError!!,
                    style = MaterialTheme.typography.bodySmall,
                    color = neon.red,
                    modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                )

                else -> {
                    val folders = listing?.entries.orEmpty().filter { it.isDir }
                    if (folders.isEmpty()) {
                        Text(
                            "No sub-folders here.",
                            style = MaterialTheme.typography.bodySmall,
                            color = neon.textDim,
                            modifier = Modifier.fillMaxWidth().padding(vertical = 16.dp),
                        )
                    } else {
                        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                            folders.forEach { entry ->
                                FolderRow(name = entry.name, onTap = { currentPath = entry.path })
                            }
                        }
                    }
                }
            }
        }

        // Hairline separates the pinned action bar from the browse list
        // scrolling above it (parity with iOS's opaque bottom bar + top
        // hairline). The sheet container is already `neon.surfaceSolid`,
        // so the bar reads as solid; the divider supplies the separation.
        androidx.compose.material3.HorizontalDivider(color = neon.border, thickness = 1.dp)
        Column(
            modifier = Modifier.fillMaxWidth().padding(16.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            // Part B: dismissible "Set up agent harness" chip, shown only when
            // the broker confirmed BOTH CLAUDE.md and AGENTS.md are absent.
            // Tapping seeds the curated bootstrap prompt and starts cd'd in.
            val showHarnessChip = harnessStatus?.let { !it.hasHarness } == true &&
                !harnessChipDismissed && listing != null
            if (showHarnessChip) {
                HarnessChip(
                    tint = agentTint,
                    onTap = {
                        onCreate(
                            listing?.path, selectedModel, selectedEffort, selectedMode,
                            SessionStore.HARNESS_BOOTSTRAP_PROMPT,
                        )
                    },
                    onDismiss = { harnessChipDismissed = true },
                )
            }
            if (useLaunch) {
                // Live launch preview (§3): will run <agent> · <effort> · <folder>.
                val folder = listing?.path?.trimEnd('/')?.substringAfterLast('/')?.ifEmpty { null }
                Text(
                    buildString {
                        append("will run ")
                        append(assistant)
                        if (selectedEffort != null) { append(" · "); append(selectedEffort) }
                        if (!folder.isNullOrEmpty()) { append(" · "); append(folder) }
                    },
                    fontFamily = neon.mono,
                    fontSize = 11.5.sp,
                    color = neon.textFaint,
                    maxLines = 1,
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            Button(
                onClick = { onCreate(listing?.path, selectedModel, selectedEffort, selectedMode, null) },
                enabled = listing != null,
                shape = RoundedCornerShape(14.dp),
                colors = androidx.compose.material3.ButtonDefaults.buttonColors(
                    containerColor = agentTint,
                    contentColor = neon.accentText,
                ),
                modifier = Modifier.fillMaxWidth(),
            ) {
                Icon(Icons.Filled.CheckCircle, null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text("Use this folder", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
            }
            TextButton(onClick = { onCreate(null, selectedModel, selectedEffort, selectedMode, null) }) {
                Text(
                    "Start without a folder",
                    fontFamily = neon.sans,
                    color = neon.textDim,
                )
            }
        }
    }
}

/**
 * Part B: a tasteful, dismissible "Set up agent harness" suggestion shown only
 * when the chosen folder has neither CLAUDE.md nor AGENTS.md. Tapping seeds the
 * curated bootstrap prompt (audit repo → write CLAUDE.md + AGENTS.md with
 * verified gates, ask before committing) and starts cd'd into the folder. The
 * x dismisses it for the session. Mirror of iOS `harnessChip`.
 */
@Composable
private fun HarnessChip(
    tint: Color,
    onTap: () -> Unit,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(12.dp))
            .background(tint.copy(alpha = 0.10f))
            .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(12.dp))
            .clickable(onClick = onTap)
            .padding(horizontal = 12.dp, vertical = 10.dp),
    ) {
        Icon(Icons.Filled.AutoAwesome, null, tint = tint, modifier = Modifier.size(16.dp))
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                "Set up agent harness",
                fontFamily = neon.sans,
                fontWeight = FontWeight.SemiBold,
                fontSize = 13.sp,
                color = neon.text,
            )
            Text(
                "No CLAUDE.md or AGENTS.md here. Have the agent audit the repo and write them.",
                fontFamily = neon.mono,
                fontSize = 10.5.sp,
                color = neon.textDim,
            )
        }
        Icon(
            Icons.Filled.Close,
            contentDescription = "Dismiss harness suggestion",
            tint = neon.textFaint,
            modifier = Modifier
                .size(26.dp)
                .clip(RoundedCornerShape(13.dp))
                .clickable(onClick = onDismiss)
                .padding(6.dp),
        )
    }
}

/**
 * Model picker for the new-session flow. Mirrors the fork chooser's model
 * dropdown (`SessionInfoScreen.kt`) and the iOS new-session model menu.
 * Reuses the shared per-assistant option/label helpers so the broker never
 * gets an alias it would drop. The default selection is the inherit
 * sentinel → no `--model` override.
 */
@Composable
private fun ModelPicker(
    assistant: String,
    model: String,
    catalog: List<sh.nikhil.conduit.SessionStore.AgentModel>?,
    onSelect: (String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val options = forkModelOptions(assistant, catalog)
    var expanded by remember { mutableStateOf(false) }
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        SectionLabel("Model")
        Box {
            Surface(
                shape = RoundedCornerShape(14.dp),
                color = neon.surface,
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable { expanded = true },
            ) {
                Row(
                    modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp).fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.SpaceBetween,
                ) {
                    Text(
                        forkModelLabel(model, catalog),
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = neon.sans,
                        color = neon.text,
                    )
                    Icon(
                        Icons.Filled.ArrowDropDown,
                        contentDescription = "Choose model",
                        tint = neon.textDim,
                    )
                }
            }
            DropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false },
            ) {
                options.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(forkModelLabel(option, catalog), fontFamily = neon.sans) },
                        onClick = {
                            onSelect(option)
                            expanded = false
                        },
                    )
                }
            }
        }
        // The agent's own description of the (resolved) selection — e.g.
        // "Sonnet 4.6 · Efficient for routine tasks". Only when the live
        // catalog is in; the static fallback has none.
        forkModelDetail(model, catalog)?.let { detail ->
            Text(
                detail,
                fontFamily = neon.mono,
                fontSize = 10.5.sp,
                color = neon.textFaint,
            )
        }
    }
}

@Composable
private fun SectionLabel(text: String) {
    val neon = LocalNeonTheme.current
    Text(
        text.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        color = neon.textDim,
    )
}

@Composable
private fun Breadcrumb(
    listing: RemoteDirectoryListing?,
    onUp: (String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    val canGoUp = listing != null &&
        listing.parent.isNotEmpty() &&
        listing.parent != listing.path
    Row(verticalAlignment = Alignment.CenterVertically) {
        Box(
            modifier = Modifier
                .size(30.dp)
                .clip(CircleShape)
                .background(neon.surface, CircleShape)
                .border(1.dp, neon.border, CircleShape)
                .clickable(enabled = canGoUp) { listing?.parent?.let(onUp) },
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                Icons.Filled.ArrowUpward,
                contentDescription = "Up one folder",
                modifier = Modifier.size(16.dp),
                tint = if (canGoUp) neon.accent else neon.textFaint,
            )
        }
        Spacer(Modifier.width(8.dp))
        Text(
            listing?.path ?: "…",
            style = MaterialTheme.typography.bodySmall,
            fontFamily = neon.mono,
            color = neon.textDim,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
    }
}

@Composable
private fun RecentRow(path: String, onTap: () -> Unit) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.History, null, modifier = Modifier.size(20.dp), tint = neon.accent)
            Spacer(Modifier.width(12.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    displayName(path),
                    style = MaterialTheme.typography.titleSmall,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
                Text(
                    path,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(Icons.Filled.ArrowOutward, null, modifier = Modifier.size(16.dp), tint = neon.textDim)
        }
    }
}

@Composable
private fun FolderRow(name: String, onTap: () -> Unit) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = shape, fill = neon.surface)
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(Icons.Filled.Folder, null, modifier = Modifier.size(20.dp), tint = neon.accent)
            Spacer(Modifier.width(12.dp))
            Text(name, style = MaterialTheme.typography.titleSmall, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.text, modifier = Modifier.weight(1f))
            Icon(Icons.Filled.ChevronRight, null, tint = neon.textDim)
        }
    }
}

private fun displayName(path: String): String {
    val trimmed = path.trimEnd('/')
    val last = trimmed.substringAfterLast('/', "")
    return last.ifEmpty { trimmed }
}

/**
 * One paired box the session can be created on; the checked row wins.
 * Mirror of iOS `ConduitAgentPickerSheet.boxSection`.
 */
@Composable
private fun BoxRow(
    name: String,
    host: String,
    selected: Boolean,
    onTap: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(13.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = shape,
                fill = if (selected) neon.accent.copy(alpha = 0.10f) else neon.surface,
                borderColor = if (selected) neon.accent.copy(alpha = 0.5f) else neon.border,
            )
            .clickable(onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    color = neon.text,
                )
                Text(
                    host,
                    style = MaterialTheme.typography.labelSmall,
                    fontFamily = neon.mono,
                    color = neon.textDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
            Icon(
                Icons.Filled.CheckCircle,
                contentDescription = if (selected) "Selected box" else null,
                tint = if (selected) neon.accent else neon.textFaint.copy(alpha = 0.35f),
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

/**
 * Reasoning-effort dial (§3, `03-ns`): one stop per effort level the
 * selected model supports — Fast/Balanced/Deep for the classic three,
 * growing to X-High/Max when the agent's catalog offers them. The track
 * fills up to (and including) the selected stop in the agent tint; a
 * consequence line + the raw API value chip sit beneath. Mirrors iOS
 * `effortDialSection`.
 */
@Composable
private fun EffortDial(
    options: List<String>,
    effort: String,
    tint: Color,
    onSelect: (String) -> Unit,
) {
    val neon = LocalNeonTheme.current
    data class Stop(val label: String, val value: String, val desc: String)
    val stops = options.map { Stop(effortLabel(it), it, effortDescription(it)) }
    if (stops.isEmpty()) return
    val idx = stops.indexOfFirst { it.value == effort }
        .let { if (it < 0) minOf(1, stops.size - 1) else it }
    val cur = stops[idx]
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        SectionLabel("Reasoning effort")
        Row(horizontalArrangement = Arrangement.spacedBy(7.dp), modifier = Modifier.fillMaxWidth()) {
            stops.forEachIndexed { i, stop ->
                Column(
                    modifier = Modifier.weight(1f).clickable { onSelect(stop.value) },
                    verticalArrangement = Arrangement.spacedBy(9.dp),
                ) {
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .height(8.dp)
                            .clip(RoundedCornerShape(99.dp))
                            .background(if (i <= idx) tint else neon.textFaint.copy(alpha = 0.25f)),
                    )
                    Text(
                        stop.label,
                        fontFamily = neon.sans,
                        fontSize = 13.sp,
                        fontWeight = if (i == idx) FontWeight.Bold else FontWeight.Medium,
                        color = if (i == idx) neon.text else neon.textFaint,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                }
            }
        }
        Row(
            modifier = Modifier.fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface)
                .padding(horizontal = 13.dp, vertical = 11.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(9.dp),
        ) {
            Text(
                cur.value,
                fontFamily = neon.mono,
                fontSize = 11.sp,
                fontWeight = FontWeight.Bold,
                color = tint,
                modifier = Modifier
                    .clip(RoundedCornerShape(99.dp))
                    .background(tint.copy(alpha = 0.12f))
                    .padding(horizontal = 8.dp, vertical = 3.dp),
            )
            Text(cur.desc, fontFamily = neon.sans, fontSize = 13.sp, color = neon.textDim)
        }
    }
}

@Composable
private fun AgentTile(
    assistant: String,
    label: String,
    subtitle: String,
    tint: Color,
    enabled: Boolean,
    onTap: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val shape = RoundedCornerShape(14.dp)
    Box(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(
                neon = neon,
                shape = shape,
                fill = tint.copy(alpha = if (enabled) 0.14f else 0.05f),
                borderColor = tint.copy(alpha = if (enabled) 0.5f else 0.2f),
                glowTint = if (enabled) tint else null,
            )
            .clickable(enabled = enabled, onClick = onTap),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth().padding(14.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AgentAvatar(assistant = assistant, size = 44.dp)
            Spacer(Modifier.width(14.dp))
            Column(modifier = Modifier.weight(1f)) {
                Text(label, style = MaterialTheme.typography.titleMedium, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, color = neon.text)
                Text(
                    subtitle,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.sans,
                    color = neon.textDim,
                )
            }
            Icon(Icons.Filled.ChevronRight, null, tint = neon.textDim)
        }
    }
}
