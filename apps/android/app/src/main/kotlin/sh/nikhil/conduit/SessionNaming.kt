package sh.nikhil.conduit

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.util.Locale
import uniffi.conduit_core.ConversationItem
import uniffi.conduit_core.ProjectSession

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
     *  2. `aiTitle` (the broker AI-generated title, task: ai-session-titles)
     *     when it isn't itself the raw UUID.
     *  3. First user chat message — trimmed, single-lined, ellipsized.
     *  4. `serverLabel` (a broker-supplied `displayName`/`sessionName`),
     *     when it isn't itself the raw UUID.
     *  5. Fallback: "<agent> · <relative start time>" from `startedAt`.
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
        aiTitle: String? = null,
        nowMs: Long = System.currentTimeMillis(),
        zone: ZoneId = ZoneId.systemDefault(),
    ): String {
        custom?.trim()?.takeIf { it.isNotEmpty() }?.let { return it }

        // Broker AI title sits just below a manual rename and above the
        // first message. Reject a UUID-shaped echo so we never re-spill the
        // id as a label.
        aiTitle?.trim()
            ?.takeIf { it.isNotEmpty() && !looksLikeRawId(it, sessionId, rawName) }
            ?.let { return it }

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

    /**
     * Epoch millis for an RFC3339 timestamp, or null when blank /
     * unparseable. Used as the Home-row sort key (newest-first) — see
     * [sortSessionsByActivity].
     */
    fun epochMillisOrNull(raw: String?): Long? = parseInstant(raw)?.toEpochMilli()

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
        aiTitle: String? = null,
        nowMs: Long = System.currentTimeMillis(),
    ): String = friendly(
        sessionId = session.id,
        rawName = session.name,
        agent = session.assistant,
        custom = custom,
        firstUserMessage = firstUserMessage,
        serverLabel = session.displayName,
        startedAt = session.startedAt,
        aiTitle = aiTitle,
        nowMs = nowMs,
    )

    val UUID_REGEX = Regex(
        "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
    )
    private val TIME_FMT = DateTimeFormatter.ofPattern("h:mm a", Locale.US)
    private val WEEKDAY_FMT = DateTimeFormatter.ofPattern("EEE", Locale.US)
    private val SHORT_DATE_FMT = DateTimeFormatter.ofPattern("MMM d", Locale.US)

    /**
     * Condense a single transcript item into a one-line activity preview
     * for the home card. Pure string inputs (role / kind / toolName /
     * command / content) keep this Compose- and core-type-free so JUnit
     * can pin it. Mirror of iOS `HomeViewModel.activityPreview`:
     *  - a tool action surfaces its command ("Bash: cargo test") or, with
     *    no command, "<tool>: <first line>";
     *  - assistant / other text uses the first non-empty body line.
     * Returns null when there's nothing worth showing.
     */
    fun activityPreview(
        role: String,
        kind: String,
        toolName: String?,
        command: String?,
        content: String,
        budget: Int = 72,
    ): String? {
        if (role.lowercase() == "tool" || kind.lowercase() == "tool") {
            val cmd = command?.takeIf { it.isNotBlank() }
            if (cmd != null) {
                val label = toolName?.takeIf { it.isNotEmpty() } ?: "Run"
                return clip("$label: ${firstLine(cmd)}", budget)
            }
            val body = firstLine(content)
            if (body.isNotEmpty()) {
                val prefix = toolName?.takeIf { it.isNotEmpty() }?.let { "$it: " } ?: ""
                return clip(prefix + body, budget)
            }
            return toolName?.takeIf { it.isNotEmpty() }?.let { clip(it, budget) }
        }
        val body = firstLine(content)
        return if (body.isEmpty()) null else clip(body, budget)
    }

    /**
     * First non-empty line of a (possibly multi-line) string with
     * internal whitespace runs collapsed to single spaces.
     */
    private fun firstLine(raw: String): String {
        raw.lineSequence().forEach { line ->
            val collapsed = line.split(Regex("\\s+")).filter { it.isNotEmpty() }.joinToString(" ")
            if (collapsed.isNotEmpty()) return collapsed
        }
        return ""
    }

    /** Trim to [budget] chars with an ellipsis when over. */
    private fun clip(s: String, budget: Int): String =
        if (s.length <= budget) s else s.take(budget - 1) + "…"
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

/**
 * One-line "what's happening" preview for a session card — the most
 * recent NON-user transcript item (assistant reply or tool action),
 * condensed. The card title is already the first user message, so this
 * complements it and lets the user tell active sessions apart at a
 * glance. Mirror of iOS `ConduitHomeView.latestActivityPreview` +
 * `HomeViewModel.activityPreview`. Returns null when there's no non-user
 * activity yet (placeholder / user-only transcripts).
 */
internal fun latestActivityPreviewOf(
    conversation: List<ConversationItem>?,
): String? {
    val latest = conversation?.lastOrNull { it.role.lowercase() != "user" } ?: return null
    return SessionNaming.activityPreview(
        role = latest.role,
        kind = latest.kind,
        toolName = latest.toolName,
        command = latest.command,
        content = latest.content,
    )
}

/**
 * Broker-stamped `ts` of the most recent item in a session's live
 * conversation log — the real "last message" time, used for the Home row's
 * relative stamp and sort. Null when the log is empty / not yet replayed
 * (e.g. a freshly-reattached session), so the caller falls back to the
 * session's own metadata rather than the reconnect-set status timestamp
 * (which on a cold-boot reconnect is the CONNECTION time, not a message).
 * Items are appended in broker-clock order, so `last` is the freshest.
 * Mirror of iOS `ConduitHomeView.lastMessageTimestamp`.
 */
internal fun lastMessageTimestampOf(
    conversation: List<ConversationItem>?,
): String? = conversation?.lastOrNull()?.ts?.takeIf { it.isNotBlank() }

/**
 * Order active session rows most-recent-activity first for the Home list,
 * STABLY: rows whose timestamp is missing or equal keep their original
 * input order (the broker's list order). A dated row always sorts before an
 * undated one; among dated rows the newer wins; ties (equal or both-null)
 * fall back to the original index. Mirror of iOS
 * `HomeViewModel.sortedSessions`. Generic over the row type so the Composable
 * and tests can both drive it; [lastActivityAt] extracts the chosen
 * timestamp (RFC3339) per row.
 */
internal fun <T> sortSessionsByActivity(
    rows: List<T>,
    lastActivityAt: (T) -> String?,
): List<T> =
    rows.withIndex()
        .sortedWith(
            compareByDescending<IndexedValue<T>> { iv ->
                // Epoch millis; null (missing/unparseable) sorts last via the
                // dated-before-undated split below.
                SessionNaming.epochMillisOrNull(lastActivityAt(iv.value))
            }.thenBy { it.index },
        )
        .map { it.value }

/** One session blocked on the user, for the Home "needs you" banner. */
internal data class NeedsYouItem(val id: String, val title: String, val agent: String)

/**
 * The Home "needs you" banner state (design handoff §B.10): the sessions
 * whose agent is currently blocked on the user. A session is awaiting input
 * when the LAST item in its transcript is a non-user `pending_input` (an
 * approval prompt / options menu) with nothing from the user after it —
 * the same signal the chat view uses for its pending-input card. The banner
 * is hidden (`isEmpty`) when none are waiting, so it never shows a
 * fabricated count. Mirror of iOS `HomeViewModel.needsYouBanner`.
 */
internal data class NeedsYouBanner(val sessions: List<NeedsYouItem>) {
    val count: Int get() = sessions.size
    val isEmpty: Boolean get() = sessions.isEmpty()
    /** The session a tap should open (the first one awaiting input). */
    val primaryId: String? get() = sessions.firstOrNull()?.id
}

/** True when [conversation]'s last item is an unanswered non-user `pending_input`. */
internal fun isAwaitingInput(conversation: List<ConversationItem>?): Boolean {
    val last = conversation?.lastOrNull() ?: return false
    return last.role.lowercase() != "user" && last.kind.lowercase() == "pending_input"
}

/**
 * Build the needs-you banner from a list of candidate sessions, each paired
 * with its conversation log. Only sessions actually [isAwaitingInput] are
 * included, in input order.
 */
internal fun needsYouBanner(
    candidates: List<Pair<NeedsYouItem, List<ConversationItem>?>>,
): NeedsYouBanner =
    NeedsYouBanner(candidates.filter { isAwaitingInput(it.second) }.map { it.first })
