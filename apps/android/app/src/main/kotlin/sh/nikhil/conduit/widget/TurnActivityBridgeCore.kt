package sh.nikhil.conduit.widget

/**
 * Android mirror of iOS `TurnLiveActivityBridgeCore`
 * (`apps/ios/Sources/Models/TurnLiveActivityBridge.swift`).
 *
 * Pure multi-session diff. Folds a fresh [TurnActivityFrame] from the
 * store into per-session cursors and returns the [TurnActivityIntent]s a
 * [TurnActivityController] should apply, in order. Owns no Android
 * framework state — unit-testable without a SessionStore or any
 * notification / Glance surface, so the two platforms can't drift on the
 * multi-session start/end edges.
 *
 * Idle policy: [idleTimeoutMillis] after the most recent tool/command
 * item for a session, emit [TurnActivityIntent.End]. Mirrors
 * `TurnActivityModel.DEFAULT_IDLE_TIMEOUT_MILLIS` so the bridge and the
 * per-session model agree on the closing edge — either firing first is
 * fine because the controller's paths are idempotent.
 */

/** Pure-data view of the SessionStore slice the bridge cares about. */
data class TurnActivityFrame(
    val sessions: List<Session>,
) {
    data class Session(
        val sessionID: String,
        val agentName: String,
        /** Phase from SessionStatus, e.g. "running", "exited(0)", "exited". */
        val phase: String?,
        val conversation: List<TurnActivityItem>,
    )
}

/**
 * Intent the bridge wants the controller to apply, in terms of the
 * controller's verbs. Sits between the pure "diff the store" step and
 * the side-effecting surface calls so the diff stays testable.
 */
sealed class TurnActivityIntent {
    /** A fresh tool/command item should drive the activity. */
    data class Observe(
        val sessionID: String,
        val agentName: String,
        val item: TurnActivityItem,
    ) : TurnActivityIntent()

    /** Session exited (lifecycle, status frame, or idle past the window). */
    data class End(val sessionID: String) : TurnActivityIntent()

    /** Periodic nudge so the controller can run its own idle-timeout path. */
    data object Tick : TurnActivityIntent()
}

class TurnActivityBridgeCore(
    val idleTimeoutMillis: Long = TurnActivityModel.DEFAULT_IDLE_TIMEOUT_MILLIS,
) {
    /** Last observed conversation-item id per session, so an idempotent
     *  re-emit of the same item doesn't replay an [TurnActivityIntent.Observe]. */
    private val lastSeenItemID = mutableMapOf<String, String>()

    /** Last observed phase per session, so we only emit [End] on the edge
     *  into "exited", not on every status frame that carries it. */
    private val lastSeenPhase = mutableMapOf<String, String>()

    /** Wall-clock of the most recent tool/command emission per session —
     *  input to the idle-timeout decision. */
    private val lastActivityAt = mutableMapOf<String, Long>()

    /** Sessions already ended once. Cleared when a fresh tool item arrives,
     *  so the idle sweep doesn't emit [End] repeatedly. */
    private val endedSessions = mutableSetOf<String>()

    /** Fold a fresh store frame into the bridge state and return the
     *  intents the controller should apply, in order. */
    fun ingest(frame: TurnActivityFrame, nowMillis: Long): List<TurnActivityIntent> {
        val intents = mutableListOf<TurnActivityIntent>()
        for (session in frame.sessions) {
            val sid = session.sessionID

            // Exit edge: a fresh "exited..." phase ends the activity
            // independent of whether the conversation log carried an EXIT
            // row. The controller collapses both.
            val phase = session.phase
            if (phase != null && phase.startsWith("exited")) {
                val prev = lastSeenPhase[sid]
                lastSeenPhase[sid] = phase
                if (prev != phase && sid !in endedSessions) {
                    intents.add(TurnActivityIntent.End(sid))
                    endedSessions.add(sid)
                    // Session is dead — skip the conversation scan.
                    continue
                }
            } else if (phase != null) {
                lastSeenPhase[sid] = phase
            }

            // Walk the conversation forward. Once past the last-seen id,
            // every fresh tool/command drives an Observe; EXIT drives End.
            // Plain message rows don't surface.
            var pastLastSeen = !lastSeenItemID.containsKey(sid)
            for (item in session.conversation) {
                if (!pastLastSeen) {
                    if (item.id == lastSeenItemID[sid]) pastLastSeen = true
                    continue
                }
                when (item.kind) {
                    TurnActivityItem.Kind.TOOL, TurnActivityItem.Kind.COMMAND -> {
                        intents.add(TurnActivityIntent.Observe(sid, session.agentName, item))
                        lastActivityAt[sid] = item.timestampMillis
                        endedSessions.remove(sid)
                    }
                    TurnActivityItem.Kind.EXIT -> {
                        if (sid !in endedSessions) {
                            intents.add(TurnActivityIntent.End(sid))
                            endedSessions.add(sid)
                        }
                    }
                    else -> { /* message / other rows don't surface */ }
                }
                lastSeenItemID[sid] = item.id
            }
            // NOTE: iOS seeds the cursor to "" here for an empty first
            // frame. We deliberately don't: the cursor-walk above skips
            // every item up to and including `lastSeenItemID`, and since
            // no real item has id "", that seed permanently strands any
            // session whose first observed frame was empty (common — a
            // session shows up in statusBySession before its first tool
            // item). Leaving the cursor unset means the next non-empty
            // frame is processed from the start, which is the intended
            // behaviour. (iOS carries the same latent bug — tracked for a
            // follow-up so the two stay in lockstep.)
        }

        // Idle-timeout sweep: any session past the window without a fresh
        // tool item that hasn't already been ended.
        for ((sid, last) in lastActivityAt) {
            if (sid in endedSessions) continue
            if (nowMillis - last >= idleTimeoutMillis) {
                intents.add(TurnActivityIntent.End(sid))
                endedSessions.add(sid)
            }
        }

        // Trailing tick so the controller can close anything the bridge
        // isn't tracking (e.g. an activity started before it attached).
        intents.add(TurnActivityIntent.Tick)
        return intents
    }
}
