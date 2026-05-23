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

    companion object {
        /** Clamp range for [bodyPointSize] (matches iOS). */
        val BODY_POINT_SIZE_RANGE: ClosedFloatingPointRange<Float> = 12f..18f
        /** Default body point size on a fresh install (matches iOS). */
        const val DEFAULT_BODY_POINT_SIZE: Float = 14f
    }

    private companion object {
        const val KEY_FONT = "font"
        const val KEY_THEME = "theme"
        const val KEY_COLLAPSE = "collapseTurns"
        const val KEY_EXPERIMENTAL_NATIVE_TERMINAL = "experimentalNativeTerminal"
        const val KEY_BODY_POINT_SIZE = "bodyPointSize"
    }
}

/**
 * CompositionLocal so any composable below `AppRoot` can read
 * appearance without threading the store through every parameter list.
 */
val LocalAppearanceStore = staticCompositionLocalOf<AppearanceStore> {
    error("AppearanceStore not provided")
}
