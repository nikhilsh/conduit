package sh.nikhil.swekitty

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

    enum class FontFamily(val label: String) {
        Monospaced("Monospaced"),
        System("System"),
    }

    enum class ThemeMode(val label: String) {
        System("System"),
        Light("Light"),
        Dark("Dark"),
    }

    /**
     * Color theme for the terminal renderer. Mirrors iOS
     * `GhosttyVT.GhosttyTheme` / `AppearanceStore.GhosttyTerminalTheme`
     * one-for-one — same five curated themes, and the concrete
     * `#rrggbb` values live in [sh.nikhil.swekitty.ui.TerminalPalette]
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

    private val _fontFamily = MutableStateFlow(FontFamily.Monospaced)
    val fontFamily: StateFlow<FontFamily> = _fontFamily.asStateFlow()

    private val _themeMode = MutableStateFlow(ThemeMode.System)
    val themeMode: StateFlow<ThemeMode> = _themeMode.asStateFlow()

    private val _collapseTurns = MutableStateFlow(false)
    val collapseTurns: StateFlow<Boolean> = _collapseTurns.asStateFlow()

    /**
     * Stage 0 feature flag for the Termux `terminal-view` native
     * terminal path. Mirrors iOS `experimentalNativeTerminal`. Off by
     * default — the xterm.js path ([WebTerminal]) remains the
     * production renderer until Stage 2 of the rewrite ships. See
     * `docs/PLAN-TERMINAL-REWRITE.md` (Android section).
     */
    private val _experimentalNativeTerminal = MutableStateFlow(false)
    val experimentalNativeTerminal: StateFlow<Boolean> = _experimentalNativeTerminal.asStateFlow()

    /**
     * Body point size for the chat typography ramp (Android mirror of
     * iOS [AppearanceStore.bodyPointSize], landed alongside the
     * Settings → Font Size slider in PLAN-LITTER-VISUAL-PARITY PR 2).
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

    private var prefs: SharedPreferences? = null

    fun hydrate(ctx: Context) {
        val p = ctx.getSharedPreferences("swekitty.appearance", Context.MODE_PRIVATE)
        prefs = p
        _fontFamily.value = p.getString(KEY_FONT, null)
            ?.let { runCatching { FontFamily.valueOf(it) }.getOrNull() }
            ?: FontFamily.Monospaced
        _themeMode.value = p.getString(KEY_THEME, null)
            ?.let { runCatching { ThemeMode.valueOf(it) }.getOrNull() }
            ?: ThemeMode.System
        _collapseTurns.value = p.getBoolean(KEY_COLLAPSE, false)
        _experimentalNativeTerminal.value = p.getBoolean(KEY_EXPERIMENTAL_NATIVE_TERMINAL, false)
        _bodyPointSize.value = p.getFloat(KEY_BODY_POINT_SIZE, DEFAULT_BODY_POINT_SIZE)
            .coerceIn(BODY_POINT_SIZE_RANGE)
        _terminalFontSize.value = p.getFloat(KEY_TERMINAL_FONT_SIZE, DEFAULT_TERMINAL_FONT_SIZE)
            .coerceIn(TERMINAL_FONT_SIZE_RANGE)
        _terminalTheme.value = p.getString(KEY_TERMINAL_THEME, null)
            ?.let { runCatching { TerminalTheme.valueOf(it) }.getOrNull() }
            ?: TerminalTheme.GhosttyDark
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

    companion object {
        /** Clamp range for [bodyPointSize] (matches iOS). */
        val BODY_POINT_SIZE_RANGE: ClosedFloatingPointRange<Float> = 12f..18f
        /** Default body point size on a fresh install (matches iOS). */
        const val DEFAULT_BODY_POINT_SIZE: Float = 14f

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
        private const val KEY_EXPERIMENTAL_NATIVE_TERMINAL = "experimentalNativeTerminal"
        private const val KEY_BODY_POINT_SIZE = "bodyPointSize"
        private const val KEY_TERMINAL_FONT_SIZE = "terminalFontSize"
        private const val KEY_TERMINAL_THEME = "terminalTheme"
    }
}

/**
 * CompositionLocal so any composable below `AppRoot` can read
 * appearance without threading the store through every parameter list.
 */
val LocalAppearanceStore = staticCompositionLocalOf<AppearanceStore> {
    error("AppearanceStore not provided")
}
