package sh.nikhil.conduit

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android mirror of the iOS `ghosttyFontSize` / `ghosttyTerminalTheme`
 * AppearanceStore cases. Locks down the terminal font-size + color-theme
 * controls that drive both the xterm.js path ([sh.nikhil.conduit.ui.WebTerminal])
 * and the Termux path ([sh.nikhil.conduit.ui.TermuxTerminalView]):
 *   - fresh-install defaults (10pt, Ghostty Dark) match iOS
 *   - writes round-trip through SharedPreferences
 *   - out-of-range font sizes clamp into [AppearanceStore.TERMINAL_FONT_SIZE_RANGE]
 *   - a corrupted on-disk font size is clamped on hydrate
 *
 * Without these pins a setter change could silently ship a 200pt grid (a
 * one-column terminal) or drop the iOS-parity default.
 */
@RunWith(RobolectricTestRunner::class)
class AppearanceStoreTerminalTest {

    @Before
    fun clearPrefs() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("conduit.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @Test
    fun freshInstall_terminalFontSize_isDenseDefault() {
        // 10pt matches iOS `defaultGhosttyFontSize` — denser than the old
        // 13pt xterm.js default.
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(AppearanceStore.DEFAULT_TERMINAL_FONT_SIZE, store.terminalFontSize.value)
        assertEquals(10f, store.terminalFontSize.value)
    }

    @Test
    fun freshInstall_terminalTheme_isGhosttyDark() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(AppearanceStore.TerminalTheme.GhosttyDark, store.terminalTheme.value)
    }

    @Test
    fun terminalFontSize_persistsAcrossHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setTerminalFontSize(16f)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertEquals(16f, second.terminalFontSize.value)
    }

    @Test
    fun terminalTheme_persistsAcrossHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setTerminalTheme(AppearanceStore.TerminalTheme.Dracula)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertEquals(AppearanceStore.TerminalTheme.Dracula, second.terminalTheme.value)
    }

    @Test
    fun terminalFontSize_clampsAboveRange() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        store.setTerminalFontSize(99f)
        assertEquals(
            AppearanceStore.TERMINAL_FONT_SIZE_RANGE.endInclusive,
            store.terminalFontSize.value,
        )
    }

    @Test
    fun terminalFontSize_clampsBelowRange() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        store.setTerminalFontSize(2f)
        assertEquals(
            AppearanceStore.TERMINAL_FONT_SIZE_RANGE.start,
            store.terminalFontSize.value,
        )
    }

    @Test
    fun corruptedTerminalFontSize_isClampedOnHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("conduit.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .putFloat("terminalFontSize", 99f)
            .commit()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(
            AppearanceStore.TERMINAL_FONT_SIZE_RANGE.endInclusive,
            store.terminalFontSize.value,
        )
    }

    @Test
    fun corruptedTerminalTheme_fallsBackToGhosttyDark() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("conduit.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .putString("terminalTheme", "NotARealTheme")
            .commit()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(AppearanceStore.TerminalTheme.GhosttyDark, store.terminalTheme.value)
    }
}
