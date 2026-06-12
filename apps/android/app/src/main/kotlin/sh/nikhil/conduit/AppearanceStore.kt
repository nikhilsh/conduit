package sh.nikhil.conduit

import android.content.Context
import android.content.SharedPreferences
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.lifecycle.ViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * User-tunable appearance settings: chat body font, theme override,
 * and turn-collapse preference. Persisted to plain SharedPreferences
 * (these aren't secrets — no encryption needed).
 *
 * Mirrors `apps/ios/Sources/Models/AppearanceStore.swift`. Plan called
 * for DataStore but SharedPreferences keeps the dependency surface
 * smaller and is consistent with [SessionStore]'s prefs pattern.
 */
class AppearanceStore : ViewModel() {

    /**
     * Chat / reading body font (handoff Part A "Chat font"). The
     * conversation font, NOT the terminal-native one. The pre-redesign
     * enum was {Monospaced, System}; the type-forward redesign replaces it
     * with four curated faces. Legacy persisted `Monospaced` (and an iOS
     * `Serif`) decode through [fromPersisted] so existing installs migrate
     * instead of resetting.
     */
    /**
     * Chat-font **pairing** (handoff §4) — mirrors iOS
     * `AppearanceStore.FontFamily`. Each case names BOTH a prose face and a
     * mono face, because Conduit's soul is the mono (commands, identifiers,
     * exit codes). The pairing drives both `neon.sans` and `neon.mono`
     * app-wide. [note] is the "Prose · Mono" face names; [blurb] the
     * one-line personality.
     */
    enum class FontFamily(val label: String, val note: String, val blurb: String) {
        Terminal("Terminal", "Space Grotesk · JetBrains Mono", "Sharp, techy, a little futurist. The baseline."),
        Plex("Plex", "IBM Plex Sans · IBM Plex Mono", "Engineered and neutral. Prose and code feel related."),
        Geist("Geist", "Geist · Geist Mono", "Clean, modern, developer-native."),
        Editorial("Editorial", "Newsreader · Spline Sans Mono", "Serif prose + humanist mono — the calmest voice."),
        Soft("Soft", "IBM Plex Sans · Spline Sans Mono", "Rounded, friendly mono. Warm but still machine.");

        companion object {
            /**
             * Decode a persisted name, migrating BOTH prior generations:
             * the original {Serif,Monospaced,System} and the single-face
             * {System,SpaceGrotesk,IbmPlexSans,Newsreader} enum → the
             * pairing whose prose face matches.
             */
            fun fromPersisted(raw: String?): FontFamily = when (raw) {
                null -> Terminal
                "SpaceGrotesk" -> Terminal
                "IbmPlexSans" -> Plex
                "Newsreader" -> Editorial
                "System" -> Terminal
                "Serif" -> Editorial
                "Monospaced" -> Terminal
                else -> runCatching { valueOf(raw) }.getOrNull() ?: Terminal
            }
        }
    }

    enum class ThemeMode(val label: String) {
        System("System"),
        Light("Light"),
        Dark("Dark"),
    }

    /**
     * Palette choice for the "Neon Terminal" theme system. Enum-name
     * persistence is by the stable [id] string (not [name]) so it
     * matches iOS `NeonPaletteChoice` / `NeonPalette` and the Compose
     * `NeonPalette.id` one-for-one. Tokens are resolved by
     * `sh.nikhil.conduit.ui.NeonTheme.resolve(...)`; the effective
     * dark/light is reused from [themeMode] (no separate neon mode).
     */
    enum class NeonPalette(val id: String, val label: String) {
        Ice("ice", "Ice"),
        Synth("synth", "Synthwave"),
        Matrix("matrix", "Matrix"),
        Amber("amber", "Amber CRT");

        companion object {
            fun fromId(id: String?): NeonPalette =
                entries.firstOrNull { it.id == id } ?: Ice
        }
    }

    /**
     * Color theme for the terminal renderer. Mirrors iOS
     * `GhosttyVT.GhosttyTheme` / `AppearanceStore.GhosttyTerminalTheme`
     * one-for-one — same five curated themes, and the concrete
     * `#rrggbb` values live in [sh.nikhil.conduit.ui.TerminalPalette]
     * (read verbatim from the iOS source) so both platforms render
     * identically. Applied to the xterm.js path ([WebTerminal]) and the
     * Termux path ([TermuxTerminalView]) alike. Persisted by enum name.
     */
    enum class TerminalTheme(val label: String) {
        GhosttyDark("Ghostty Dark"),
        SolarizedDark("Solarized Dark"),
        Nord("Nord"),
        Dracula("Dracula"),
        GruvboxDark("Gruvbox Dark"),
    }

    private val _fontFamily = MutableStateFlow(FontFamily.Terminal)
    val fontFamily: StateFlow<FontFamily> = _fontFamily.asStateFlow()

    private val _themeMode = MutableStateFlow(ThemeMode.System)
    val themeMode: StateFlow<ThemeMode> = _themeMode.asStateFlow()

    private val _collapseTurns = MutableStateFlow(false)
    val collapseTurns: StateFlow<Boolean> = _collapseTurns.asStateFlow()

    /**
     * Reply haptics: play a short tap when an agent reply starts and
     * finishes (ChatGPT-style, but without the continuous buzz). Default
     * `true`, mirroring iOS `FeatureFlags.replyHaptics`. Surfaced in
     * Settings → Conversation; the player additionally respects the system
     * haptic-feedback-enabled setting (via `View.performHapticFeedback`).
     */
    private val _replyHaptics = MutableStateFlow(true)
    val replyHaptics: StateFlow<Boolean> = _replyHaptics.asStateFlow()

    /**
     * Terminal renderer selector. `true` (the default) uses the native
     * Termux `terminal-view` path ([TermuxTerminalView]); `false` falls
     * back to the legacy xterm.js WebView ([WebTerminal]). Mirrors iOS
     * `experimentalNativeTerminal`. Flipped to default-on once the Termux
     * path reached Stage 2/3 parity; the xterm.js path is retained as a
     * one-toggle fallback. See `docs/PLAN-TERMINAL-REWRITE.md`.
     */
    private val _experimentalNativeTerminal = MutableStateFlow(true)
    val experimentalNativeTerminal: StateFlow<Boolean> = _experimentalNativeTerminal.asStateFlow()

    /**
     * Body point size for the chat typography ramp (Android mirror of
     * iOS [AppearanceStore.bodyPointSize], landed alongside the
     * Settings → Font Size slider in PLAN-CONDUIT-VISUAL-PARITY PR 2).
     * Range is [BODY_POINT_SIZE_RANGE]; setters clamp out-of-range
     * writes so corrupted prefs cannot blow out the layout.
     */
    private val _bodyPointSize = MutableStateFlow(DEFAULT_BODY_POINT_SIZE)
    val bodyPointSize: StateFlow<Float> = _bodyPointSize.asStateFlow()

    /**
     * Terminal cell font size in points. Android mirror of iOS
     * [AppearanceStore.ghosttyFontSize]. Default is a dense
     * [DEFAULT_TERMINAL_FONT_SIZE] (10pt) so a real-terminal grid fits
     * on a phone, matching iOS; range is [TERMINAL_FONT_SIZE_RANGE].
     * Drives the xterm.js `fontSize` option (re-fit on change) and the
     * Termux cell text size. Setters clamp out-of-range writes.
     */
    private val _terminalFontSize = MutableStateFlow(DEFAULT_TERMINAL_FONT_SIZE)
    val terminalFontSize: StateFlow<Float> = _terminalFontSize.asStateFlow()

    /**
     * Curated terminal color theme. Default [TerminalTheme.GhosttyDark]
     * matches iOS. Drives the xterm.js `theme` option and the Termux
     * colour table. Persisted by enum name.
     */
    private val _terminalTheme = MutableStateFlow(TerminalTheme.GhosttyDark)
    val terminalTheme: StateFlow<TerminalTheme> = _terminalTheme.asStateFlow()

    /**
     * Neon Terminal palette choice. Default [NeonPalette.Ice], matching
     * iOS. Persisted by [NeonPalette.id]; resolved into a [NeonTheme]
     * and provided via `LocalNeonTheme` in MainActivity.
     */
    private val _neonPalette = MutableStateFlow(NeonPalette.Ice)
    val neonPalette: StateFlow<NeonPalette> = _neonPalette.asStateFlow()

    /**
     * Neon Terminal glow on/off. Default `true`, matching iOS. Flows
     * into `NeonTheme.resolve(...)` so later card work can render (or
     * skip) the layered glow shadows.
     */
    private val _neonGlow = MutableStateFlow(true)
    val neonGlow: StateFlow<Boolean> = _neonGlow.asStateFlow()

    // ── Feature flags / experiments (§2/§3/§5) — Android mirror of iOS
    //    FeatureFlags. Pure decision logic lives in [FeatureFlags]; this is
    //    the persisted state it feeds into.

    /** chat-shell-v2 conversation-style override (Settings › Labs). */
    private val _chatStylePreference = MutableStateFlow(FeatureFlags.ChatStylePreference.Auto)
    val chatStylePreference: StateFlow<FeatureFlags.ChatStylePreference> = _chatStylePreference.asStateFlow()

    /** Kill-switch (guardrail) — forces arm A globally. */
    private val _chatExperimentKilled = MutableStateFlow(false)
    val chatExperimentKilled: StateFlow<Boolean> = _chatExperimentKilled.asStateFlow()

    /** The deterministically-assigned bucket for this device, computed once
     *  from [chatStableID] and persisted (never re-bucketed). */
    private val _chatAssignedArm = MutableStateFlow(FeatureFlags.ChatArm.A)
    val chatAssignedArm: StateFlow<FeatureFlags.ChatArm> = _chatAssignedArm.asStateFlow()

    /** Stable per-device id the bucket hashes over (no accounts). */
    var chatStableID: String = ""
        private set

    /** New-session redesign flags (§3) — default on. */
    private val _newSessionAgentCards = MutableStateFlow(true)
    val newSessionAgentCards: StateFlow<Boolean> = _newSessionAgentCards.asStateFlow()
    private val _newSessionEffortDial = MutableStateFlow(true)
    val newSessionEffortDial: StateFlow<Boolean> = _newSessionEffortDial.asStateFlow()
    private val _newSessionLaunchLine = MutableStateFlow(true)
    val newSessionLaunchLine: StateFlow<Boolean> = _newSessionLaunchLine.asStateFlow()

    /** Last reasoning-effort picked on the dial (§3 — persists last choice).
     *  Empty until first use → the sheet falls back to the agent default. */
    private val _newSessionLastEffort = MutableStateFlow("")
    val newSessionLastEffort: StateFlow<String> = _newSessionLastEffort.asStateFlow()

    /**
     * Debug: show the subagent-roster "Agents" panel in the session
     * Information screen. Default OFF (FeatureFlags.showSubagentPanel).
     * Surfaced in Settings Labs so QA/staff can enable it without a build
     * change. Mirror of iOS `AppearanceStore.showSubagentPanel`.
     */
    private val _showSubagentPanel = MutableStateFlow(FeatureFlags.showSubagentPanel)
    val showSubagentPanel: StateFlow<Boolean> = _showSubagentPanel.asStateFlow()

    /**
     * Agents enabled in the new-session picker (§ declutter). claude + codex
     * ship on; gemini / opencode are opt-in. Persisted as a string set; the
     * picker filters its candidate list to this set via
     * [FeatureFlags.visibleAgents].
     */
    private val _enabledAgents = MutableStateFlow(FeatureFlags.defaultEnabledAgents.toSet())
    val enabledAgents: StateFlow<Set<String>> = _enabledAgents.asStateFlow()

    /** Onboarding state (§5). seenWelcome only governs the Welcome screen. */
    private val _onboardingSeenWelcome = MutableStateFlow(false)
    val onboardingSeenWelcome: StateFlow<Boolean> = _onboardingSeenWelcome.asStateFlow()
    private val _onboardingFurthestStep = MutableStateFlow(0)
    val onboardingFurthestStep: StateFlow<Int> = _onboardingFurthestStep.asStateFlow()
    private val _onboardingGuide = MutableStateFlow(true)
    val onboardingGuide: StateFlow<Boolean> = _onboardingGuide.asStateFlow()

    private var prefs: SharedPreferences? = null

    fun hydrate(ctx: Context) {
        val p = ctx.getSharedPreferences("conduit.appearance", Context.MODE_PRIVATE)
        prefs = p
        _fontFamily.value = FontFamily.fromPersisted(p.getString(KEY_FONT, null))
        _themeMode.value = p.getString(KEY_THEME, null)
            ?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() }
            ?: ThemeMode.System
        _collapseTurns.value = p.getBoolean(KEY_COLLAPSE, false)
        _replyHaptics.value = p.getBoolean(KEY_REPLY_HAPTICS, true)
        _experimentalNativeTerminal.value = p.getBoolean(KEY_EXPERIMENTAL_NATIVE_TERMINAL, true)
        _bodyPointSize.value = p.getFloat(KEY_BODY_POINT_SIZE, DEFAULT_BODY_POINT_SIZE)
            .coerceIn(BODY_POINT_SIZE_RANGE)
        _terminalFontSize.value = p.getFloat(KEY_TERMINAL_FONT_SIZE, DEFAULT_TERMINAL_FONT_SIZE)
            .coerceIn(TERMINAL_FONT_SIZE_RANGE)
        _terminalTheme.value = p.getString(KEY_TERMINAL_THEME, null)
            ?.let { runCatching { TerminalTheme.valueOf(it) }.getOrNull() }
            ?: TerminalTheme.GhosttyDark
        _neonPalette.value = NeonPalette.fromId(p.getString(KEY_NEON_PALETTE, null))
        _neonGlow.value = p.getBoolean(KEY_NEON_GLOW, true)

        // Feature flags / experiments.
        _chatStylePreference.value =
            FeatureFlags.ChatStylePreference.fromId(p.getString(KEY_CHAT_STYLE_PREF, null))
        _chatExperimentKilled.value = p.getBoolean(KEY_CHAT_KILLED, false)
        _newSessionAgentCards.value = p.getBoolean(KEY_NS_AGENT_CARDS, true)
        _newSessionEffortDial.value = p.getBoolean(KEY_NS_EFFORT_DIAL, true)
        _newSessionLaunchLine.value = p.getBoolean(KEY_NS_LAUNCH_LINE, true)
        _newSessionLastEffort.value = p.getString(KEY_NS_LAST_EFFORT, null) ?: ""
        _onboardingSeenWelcome.value = p.getBoolean(KEY_ONB_SEEN_WELCOME, false)
        _onboardingFurthestStep.value = p.getInt(KEY_ONB_FURTHEST_STEP, 0)
        _onboardingGuide.value = p.getBoolean(KEY_ONB_GUIDE, true)
        _showSubagentPanel.value = p.getBoolean(KEY_SHOW_SUBAGENT_PANEL, FeatureFlags.showSubagentPanel)
        _enabledAgents.value =
            p.getStringSet(KEY_ENABLED_AGENTS, null)?.toSet() ?: FeatureFlags.defaultEnabledAgents.toSet()

        // Stable DEVICE id (no accounts): persist a generated id once so the
        // bucket never moves. Then assign the bucket once and persist it —
        // never re-bucket the same install.
        chatStableID = p.getString(KEY_CHAT_STABLE_ID, null) ?: run {
            val seed = java.util.UUID.randomUUID().toString()
            p.edit().putString(KEY_CHAT_STABLE_ID, seed).apply()
            seed
        }
        _chatAssignedArm.value = p.getString(KEY_CHAT_ASSIGNED_ARM, null)
            ?.let { FeatureFlags.ChatArm.fromId(it) }
            ?: FeatureFlags.bucket(chatStableID).also {
                p.edit().putString(KEY_CHAT_ASSIGNED_ARM, it.id).apply()
            }
    }

    /** Resolved chat arm after overrides + kill-switch (§2). */
    fun resolvedChatArm(): FeatureFlags.ChatArm = FeatureFlags.resolvedChatArm(
        preference = _chatStylePreference.value,
        killed = _chatExperimentKilled.value,
        assigned = _chatAssignedArm.value,
    )

    fun setChatStylePreference(value: FeatureFlags.ChatStylePreference) {
        _chatStylePreference.value = value
        prefs?.edit()?.putString(KEY_CHAT_STYLE_PREF, value.id)?.apply()
    }

    fun setChatExperimentKilled(value: Boolean) {
        _chatExperimentKilled.value = value
        prefs?.edit()?.putBoolean(KEY_CHAT_KILLED, value)?.apply()
    }

    fun setNewSessionAgentCards(value: Boolean) {
        _newSessionAgentCards.value = value
        prefs?.edit()?.putBoolean(KEY_NS_AGENT_CARDS, value)?.apply()
    }

    fun setNewSessionEffortDial(value: Boolean) {
        _newSessionEffortDial.value = value
        prefs?.edit()?.putBoolean(KEY_NS_EFFORT_DIAL, value)?.apply()
    }

    fun setNewSessionLaunchLine(value: Boolean) {
        _newSessionLaunchLine.value = value
        prefs?.edit()?.putBoolean(KEY_NS_LAUNCH_LINE, value)?.apply()
    }

    fun setNewSessionLastEffort(value: String) {
        _newSessionLastEffort.value = value
        prefs?.edit()?.putString(KEY_NS_LAST_EFFORT, value)?.apply()
    }

    fun setOnboardingSeenWelcome(value: Boolean) {
        _onboardingSeenWelcome.value = value
        prefs?.edit()?.putBoolean(KEY_ONB_SEEN_WELCOME, value)?.apply()
    }

    fun setOnboardingFurthestStep(value: Int) {
        _onboardingFurthestStep.value = value
        prefs?.edit()?.putInt(KEY_ONB_FURTHEST_STEP, value)?.apply()
    }

    fun setOnboardingGuide(value: Boolean) {
        _onboardingGuide.value = value
        prefs?.edit()?.putBoolean(KEY_ONB_GUIDE, value)?.apply()
    }

    fun setShowSubagentPanel(value: Boolean) {
        _showSubagentPanel.value = value
        prefs?.edit()?.putBoolean(KEY_SHOW_SUBAGENT_PANEL, value)?.apply()
    }

    /** Enable/disable an agent in the new-session picker. Default agents
     *  (claude/codex) can be toggled too but [FeatureFlags.visibleAgents]
     *  keeps them visible regardless, so the picker is never empty. */
    fun setAgentEnabled(agent: String, enabled: Boolean) {
        val next = _enabledAgents.value.toMutableSet()
        if (enabled) next.add(agent) else next.remove(agent)
        _enabledAgents.value = next
        prefs?.edit()?.putStringSet(KEY_ENABLED_AGENTS, next)?.apply()
    }

    fun setFontFamily(value: FontFamily) {
        _fontFamily.value = value
        prefs?.edit()?.putString(KEY_FONT, value.name)?.apply()
    }

    fun setThemeMode(value: ThemeMode) {
        _themeMode.value = value
        prefs?.edit()?.putString(KEY_THEME, value.name)?.apply()
    }

    fun setCollapseTurns(value: Boolean) {
        _collapseTurns.value = value
        prefs?.edit()?.putBoolean(KEY_COLLAPSE, value)?.apply()
    }

    fun setReplyHaptics(value: Boolean) {
        _replyHaptics.value = value
        prefs?.edit()?.putBoolean(KEY_REPLY_HAPTICS, value)?.apply()
    }

    fun setExperimentalNativeTerminal(value: Boolean) {
        _experimentalNativeTerminal.value = value
        prefs?.edit()?.putBoolean(KEY_EXPERIMENTAL_NATIVE_TERMINAL, value)?.apply()
    }

    /**
     * Set body point size, clamped into [BODY_POINT_SIZE_RANGE]. Mirrors
     * the iOS setter: silent clamp on out-of-range writes so a slider
     * with rounding error or a corrupted pref cannot blow out the
     * layout.
     */
    fun setBodyPointSize(value: Float) {
        val clamped = value.coerceIn(BODY_POINT_SIZE_RANGE)
        _bodyPointSize.value = clamped
        prefs?.edit()?.putFloat(KEY_BODY_POINT_SIZE, clamped)?.apply()
    }

    /** Set terminal font size, clamped into [TERMINAL_FONT_SIZE_RANGE]
     *  (mirrors the iOS [ghosttyFontSize] setter's silent clamp). */
    fun setTerminalFontSize(value: Float) {
        val clamped = value.coerceIn(TERMINAL_FONT_SIZE_RANGE)
        _terminalFontSize.value = clamped
        prefs?.edit()?.putFloat(KEY_TERMINAL_FONT_SIZE, clamped)?.apply()
    }

    fun setTerminalTheme(value: TerminalTheme) {
        _terminalTheme.value = value
        prefs?.edit()?.putString(KEY_TERMINAL_THEME, value.name)?.apply()
    }

    /** Set the Neon Terminal palette; persisted by stable [NeonPalette.id]. */
    fun setNeonPalette(value: NeonPalette) {
        _neonPalette.value = value
        prefs?.edit()?.putString(KEY_NEON_PALETTE, value.id)?.apply()
    }

    /** Set the Neon Terminal glow flag. */
    fun setNeonGlow(value: Boolean) {
        _neonGlow.value = value
        prefs?.edit()?.putBoolean(KEY_NEON_GLOW, value)?.apply()
    }

    companion object {
        /** Clamp range for [bodyPointSize] (matches iOS 12...20). */
        val BODY_POINT_SIZE_RANGE: ClosedFloatingPointRange<Float> = 12f..20f
        /** Default body point size on a fresh install — bumped to 18
         *  (handoff Part A; matches iOS). Persisted values still win on
         *  hydrate via [getFloat] (no re-seed). */
        const val DEFAULT_BODY_POINT_SIZE: Float = 18f

        /** Clamp range for [terminalFontSize] (matches iOS
         *  `ghosttyFontSizeRange` 8...24). */
        val TERMINAL_FONT_SIZE_RANGE: ClosedFloatingPointRange<Float> = 8f..24f
        /** Default terminal font size — a dense 10pt, matching iOS
         *  `defaultGhosttyFontSize`. Denser than the old 13pt xterm.js
         *  default so a real-terminal grid fits on a phone. */
        const val DEFAULT_TERMINAL_FONT_SIZE: Float = 10f

        // SharedPreferences keys — kept private (file-scope) so callers
        // go through the typed setters / state flows above. Live in the
        // public companion so we can have just one (Kotlin only allows a
        // single companion object per class).
        private const val KEY_FONT = "font"
        private const val KEY_THEME = "theme"
        private const val KEY_COLLAPSE = "collapseTurns"
        private const val KEY_REPLY_HAPTICS = "replyHaptics"
        private const val KEY_EXPERIMENTAL_NATIVE_TERMINAL = "experimentalNativeTerminal"
        private const val KEY_BODY_POINT_SIZE = "bodyPointSize"
        private const val KEY_TERMINAL_FONT_SIZE = "terminalFontSize"
        private const val KEY_TERMINAL_THEME = "terminalTheme"
        private const val KEY_NEON_PALETTE = "neonPalette"
        private const val KEY_NEON_GLOW = "neonGlow"
        private const val KEY_CHAT_STYLE_PREF = "chat.stylePreference"
        private const val KEY_CHAT_KILLED = "chat.experimentKilled"
        private const val KEY_CHAT_ASSIGNED_ARM = "chat.assignedArm"
        private const val KEY_CHAT_STABLE_ID = "chat.stableID"
        private const val KEY_NS_AGENT_CARDS = "newSession.agentCards"
        private const val KEY_NS_EFFORT_DIAL = "newSession.effortDial"
        private const val KEY_NS_LAUNCH_LINE = "newSession.launchLine"
        private const val KEY_NS_LAST_EFFORT = "newSession.lastEffort"
        private const val KEY_ONB_SEEN_WELCOME = "onboarding.seenWelcome"
        private const val KEY_ONB_FURTHEST_STEP = "onboarding.furthestStep"
        private const val KEY_ONB_GUIDE = "onboarding.guide"
        private const val KEY_SHOW_SUBAGENT_PANEL = "debug.showSubagentPanel"
        private const val KEY_ENABLED_AGENTS = "newSession.enabledAgents"
    }
}

/**
 * CompositionLocal so any composable below `AppRoot` can read
 * appearance without threading the store through every parameter list.
 */
val LocalAppearanceStore = staticCompositionLocalOf<AppearanceStore> {
    error("AppearanceStore not provided")
}
