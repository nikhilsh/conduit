package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pins the Session Info "Details" rows (iOS #239 parity): model (+effort)
 * always present, timestamp rows omitted when absent, uptime math, and
 * relative-time bucket formatting. Pure JUnit — [SessionDetails] takes an
 * injectable `nowMs` so the relative buckets are deterministic. Mirror of
 * iOS `LitterSessionInfoViewModelTests` details/relative coverage.
 */
class SessionDetailsTest {

    // Fixed "now": 2026-05-25T18:00:00Z.
    private val nowMs = java.time.Instant.parse("2026-05-25T18:00:00Z").toEpochMilli()

    @Test
    fun modelAlwaysPresentWithEffort() {
        val rows = SessionDetails.rows(
            assistant = "claude",
            reasoningEffort = "high",
            startedAt = null,
            lastActivityAt = null,
            nowMs = nowMs,
        )
        val model = rows.first { it.label == "Model" }
        assertEquals("claude · high", model.value)
    }

    @Test
    fun modelWithoutEffortIsBareAssistant() {
        val rows = SessionDetails.rows(
            assistant = "codex",
            reasoningEffort = null,
            startedAt = null,
            lastActivityAt = null,
            nowMs = nowMs,
        )
        assertEquals("codex", rows.first { it.label == "Model" }.value)
    }

    @Test
    fun timestampRowsOmittedWhenAbsent() {
        val rows = SessionDetails.rows(
            assistant = "claude",
            reasoningEffort = null,
            startedAt = null,
            lastActivityAt = null,
            nowMs = nowMs,
        )
        // Only the Model row survives with no timestamps.
        assertEquals(1, rows.size)
        assertNull(rows.firstOrNull { it.label == "Started" })
        assertNull(rows.firstOrNull { it.label == "Uptime" })
    }

    @Test
    fun startedCarriesAbsoluteValueAndRelativeCaption() {
        val started = "2026-05-25T15:00:00Z" // 3h before now
        val rows = SessionDetails.rows(
            assistant = "claude",
            reasoningEffort = null,
            startedAt = started,
            lastActivityAt = started,
            nowMs = nowMs,
        )
        val startedRow = rows.first { it.label == "Started" }
        assertTrue(startedRow.value.isNotBlank())
        assertEquals("3h ago", startedRow.caption)
    }

    @Test
    fun uptimeIsStartedToLastActivity() {
        val rows = SessionDetails.rows(
            assistant = "claude",
            reasoningEffort = null,
            startedAt = "2026-05-25T15:00:00Z",
            lastActivityAt = "2026-05-25T16:30:00Z", // 1h30m later
            nowMs = nowMs,
        )
        assertEquals("1h 30m", rows.first { it.label == "Uptime" }.value)
    }

    @Test
    fun uptimeRunsToNowWhenNoLastActivity() {
        // lastActivityAt absent → uptime runs started → now (3h).
        val rows = SessionDetails.rows(
            assistant = "claude",
            reasoningEffort = null,
            startedAt = "2026-05-25T15:00:00Z",
            lastActivityAt = null,
            nowMs = nowMs,
        )
        assertEquals("3h 0m", rows.first { it.label == "Uptime" }.value)
    }

    // ---------- relative() buckets ----------

    @Test
    fun relativeBuckets() {
        val t = { offsetSec: Long -> nowMs - offsetSec * 1000L }
        assertEquals("just now", SessionDetails.relative(t(10), nowMs))
        assertEquals("5m ago", SessionDetails.relative(t(5 * 60), nowMs))
        assertEquals("3h ago", SessionDetails.relative(t(3 * 3600), nowMs))
        assertEquals("2d ago", SessionDetails.relative(t(2 * 86_400), nowMs))
        // Older than two weeks falls back to a short date.
        val old = SessionDetails.relative(t(30L * 86_400), nowMs)
        assertNotNull(old)
        assertTrue(old.contains("/"))
    }

    @Test
    fun durationFormatting() {
        assertEquals("—", SessionDetails.formatDuration(0))
        assertEquals("5s", SessionDetails.formatDuration(5_000))
        assertEquals("2m 3s", SessionDetails.formatDuration((2 * 60 + 3) * 1000L))
        assertEquals("1h 5m", SessionDetails.formatDuration((65 * 60) * 1000L))
    }
}
