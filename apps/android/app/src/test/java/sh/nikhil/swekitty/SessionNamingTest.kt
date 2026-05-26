package sh.nikhil.swekitty

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.time.ZoneId

/**
 * Pins the friendly-naming + recency-bucket rules (Android parity of the
 * iOS list/naming work). Pure JUnit — no Robolectric — because
 * [SessionNaming] / [SessionRecencyGrouping] have zero Android deps and
 * take an injectable clock + zone so the buckets are deterministic.
 */
class SessionNamingTest {

    private val utc = ZoneId.of("UTC")
    // Fixed "now": 2026-05-25T18:00:00Z (a Monday).
    private val nowMs = java.time.Instant.parse("2026-05-25T18:00:00Z").toEpochMilli()

    private val rawUuid = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    // ---------- friendly name priority order ----------

    @Test
    fun customNameWinsOverEverything() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = "  My renamed thread ",
            firstUserMessage = "fix the login bug",
            serverLabel = "server label",
            startedAt = "2026-05-25T17:58:00Z",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("My renamed thread", name)
    }

    @Test
    fun firstUserMessageUsedWhenNoCustomName() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = "Fix the login redirect loop please",
            serverLabel = null,
            startedAt = "2026-05-25T17:58:00Z",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("Fix the login redirect loop please", name)
    }

    @Test
    fun firstUserMessageIsCondensedToSingleEllipsizedLine() {
        val long = "Refactor the\nentire authentication module to use the new token exchange flow"
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = long,
            serverLabel = null,
            startedAt = null,
            nowMs = nowMs,
            zone = utc,
        )
        assertTrue("no newlines: $name", !name.contains("\n"))
        assertTrue("ellipsized: $name", name.endsWith("…"))
        // Body (minus the ellipsis) stays within the char limit.
        assertTrue(name.dropLast(1).length <= SessionNaming.NAME_CHAR_LIMIT)
        assertTrue(name.startsWith("Refactor the entire"))
    }

    @Test
    fun serverLabelUsedWhenNoCustomOrChat_butNeverWhenItIsTheRawId() {
        val realLabel = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "codex",
            custom = null,
            firstUserMessage = null,
            serverLabel = "deploy pipeline",
            startedAt = null,
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("deploy pipeline", realLabel)

        // A UUID-shaped server label is rejected → falls through to fallback.
        val uuidLabel = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "codex",
            custom = null,
            firstUserMessage = null,
            serverLabel = rawUuid,
            startedAt = "2026-05-25T17:58:00Z",
            nowMs = nowMs,
            zone = utc,
        )
        assertTrue("must not be the uuid: $uuidLabel", !uuidLabel.contains(rawUuid))
        assertTrue(uuidLabel.startsWith("codex · "))
    }

    @Test
    fun fallbackNeverRendersRawUuid() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = null,
            serverLabel = null,
            startedAt = "2026-05-25T16:02:00Z",
            nowMs = nowMs,
            zone = utc,
        )
        // "claude · 4:02 PM" (started today).
        assertEquals("claude · 4:02 PM", name)
    }

    @Test
    fun fallbackUsesWeekdayForOlderSessions() {
        // Started Thursday 2026-05-21, now Monday → within a week → weekday.
        val name = SessionNaming.fallbackName(
            agent = "claude",
            startedAt = "2026-05-21T09:00:00Z",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("claude · Thu", name)
    }

    @Test
    fun fallbackWithNoTimestampIsJustAgent() {
        assertEquals(
            "claude",
            SessionNaming.fallbackName(agent = "claude", startedAt = null, nowMs = nowMs, zone = utc),
        )
    }

    @Test
    fun condenseReturnsNullForBlank() {
        assertNull(SessionNaming.condense("   \n  "))
    }

    // ---------- relative "ago" ----------

    @Test
    fun relativeAgoBuckets() {
        assertEquals("now", SessionNaming.relativeAgo("2026-05-25T17:59:30Z", nowMs, utc))
        assertEquals("2m ago", SessionNaming.relativeAgo("2026-05-25T17:58:00Z", nowMs, utc))
        assertEquals("3h ago", SessionNaming.relativeAgo("2026-05-25T15:00:00Z", nowMs, utc))
        assertEquals("5d ago", SessionNaming.relativeAgo("2026-05-20T18:00:00Z", nowMs, utc))
        assertEquals("", SessionNaming.relativeAgo(null, nowMs, utc))
    }

    // ---------- recency buckets ----------

    private data class Row(val id: String, val lastSeen: String?)

    @Test
    fun groupsByRecencyBucketLatestFirstNonEmptyOnly() {
        val rows = listOf(
            Row("today-old", "2026-05-25T08:00:00Z"),
            Row("today-new", "2026-05-25T17:30:00Z"),
            Row("yesterday", "2026-05-24T12:00:00Z"),
            Row("week", "2026-05-20T12:00:00Z"),
            Row("earlier", "2026-04-01T12:00:00Z"),
            Row("no-ts", null),
        )
        val groups = SessionRecencyGrouping.group(rows, nowMs, utc) { it.lastSeen }

        // Buckets present, in fixed order.
        assertEquals(
            listOf(
                RecencyBucket.TODAY,
                RecencyBucket.YESTERDAY,
                RecencyBucket.PREVIOUS_7_DAYS,
                RecencyBucket.EARLIER,
            ),
            groups.map { it.bucket },
        )
        // Today latest-first.
        assertEquals(listOf("today-new", "today-old"), groups[0].rows.map { it.id })
        assertEquals(listOf("yesterday"), groups[1].rows.map { it.id })
        assertEquals(listOf("week"), groups[2].rows.map { it.id })
        // Earlier holds the old row + the timestamp-less row (sorted last).
        assertEquals(listOf("earlier", "no-ts"), groups[3].rows.map { it.id })
    }

    @Test
    fun emptyBucketsAreDropped() {
        val rows = listOf(Row("a", "2026-05-25T10:00:00Z"))
        val groups = SessionRecencyGrouping.group(rows, nowMs, utc) { it.lastSeen }
        assertEquals(1, groups.size)
        assertEquals(RecencyBucket.TODAY, groups[0].bucket)
    }

    @Test
    fun previous7DaysExcludesYesterdayAndToday() {
        // Day boundaries: today=day0, yesterday=day1, days 2..7 → Previous 7,
        // day 8+ → Earlier.
        val sevenDaysAgo = "2026-05-18T12:00:00Z" // 7 days before the 25th
        val eightDaysAgo = "2026-05-17T12:00:00Z"
        val groups = SessionRecencyGrouping.group(
            listOf(Row("seven", sevenDaysAgo), Row("eight", eightDaysAgo)),
            nowMs, utc,
        ) { it.lastSeen }
        assertEquals(RecencyBucket.PREVIOUS_7_DAYS, groups[0].bucket)
        assertEquals(listOf("seven"), groups[0].rows.map { it.id })
        assertEquals(RecencyBucket.EARLIER, groups[1].bucket)
        assertEquals(listOf("eight"), groups[1].rows.map { it.id })
    }

    @Test
    fun emptyInputProducesNoGroups() {
        assertTrue(SessionRecencyGrouping.group(emptyList<Row>(), nowMs, utc) { null }.isEmpty())
    }

    // ---------- AI session titles (task: ai-session-titles) ----------

    @Test
    fun aiTitleBeatsFirstMessageAndServerLabel() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = "fix the login bug",
            serverLabel = "server label",
            startedAt = "2026-05-25T17:58:00Z",
            aiTitle = "Debug Broker Session Limit",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("Debug Broker Session Limit", name)
    }

    @Test
    fun manualRenameBeatsAiTitle() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = "My Session",
            firstUserMessage = "fix the login bug",
            serverLabel = null,
            startedAt = null,
            aiTitle = "Debug Broker Session Limit",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("My Session", name)
    }

    @Test
    fun blankAiTitleFallsThroughToFirstMessage() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = "fix the login bug",
            serverLabel = null,
            startedAt = null,
            aiTitle = "   ",
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("fix the login bug", name)
    }

    @Test
    fun uuidShapedAiTitleIsRejected() {
        val name = SessionNaming.friendly(
            sessionId = rawUuid,
            rawName = rawUuid,
            agent = "claude",
            custom = null,
            firstUserMessage = "fix the login bug",
            serverLabel = null,
            startedAt = null,
            aiTitle = rawUuid,
            nowMs = nowMs,
            zone = utc,
        )
        assertEquals("fix the login bug", name)
    }
}
