package sh.nikhil.swekitty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.swe_kitty_core.SessionStatus

/**
 * Android mirror of
 * `apps/ios/Tests/SweKittyTests/SessionStoreTests.swift`
 * (`SessionStoreReadOnlyTests`, iOS PR #214). Read-only is the DEFAULT
 * for any session not positively confirmed live on the broker. These
 * pin the inversion so a regression that re-introduces a
 * default-`Live` (the "History still interactive" bug) fails loudly.
 *
 * The store is exercised without [SessionStore.hydrate] so we stay on
 * the JVM unit-test classpath. Status / exit state is seeded through
 * the public `SweKittyDelegate` callbacks ([SessionStore.onStatus] /
 * [SessionStore.onExit]) — the same in-memory StateFlow code paths the
 * live socket drives. `refreshSessions` no-ops with no client, so the
 * callbacks are safe off-device.
 */
class SessionStoreReadOnlyTest {

    private fun status(id: String, phase: String): SessionStatus = SessionStatus(
        session = id,
        assistant = "claude",
        phase = phase,
        health = "green",
        rows = 40u,
        cols = 120u,
        yolo = false,
        preview = null,
        sessionName = null,
        viewers = 1u,
        reasoningEffort = null,
        cwd = null,
        startedAt = null,
        lastActivityAt = null,
        displayName = null,
    )

    // MARK: isLivePhase classifier

    @Test
    fun livePhasesClassifyLive() {
        for (p in listOf("running", "ready", "idle", "thinking", "RUNNING", " ready ")) {
            assertTrue("$p should be live", SessionStore.isLivePhase(p))
        }
    }

    @Test
    fun terminalAndUnknownPhasesClassifyNotLive() {
        for (p in listOf("exited", "exited(0)", "exited(137)", "failed", "dead", "", "swapped", "zombie")) {
            assertFalse("$p should NOT be live", SessionStore.isLivePhase(p))
        }
    }

    @Test
    fun exitCodeParsesFromPhase() {
        assertEquals(137, SessionStore.exitCode("exited(137)"))
        assertEquals(0, SessionStore.exitCode("exited(0)"))
        assertNull(SessionStore.exitCode("exited"))
    }

    // MARK: default = read-only

    @Test
    fun unknownSessionIsReadOnly() {
        val store = SessionStore()
        assertTrue(store.isReadOnly("never-seen"))
        assertFalse(store.isConfirmedLive("never-seen"))
    }

    // MARK: confirmed live = interactive

    @Test
    fun runningStatusIsInteractive() {
        val store = SessionStore()
        val id = "live-1"
        store.onStatus(status(id, phase = "running"))
        assertTrue(store.isConfirmedLive(id))
        assertFalse(store.isReadOnly(id))
    }

    // MARK: exited / recovered = read-only

    @Test
    fun ingestExitMakesReadOnly() {
        val store = SessionStore()
        val id = "exit-1"
        store.onStatus(status(id, phase = "running"))
        assertFalse(store.isReadOnly(id))
        store.onExit(id, 0)
        assertTrue(store.isReadOnly(id))
    }

    @Test
    fun statusWithExitedPhaseIsReadOnlyEvenWithoutExitFrame() {
        // Joining an already-dead session: the broker's first status frame
        // reports `exited` (no prior `exit` frame on this client). Must
        // lock read-only, not promote to `Live`.
        val store = SessionStore()
        val id = "recovered-1"
        store.onStatus(status(id, phase = "exited(137)"))
        assertTrue(store.isReadOnly(id))
        val lc = store.sessionLifecycle.value[id]
        assertTrue("expected Exited lifecycle from an exited status phase", lc is SessionLifecycle.Exited)
        assertEquals(137, (lc as SessionLifecycle.Exited).code)
    }

    @Test
    fun liveSessionDemotedByLaterExitedStatus() {
        val store = SessionStore()
        val id = "demote-1"
        store.onStatus(status(id, phase = "running"))
        assertFalse(store.isReadOnly(id))
        store.onStatus(status(id, phase = "exited"))
        assertTrue(store.isReadOnly(id))
    }

    @Test
    fun exitedLifecycleNeverRevivedByLaterRunningStatus() {
        // Terminal is terminal — a stale `running` delta after exit must
        // not resurrect an interactive surface.
        val store = SessionStore()
        val id = "terminal-1"
        store.onExit(id, 0)
        assertTrue(store.isReadOnly(id))
        store.onStatus(status(id, phase = "running"))
        assertTrue(store.isReadOnly(id))
    }

    @Test
    fun unknownPhaseStatusFailsClosedToReadOnly() {
        // A status frame whose phase we don't recognize (and isn't
        // exited) must leave the session read-only — fail closed.
        val store = SessionStore()
        val id = "unknown-phase-1"
        store.onStatus(status(id, phase = "zombie"))
        assertTrue(store.isReadOnly(id))
        assertFalse(store.isConfirmedLive(id))
    }
}
