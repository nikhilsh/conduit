package sh.nikhil.swekitty

import androidx.test.core.app.ApplicationProvider
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/**
 * Android mirror of `apps/ios/Tests/SweKittyTests/AppearanceStoreTests.swift`
 * `bodyPointSize…` cases (PLAN-LITTER-VISUAL-PARITY PR 2). Locks down:
 *   - fresh-install default sits at [AppearanceStore.DEFAULT_BODY_POINT_SIZE]
 *   - writes round-trip through SharedPreferences
 *   - out-of-range writes clamp into [AppearanceStore.BODY_POINT_SIZE_RANGE]
 *   - corrupted on-disk values are clamped on hydrate
 *
 * Without these pins, a future setter "tightening" could silently ship
 * a 200pt body across the app — a layout-breaking regression the slider
 * itself can't catch.
 */
@RunWith(RobolectricTestRunner::class)
class AppearanceStoreBodyPointSizeTest {

    @Before
    fun clearPrefs() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("swekitty.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @Test
    fun freshInstall_bodyPointSize_isDefault() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(AppearanceStore.DEFAULT_BODY_POINT_SIZE, store.bodyPointSize.value)
    }

    @Test
    fun bodyPointSize_persistsAcrossHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setBodyPointSize(16f)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertEquals(16f, second.bodyPointSize.value)
    }

    @Test
    fun bodyPointSize_clampsAboveRange() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        store.setBodyPointSize(99f)
        assertEquals(AppearanceStore.BODY_POINT_SIZE_RANGE.endInclusive, store.bodyPointSize.value)
    }

    @Test
    fun bodyPointSize_clampsBelowRange() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        store.setBodyPointSize(4f)
        assertEquals(AppearanceStore.BODY_POINT_SIZE_RANGE.start, store.bodyPointSize.value)
    }

    @Test
    fun corruptedBodyPointSize_isClampedOnHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("swekitty.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .putFloat("bodyPointSize", 99f)
            .commit()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertEquals(AppearanceStore.BODY_POINT_SIZE_RANGE.endInclusive, store.bodyPointSize.value)
    }
}
