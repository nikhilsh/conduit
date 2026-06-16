package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ConduitException

/**
 * Android mirror of the iOS `SessionStoreTests` UnknownSession suite
 * (PR #652). When the broker has forgotten a session (restart/redeploy/GC) a
 * queued send returns [ConduitException.UnknownSession]. The deliver path must
 * STOP retrying (drop only that dead entry so later flushes don't re-hit the
 * dead session, and other pending sends are untouched) and flip the echo to
 * `expired` so the bubble offers Resume -- instead of burning the retry budget
 * + capturing a Sentry ERROR on every broker restart.
 *
 * Exercised without a live WS: [SessionStore.sendChat] with a null client
 * seeds an optimistic echo + a pending queue entry, and
 * [SessionStore.handleExpiredSession] is the exact branch the deliver
 * catch-handler calls.
 */
class SessionStoreUnknownSessionTest {

    /** The detector must match ONLY the UnknownSession case (UniFFI case 6) so
     *  genuine failures keep their retry + error-capture path. */
    @Test
    fun isUnknownSessionMatchesOnlyThatCase() {
        val store = SessionStore()
        assertTrue(store.isUnknownSession(ConduitException.UnknownSession("gone")))
        assertFalse(store.isUnknownSession(ConduitException.Connection("x")))
        assertFalse(store.isUnknownSession(ConduitException.NotConnected("x")))
        assertFalse(store.isUnknownSession(RuntimeException("boom")))
        assertFalse(store.isUnknownSession(null))
    }

    /** On UnknownSession the echo flips to `expired` (drives the Resume footer)
     *  and the entry is dropped from the queue so flushes won't re-deliver into
     *  a dead session. */
    @Test
    fun unknownSessionMarksEchoExpiredAndDropsFromQueue() {
        val store = SessionStore()
        val sessionId = "test-expired-${java.util.UUID.randomUUID()}"

        // Seed an optimistic echo (no client -> queued + pending).
        store.sendChat(sessionId, "Hi")
        val localId = store.conversationLog.value[sessionId]?.first()?.id ?: ""
        assertTrue(store.pendingChats.value.isPending(localId, sessionId))

        // Drive the UnknownSession handler the deliver catch-branch calls.
        store.handleExpiredSession(sessionId, localId)

        assertEquals("expired", store.conversationLog.value[sessionId]?.first()?.status)
        assertFalse(store.pendingChats.value.isPending(localId, sessionId))
    }

    /** Early-stop must drop ONLY the dead entry: other pending sends in the
     *  same session stay queued so they aren't stranded. */
    @Test
    fun unknownSessionDoesNotStrandOtherPendingSends() {
        val store = SessionStore()
        val sessionId = "test-expired-${java.util.UUID.randomUUID()}"

        store.sendChat(sessionId, "first")
        store.sendChat(sessionId, "second")
        val items = store.conversationLog.value[sessionId].orEmpty()
        val firstId = items[0].id
        val secondId = items[1].id
        assertTrue(store.pendingChats.value.isPending(firstId, sessionId))
        assertTrue(store.pendingChats.value.isPending(secondId, sessionId))

        store.handleExpiredSession(sessionId, firstId)

        // Dead entry gone; the other send is untouched.
        assertFalse(store.pendingChats.value.isPending(firstId, sessionId))
        assertEquals("expired", store.conversationLog.value[sessionId]?.get(0)?.status)
        assertTrue(store.pendingChats.value.isPending(secondId, sessionId))
    }
}
