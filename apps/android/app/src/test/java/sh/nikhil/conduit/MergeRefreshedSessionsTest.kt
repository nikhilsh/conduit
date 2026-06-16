package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins the data-loss guard in [mergeRefreshedSessions]: a transient empty or
 * partial `listSessions()` (which the Rust core returns right after a
 * resume/adopt join, before status frames land) must NOT wipe existing
 * current-box sessions. Regression test for the "tap Resume -> No sessions yet,
 * all sessions vanish" bug.
 */
class MergeRefreshedSessionsTest {

    private fun merge(
        existing: List<String>,
        listed: List<String>,
        sessionBox: Map<String, String>,
        currentBoxId: String,
        deleted: Set<String> = emptySet(),
        recentlyArchived: Set<String> = emptySet(),
    ): List<String> = mergeRefreshedSessions(
        existing = existing,
        listed = listed,
        sessionBox = sessionBox,
        currentBoxId = currentBoxId,
        deleted = deleted,
        recentlyArchived = recentlyArchived,
        idOf = { it },
    )

    @Test
    fun emptyListedDoesNotWipeCurrentBoxSessions() {
        // The whole bug: resume join makes listSessions() return [] transiently.
        val result = merge(
            existing = listOf("a", "b", "c"),
            listed = emptyList(),
            sessionBox = mapOf("a" to "box1", "b" to "box1", "c" to "box1"),
            currentBoxId = "box1",
        )
        assertEquals(listOf("a", "b", "c"), result)
    }

    @Test
    fun partialListedPreservesOmittedCurrentBoxSessions() {
        // listSessions() returns only the just-joined session; the rest are
        // preserved rather than dropped.
        val result = merge(
            existing = listOf("a", "b", "c"),
            listed = listOf("resumed"),
            sessionBox = mapOf("a" to "box1", "b" to "box1", "c" to "box1"),
            currentBoxId = "box1",
        )
        assertEquals(setOf("resumed", "a", "b", "c"), result.toSet())
        // Fresh listed wins ordering-first.
        assertEquals("resumed", result.first())
    }

    @Test
    fun deletedSessionIsNotPreserved() {
        val result = merge(
            existing = listOf("a", "gone"),
            listed = emptyList(),
            sessionBox = mapOf("a" to "box1", "gone" to "box1"),
            currentBoxId = "box1",
            deleted = setOf("gone"),
        )
        assertEquals(listOf("a"), result)
    }

    @Test
    fun recentlyArchivedSessionIsNotPreserved() {
        val result = merge(
            existing = listOf("a", "archived"),
            listed = emptyList(),
            sessionBox = mapOf("a" to "box1", "archived" to "box1"),
            currentBoxId = "box1",
            recentlyArchived = setOf("archived"),
        )
        assertEquals(listOf("a"), result)
    }

    @Test
    fun otherBoxSessionsAreKeptAsDimmedHistory() {
        // Box-switch: box1's prior session stays visible while box2 loads.
        val result = merge(
            existing = listOf("fromBox1"),
            listed = listOf("fromBox2"),
            sessionBox = mapOf("fromBox1" to "box1", "fromBox2" to "box2"),
            currentBoxId = "box2",
        )
        assertEquals(setOf("fromBox1", "fromBox2"), result.toSet())
    }

    @Test
    fun unstampedExistingSessionsAreNotPreservedWhenOmitted() {
        // No box stamp -> neither other-box nor current-box; dropped on refresh
        // (matches prior behavior where only stamped current-box rows persist).
        val result = merge(
            existing = listOf("orphan"),
            listed = emptyList(),
            sessionBox = emptyMap(),
            currentBoxId = "box1",
        )
        assertEquals(emptyList<String>(), result)
    }
}
