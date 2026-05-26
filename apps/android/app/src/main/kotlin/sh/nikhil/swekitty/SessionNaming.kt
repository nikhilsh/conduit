package sh.nikhil.swekitty

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import uniffi.swe_kitty_core.ConversationItem
import uniffi.swe_kitty_core.ProjectSession

/**
 * Pure, Compose-free helpers for turning a raw session into a friendly,
 * scannable label — and for bucketing a history list by recency. Lifted
 * out of [SessionStore] / the screens so JUnit can pin the rules with
 * fixed clocks (no Robolectric, no live ViewModel). Android parity of the
 * iOS list/naming work; mirrors the priority order documented on
 * `SessionStore.displayName`.
 */
internal object SessionNaming {

    /** Max characters for a chat-derived name before ellipsizing. */
    const val NAME_CHAR_LIMIT = 40

    /**
     * Friendly default name for a session, in priority order:
     *  1. `custom` (a user-set rename) — wins, returned verbatim.
     *  2. First user chat message — trimmed, single-lined, ellipsized.
     *  3. `serverLabel` (a broker-supplied `displayName`/`sessionName`),
     *     when it isn't itself the raw UUID.
     *  4. Fallback: "<agent> · <relative start time>" from `startedAt`.
     *
     * NEVER returns the raw session id / UUID `name`. The UUID is only for
     * Session Info, never a user-facing label.
     */
    fun friendly(
        sessionId: String,
        rawName: String,
        agent: String,
        custom: String?,
        firstUserMessage: String?,
        serverLabel: String?,
        startedAt: String?,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        custom?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }

        firstUserMessage?.let { msg ->
            condense(msg)?.let { return it }
        }

        // A broker-supplied label is only useful when it isn't the UUID we
        // were trying to avoid (the broker echoes the id as `name` for
        // unnamed sessions).
        serverLabel?.trim()
            ?.takeIf { it.isNotEmpty() && !looksLikeRawId(it, sessionId, rawName) }
            ?.let { return it }

        return fallbackName(agent, startedAt, nowMs, zone)
    }

    /**
     * Trim a chat message down to a single ellipsized line. Collapses
     * internal whitespace/newlines to single spaces (a multi-line prompt
     * should read as one tidy line), returns null when the message is
     * effectively empty so the caller can fall through.
     */
    fun condense(raw: String): String? {
        val oneLine = raw.replace(Regex("\\s+"), " ").trim()
        if (oneLine.isEmpty()) return null
        if (oneLine.length <= NAME_CHAR_LIMIT) return oneLine
        // Trim to the limit, then drop a dangling partial word for cleaner
        // truncation before appending the ellipsis.
        val clipped = oneLine.take(NAME_CHAR_LIMIT).trimEnd()
        val lastSpace = clipped.lastIndexOf(' ')
        val base = if (lastSpace >= NAME_CHAR_LIMIT / 2) clipped.substring(0, lastSpace) else clipped
        return base.trimEnd() + "…"
    }

    /** "<agent> · <relative start time>", e.g. "claude · 4:02 PM" / "claude · Mon". */
    fun fallbackName(
        agent: String,
        startedAt: String?,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val agentLabel = agent.trim().ifEmpty { "session" }
        val when_ = relativeStart(startedAt, nowMs, zone)
        return if (when_ != null) "$agentLabel · $when_" else agentLabel
    }

    /**
     * Clock-style relative start: time of day when the session started
     * today ("4:02 PM"), the weekday for anything older ("Mon"), or a
     * short date when older than a week ("May 12"). Null when unparseable.
     */
    fun relativeStart(
        raw: String?,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String? {
        val instant = parseInstant(raw) ?: return null
        val started = instant.atZone(zone).toLocalDate()
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        val days = today.toEpochDay() - started.toEpochDay()
        val dt = instant.atZone(zone)
        return when {
            days <= 0L -> dt.format(TIME_FMT)
            days < 7L -> dt.format(WEEKDAY_FMT)
            else -> dt.format(SHORT_DATE_FMT)
        }
    }

    /**
     * Short "time ago" string for a row's trailing slot ("now", "2m",
     * "3h", "5d", or a short date). Empty when unparseable/blank.
     */
    fun relativeAgo(
        raw: String?,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        val instant = parseInstant(raw) ?: return ""
        val deltaMs = (nowMs - instant.toEpochMilli()).coerceAtLeast(0)
        val minutes = deltaMs / 60_000
        val hours = deltaMs / 3_600_000
        val days = deltaMs / 86_400_000
        return when {
            minutes < 1 -> "now"
            minutes < 60 -> "${minutes}m ago"
            hours < 24 -> "${hours}h ago"
            days < 7 -> "${days}d ago"
            else -> instant.atZone(zone).format(SHORT_DATE_FMT)
        }
    }

    private fun looksLikeRawId(label: String, sessionId: String, rawName: String): Boolean {
        if (label == sessionId || label == rawName) return true
        // A bare UUID: 8-4-4-4-12 hex. Such a label is never something a
        // human typed, so treat it as "raw" and fall through.
        return UUID_REGEX.matches(label)
    }

    private fun parseInstant(raw: String?): Instant? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        return runCatching { Instant.parse(trimmed) }.getOrNull()
            ?: runCatching {
                java.time.OffsetDateTime.parse(trimmed).toInstant()
            }.getOrNull()
    }

    /** Convenience: the friendly name for a live [ProjectSession]. */
    fun friendlyFor(
        session: ProjectSession,
        custom: String?,
        firstUserMessage: String?,
        nowMs: Long = System.currentTimeMillis(),
    ): String = friendly(
        sessionId = session.id,
        rawName = session.name,
        agent = session.assistant,
        custom = custom,
        firstUserMessage = firstUserMessage,
        serverLabel = session.displayName,
        startedAt = session.startedAt,
        nowMs = nowMs,
    )

    val UUID_REGEX = Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    )
    private val TIME_FMT = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    private val WEEKDAY_FMT = DateTimeFormatter.ofPattern("EEE", Locale.US)
    private val SHORT_DATE_FMT = DateTimeFormatter.ofPattern("MMM d", Locale.US)
}

/**
 * Recency buckets for the history list. Order is fixed: only non-empty
 * buckets are emitted, in this sequence. Android parity of the iOS
 * list/naming PR's time grouping (which replaced server-grouping).
 */
enum class RecencyBucket(val label: String) {
    TODAY("Today"),
    YESTERDAY("Yesterday"),
    PREVIOUS_7_DAYS("Previous 7 Days"),
    EARLIER("Earlier"),
}

/**
 * Pure grouping of arbitrary rows by a `lastSeen` timestamp into
 * [RecencyBucket]s, latest-first within each bucket. Generic over the row
 * type so both the search screen and tests can drive it; callers supply a
 * `lastSeen` extractor (RFC3339 string) and the bucketing key. Empty
 * buckets are dropped; bucket order follows [RecencyBucket.values].
 */
object SessionRecencyGrouping {

    data class Group<T>(val bucket: RecencyBucket, val rows: List<T>)

    fun <T> group(
        rows: List<T>,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
        lastSeen: (T) -> String?,
    ): List<Group<T>> {
        val today = Instant.ofEpochMilli(nowMs).atZone(zone).toLocalDate()
        // Decorate each row with (bucket, epochMilli) so we can sort
        // latest-first deterministically. Rows with no parseable timestamp
        // sort to the bottom of EARLIER.
        val decorated = rows.map { row ->
            val instant = parseInstant(lastSeen(row))
            val bucket = bucketFor(instant, today, zone)
            Triple(row, bucket, instant?.toEpochMilli() ?: Long.MIN_VALUE)
        }
        return RecencyBucket.entries.mapNotNull { bucket ->
            val inBucket = decorated
                .filter { it.second == bucket }
                .sortedByDescending { it.third }
                .map { it.first }
            if (inBucket.isEmpty()) null else Group(bucket, inBucket)
        }
    }

    private fun bucketFor(instant: Instant?, today: LocalDate, zone: ZoneId): RecencyBucket {
        if (instant == null) return RecencyBucket.EARLIER
        val date = instant.atZone(zone).toLocalDate()
        val days = today.toEpochDay() - date.toEpochDay()
        return when {
            days <= 0L -> RecencyBucket.TODAY
            days == 1L -> RecencyBucket.YESTERDAY
            days < 8L -> RecencyBucket.PREVIOUS_7_DAYS
            else -> RecencyBucket.EARLIER
        }
    }

    private fun parseInstant(raw: String?): Instant? {
        val trimmed = raw?.trim().orEmpty()
        if (trimmed.isEmpty()) return null
        return runCatching { Instant.parse(trimmed) }.getOrNull()
            ?: runCatching { java.time.OffsetDateTime.parse(trimmed).toInstant() }.getOrNull()
    }
}

/**
 * Best-effort first user message for a session, scanning the typed
 * conversation log then the raw chat log — mirror of iOS
 * `SessionStore.firstUserMessage(in:)`. Returns null when neither carries
 * a user turn yet (terminal-only sessions, or a transcript not loaded).
 */
internal fun firstUserMessageOf(
    conversation: List<ConversationItem>?,
): String? {
    conversation?.firstOrNull { it.role.lowercase() == "user" }?.content
        ?.takeIf { it.isNotBlank() }
        ?.let { return it }
    return null
}
