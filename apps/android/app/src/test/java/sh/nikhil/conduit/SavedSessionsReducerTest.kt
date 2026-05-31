package sh.nikhil.conduit

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import uniffi.conduit_core.ProjectSession

/**
 * Pins the pure archived-index reducers that back the two-tier delete on
 * Android — the parity of iOS `SavedSessionsStoreTests`. Exercises the
 * reducer directly (no ViewModel / EncryptedSharedPreferences, which need
 * the AndroidKeyStore at runtime).
 */
class SavedSessionsReducerTest {

    private fun session(id: String, agent: String = "claude", cwd: String? = "/repo"): ProjectSession =
        ProjectSession(
            id = id,
            name = id,
            assistant = agent,
            branch = "main",
            preview = null,
            reasoningEffort = null,
            cwd = cwd,
            startedAt = "2026-05-20T10:00:00Z",
            lastActivityAt = "2026-05-20T10:05:00Z",
            displayName = null,
        )

    private fun upsert(
        current: List<SavedSession>,
        s: ProjectSession,
        isExited: Boolean = false,
        deleted: Set<String> = emptySet(),
        firstUserMessage: String? = "fix the build",
    ): List<SavedSession> =
        SavedSessionsReducer.upsert(
            current = current,
            session = s,
            serverId = "srv-1",
            status = null,
            firstUserMessage = firstUserMessage,
            messageCount = 3,
            isExited = isExited,
            deleted = deleted,
            nowIso = "2026-05-20T10:05:00Z",
        )

    @Test
    fun upsert_addsNewRowWithSummaryAndAgent() {
        val rows = upsert(emptyList(), session("s1"))
        assertEquals(1, rows.size)
        val row = rows.first()
        assertEquals("s1", row.id)
        assertEquals("srv-1", row.serverId)
        assertEquals("claude", row.agent)
        assertEquals("fix the build", row.summary)
        assertEquals(SavedSessionStatus.LIVE, row.status)
        assertEquals("srv-1::s1", row.compoundId)
    }

    @Test
    fun upsert_isIdempotent() {
        val once = upsert(emptyList(), session("s1"))
        val twice = upsert(once, session("s1"))
        assertEquals(1, twice.size)
        // Unchanged input returns the same instance (no spurious write).
        assertTrue(once === twice)
    }

    @Test
    fun upsert_exitedIsTerminal() {
        val live = upsert(emptyList(), session("s1"), isExited = false)
        assertEquals(SavedSessionStatus.LIVE, live.first().status)
        val exited = upsert(live, session("s1"), isExited = true)
        assertEquals(SavedSessionStatus.EXITED, exited.first().status)
        // A later live frame must NOT resurrect an exited row.
        val reLive = upsert(exited, session("s1"), isExited = false)
        assertEquals(SavedSessionStatus.EXITED, reLive.first().status)
    }

    @Test
    fun upsert_suppressesTombstonedId() {
        val rows = upsert(emptyList(), session("s1"), deleted = setOf("s1"))
        assertTrue("tombstoned id must never be (re-)added", rows.isEmpty())
    }

    @Test
    fun upsert_firstNonEmptySummaryWins() {
        val first = upsert(emptyList(), session("s1"), firstUserMessage = "original")
        val second = upsert(first, session("s1"), firstUserMessage = "different later")
        assertEquals("original", second.first().summary)
    }

    @Test
    fun remove_dropsAllRowsForId() {
        val rows = upsert(upsert(emptyList(), session("s1")), session("s2"))
        val after = SavedSessionsReducer.remove(rows, "s1")
        assertEquals(listOf("s2"), after.map { it.id })
    }

    @Test
    fun remove_isNoOpForUnknownId() {
        val rows = upsert(emptyList(), session("s1"))
        assertTrue(SavedSessionsReducer.remove(rows, "nope") === rows)
    }

    @Test
    fun recent_excludesTombstonedAndSortsLatestFirst() {
        var rows = SavedSessionsReducer.upsert(
            emptyList(), session("old"), "srv-1", null, "old", 1, false, emptySet(),
            nowIso = "2026-05-19T00:00:00Z",
        )
        rows = SavedSessionsReducer.upsert(
            rows, session("new"), "srv-1", null, "new", 1, false, emptySet(),
            nowIso = "2026-05-21T00:00:00Z",
        )
        val recent = SavedSessionsReducer.recent(rows, deleted = setOf("new"))
        assertEquals(listOf("old"), recent.map { it.id })
    }

    @Test
    fun encode_decode_roundTrips() {
        val rows = upsert(upsert(emptyList(), session("s1")), session("s2", agent = "codex"))
        val decoded = SavedSessionsReducer.decode(SavedSessionsReducer.encode(rows))
        assertEquals(rows.map { it.id }.toSet(), decoded.map { it.id }.toSet())
        val s2 = decoded.first { it.id == "s2" }
        assertEquals("codex", s2.agent)
        assertEquals("fix the build", s2.summary)
    }

    @Test
    fun decode_emptyOrGarbageIsEmpty() {
        assertTrue(SavedSessionsReducer.decode(null).isEmpty())
        assertTrue(SavedSessionsReducer.decode("").isEmpty())
        assertTrue(SavedSessionsReducer.decode("not json").isEmpty())
    }

    @Test
    fun truncateSummary_clampsToBudgetSingleLine() {
        val long = "a".repeat(200)
        val out = SavedSessionsReducer.truncateSummary("first\nsecond")
        assertEquals("first", out)
        assertEquals(SavedSessionsReducer.SUMMARY_MAX_CHARS, SavedSessionsReducer.truncateSummary(long).length)
    }

    @Test
    fun mergeStatus_lattice() {
        assertEquals(
            SavedSessionStatus.EXITED,
            SavedSessionsReducer.mergeStatus(SavedSessionStatus.LIVE, SavedSessionStatus.EXITED),
        )
        assertEquals(
            SavedSessionStatus.LIVE,
            SavedSessionsReducer.mergeStatus(SavedSessionStatus.UNKNOWN, SavedSessionStatus.LIVE),
        )
        assertEquals(
            SavedSessionStatus.UNKNOWN,
            SavedSessionsReducer.mergeStatus(SavedSessionStatus.UNKNOWN, SavedSessionStatus.UNKNOWN),
        )
    }

    @Test
    fun savedSessionStatus_fromRawDefaultsUnknown() {
        assertEquals(SavedSessionStatus.LIVE, SavedSessionStatus.fromRaw("live"))
        assertEquals(SavedSessionStatus.EXITED, SavedSessionStatus.fromRaw("EXITED"))
        assertEquals(SavedSessionStatus.UNKNOWN, SavedSessionStatus.fromRaw(null))
        assertEquals(SavedSessionStatus.UNKNOWN, SavedSessionStatus.fromRaw("bogus"))
    }

    @Test
    fun decode_missingCwdDecodesNull() {
        val s = session("s1", cwd = null)
        val rows = upsert(emptyList(), s)
        val decoded = SavedSessionsReducer.decode(SavedSessionsReducer.encode(rows))
        assertNull(decoded.first().cwd)
        assertFalse(decoded.first().agent.isEmpty())
    }
}
