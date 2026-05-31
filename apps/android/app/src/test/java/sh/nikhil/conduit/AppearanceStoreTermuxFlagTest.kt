package sh.nikhil.conduit

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android mirror of `apps/ios/Tests/ConduitTests/AppearanceStoreTests.swift`
 * (the `persistsExperimentalNativeTerminal` + `freshInstallHasExperimentalNativeTerminalOff`
 * cases). Stage 0 feature flag for the Termux-backed native terminal
 * path — see `docs/PLAN-TERMINAL-REWRITE.md` (Android section).
 *
 * Persistence is the only behavior we can lock down at this stage; the
 * actual [sh.nikhil.conduit.ui.TermuxTerminalView] is a placeholder
 * until Stage 1 wires `com.termux:terminal-view`.
 *
 * Runs under Robolectric because the store talks to real
 * `SharedPreferences` through [android.content.Context], and the unit-
 * test classpath needs the Android framework to back that. Each test
 * clears the shared "conduit.appearance" prefs file before running so
 * the fresh-install assertion is not polluted by a previous run.
 */
@RunWith(RobolectricTestRunner::class)
class AppearanceStoreTermuxFlagTest {

    @Before
    fun clearPrefs() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("conduit.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @Test
    fun freshInstall_experimentalNativeTerminal_isOff() {
        // The xterm.js path remains the production renderer; flipping
        // this default to `true` would unconditionally swap it for the
        // Stage 0 placeholder. Same invariant the iOS test
        // `freshInstallHasExperimentalNativeTerminalOff` defends.
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertFalse(store.experimentalNativeTerminal.value)
    }

    @Test
    fun experimentalNativeTerminal_persistsAcrossHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setExperimentalNativeTerminal(true)
        assertTrue(first.experimentalNativeTerminal.value)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertTrue(second.experimentalNativeTerminal.value)
    }

    @Test
    fun experimentalNativeTerminal_canBeToggledOff() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setExperimentalNativeTerminal(true)
        first.setExperimentalNativeTerminal(false)
        assertFalse(first.experimentalNativeTerminal.value)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertEquals(false, second.experimentalNativeTerminal.value)
    }
}
