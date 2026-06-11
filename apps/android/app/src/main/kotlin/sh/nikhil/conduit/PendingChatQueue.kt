package sh.nikhil.conduit

import org.json.JSONArray
import org.json.JSONObject

/**
 * Entry kind — mirrors iOS `PendingChatKind` and the spec's state model.
 *
 * - [normal]      : today's optimistic fire-and-deliver (no turn active). UNCHANGED.
 * - [queuedTurn]  : held because a turn is active; flushed on turn-complete.
 * - [steering]    : codex entry currently being injected into the running turn.
 * - [retrying]    : a steer/send attempt failed; show "Retrying", offer the Steer button.
 */
enum class PendingChatKind {
    normal,
    queuedTurn,
    steering,
    retrying,
}

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
 *
 * [kind] drives the "Queued Next" panel behavior:
 * - [PendingChatKind.normal]     : delivered immediately when connected.
 * - [PendingChatKind.queuedTurn] : held for turn-complete; shown in the panel.
 * - [PendingChatKind.steering]   : codex in-flight steer attempt.
 * - [PendingChatKind.retrying]   : steer failed; awaiting manual re-steer.
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
    /**
     * Entry lifecycle kind per the "Queued Next" spec. Defaults to [PendingChatKind.normal]
     * so existing callers are unaffected. Updated by the steer/queue-on-turn-active path.
     */
    val kind: PendingChatKind = PendingChatKind.normal,
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
 *
 * Steer / Queued-Next extensions (spec PR #481):
 *   5. [enqueueQueued]     — enqueue with kind=queuedTurn (turn is active).
 *   6. [markSteering]      — flip kind to steering (steer in-flight).
 *   7. [markSteeringFailed]— steer failed; flip to retrying.
 *   8. [flushOnTurnComplete] — returns the OLDEST queuedTurn/retrying entry
 *                             to deliver when a turn ends (one at a time).
 *   9. [queuedTurnEntries] — entries in the "Queued Next" panel for a session.
 *  10. [cancel]            — remove a queued entry before it auto-sends.
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
     * Enqueue a message that was sent while a turn is active. Kind is
     * [PendingChatKind.queuedTurn] — held in the "Queued Next" panel until the
     * turn completes (or manually steered for codex). Idempotent on [localId].
     */
    fun enqueueQueued(sessionId: String, localId: String, message: String, ts: String): PendingChatQueue {
        val list = bySession[sessionId].orEmpty()
        if (list.any { it.localId == localId }) return this
        return copy(
            bySession = bySession + (sessionId to list + PendingChat(
                localId = localId,
                message = message,
                ts = ts,
                kind = PendingChatKind.queuedTurn,
            )),
        )
    }

    /**
     * Entries the shell should (re)attempt now: [PendingChatKind.normal] entries
     * not yet marked [PendingChat.failed]. Queue-on-turn-active entries
     * ([queuedTurn], [steering], [retrying]) are excluded from the auto-flush
     * path — they have their own delivery gate. A failed entry waits for an
     * explicit [retry] before it re-enters the flush set.
     *
     * DO NOT REGRESS #479: [normal] entries must still flush on
     * connect/foreground/reconnect exactly as before.
     */
    fun flushable(sessionId: String): List<PendingChat> =
        bySession[sessionId].orEmpty().filter {
            !it.failed && it.kind == PendingChatKind.normal
        }

    /**
     * Return the OLDEST [queuedTurn] or [retrying] entry for [sessionId] — the
     * one to auto-send when a turn completes. Returns null when there is
     * nothing queued. The caller delivers this entry via the normal send path
     * (which starts a new turn), and any remaining entries stay queued for the
     * NEXT turn-complete (natural serialization — one at a time, not a blast).
     */
    fun flushOnTurnComplete(sessionId: String): PendingChat? =
        bySession[sessionId].orEmpty().firstOrNull {
            it.kind == PendingChatKind.queuedTurn || it.kind == PendingChatKind.retrying
        }

    /**
     * All "Queued Next" panel entries for a session, in insertion order
     * (oldest first). Includes [queuedTurn], [steering], and [retrying] kinds.
     */
    fun queuedTurnEntries(sessionId: String): List<PendingChat> =
        bySession[sessionId].orEmpty().filter {
            it.kind == PendingChatKind.queuedTurn ||
                it.kind == PendingChatKind.steering ||
                it.kind == PendingChatKind.retrying
        }

    /**
     * Flip [localId]'s kind to [PendingChatKind.steering] — steer in-flight.
     * No-op when not found.
     */
    fun markSteering(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.map {
            if (it.localId != localId) it else it.copy(kind = PendingChatKind.steering)
        }
        return copy(bySession = bySession + (sessionId to next))
    }

    /**
     * Flip [localId]'s kind to [PendingChatKind.retrying] — steer attempt
     * failed; user can re-tap the Steer button. No-op when not found.
     */
    fun markSteeringFailed(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.map {
            if (it.localId != localId) it else it.copy(kind = PendingChatKind.retrying)
        }
        return copy(bySession = bySession + (sessionId to next))
    }

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

    /**
     * User cancelled a queued entry from the "Queued Next" panel — remove it
     * before it auto-sends. No-op when not found.
     */
    fun cancel(sessionId: String, localId: String): PendingChatQueue {
        val list = bySession[sessionId] ?: return this
        val next = list.filterNot { it.localId == localId }
        return copy(
            bySession = if (next.isEmpty()) bySession - sessionId else bySession + (sessionId to next),
        )
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
                            .put("failed", c.failed)
                            .put("kind", c.kind.name),
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
                                val kindStr = o.optString("kind", PendingChatKind.normal.name)
                                val kind = runCatching {
                                    PendingChatKind.valueOf(kindStr)
                                }.getOrDefault(PendingChatKind.normal)
                                add(
                                    PendingChat(
                                        localId = o.optString("localId", ""),
                                        message = o.optString("message", ""),
                                        ts = o.optString("ts", ""),
                                        attempts = o.optInt("attempts", 0),
                                        failed = o.optBoolean("failed", false),
                                        kind = kind,
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
