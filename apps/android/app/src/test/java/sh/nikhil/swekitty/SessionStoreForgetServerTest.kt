package sh.nikhil.swekitty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * Android mirror of
 * `apps/ios/Tests/SweKittyTests/SessionStoreForgetServerTests.swift`
 * (iOS PR #128). Pins the new [SessionStore.forgetServer] entry point
 * that backs the swipe / "Forget" confirmation paths on saved
 * servers — before this contract landed, the only way to drop a
 * saved pairing was [SessionStore.removeSavedServer], which left the
 * per-id display-name override stranded in EncryptedSharedPreferences
 * keyed by the now-defunct server id.
 *
 * The store is exercised without calling [SessionStore.hydrate] so we
 * stay on the JVM unit-test classpath — the EncryptedSharedPreferences
 * dependency needs the AndroidKeyStore at runtime, which Robolectric
 * does not provide out of the box. The in-memory contract (which is
 * what the UI observes via the StateFlows) is the same code path the
 * persisted variant goes through, just with the safe-call `prefs?.`
 * sinks short-circuited.
 */
class SessionStoreForgetServerTest {

    @Test
    fun forgetServer_dropsRowAndDisplayName() {
        val store = SessionStore()
        val endpoint = Endpoint(url = "ws://10.0.0.7:1977", token = "tok-test")
        store.upsertSavedServer(name = "lab-forget", endpoint = endpoint, makeDefault = false)
        val savedId = store.savedServers.value.first { it.endpoint == endpoint }.id

        // Seed a display-name override keyed by the saved-server id —
        // the forget path is supposed to sweep this too. Mirrors the
        // iOS test that mutates `store.displayNames[savedID]` directly;
        // on Android the only public seed is [renameSession], which
        // takes the same id-keyed Map.
        store.renameSession(savedId, "Custom Lab Name")
        assertEquals("Custom Lab Name", store.displayNames.value[savedId])

        store.forgetServer(savedId)

        assertFalse(
            "row remains in savedServers after forgetServer",
            store.savedServers.value.any { it.id == savedId },
        )
        assertNull(
            "displayName override remained after forgetServer",
            store.displayNames.value[savedId],
        )
    }

    @Test
    fun forgetServer_isIdempotentForUnknownId() {
        val store = SessionStore()
        val before = store.savedServers.value.size
        // A made-up id was never in the saved set — forget should
        // no-op rather than throwing or scrambling state.
        store.forgetServer("nope-id-${System.nanoTime()}")
        assertEquals(before, store.savedServers.value.size)
    }

    @Test
    fun forgetServer_doesNotTouchOtherRowsOrOverrides() {
        // Two saved rows + two display-name overrides. forgetServer
        // on the first one must leave the second one's state intact —
        // catches a regression where the sweep would over-trim by id
        // prefix or by index.
        val store = SessionStore()
        val keep = Endpoint(url = "ws://10.0.0.8:1977", token = "keep")
        val drop = Endpoint(url = "ws://10.0.0.9:1977", token = "drop")
        store.upsertSavedServer(name = "keep-row", endpoint = keep, makeDefault = false)
        store.upsertSavedServer(name = "drop-row", endpoint = drop, makeDefault = false)
        val keepId = store.savedServers.value.first { it.endpoint == keep }.id
        val dropId = store.savedServers.value.first { it.endpoint == drop }.id
        store.renameSession(keepId, "Keep Override")
        store.renameSession(dropId, "Drop Override")

        store.forgetServer(dropId)

        assertNotNull(
            "untargeted saved row was incorrectly removed",
            store.savedServers.value.firstOrNull { it.id == keepId },
        )
        assertEquals(
            "untargeted displayName override was incorrectly cleared",
            "Keep Override",
            store.displayNames.value[keepId],
        )
        assertFalse(store.savedServers.value.any { it.id == dropId })
        assertNull(store.displayNames.value[dropId])
    }
}
