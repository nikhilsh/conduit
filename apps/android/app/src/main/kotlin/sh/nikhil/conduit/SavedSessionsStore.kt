package sh.nikhil.conduit

import org.json.JSONObject
import uniffi.conduit_core.ProjectSession
import uniffi.conduit_core.SessionStatus

/**
 * Lifecycle bucket for a persisted (archived) session row. Mirror of iOS
 * `SavedSessionStatus` / Rust `core/src/saved/mod.rs::SavedSessionStatus`.
 * `exited` is terminal — once recorded, never resurrected (see
 * [SavedSessionsReducer.mergeStatus]).
 */
enum class SavedSessionStatus(val raw: String) {
    LIVE("live"),
    EXITED("exited"),
    UNKNOWN("unknown");

    companion object {
        fun fromRaw(raw: String?): SavedSessionStatus = when (raw?.trim()?.lowercase()) {
            "live" -> LIVE
            "exited" -> EXITED
            else -> UNKNOWN
        }
    }
}

/**
 * Android mirror of the iOS `SavedSession` (`apps/ios/Sources/Models/SavedSessionsStore.swift`).
 *
 * One row in the persisted archived-session index. Keeps just enough to
 * render a History row read-only after the live session has ended and
 * dropped out of the broker's active list: a friendly summary (the first
 * user message), the agent, the originating server, and the last time we
 * saw it. The transcript itself is NOT stored here — it stays fetchable
 * from the broker's `archived-sessions/<id>/conversation.jsonl` via
 * [SessionStore.fetchConversation].
 */
data class SavedSession(
    val id: String,
    val serverId: String,
    val agent: String,
    val cwd: String?,
    val firstSeen: String,
    val lastSeen: String,
    val messageCount: Int,
    val summary: String,
    val status: SavedSessionStatus,
) {
    /** Compound identity matching the iOS/Rust `compound_key`. */
    val compoundId: String get() = "$serverId::$id"
}

/**
 * Pure reducers for the archived-session index — pulled out so JUnit can
 * exercise the archive-vs-permanent-delete contract without a live
 * ViewModel or EncryptedSharedPreferences (which need the AndroidKeyStore
 * at runtime). Mirror of the iOS `SavedSessionsStore.upsert` / `remove`
 * algorithms and the Rust `core/src/saved/mod.rs` rules.
 */
internal object SavedSessionsReducer {

    /** UTF-8 budget for the summary line — matches the iOS/Rust 100-char cap. */
    const val SUMMARY_MAX_CHARS = 100

    /** Upper bound on retained rows so the index can't grow unbounded. */
    const val INDEX_CAP = 500

    /**
     * Fold a live [ProjectSession] + [SessionStatus] snapshot into the
     * archived index. Idempotent — the same input twice returns an equal
     * list. `firstSeen` is sticky, `lastSeen` advances, the first non-empty
     * summary wins, and once a row is `EXITED` it stays that way. A
     * tombstoned id ([deleted]) is never (re-)added: a permanently-deleted
     * session must stay gone even though the broker can keep reporting it
     * (#199). Mirror of iOS `SavedSessionsStore.upsert`.
     */
    fun upsert(
        current: List<SavedSession>,
        session: ProjectSession,
        serverId: String,
        status: SessionStatus?,
        firstUserMessage: String?,
        messageCount: Int,
        isExited: Boolean,
        deleted: Set<String>,
        nowIso: String,
    ): List<SavedSession> {
        if (session.id in deleted) return current
        val now = status?.lastActivityAt
            ?: status?.startedAt
            ?: session.lastActivityAt
            ?: session.startedAt
            ?: nowIso
        val summary = truncateSummary(firstUserMessage ?: "")
        val nextStatus = if (isExited) SavedSessionStatus.EXITED else SavedSessionStatus.LIVE
        val agent = session.assistant
        val cwd = status?.cwd ?: session.cwd

        val idx = current.indexOfFirst { it.id == session.id && it.serverId == serverId }
        if (idx >= 0) {
            val row = current[idx]
            val merged = row.copy(
                lastSeen = maxOf(row.lastSeen, now),
                messageCount = maxOf(row.messageCount, messageCount.coerceAtLeast(0)),
                agent = agent,
                cwd = cwd ?: row.cwd,
                summary = if (row.summary.isEmpty() && summary.isNotEmpty()) summary else row.summary,
                status = mergeStatus(row.status, nextStatus),
            )
            if (merged == row) return current
            return current.toMutableList().also { it[idx] = merged }
        }
        val row = SavedSession(
            id = session.id,
            serverId = serverId,
            agent = agent,
            cwd = cwd,
            firstSeen = now,
            lastSeen = now,
            messageCount = messageCount.coerceAtLeast(0),
            summary = summary,
            status = nextStatus,
        )
        return capNewestFirst(current + row)
    }

    /**
     * Remove every row whose session id equals [id] from the index. Used
     * by permanent delete; archiving does NOT call this (the row stays).
     * Returns the input unchanged when nothing matched. Mirror of iOS
     * `SavedSessionsStore.remove(id:)`'s row-removal half (the tombstone
     * half lives in [SessionStore.tombstone]).
     */
    fun remove(current: List<SavedSession>, id: String): List<SavedSession> {
        val next = current.filterNot { it.id == id }
        return if (next.size == current.size) current else next
    }

    /**
     * Latest-first slice clamped to [limit], excluding tombstoned ids
     * (belt-and-braces — a permanently-deleted row is already removed, but
     * filter here too so a race can never leak one into History). Ties
     * broken by id for deterministic snapshot tests. Mirror of iOS
     * `SavedSessionsStore.recent`.
     */
    fun recent(
        current: List<SavedSession>,
        deleted: Set<String>,
        limit: Int = 200,
    ): List<SavedSession> {
        val sorted = current
            .filterNot { it.id in deleted }
            .sortedWith(compareByDescending<SavedSession> { it.lastSeen }.thenBy { it.id })
        return if (sorted.size <= limit) sorted else sorted.take(limit)
    }

    /** Exited is terminal (Unknown ⊏ Live ⊏ Exited). Mirror of iOS `mergeStatus`. */
    fun mergeStatus(existing: SavedSessionStatus, next: SavedSessionStatus): SavedSessionStatus {
        if (existing == SavedSessionStatus.EXITED || next == SavedSessionStatus.EXITED) {
            return SavedSessionStatus.EXITED
        }
        if (existing == SavedSessionStatus.LIVE || next == SavedSessionStatus.LIVE) {
            return SavedSessionStatus.LIVE
        }
        return SavedSessionStatus.UNKNOWN
    }

    /**
     * First-line, trimmed, ellipsized to [SUMMARY_MAX_CHARS]. Mirror of
     * iOS `truncateSummary` / Rust `truncate_summary`.
     */
    fun truncateSummary(text: String): String {
        val firstLine = text.lineSequence().firstOrNull().orEmpty().trim()
        if (firstLine.length <= SUMMARY_MAX_CHARS) return firstLine
        return firstLine.take(SUMMARY_MAX_CHARS - 1) + "…"
    }

    /** Keep the newest [INDEX_CAP] rows by `lastSeen` so the index can't grow forever. */
    private fun capNewestFirst(rows: List<SavedSession>): List<SavedSession> {
        if (rows.size <= INDEX_CAP) return rows
        return rows.sortedByDescending { it.lastSeen }.take(INDEX_CAP)
    }

    // MARK: - JSON persistence

    /**
     * Encode to the same envelope shape iOS/Rust use:
     * `{"sessions": {"<server>::<id>": {...}, ...}}` so the file stays
     * cross-platform round-trippable.
     */
    fun encode(rows: List<SavedSession>): String {
        val sessions = JSONObject()
        rows.forEach { r ->
            sessions.put(
                r.compoundId,
                JSONObject().apply {
                    put("id", r.id)
                    put("server_id", r.serverId)
                    put("agent", r.agent)
                    r.cwd?.let { put("cwd", it) }
                    put("first_seen", r.firstSeen)
                    put("last_seen", r.lastSeen)
                    put("message_count", r.messageCount)
                    put("summary", r.summary)
                    put("status", r.status.raw)
                },
            )
        }
        return JSONObject().apply { put("sessions", sessions) }.toString()
    }

    fun decode(raw: String?): List<SavedSession> {
        if (raw.isNullOrBlank()) return emptyList()
        return runCatching {
            val obj = JSONObject(raw)
            val sessions = obj.optJSONObject("sessions") ?: return@runCatching emptyList<SavedSession>()
            buildList {
                sessions.keys().forEach { key ->
                    val o = sessions.optJSONObject(key) ?: return@forEach
                    add(
                        SavedSession(
                            id = o.optString("id", ""),
                            serverId = o.optString("server_id", ""),
                            agent = o.optString("agent", ""),
                            cwd = o.optString("cwd", "").takeIf { it.isNotEmpty() },
                            firstSeen = o.optString("first_seen", ""),
                            lastSeen = o.optString("last_seen", ""),
                            messageCount = o.optInt("message_count", 0),
                            summary = o.optString("summary", ""),
                            status = SavedSessionStatus.fromRaw(o.optString("status", "unknown")),
                        ),
                    )
                }
            }.filter { it.id.isNotEmpty() }
        }.getOrDefault(emptyList())
    }
}
