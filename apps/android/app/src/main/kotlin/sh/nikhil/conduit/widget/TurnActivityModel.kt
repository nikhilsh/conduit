package sh.nikhil.conduit.widget

/**
 * Android mirror of iOS `apps/ios/Sources/Models/TurnActivityModel.swift`
 * (PLAN-2026-05-19 Package 7).
 *
 * Pure state machine that decides whether to **start** / **update** /
 * **end** an "active turn" surface for a single session. iOS feeds the
 * resulting effects into ActivityKit (`Activity.request` /
 * `activity.update` / `activity.end`); Android wires them into a
 * Glance widget update in a follow-up PR. This file ships the pure
 * shape + tests so the two platforms can't drift on the transition
 * rules.
 *
 * The data shapes (`TurnActivityAttributesData`, `ContentState`,
 * `TurnActivityItem`) match the Swift types verbatim — same field
 * names, same value semantics — so a future shared-`core` move can
 * lift either side into the Rust bridge without churning the
 * platform call sites.
 */

/**
 * Static descriptors for the activity. Pinned at start time and
 * unchanged for the lifetime of the active turn. Mirrors iOS
 * `TurnActivityAttributesData`.
 */
data class TurnActivityAttributesData(
    val agentName: String,
    val sessionID: String,
)

/**
 * Mutable per-turn state. Mirrors iOS `TurnActivityContentState`.
 *
 * `startedAt` is epoch millis (Swift uses `Date`; we use `Long` so
 * the model stays serializable to / from a plain WorkData / Glance
 * preferences). `status` matches Litter's vocabulary — `"running"`,
 * `"pending"`, `"exited"`.
 */
data class TurnActivityContentState(
    val currentTool: String? = null,
    val currentCommand: String? = null,
    val startedAtMillis: Long,
    val tokensIn: Int = 0,
    val tokensOut: Int = 0,
    val status: String = "running",
)

/**
 * Lightweight projection of `ConversationItem`. Carries just the
 * fields the state machine cares about so tests don't have to depend
 * on the generated UniFFI module. Mirrors iOS `TurnActivityItem`.
 */
data class TurnActivityItem(
    val id: String,
    val kind: Kind,
    val toolName: String? = null,
    val command: String? = null,
    val status: String = "running",
    val exitCode: Int? = null,
    val timestampMillis: Long,
) {
    enum class Kind { TOOL, COMMAND, MESSAGE, EXIT, OTHER }
}

/**
 * Side effect a `TurnActivityModel` step wants the host to apply.
 * `START` / `UPDATE` / `END` map 1:1 to the three iOS ActivityKit
 * verbs. Android's host (in a follow-up PR) maps them to:
 *   - `START` → `GlanceAppWidgetManager.update(...)` first emit
 *   - `UPDATE` → subsequent `update(...)` calls
 *   - `END` → `update(...)` with empty / "Idle" state
 */
sealed class TurnActivityEffect {
    data object Noop : TurnActivityEffect()
    data class Start(
        val attributes: TurnActivityAttributesData,
        val state: TurnActivityContentState,
    ) : TurnActivityEffect()
    data class Update(val state: TurnActivityContentState) : TurnActivityEffect()
    data class End(val state: TurnActivityContentState) : TurnActivityEffect()
}

/**
 * Pure state machine for a single session. Mutates internal state and
 * returns one [TurnActivityEffect] per `apply` / `tick` call.
 *
 * Transition rules (verbatim port of iOS):
 *  - First `TOOL` or `COMMAND` item arrives → `Start`
 *  - Subsequent `TOOL` / `COMMAND` items → `Update`
 *  - `EXIT` item OR an item with `status == "exited"` → `End`
 *  - Tick after [idleTimeoutMillis] with no fresh tool item → `End`
 *  - Explicit [sessionExited] call → `End`
 */
class TurnActivityModel(
    val idleTimeoutMillis: Long = DEFAULT_IDLE_TIMEOUT_MILLIS,
) {
    var attributes: TurnActivityAttributesData? = null
        private set
    var contentState: TurnActivityContentState? = null
        private set
    var lastActivityAtMillis: Long? = null
        private set

    val isActive: Boolean
        get() = attributes != null && contentState != null

    fun apply(
        item: TurnActivityItem,
        sessionID: String,
        agentName: String,
    ): TurnActivityEffect {
        // Terminal kinds end the activity unconditionally.
        if (item.kind == TurnActivityItem.Kind.EXIT) {
            return endActivity(item.timestampMillis, status = "exited")
        }
        if (item.status == "exited" && contentState != null) {
            return endActivity(item.timestampMillis, status = "exited")
        }

        // Only TOOL / COMMAND drive start/update — bare MESSAGE rows
        // don't justify a widget update.
        if (item.kind != TurnActivityItem.Kind.TOOL && item.kind != TurnActivityItem.Kind.COMMAND) {
            return TurnActivityEffect.Noop
        }

        lastActivityAtMillis = item.timestampMillis

        if (!isActive) {
            val attrs = TurnActivityAttributesData(agentName = agentName, sessionID = sessionID)
            val state = TurnActivityContentState(
                currentTool = item.toolName,
                currentCommand = item.command,
                startedAtMillis = item.timestampMillis,
                tokensIn = 0,
                tokensOut = 0,
                status = "running",
            )
            attributes = attrs
            contentState = state
            return TurnActivityEffect.Start(attrs, state)
        }

        val next = contentState!!.copy(
            currentTool = item.toolName ?: contentState!!.currentTool,
            currentCommand = item.command ?: contentState!!.currentCommand,
            status = "running",
        )
        contentState = next
        return TurnActivityEffect.Update(next)
    }

    /**
     * Externally-signalled end (session lifecycle exit, host reset,
     * app teardown). Idempotent: calling on an inactive model is a
     * Noop.
     */
    fun sessionExited(
        nowMillis: Long = System.currentTimeMillis(),
        status: String = "exited",
    ): TurnActivityEffect = endActivity(nowMillis, status)

    /**
     * Time-driven step. Called periodically (or on any external
     * nudge) so the model can end the activity after [idleTimeoutMillis]
     * without a new tool. Returns `End` exactly once per active turn.
     */
    fun tick(nowMillis: Long): TurnActivityEffect {
        val last = lastActivityAtMillis ?: return TurnActivityEffect.Noop
        if (!isActive) return TurnActivityEffect.Noop
        return if (nowMillis - last >= idleTimeoutMillis) {
            endActivity(nowMillis, status = "exited")
        } else {
            TurnActivityEffect.Noop
        }
    }

    /**
     * Apply a fresh token-count update without changing the active
     * tool. Token counts arrive on a different channel from tool
     * calls, so this is a separate input.
     */
    fun updateTokens(tokensIn: Int, tokensOut: Int): TurnActivityEffect {
        val cur = contentState ?: return TurnActivityEffect.Noop
        val next = cur.copy(tokensIn = tokensIn, tokensOut = tokensOut)
        contentState = next
        return TurnActivityEffect.Update(next)
    }

    private fun endActivity(whenMillis: Long, status: String): TurnActivityEffect {
        val cur = contentState
        if (cur == null) {
            attributes = null
            return TurnActivityEffect.Noop
        }
        val final = cur.copy(status = status)
        val effect = TurnActivityEffect.End(final)
        attributes = null
        contentState = null
        lastActivityAtMillis = null
        return effect
    }

    companion object {
        /**
         * Idle window after the last tool/command before the activity
         * is ended. 5 seconds mirrors iOS — tuned so a chain of fast
         * tool calls keeps the activity alive without flashing on/off.
         */
        const val DEFAULT_IDLE_TIMEOUT_MILLIS: Long = 5_000L
    }
}
