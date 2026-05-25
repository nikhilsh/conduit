package sh.nikhil.swekitty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Android mirror of the tombstone half of
 * `apps/ios/Tests/SweKittyTests/SavedSessionsStoreTests.swift`.
 *
 * Pins delete-is-terminal: a deleted session is recorded in a persisted
 * tombstone set, and [SessionStore.refreshSessions] filters
 * [listSessions] against it so a session whose tmux the broker keeps
 * alive (#199) can never reappear in the list / read as interactive.
 *
 * Like [SessionStoreForgetServerTest], the store is exercised without
 * [SessionStore.hydrate] so we stay on the JVM unit-test classpath —
 * EncryptedSharedPreferences needs the AndroidKeyStore at runtime. We
 * drive [SessionStore.tombstone] directly rather than [SessionStore.exit]
 * because `exit` also launches a best-effort network coroutine on
 * `viewModelScope`, which needs `Dispatchers.Main` (absent here). `exit`
 * calls `tombstone` first, so this covers the same recording contract.
 */
class SessionStoreTombstoneTest {

    @Test
    fun tombstone_recordsDeletedId() {
        val store = SessionStore()
        assertFalse("s-zombie" in store.deletedIds.value)
        store.tombstone("s-zombie")
        assertTrue(
            "deleted id missing from tombstone set",
            "s-zombie" in store.deletedIds.value,
        )
    }

    @Test
    fun tombstone_isIdempotent() {
        val store = SessionStore()
        store.tombstone("s-dup")
        store.tombstone("s-dup")
        assertEquals(
            "duplicate tombstone recorded for the same id",
            1,
            store.deletedIds.value.count { it == "s-dup" },
        )
    }

    @Test
    fun tombstonedId_isFilteredFromListLikeRefreshSessions() {
        // Mirrors the predicate refreshSessions applies to listSessions:
        // a tombstoned id is dropped from the visible list even though
        // the broker still reports it (tmux lingers, #199).
        val store = SessionStore()
        store.tombstone("s-deleted")
        val brokerReported = listOf("s-live", "s-deleted")
        val deleted = store.deletedIds.value.toSet()
        val visible = brokerReported.filterNot { it in deleted }
        assertEquals(listOf("s-live"), visible)
    }

    @Test
    fun tombstoneSet_capsAtBound() {
        // Delete well past the cap; the set must not grow unbounded and
        // must retain the newest deletions (the broker has long reaped
        // the oldest by then, so evicting them is harmless).
        val store = SessionStore()
        val cap = 500
        val total = cap + 50
        for (i in 0 until total) store.tombstone("s-$i")
        assertEquals(
            "tombstone set exceeded its cap",
            cap,
            store.deletedIds.value.size,
        )
        assertTrue(
            "newest tombstone was evicted",
            "s-${total - 1}" in store.deletedIds.value,
        )
        assertFalse(
            "oldest tombstone should have been evicted past the cap",
            "s-0" in store.deletedIds.value,
        )
    }
}
