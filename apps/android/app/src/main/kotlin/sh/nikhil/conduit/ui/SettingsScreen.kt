package sh.nikhil.conduit.ui

import sh.nikhil.conduit.BuildConfig
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ListItem
import androidx.compose.material3.ListItemDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.RadioButton
import androidx.compose.material3.RadioButtonDefaults
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
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
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.AlertDialog
import sh.nikhil.conduit.AppearanceStore
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

/**
 * Settings — Conduit redesign IA (handoff §A.2, image 03), mirror of iOS
 * `ConduitUI.SettingsView`. The shipped build had ~11 stacked sections with
 * appearance shattered across six of them; this collapses to exactly eight:
 *
 *   identity · Account · Usage & limits · Appearance · Terminal ·
 *   Conversation · Servers · About
 *
 *   • identity      — `>conduit` wordmark card (mono, the `>` cyan-tinted) +
 *                     version/build line + a live/offline badge.
 *   • Account       — pairing row + "Sign in to agent" (sheets unchanged).
 *   • Usage & limits— account-wide, BOTH agents (claude + codex), each with a
 *                     5-hour AND a weekly window (bar / % / reset).
 *   • Appearance    — ONE grouped card: Theme segmented, accent-palette
 *                     swatches, App font drill-in, Text size slider, Glow &
 *                     scanlines toggle, + the `conduit --theme ice` chip.
 *   • Terminal      — Color theme drill-in row, font-size slider, native
 *                     terminal toggle.
 *   • Conversation  — collapse-turns toggle.
 *   • Servers       — saved servers + Add server.
 *   • About         — version + licenses.
 *
 * Presentation + IA only: every store/AppearanceStore binding and sheet is
 * preserved. Styling follows the neon theme tokens via [LocalNeonTheme] and
 * the [neonCardSurface] section card, matching the iOS rewrite.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    store: SessionStore,
    onDismiss: () -> Unit,
    onOpenLicenses: () -> Unit = {},
    // When true, render inline as a tablet section pane (no bottom-sheet
    // shell) — mirrors iOS ConduitUI.SettingsView(embedded:).
    embedded: Boolean = false,
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val appearance = LocalAppearanceStore.current
    val endpoint by store.endpoint.collectAsState()
    val harness by store.harness.collectAsState()
    val savedServers by store.savedServers.collectAsState()
    val sessions by store.sessions.collectAsState()
    val statuses by store.statusBySession.collectAsState()
    val fontFamily by appearance.fontFamily.collectAsState()
    val themeMode by appearance.themeMode.collectAsState()
    val collapseTurns by appearance.collapseTurns.collectAsState()
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    val terminalFontSize by appearance.terminalFontSize.collectAsState()
    val terminalTheme by appearance.terminalTheme.collectAsState()
    val neonGlow by appearance.neonGlow.collectAsState()

    var showAddServer by remember { mutableStateOf(false) }
    var showAppFont by remember { mutableStateOf(false) }
    var showTerminalTheme by remember { mutableStateOf(false) }
    var showAgentLogin by remember { mutableStateOf(false) }
    // Saved-server pending deletion. Mirror of iOS PR #128's
    // `pendingServerDelete`: gating the destructive sweep behind an
    // explicit confirm lets us call `forgetServer` (which also drops
    // the per-id displayName override) instead of the legacy
    // `removeSavedServer`, and gives the prompt somewhere to explain
    // what's being cleared.
    var pendingForget by remember { mutableStateOf<SavedServer?>(null) }

    val neon = LocalNeonTheme.current
    val versionLabel = if (BuildConfig.RELEASE_TAG != "dev") {
        "${BuildConfig.RELEASE_TAG} (${BuildConfig.GIT_SHA})"
    } else {
        "${BuildConfig.VERSION_NAME} (dev)"
    }

    val content: @Composable () -> Unit = {
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp, vertical = 12.dp)
                .verticalScroll(rememberScrollState()),
            verticalArrangement = Arrangement.spacedBy(18.dp),
        ) {
            // identity — `>conduit` wordmark + version + live/offline badge.
            IdentityCard(neon = neon, version = versionLabel, harness = harness)

            // Account — pairing row + sign-in to agent.
            SettingsSection("Account") {
                SettingsRow(
                    icon = Icons.Filled.Person,
                    title = if (endpoint.isComplete) endpoint.displayHost else "Not paired",
                    subtitle = harness.badgeLabel,
                    onClick = { showAgentLogin = true },
                )
                SettingsDivider()
                SettingsRow(
                    icon = Icons.Filled.Person,
                    title = "Sign in to agent",
                    subtitle = "OAuth for Claude / ChatGPT",
                    onClick = { showAgentLogin = true },
                )
            }

            // Usage & limits — account-wide, BOTH agents (claude + codex),
            // each with a 5-hour AND a weekly window. Numbers are per-account,
            // not per-session; read off any session of that agent. Honest
            // empty state when an agent has no data yet.
            SettingsSection("Usage & limits") {
                AgentUsageRows(
                    store = store,
                    agent = "claude",
                    tint = neon.claude,
                    sessions = sessions,
                    statuses = statuses,
                )
                SettingsDivider()
                AgentUsageRows(
                    store = store,
                    agent = "codex",
                    tint = neon.codex,
                    sessions = sessions,
                    statuses = statuses,
                )
            }

            // Appearance — ONE grouped card: Theme segmented, accent palette,
            // App font drill-in, Text size slider, Glow & scanlines.
            Column(modifier = Modifier.fillMaxWidth()) {
                SectionEyebrow("Appearance")
                Column(
                    modifier = Modifier
                        .fillMaxWidth()
                        .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                ) {
                    // Theme — segmented System / Light / Dark.
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Text(
                            "Theme",
                            style = MaterialTheme.typography.bodyLarge,
                            fontFamily = neon.sans,
                            fontWeight = FontWeight.SemiBold,
                            color = neon.text,
                        )
                        SingleChoiceSegmentedButtonRow(modifier = Modifier.fillMaxWidth()) {
                            val modes = AppearanceStore.ThemeMode.values()
                            modes.forEachIndexed { idx, mode ->
                                SegmentedButton(
                                    selected = themeMode == mode,
                                    onClick = { appearance.setThemeMode(mode) },
                                    shape = SegmentedButtonDefaults.itemShape(index = idx, count = modes.size),
                                    colors = SegmentedButtonDefaults.colors(
                                        activeContainerColor = neon.accent.copy(alpha = 0.18f),
                                        activeContentColor = neon.text,
                                        activeBorderColor = neon.accent,
                                        inactiveContainerColor = Color.Transparent,
                                        inactiveContentColor = neon.textDim,
                                        inactiveBorderColor = neon.border,
                                    ),
                                    label = { Text(mode.label, fontFamily = neon.sans) },
                                )
                            }
                        }
                    }

                    SettingsDivider()

                    // Accent palette — Ice / Synth / Matrix / Amber swatches.
                    NeonAccentPalettePicker(appearance)

                    SettingsDivider()

                    // App font — drill-in row.
                    ListItem(
                        modifier = Modifier.clickable { showAppFont = true },
                        leadingContent = { Icon(Icons.Filled.TextFields, contentDescription = null, tint = neon.accent) },
                        headlineContent = { Text("App font", color = neon.text, fontFamily = neon.sans) },
                        trailingContent = {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(fontFamily.label, fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.textFaint)
                                Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = neon.textFaint)
                            }
                        },
                        colors = transparentListItemColors(),
                    )

                    SettingsDivider()

                    // Text size slider.
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.FormatSize, contentDescription = null, tint = neon.accent, modifier = Modifier.size(24.dp))
                            Spacer(Modifier.width(16.dp))
                            Text("Text size", style = MaterialTheme.typography.bodyLarge, fontFamily = neon.sans, color = neon.text)
                            Spacer(Modifier.weight(1f))
                            Text("${bodyPointSize.toInt()}pt", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
                        }
                        Slider(
                            value = bodyPointSize,
                            onValueChange = { appearance.setBodyPointSize(it) },
                            valueRange = AppearanceStore.BODY_POINT_SIZE_RANGE,
                            steps = (AppearanceStore.BODY_POINT_SIZE_RANGE.endInclusive
                                - AppearanceStore.BODY_POINT_SIZE_RANGE.start).toInt() - 1,
                            colors = SliderDefaults.colors(
                                thumbColor = neon.accent,
                                activeTrackColor = neon.accent,
                            ),
                        )
                    }

                    SettingsDivider()

                    // Glow & scanlines.
                    ToggleRow(
                        icon = Icons.Filled.Star,
                        title = "Glow & scanlines",
                        subtitle = if (neon.dark) "neon halos · on dark" else "neon halos · dimmed in light",
                        isOn = neonGlow,
                        onChange = { appearance.setNeonGlow(it) },
                    )
                }

                Spacer(Modifier.height(10.dp))
                // Live `$ conduit --theme <id>` preview chip.
                NeonThemePreviewChip(appearance)
            }

            // Terminal — color theme drill-in row + font-size slider + the
            // native-terminal toggle. (Android's terminal font is fixed —
            // there's no per-font setting like iOS's libghostty path — so the
            // section surfaces the real terminal knobs rather than a dead row.)
            SettingsSection("Terminal") {
                ListItem(
                    modifier = Modifier.clickable { showTerminalTheme = true },
                    leadingContent = { Icon(Icons.Filled.Palette, contentDescription = null, tint = neon.accent) },
                    headlineContent = { Text("Color theme", color = neon.text, fontFamily = neon.sans) },
                    trailingContent = {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            Text(terminalTheme.label, fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.textFaint)
                            Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = neon.textFaint)
                        }
                    },
                    colors = transparentListItemColors(),
                )
                SettingsDivider()
                Column(
                    modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Icon(Icons.Filled.FormatSize, contentDescription = null, tint = neon.accent, modifier = Modifier.size(24.dp))
                        Spacer(Modifier.width(16.dp))
                        Text("Font size", style = MaterialTheme.typography.bodyLarge, fontFamily = neon.sans, color = neon.text)
                        Spacer(Modifier.weight(1f))
                        Text("${terminalFontSize.toInt()}pt", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textFaint)
                    }
                    Slider(
                        value = terminalFontSize,
                        onValueChange = { appearance.setTerminalFontSize(it) },
                        valueRange = AppearanceStore.TERMINAL_FONT_SIZE_RANGE,
                        steps = (AppearanceStore.TERMINAL_FONT_SIZE_RANGE.endInclusive
                            - AppearanceStore.TERMINAL_FONT_SIZE_RANGE.start).toInt() - 1,
                        colors = SliderDefaults.colors(
                            thumbColor = neon.accent,
                            activeTrackColor = neon.accent,
                        ),
                    )
                }
                SettingsDivider()
                ToggleRow(
                    icon = Icons.Filled.Science,
                    title = "Native terminal",
                    subtitle = "On by default. Turn off to use the legacy web terminal.",
                    isOn = experimentalNativeTerminal,
                    onChange = { appearance.setExperimentalNativeTerminal(it) },
                )
            }

            // Conversation.
            SettingsSection("Conversation") {
                ToggleRow(
                    icon = Icons.Filled.UnfoldLess,
                    title = "Collapse Turns",
                    subtitle = "Show only summaries; tap to expand",
                    isOn = collapseTurns,
                    onChange = { appearance.setCollapseTurns(it) },
                )
            }

            // Servers.
            SettingsSection("Servers") {
                savedServers.forEachIndexed { idx, server ->
                    ListItem(
                        leadingContent = {
                            Icon(
                                Icons.Filled.Apps,
                                contentDescription = null,
                                tint = neon.accent,
                            )
                        },
                        headlineContent = { Text(server.name, color = neon.text, fontFamily = neon.sans) },
                        supportingContent = {
                            Text(
                                server.endpoint.displayHost,
                                fontFamily = neon.sans,
                                color = neon.textDim,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                        },
                        trailingContent = {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                if (server.isDefault) {
                                    Surface(
                                        shape = RoundedCornerShape(50),
                                        color = neon.accent.copy(alpha = 0.22f),
                                    ) {
                                        Text(
                                            "Default",
                                            modifier = Modifier.padding(horizontal = 8.dp, vertical = 3.dp),
                                            fontFamily = neon.mono,
                                            fontSize = 10.sp,
                                            fontWeight = FontWeight.Bold,
                                            color = neon.accent,
                                        )
                                    }
                                }
                                TextButton(onClick = { store.selectSavedServer(server.id, autoConnect = true) }) {
                                    Text("Use", color = neon.accent)
                                }
                                IconButton(onClick = { pendingForget = server }) {
                                    Icon(Icons.Filled.Delete, contentDescription = "Forget", tint = neon.textDim)
                                }
                            }
                        },
                        colors = transparentListItemColors(),
                    )
                    SettingsDivider()
                }
                SettingsRow(
                    icon = Icons.Filled.AddCircle,
                    title = "Add server",
                    subtitle = "QR · LAN discover · SSH · paste URL+token",
                    onClick = { showAddServer = true },
                )
            }

            // About — static identity card + a tap-through to the
            // third-party licenses + trademark attribution screen.
            SettingsSection("About") {
                KeyValueRow(label = "Conduit", value = versionLabel)
                SettingsDivider()
                SettingsRow(
                    icon = Icons.Filled.Article,
                    title = "Licenses",
                    subtitle = "Open source & trademark attribution",
                    onClick = onOpenLicenses,
                )
            }

            Spacer(Modifier.height(12.dp))
        }
    }

    if (embedded) {
        // Tablet pane: inset below the status bar (the phone form is a
        // ModalBottomSheet that never reaches it, so only embedded needs this).
        Box(modifier = Modifier.statusBarsPadding()) { content() }
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

    if (showAddServer) {
        AddServerSheet(store = store, onDismiss = { showAddServer = false })
    }
    if (showAppFont) {
        AppFontPickerSheet(appearance = appearance, current = fontFamily, onDismiss = { showAppFont = false })
    }
    if (showTerminalTheme) {
        TerminalThemePickerSheet(appearance = appearance, current = terminalTheme, onDismiss = { showTerminalTheme = false })
    }
    if (showAgentLogin) {
        AgentLoginSheet(store = store, onDismiss = { showAgentLogin = false })
    }
    pendingForget?.let { target ->
        AlertDialog(
            onDismissRequest = { pendingForget = null },
            title = { Text("Forget server?") },
            text = {
                Text(
                    "Drops the saved pairing for ${target.name}. Sessions already running on this server keep running until you delete them.",
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    store.forgetServer(target.id)
                    pendingForget = null
                }) {
                    Text("Forget", color = MaterialTheme.colorScheme.error)
                }
            },
            dismissButton = {
                TextButton(onClick = { pendingForget = null }) { Text("Cancel") }
            },
        )
    }
}

/**
 * identity card — the `>conduit` wordmark (BRAND.md §1: lowercase JetBrains
 * Mono, the `>` cyan-tinted) beside the daemon mark, the version/build line,
 * and a live/offline status badge.
 */
@Composable
private fun IdentityCard(neon: NeonTheme, version: String, harness: HarnessState) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface)
            .padding(14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            modifier = Modifier
                .size(46.dp)
                .background(neon.surface, RoundedCornerShape(12.dp))
                .border(1.dp, neon.border, RoundedCornerShape(12.dp)),
            contentAlignment = Alignment.Center,
        ) { ConduitMark(size = 30.dp) }
        Spacer(Modifier.width(12.dp))
        Column(verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row {
                Text(">", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 18.sp, color = neon.accent)
                Text("conduit", fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 18.sp, color = neon.text)
            }
            Text(
                version,
                fontFamily = neon.mono,
                fontSize = 11.sp,
                color = neon.textFaint,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Spacer(Modifier.weight(1f))
        val reachable = harness.isReachable
        val color = if (reachable) neon.green else neon.textDim
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(5.dp),
            modifier = Modifier
                .background(color.copy(alpha = 0.12f), RoundedCornerShape(50))
                .border(1.dp, color.copy(alpha = 0.3f), RoundedCornerShape(50))
                .padding(horizontal = 9.dp, vertical = 5.dp),
        ) {
            Box(Modifier.size(6.dp).background(color, CircleShape))
            Text(harness.badgeLabel, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 10.5.sp, color = color)
        }
    }
}

/**
 * Account-wide plan limits for one agent (claude or codex): the 5-hour and
 * weekly windows with a refresh affordance, reusing [NeonAccountUsageCard].
 * Reads the freshest account-usage values off any session of [agent] (the
 * numbers are per-account, not per-session). Shows an honest empty state when
 * no session of that agent exists rather than fabricating a percentage.
 */
@Composable
private fun AgentUsageRows(
    store: SessionStore,
    agent: String,
    tint: Color,
    sessions: List<ProjectSession>,
    statuses: Map<String, SessionStatus>,
) {
    val neon = LocalNeonTheme.current
    val snap = remember(sessions, statuses, agent) { agentAccountUsage(sessions, statuses, agent) }
    Column(
        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 12.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.size(6.dp).background(tint, CircleShape))
            Text(agent, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.5.sp, color = tint)
        }
        val sourceId = snap.sourceSessionId
        if (sourceId == null) {
            Text(
                "no $agent session — start one to see limits",
                fontFamily = neon.mono,
                fontSize = 10.5.sp,
                color = neon.textFaint,
            )
        } else {
            // NeonAccountUsageCard renders both 5h + weekly window rows + a
            // refresh button; the agent dot above already labels the block.
            NeonAccountUsageCard(
                fivePct = snap.fivePct,
                fiveResetsAt = snap.fiveResetsAt,
                weekPct = snap.weekPct,
                weekResetsAt = snap.weekResetsAt,
                onRefresh = { store.refreshAccountUsage(sourceId) },
                heading = "5h & weekly",
            )
        }
    }
}

/**
 * Freshest account usage across one agent's sessions (live status preferred,
 * session snapshot as fallback). Parameterised mirror of
 * [accountUsageSnapshot], so the Settings card can show both claude and codex
 * rather than the Claude-only ambient strip.
 */
private fun agentAccountUsage(
    sessions: List<ProjectSession>,
    statuses: Map<String, SessionStatus>,
    agent: String,
): AccountUsageSnapshot {
    for (s in sessions) {
        if (s.assistant != agent) continue
        val st = statuses[s.id]
        val five = st?.account5hPct ?: s.account5hPct
        val week = st?.account7dPct ?: s.account7dPct
        if (five != null || week != null) {
            return AccountUsageSnapshot(
                fivePct = five,
                fiveResetsAt = st?.account5hResetsAt ?: s.account5hResetsAt,
                weekPct = week,
                weekResetsAt = st?.account7dResetsAt ?: s.account7dResetsAt,
                sourceSessionId = s.id,
            )
        }
    }
    return AccountUsageSnapshot(sourceSessionId = sessions.firstOrNull { it.assistant == agent }?.id)
}

/** App font drill-in target. Single-select over the chat/UI body font. */
@Composable
private fun AppFontPickerSheet(
    appearance: AppearanceStore,
    current: AppearanceStore.FontFamily,
    onDismiss: () -> Unit,
) {
    PickerSheet(title = "App font", onDismiss = onDismiss) {
        AppearanceStore.FontFamily.values().forEachIndexed { idx, choice ->
            PickerRow(
                icon = Icons.Filled.TextFields,
                title = choice.label,
                isSelected = current == choice,
                onClick = { appearance.setFontFamily(choice); onDismiss() },
            )
            if (idx < AppearanceStore.FontFamily.values().lastIndex) SettingsDivider()
        }
    }
}

/** Terminal color-theme drill-in target. Single-select over [AppearanceStore.TerminalTheme]. */
@Composable
private fun TerminalThemePickerSheet(
    appearance: AppearanceStore,
    current: AppearanceStore.TerminalTheme,
    onDismiss: () -> Unit,
) {
    PickerSheet(title = "Color theme", onDismiss = onDismiss) {
        AppearanceStore.TerminalTheme.values().forEachIndexed { idx, choice ->
            PickerRow(
                icon = Icons.Filled.Palette,
                title = choice.label,
                isSelected = current == choice,
                onClick = { appearance.setTerminalTheme(choice); onDismiss() },
            )
            if (idx < AppearanceStore.TerminalTheme.values().lastIndex) SettingsDivider()
        }
    }
}

/** Bottom-sheet shell for the Settings drill-in pickers. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun PickerSheet(title: String, onDismiss: () -> Unit, content: @Composable ColumnScope.() -> Unit) {
    val neon = LocalNeonTheme.current
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
        shape = RoundedCornerShape(topStart = 26.dp, topEnd = 26.dp),
    ) {
        Column(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SectionEyebrow(title)
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
                content = content,
            )
            Spacer(Modifier.height(12.dp))
        }
    }
}

/** All-caps mono section eyebrow above a neon card. */
@Composable
private fun SectionEyebrow(title: String) {
    val neon = LocalNeonTheme.current
    Text(
        title.uppercase(),
        style = MaterialTheme.typography.labelSmall,
        fontFamily = neon.mono,
        fontWeight = FontWeight.Bold,
        color = neon.textDim,
        maxLines = 1,
        softWrap = false,
        modifier = Modifier.padding(start = 4.dp, bottom = 8.dp),
    )
}

/**
 * A grouped settings section. A small ALL-CAPS monospaced muted label above
 * a neon-surface card (hairline border + theme glow). Rows inside keep their
 * transparent ListItem backgrounds so they sit on this surface.
 */
@Composable
internal fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    val neon = LocalNeonTheme.current
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionEyebrow(title)
        val shape = RoundedCornerShape(14.dp)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = shape, fill = neon.surface),
        ) {
            content()
        }
    }
}

/** Inset divider between rows within a settings section. */
@Composable
private fun SettingsDivider() {
    val neon = LocalNeonTheme.current
    HorizontalDivider(
        modifier = Modifier.padding(horizontal = 16.dp),
        color = neon.border,
    )
}

/**
 * Transparent [ListItem] colors so rows sit on the section card's neon
 * surface rather than painting their own opaque background.
 */
@Composable
private fun transparentListItemColors() = ListItemDefaults.colors(
    containerColor = Color.Transparent,
)

@Composable
internal fun SettingsRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    iconTint: Color = LocalNeonTheme.current.accent,
    titleColor: Color = LocalNeonTheme.current.text,
    onClick: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    ListItem(
        modifier = Modifier.clickable(onClick = onClick),
        leadingContent = {
            Icon(icon, contentDescription = null, tint = iconTint)
        },
        headlineContent = { Text(title, color = titleColor, fontFamily = neon.sans) },
        supportingContent = if (!subtitle.isNullOrBlank()) {
            {
                Text(
                    subtitle,
                    fontFamily = neon.sans,
                    color = neon.textDim,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        } else null,
        trailingContent = {
            Icon(
                Icons.Filled.ChevronRight,
                contentDescription = null,
                tint = neon.textDim,
            )
        },
        colors = transparentListItemColors(),
    )
}

@Composable
internal fun ToggleRow(
    icon: ImageVector,
    title: String,
    subtitle: String?,
    isOn: Boolean,
    onChange: (Boolean) -> Unit,
) {
    val neon = LocalNeonTheme.current
    ListItem(
        leadingContent = {
            Icon(icon, contentDescription = null, tint = neon.accent)
        },
        headlineContent = { Text(title, color = neon.text, fontFamily = neon.sans) },
        supportingContent = if (!subtitle.isNullOrBlank()) {
            { Text(subtitle, color = neon.textDim, fontFamily = neon.sans) }
        } else null,
        trailingContent = {
            Switch(
                checked = isOn,
                onCheckedChange = onChange,
                colors = SwitchDefaults.colors(
                    checkedThumbColor = neon.accentText,
                    checkedTrackColor = neon.accent,
                ),
            )
        },
        colors = transparentListItemColors(),
    )
}

@Composable
internal fun PickerRow(
    icon: ImageVector,
    title: String,
    isSelected: Boolean,
    onClick: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    ListItem(
        modifier = Modifier.selectable(
            selected = isSelected,
            onClick = onClick,
            role = Role.RadioButton,
        ),
        leadingContent = {
            Icon(icon, contentDescription = null, tint = neon.accent)
        },
        headlineContent = { Text(title, color = neon.text, fontFamily = neon.sans) },
        trailingContent = {
            RadioButton(
                selected = isSelected,
                onClick = null,
                colors = RadioButtonDefaults.colors(
                    selectedColor = neon.accent,
                ),
            )
        },
        colors = transparentListItemColors(),
    )
}

@Composable
private fun KeyValueRow(label: String, value: String) {
    val neon = LocalNeonTheme.current
    ListItem(
        headlineContent = {
            Text(label, color = neon.textDim, fontFamily = neon.sans)
        },
        trailingContent = {
            Text(
                value,
                style = MaterialTheme.typography.bodyMedium,
                fontFamily = neon.mono,
                color = neon.text,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        },
        colors = transparentListItemColors(),
    )
}
