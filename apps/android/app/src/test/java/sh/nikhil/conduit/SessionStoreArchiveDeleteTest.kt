package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ProjectSession

/**
 * Pins the TWO-TIER delete model on Android (parity of the iOS change):
 *
 *  - ARCHIVE keeps the session in the persisted History index and does
 *    NOT tombstone it — so it stays viewable read-only in History.
 *  - PERMANENT DELETE tombstones the id AND removes it from the index —
 *    so it's gone from the app entirely and can never reappear.
 *
 * Drives the synchronous building blocks ([SessionStore.recordSavedSession],
 * [SessionStore.removeSavedSession], [SessionStore.tombstone]) directly,
 * the same way [SessionStoreTombstoneTest] does: the public [archive] /
 * [deletePermanently] entry points also launch a best-effort network
 * coroutine on `viewModelScope` (needs `Dispatchers.Main`, absent on the
 * JVM unit-test classpath), but they call exactly these helpers first.
 */
class SessionStoreArchiveDeleteTest {

    private fun session(id: String): ProjectSession =
        ProjectSession(
            id = id,
            name = id,
            assistant = "claude",
            branch = "main",
            preview = null,
            reasoningEffort = null,
            cwd = "/repo",
            startedAt = "2026-05-20T10:00:00Z",
            lastActivityAt = "2026-05-20T10:05:00Z",
            displayName = null,
        )

    @Test
    fun archive_keepsSessionInIndex_andDoesNotTombstone() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-archive"))

        // The archive path snapshots into the History index, marked exited.
        store.recordSavedSession("s-archive", isExited = true)

        val recent = store.savedSessionsRecent()
        assertTrue(
            "archived session must remain in History",
            recent.any { it.id == "s-archive" },
        )
        assertEquals(SavedSessionStatus.EXITED, recent.first { it.id == "s-archive" }.status)
        assertFalse(
            "archive must NOT tombstone the session",
            "s-archive" in store.deletedIds.value,
        )
    }

    @Test
    fun permanentDelete_tombstonesAndRemovesFromIndex() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-perm"))
        // Seed History as if it had been archived first.
        store.recordSavedSession("s-perm", isExited = true)
        assertTrue(store.savedSessionsRecent().any { it.id == "s-perm" })

        // The permanent-delete path: tombstone + drop from the index.
        store.tombstone("s-perm")
        store.removeSavedSession("s-perm")

        assertTrue(
            "permanent delete must tombstone the id",
            "s-perm" in store.deletedIds.value,
        )
        assertFalse(
            "permanent delete must remove the row from History",
            store.savedSessionsRecent().any { it.id == "s-perm" },
        )
    }

    @Test
    fun tombstonedSession_cannotBeReArchived() {
        val store = SessionStore()
        store.registerSessionForTest(session("s-gone"))
        // Permanently delete.
        store.tombstone("s-gone")
        store.removeSavedSession("s-gone")

        // A later status frame tries to re-record it (broker tmux lingers,
        // #199). The reducer must suppress it because it's tombstoned.
        store.recordSavedSession("s-gone", isExited = false)

        assertFalse(
            "a tombstoned session must never reappear in History",
            store.savedSessionsRecent().any { it.id == "s-gone" },
        )
    }
}
