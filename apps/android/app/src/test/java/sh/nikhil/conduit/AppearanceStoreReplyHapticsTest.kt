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
 * Reply-haptics feature flag (Android mirror of the iOS
 * `FeatureFlags.replyHaptics` persistence test). Default-ON, persists across
 * hydrate, and is toggleable off. Runs under Robolectric because the store
 * talks to real SharedPreferences.
 */
@RunWith(RobolectricTestRunner::class)
class AppearanceStoreReplyHapticsTest {

    @Before
    fun clearPrefs() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        ctx.getSharedPreferences("conduit.appearance", android.content.Context.MODE_PRIVATE)
            .edit()
            .clear()
            .commit()
    }

    @Test
    fun freshInstall_replyHaptics_isOn() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()
        val store = AppearanceStore()
        store.hydrate(ctx)
        assertTrue(store.replyHaptics.value)
    }

    @Test
    fun replyHaptics_persistsAcrossHydrate() {
        val ctx = ApplicationProvider.getApplicationContext<android.content.Context>()

        val first = AppearanceStore()
        first.hydrate(ctx)
        first.setReplyHaptics(false)
        assertFalse(first.replyHaptics.value)

        val second = AppearanceStore()
        second.hydrate(ctx)
        assertEquals(false, second.replyHaptics.value)
    }
}
