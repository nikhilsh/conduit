package sh.nikhil.conduit

import org.json.JSONArray
import org.json.JSONObject

/**
 * One user chat message awaiting delivery to the agent.
 *
 * The shell appends an optimistic transcript echo (a `local-…`
 * [uniffi.conduit_core.ConversationItem]) the instant the user hits send,
 * then enqueues the same text here. The queue survives backgrounding and
 * process death (persisted per-session), so a message typed during a
 * reconnect window — or sent the moment the user backgrounds the app — is no
 * longer lost.
 *
 * [localId] ties the queue entry to its transcript echo: when delivery
 * succeeds the shell flips that echo from `pending` -> `done`; when it
 * ultimately fails it flips to `failed` with a retry affordance. Mirror of
 * iOS `PendingChat`.
 */
data class PendingChat(
    /** The `local-…` id of the optimistic transcript echo this entry backs. */
    val localId: String,
    /** The raw message text to deliver (already slash-command-filtered). */
    val message: String,
    /** Broker-clock-anchored timestamp string of the echo (for ordering). */
    val ts: String,
    /** Delivery attempts made so far. Drives the give-up -> failed decision. */
    val attempts: Int = 0,
    /**
     * Set once the entry has exhausted retries and is surfaced as failed. A
     * failed entry stays in the queue (so the user can retry) but is NOT
     * auto-flushed again until the user explicitly retries it.
     */
    val failed: Boolean = false,
)

/**
 * Pure, dependency-free state machine for the optimistic-send pending queue.
 * Holds NO transport and NO clock — the shell injects delivery and
 * persistence — so the queue/flush/ack/failure transitions are unit-testable
 * without a live WS. Mirror of iOS `PendingChatQueue`.
 *
 * Immutable value type: every move returns a new queue, matching the
 * StateFlow update style used across [SessionStore]. The shell drives it
 * with four moves:
 *   1. [enqueue]      — on send, register the message as pending.
 *   2. [flushable]    — when ready (connected + agent live), which entries to
 *                       (re)attempt; the shell delivers each and reports back.
 *   3. [markDelivered]— the WS write succeeded -> drop the entry (ack).
 *   4. [markAttemptFailed] — the WS write threw -> bump attempts; past the cap
 *                       the entry becomes [PendingChat.failed].
 */
data class PendingChatQueue(
    val bySession: Map<String, List<PendingChat>> = emptyMap(),
) {
    /** All entries for a session in insertion order (oldest first). */
    fun entries(sessionId: String): List<PendingChat> = bySession[sessionId].orEmpty()

    /**
     * True when [localId] is still pending (not yet delivered). Drives the
     * transcript echo's pending/failed indicator.
     */
    fun isPending(localId: String, sessionId: String): Boolean =
        bySession[sessionId].orEmpty().any { it.localId == localId }

    /** True when [localId] is pending AND has exhausted retries. */
    fun isFailed(localId: String, sessionId: String): Boolean =
        bySession[sessionId].orEmpty().any { it.localId == localId && it.failed }

    /** Register a freshly-sent message as pending. Idempotent on [localId]. */
    fun enqueue(sessionId: String, localId: String, message: String, ts: String): PendingChatQueue {
        val list = bySession[sessionId].orEmpty()
        if (list.any { it.localId == localId }) return this
        return copy(bySession = bySession + (sessionId to list + PendingChat(localId, message, ts)))
    }

    /**
     * Entries the shell should (re)attempt now: everything not yet marked
     * [PendingChat.failed]. A failed entry waits for an explicit [retry] before
     * it re-enters the flush set, so an unreachable box doesn't hammer the
     * agent on every foreground.
     */
    fun flushable(sessionId: String): List<PendingChat> =
        bySession[sessionId].orEmpty().filter { !it.failed }

    /**
     * The WS write for [localId] succeeded — drop it from the queue (ack). The
     * shell flips the transcript echo to `done`.
     */
    fun markDelivered(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.filterNot { it.localId == localId }
        return copy(
            bySession = if (next.isEmpty()) bySession - sessionId else bySession + (sessionId to next),
        )
    }

    /**
     * A delivery attempt for [localId] threw. Bump its attempt count; once it
     * reaches [MAX_ATTEMPTS] the entry becomes [PendingChat.failed] (the shell
     * flips the echo to failed + shows retry).
     */
    fun markAttemptFailed(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.map { entry ->
            if (entry.localId != localId) {
                entry
            } else {
                val attempts = entry.attempts + 1
                entry.copy(attempts = attempts, failed = entry.failed || attempts >= MAX_ATTEMPTS)
            }
        }
        return copy(bySession = bySession + (sessionId to next))
    }

    /**
     * True if [localId] just crossed into the failed state on its latest
     * attempt — lets the caller capture telemetry exactly once.
     */
    fun justFailed(sessionId: String, localId: String): Boolean =
        bySession[sessionId].orEmpty().any { it.localId == localId && it.failed && it.attempts == MAX_ATTEMPTS }

    /**
     * User tapped retry on a failed entry — clear the failed flag and reset
     * attempts so the next [flushable] picks it up again.
     */
    fun retry(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.map { if (it.localId == localId) it.copy(failed = false, attempts = 0) else it }
        return copy(bySession = bySession + (sessionId to next))
    }

    /** Drop an entire session's queue (session deleted / forgotten). */
    fun clear(sessionId: String): PendingChatQueue = copy(bySession = bySession - sessionId)

    companion object {
        /**
         * Give up after this many delivery attempts and surface the entry as
         * failed. Three covers a transient reconnect blip without spamming the
         * agent if the box is genuinely unreachable.
         */
        const val MAX_ATTEMPTS = 3

        /** Serialize to a JSON string for SharedPreferences (mirror of the
         * displayNames/savedServers persistence pattern in [SessionStore]). */
        fun encode(queue: PendingChatQueue): String {
            val obj = JSONObject()
            queue.bySession.forEach { (sid, list) ->
                val arr = JSONArray()
                list.forEach { c ->
                    arr.put(
                        JSONObject()
                            .put("localId", c.localId)
                            .put("message", c.message)
                            .put("ts", c.ts)
                            .put("attempts", c.attempts)
                            .put("failed", c.failed),
                    )
                }
                obj.put(sid, arr)
            }
            return obj.toString()
        }

        /** Parse the SharedPreferences JSON string back into a queue. */
        fun decode(raw: String?): PendingChatQueue {
            if (raw.isNullOrBlank()) return PendingChatQueue()
            return runCatching {
                val obj = JSONObject(raw)
                val map = buildMap<String, List<PendingChat>> {
                    obj.keys().forEach { sid ->
                        val arr = obj.optJSONArray(sid) ?: JSONArray()
                        val list = buildList {
                            for (i in 0 until arr.length()) {
                                val o = arr.getJSONObject(i)
                                add(
                                    PendingChat(
                                        localId = o.optString("localId", ""),
                                        message = o.optString("message", ""),
                                        ts = o.optString("ts", ""),
                                        attempts = o.optInt("attempts", 0),
                                        failed = o.optBoolean("failed", false),
                                    ),
                                )
                            }
                        }.filter { it.localId.isNotEmpty() }
                        if (list.isNotEmpty()) put(sid, list)
                    }
                }
                PendingChatQueue(map)
            }.getOrDefault(PendingChatQueue())
        }
    }
}
