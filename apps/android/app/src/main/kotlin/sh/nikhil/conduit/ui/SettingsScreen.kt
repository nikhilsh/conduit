package sh.nikhil.conduit.ui


import sh.nikhil.conduit.BuildConfig
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.Apps
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FormatSize
import androidx.compose.material.icons.filled.Palette
import androidx.compose.material.icons.filled.Person
import androidx.compose.material.icons.filled.Science
import androidx.compose.material.icons.filled.Star
import androidx.compose.material.icons.filled.TextFields
import androidx.compose.material.icons.filled.UnfoldLess
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Vibration
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.material3.AlertDialog
import android.content.Intent
import android.net.Uri
import sh.nikhil.conduit.AppearanceStore
import sh.nikhil.conduit.Telemetry
import sh.nikhil.conduit.FeatureFlags
import sh.nikhil.conduit.HarnessState
import sh.nikhil.conduit.LocalAppearanceStore
import sh.nikhil.conduit.SavedServer
import sh.nikhil.conduit.SessionStore
import sh.nikhil.conduit.Endpoint
import sh.nikhil.conduit.push.PushSettingsSection
import sh.nikhil.conduit.push.PushStore
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

private const val SUPPORT_DONATION_URL = "https://buymeacoffee.com/conduitapp"

/**
 * Settings — Conduit redesign IA (handoff Part A), mirror of iOS
 * `ConduitUI.SettingsView`. The shipped build had eight stacked sections
 * with the server appearing TWICE (Account + Servers) and Terminal floating
 * on its own. This collapses to five labelled groups, top to bottom:
 *
 *   Connection · Usage & limits · Appearance · Conversation · About
 *
 *   • Connection    — ONE home: active server row (tap → switch/manage),
 *                     the agents on it (Claude / Codex), Add account, and
 *                     Add server. Merges the old Account + Agent accounts +
 *                     Servers sections; the server has one home now.
 *   • Usage & limits— account-wide, BOTH agents (claude + codex), each with
 *                     a 5-hour AND a weekly window.
 *   • Appearance    — ONE grouped card with Terminal folded IN: Theme,
 *                     accent palette, the type-forward Chat font strip,
 *                     Terminal colors, Text size, Terminal font size, the
 *                     native-terminal toggle, Glow & scanlines, + the
 *                     `conduit --theme <id>` chip.
 *   • Conversation  — collapse-turns toggle.
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
    pushStore: PushStore? = null,
    onDismiss: () -> Unit,
    onOpenLicenses: () -> Unit = {},
    // When true, render inline as a tablet section pane (no bottom-sheet
    // shell) — mirrors iOS ConduitUI.SettingsView(embedded:).
    embedded: Boolean = false,
    // Called when the user taps "How it works" to re-open the onboarding
    // guide. Caller dismisses settings and presents the guide.
    onOpenOnboarding: (() -> Unit)? = null,
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
    val replyHaptics by appearance.replyHaptics.collectAsState()
    val chatStylePref by appearance.chatStylePreference.collectAsState()
    val experimentalNativeTerminal by appearance.experimentalNativeTerminal.collectAsState()
    val bodyPointSize by appearance.bodyPointSize.collectAsState()
    val terminalFontSize by appearance.terminalFontSize.collectAsState()
    val terminalTheme by appearance.terminalTheme.collectAsState()
    val neonGlow by appearance.neonGlow.collectAsState()
    val showSubagentPanel by appearance.showSubagentPanel.collectAsState()

    var showAddServer by remember { mutableStateOf(false) }
    var showServerSwitcher by remember { mutableStateOf(false) }
    var showTerminalTheme by remember { mutableStateOf(false) }
    var showAgentLogin by remember { mutableStateOf(false) }
    // Per-agent signed-in + plan snapshot for the Connection group (fix 3).
    // Re-read whenever the login sheet closes so a fresh sign-in flips the
    // rows to `● signed in` immediately.
    val context = LocalContext.current
    var agentAccounts by remember {
        mutableStateOf(sh.nikhil.conduit.auth.AgentAccountStatus.current(context))
    }
    // Account whose Manage dialog (re-auth / sign out) is open.
    var manageTarget by remember {
        mutableStateOf<sh.nikhil.conduit.auth.AgentAccountStatus?>(null)
    }
    // Saved-server pending deletion (drives the Forget confirmation alert).
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
            // Connection — one home: active server (→ switch), the agents on
            // it, Add account, Add server. Merges the old Account + Agent
            // accounts + Servers sections (handoff Part A).
            ConnectionSection(
                endpoint = endpoint,
                harness = harness,
                savedServers = savedServers,
                accounts = agentAccounts,
                onSwitchServer = { showServerSwitcher = true },
                onManage = { manageTarget = it },
                onSignIn = { showAgentLogin = true },
                onAddAccount = { showAgentLogin = true },
                onAddServer = { showAddServer = true },
            )

            // Notifications (WS-P.3) — push settings section. Shown when a
            // PushStore is provided (i.e. MainActivity wired it up). The
            // endpoint is the currently-active broker endpoint; features is
            // lazily probed by the BoxHealthScreen flow.
            pushStore?.let { ps ->
                PushSettingsSection(
                    pushStore = ps,
                    endpoint = endpoint,
                    features = null, // Probed lazily; null = show registration UI
                )
            }

            // Usage & limits — account-wide, BOTH agents (claude + codex),
            // each with a 5-hour AND a weekly window.
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

            // Appearance — ONE grouped card with Terminal folded in.
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

                    // Chat font — type-forward preview-card strip.
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 13.dp),
                        verticalArrangement = Arrangement.spacedBy(11.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                "Chat font",
                                style = MaterialTheme.typography.bodyLarge,
                                fontFamily = neon.sans,
                                fontWeight = FontWeight.SemiBold,
                                color = neon.text,
                            )
                            Spacer(Modifier.weight(1f))
                            Text(fontFamily.label, fontFamily = neon.mono, fontSize = 13.sp, color = neon.textFaint)
                        }
                        ChatFontStrip(current = fontFamily, onSelect = { appearance.setFontFamily(it) })
                    }

                    SettingsDivider()

                    // Terminal colors — drill-in to the terminal theme picker
                    // (folded in from the old Terminal section).
                    ListItem(
                        modifier = Modifier.clickable { showTerminalTheme = true },
                        leadingContent = { Icon(Icons.Filled.Palette, contentDescription = null, tint = neon.accent) },
                        headlineContent = { Text("Terminal colors", color = neon.text, fontFamily = neon.sans) },
                        trailingContent = {
                            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                                Text(terminalTheme.label, fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.textFaint)
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
                            Text("${bodyPointSize.toInt()}pt", fontFamily = neon.mono, fontSize = 12.sp, color = neon.accent, fontWeight = FontWeight.Bold)
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

                    // Terminal font size slider (folded in from Terminal).
                    Column(
                        modifier = Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 13.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Filled.FormatSize, contentDescription = null, tint = neon.accent, modifier = Modifier.size(24.dp))
                            Spacer(Modifier.width(16.dp))
                            Text("Terminal font size", style = MaterialTheme.typography.bodyLarge, fontFamily = neon.sans, color = neon.text)
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

                    // Native terminal toggle (folded in from Terminal).
                    ToggleRow(
                        icon = Icons.Filled.Science,
                        title = "Native terminal",
                        subtitle = "On by default. Turn off to use the legacy web terminal.",
                        isOn = experimentalNativeTerminal,
                        onChange = { appearance.setExperimentalNativeTerminal(it) },
                    )

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

            // Conversation.
            SettingsSection("Conversation") {
                ToggleRow(
                    icon = Icons.Filled.UnfoldLess,
                    title = "Collapse Turns",
                    subtitle = "Show only summaries; tap to expand",
                    isOn = collapseTurns,
                    onChange = { appearance.setCollapseTurns(it) },
                )
                ToggleRow(
                    icon = Icons.Filled.Vibration,
                    title = "Reply Haptics",
                    subtitle = "Tap when a reply starts and finishes",
                    isOn = replyHaptics,
                    onChange = { appearance.setReplyHaptics(it) },
                )
            }

            // Labs — chat-shell-v2 A/B override (§2). Auto follows the
            // assigned bucket; A/B are a local override for dogfooding.
            // Also hosts the debug-gated Agents panel toggle.
            SettingsSection("Labs") {
                val neon = LocalNeonTheme.current
                Column(modifier = Modifier.padding(horizontal = 14.dp, vertical = 12.dp)) {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Conversation style", fontFamily = neon.sans, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, color = neon.text)
                        Spacer(Modifier.weight(1f))
                        Text(appearance.resolvedChatArm().label, fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
                    }
                    Spacer(Modifier.height(8.dp))
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp), modifier = Modifier.fillMaxWidth()) {
                        FeatureFlags.ChatStylePreference.entries.forEach { p ->
                            val on = p == chatStylePref
                            Box(
                                modifier = Modifier.weight(1f).clip(RoundedCornerShape(10.dp))
                                    .background(if (on) neon.accent.copy(alpha = 0.16f) else neon.surface)
                                    .border(1.dp, if (on) neon.accent else neon.border, RoundedCornerShape(10.dp))
                                    .clickable { appearance.setChatStylePreference(p) }
                                    .padding(vertical = 8.dp),
                                contentAlignment = Alignment.Center,
                            ) {
                                Text(p.label, fontFamily = neon.mono, fontWeight = if (on) FontWeight.Bold else FontWeight.Normal, fontSize = 13.sp, color = if (on) neon.accent else neon.textDim)
                            }
                        }
                    }
                    Spacer(Modifier.height(6.dp))
                    Text("A = Breathe · B = Signature · Auto follows your assigned bucket.", fontFamily = neon.mono, fontSize = 10.5.sp, color = neon.textFaint)
                }
                SettingsDivider()
                ToggleRow(
                    icon = Icons.Filled.Person,
                    title = "Subagent panel",
                    subtitle = "Show Agents section in session Info (debug)",
                    isOn = showSubagentPanel,
                    onChange = { appearance.setShowSubagentPanel(it) },
                )
            }

            // Support — external donation link (not an IAP; opens system browser).
            SettingsSection("Support") {
                SettingsRow(
                    icon = Icons.Filled.Favorite,
                    title = "Buy me a coffee",
                    subtitle = "Support Conduit development",
                    onClick = {
                        Telemetry.breadcrumb("settings", "buy-me-a-coffee tapped")
                        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(SUPPORT_DONATION_URL))
                        context.startActivity(intent)
                    },
                )
            }

            // About — static identity card, onboarding guide re-entry, and
            // third-party licenses + trademark attribution screen.
            SettingsSection("About") {
                KeyValueRow(label = "Conduit", value = versionLabel)
                // "How it works" row — re-opens the onboarding guide.
                if (onOpenOnboarding != null) {
                    SettingsDivider()
                    SettingsRow(
                        icon = Icons.Default.AutoAwesome,
                        title = "How it works",
                        subtitle = "Add a box, run agents, work from anywhere",
                        onClick = {
                            Telemetry.breadcrumb("settings", "how_it_works_tapped")
                            onOpenOnboarding()
                        },
                    )
                }
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
    if (showServerSwitcher) {
        ServerSwitcherSheet(
            savedServers = savedServers,
            activeEndpoint = endpoint,
            onUse = { store.selectSavedServer(it.id, autoConnect = true); showServerSwitcher = false },
            onForget = { pendingForget = it },
            onAddServer = { showServerSwitcher = false; showAddServer = true },
            onDismiss = { showServerSwitcher = false },
        )
    }
    if (showTerminalTheme) {
        TerminalThemePickerSheet(appearance = appearance, current = terminalTheme, onDismiss = { showTerminalTheme = false })
    }
    if (showAgentLogin) {
        AgentLoginSheet(store = store, onDismiss = {
            showAgentLogin = false
            // Re-read the credential store so a fresh sign-in flips the
            // agent rows to `● signed in` immediately.
            agentAccounts = sh.nikhil.conduit.auth.AgentAccountStatus.current(context)
        })
    }
    // Per-agent Manage dialog (fix 3): re-auth or sign out for ONE agent.
    manageTarget?.let { account ->
        AlertDialog(
            onDismissRequest = { manageTarget = null },
            title = { Text("${account.displayName} account") },
            text = {
                Text(
                    if (account.signedIn) {
                        "Signing out clears the ${account.displayName} credential on this device. Sessions already running keep their credentials."
                    } else {
                        "Sign in to use ${account.displayName} through Conduit."
                    },
                )
            },
            confirmButton = {
                TextButton(onClick = {
                    manageTarget = null
                    showAgentLogin = true
                }) { Text("Sign in again") }
            },
            dismissButton = {
                Row {
                    if (account.signedIn) {
                        TextButton(onClick = {
                            sh.nikhil.conduit.auth.OAuthStore.clear(context, account.provider)
                            agentAccounts = sh.nikhil.conduit.auth.AgentAccountStatus.current(context)
                            manageTarget = null
                        }) { Text("Sign out", color = LocalNeonTheme.current.red) }
                    }
                    TextButton(onClick = { manageTarget = null }) { Text("Cancel") }
                }
            },
        )
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
 * Connection card (handoff Part A, render 01) — the big de-dupe. One card:
 * the active server row (tap → switch/manage), an AGENTS ON THIS SERVER
 * list (Claude / Codex), then Add account + Add server. Removes the old
 * standalone Account row and Servers section — the server has one home now.
 */
@Composable
private fun ConnectionSection(
    endpoint: Endpoint,
    harness: HarnessState,
    savedServers: List<SavedServer>,
    accounts: List<sh.nikhil.conduit.auth.AgentAccountStatus>,
    onSwitchServer: () -> Unit,
    onManage: (sh.nikhil.conduit.auth.AgentAccountStatus) -> Unit,
    onSignIn: () -> Unit,
    onAddAccount: () -> Unit,
    onAddServer: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val isDefault = savedServers.firstOrNull { it.isDefault }?.endpoint == endpoint
    val subtitle = "${if (harness.isReachable) "Live" else harness.badgeLabel} · " +
        if (isDefault) "default server" else "server"
    Column(modifier = Modifier.fillMaxWidth()) {
        SectionEyebrow("Connection")
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .neonCardSurface(neon = neon, shape = RoundedCornerShape(14.dp), fill = neon.surface),
        ) {
            // Active server row.
            ListItem(
                modifier = Modifier.clickable(onClick = onSwitchServer),
                leadingContent = { Icon(Icons.Filled.Apps, contentDescription = null, tint = neon.accent) },
                headlineContent = {
                    Text(
                        if (endpoint.isComplete) endpoint.displayHost else "Not paired",
                        color = neon.text,
                        fontFamily = neon.sans,
                        fontWeight = FontWeight.SemiBold,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                },
                supportingContent = {
                    Text(subtitle, fontFamily = neon.mono, fontSize = 12.5.sp, color = neon.textDim, maxLines = 1)
                },
                trailingContent = {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                        Text("Switch", color = neon.textDim, fontFamily = neon.sans, fontWeight = FontWeight.SemiBold)
                        Icon(Icons.Filled.ChevronRight, contentDescription = null, tint = neon.textFaint)
                    }
                },
                colors = transparentListItemColors(),
            )

            SettingsDivider()

            Text(
                "AGENTS ON THIS SERVER",
                fontFamily = neon.mono,
                fontWeight = FontWeight.Bold,
                fontSize = 11.sp,
                letterSpacing = 1.2.sp,
                color = neon.textFaint,
                maxLines = 1,
                softWrap = false,
                modifier = Modifier.padding(start = 16.dp, top = 11.dp, bottom = 2.dp),
            )

            accounts.forEach { account ->
                AgentAccountRow(
                    account = account,
                    onClick = { if (account.signedIn) onManage(account) else onSignIn() },
                )
                HorizontalDivider(modifier = Modifier.padding(start = 60.dp), color = neon.border)
            }

            // Add account.
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .clickable(onClick = onAddAccount)
                    .padding(horizontal = 14.dp, vertical = 12.dp),
            ) {
                Box(
                    modifier = Modifier
                        .size(38.dp)
                        .border(1.dp, neon.border, RoundedCornerShape(10.dp)),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("+", fontFamily = neon.mono, fontSize = 16.sp, color = neon.textDim)
                }
                Text(
                    "Add account",
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.SemiBold,
                    fontSize = 15.sp,
                    color = neon.textDim,
                )
            }

            SettingsDivider()

            // Add server.
            SettingsRow(
                icon = Icons.Filled.AddCircle,
                title = "Add server",
                subtitle = null,
                onClick = onAddServer,
            )
        }
    }
}

/**
 * Type-forward Chat-font strip (handoff Part A): a horizontal row of preview
 * cards, each rendering an `Ag` glyph in its own face with the name beneath.
 * One tap selects; the selected card gets the accent border + tint. Mirrors
 * iOS `fontCard` / `fontStripScroll`.
 */
@Composable
internal fun ChatFontStrip(
    current: AppearanceStore.FontFamily,
    onSelect: (AppearanceStore.FontFamily) -> Unit,
) {
    val neon = LocalNeonTheme.current
    LazyRow(
        horizontalArrangement = Arrangement.spacedBy(11.dp),
        contentPadding = PaddingValues(vertical = 3.dp),
    ) {
        items(AppearanceStore.FontFamily.values().toList()) { family ->
            val selected = family == current
            Column(
                modifier = Modifier
                    .width(128.dp)
                    .clip(RoundedCornerShape(14.dp))
                    .background(
                        if (selected) neon.accent.copy(alpha = 0.08f) else neon.surface2,
                        RoundedCornerShape(14.dp),
                    )
                    .border(
                        if (selected) 1.6.dp else 1.dp,
                        if (selected) neon.accent else neon.border,
                        RoundedCornerShape(14.dp),
                    )
                    .clickable { onSelect(family) }
                    .padding(start = 13.dp, end = 13.dp, top = 13.dp, bottom = 11.dp),
                verticalArrangement = Arrangement.spacedBy(9.dp),
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                    verticalAlignment = Alignment.Bottom,
                ) {
                    Text(
                        "Ag",
                        fontFamily = neonProseFontFamily(family),
                        fontSize = 30.sp,
                        color = neon.text,
                        maxLines = 1,
                    )
                    Text(
                        "\$>",
                        fontFamily = neonMonoFontFamily(family),
                        fontSize = 18.sp,
                        color = neon.accent,
                        maxLines = 1,
                    )
                }
                Text(
                    family.label,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                    color = if (selected) neon.accent else neon.textFaint,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
            }
        }
    }
}

/**
 * Server switcher — reached from Connection's active-server row. Lists saved
 * servers (Use to switch, trash to forget, Default badge + active check) plus
 * the Add Server affordance. Mirrors iOS `ServerSwitcherView`.
 */
@Composable
private fun ServerSwitcherSheet(
    savedServers: List<SavedServer>,
    activeEndpoint: Endpoint,
    onUse: (SavedServer) -> Unit,
    onForget: (SavedServer) -> Unit,
    onAddServer: () -> Unit,
    onDismiss: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    PickerSheet(title = "Servers", onDismiss = onDismiss) {
        savedServers.forEach { server ->
            val active = server.endpoint == activeEndpoint
            ListItem(
                modifier = Modifier.clickable { onUse(server) },
                leadingContent = {
                    Icon(Icons.Filled.Apps, contentDescription = null, tint = if (active) neon.green else neon.accent)
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
                            Surface(shape = RoundedCornerShape(50), color = neon.accent.copy(alpha = 0.22f)) {
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
                        IconButton(onClick = { onForget(server) }) {
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
            title = "Add Server",
            subtitle = "QR · LAN discover · SSH · paste URL+token",
            onClick = onAddServer,
        )
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
            NeonAccountUsageCard(
                fivePct = snap.fivePct,
                fiveResetsAt = snap.fiveResetsAt,
                weekPct = snap.weekPct,
                weekResetsAt = snap.weekResetsAt,
                agentTint = tint,
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

/** Terminal color-theme drill-in target. Single-select over [AppearanceStore.TerminalTheme]. */
@Composable
private fun TerminalThemePickerSheet(
    appearance: AppearanceStore,
    current: AppearanceStore.TerminalTheme,
    onDismiss: () -> Unit,
) {
    PickerSheet(title = "Terminal colors", onDismiss = onDismiss) {
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

/** One agent's account row inside [ConnectionSection]. */
@Composable
private fun AgentAccountRow(
    account: sh.nikhil.conduit.auth.AgentAccountStatus,
    onClick: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    val tint = neonAgentColor(account.agent, neon)
    Row(
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
        modifier = Modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
            .padding(horizontal = 14.dp, vertical = 11.dp),
    ) {
        Box(
            modifier = Modifier
                .size(38.dp)
                .background(tint.copy(alpha = 0.14f), RoundedCornerShape(10.dp))
                .border(1.dp, tint.copy(alpha = 0.35f), RoundedCornerShape(10.dp)),
            contentAlignment = Alignment.Center,
        ) {
            ConduitMark(size = 22.dp, color = tint)
        }
        Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                Text(
                    account.displayName,
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Bold,
                    fontSize = 15.sp,
                    color = neon.text,
                )
                account.planLabel?.let { plan ->
                    Text(
                        plan,
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.Bold,
                        fontSize = 9.sp,
                        letterSpacing = 0.6.sp,
                        color = tint,
                        modifier = Modifier
                            .background(tint.copy(alpha = 0.14f), RoundedCornerShape(50))
                            .border(1.dp, tint.copy(alpha = 0.4f), RoundedCornerShape(50))
                            .padding(horizontal = 6.dp, vertical = 2.dp),
                    )
                }
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
                val statusColor = if (account.signedIn) neon.green else neon.textFaint
                Box(Modifier.size(5.dp).background(statusColor, CircleShape))
                Text(
                    if (account.signedIn) "signed in" else "signed out",
                    fontFamily = neon.mono,
                    fontSize = 10.5.sp,
                    color = statusColor,
                )
            }
        }
        Text(
            if (account.signedIn) "Manage" else "Sign in",
            fontFamily = neon.sans,
            fontWeight = FontWeight.SemiBold,
            fontSize = 13.sp,
            color = if (account.signedIn) neon.textDim else neon.accent,
        )
        Icon(
            Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = neon.textFaint,
            modifier = Modifier.size(16.dp),
        )
    }
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
