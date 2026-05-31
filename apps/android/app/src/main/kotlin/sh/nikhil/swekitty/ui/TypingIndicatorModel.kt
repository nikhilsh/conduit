package sh.nikhil.swekitty.ui

/**
 * Pure decision for the "agent is typing…" indicator (Android parity of
 * the iOS chat-polish change's `isStreaming` indicator).
 *
 * Android has no single broker flag that means "this turn is actively
 * streaming" — the broker `phase` is `running` for any live session
 * (idle or not), so it can't drive a transient indicator without
 * getting stuck on. The reliable, fully client-side signal is the same
 * one the auto-scroll follow already keys off: the last assistant/tool
 * item's content grows token-by-token while the agent streams, then
 * stops. We treat "the trailing assistant turn grew within the last
 * [quietWindowMs]" as streaming, and clear it once the stream goes
 * quiet — exactly when iOS flips `isStreaming` back to false.
 *
 * Kept pure + Compose-free so [TypingIndicatorModelTest] can pin the
 * grow → show, quiet → hide contract without a composition. The Compose
 * layer feeds it (a) the trailing turn's role + content length on every
 * recomposition and (b) the current monotonic time.
 */
data class TypingIndicatorModel(
    /** Role of the last conversation event (lowercased), or null/empty. */
    val lastRole: String = "",
    /** Content length of the last event the last time it changed. */
    val lastLength: Int = 0,
    /** Monotonic ms at which [lastLength] last changed. */
    val lastChangeMs: Long = 0L,
    /** Whether the trailing turn is an in-progress (non-user) turn. */
    private val streamingArmed: Boolean = false,
) {

    /**
     * Fold in the latest trailing-turn observation. When the trailing
     * item is a non-user turn whose content grew, arm streaming and
     * stamp the change time. A user turn (the moment they send) or an
     * empty list disarms immediately — the agent hasn't started yet.
     */
    fun onTrailingTurn(role: String?, contentLength: Int, nowMs: Long): TypingIndicatorModel {
        val r = role?.lowercase()?.trim().orEmpty()
        if (r.isEmpty() || r == "user") {
            return copy(lastRole = r, lastLength = contentLength, lastChangeMs = nowMs, streamingArmed = false)
        }
        // A non-user trailing turn: grew (or first appeared) ⇒ streaming.
        val grew = contentLength != lastLength || r != lastRole
        return if (grew) {
            copy(lastRole = r, lastLength = contentLength, lastChangeMs = nowMs, streamingArmed = true)
        } else {
            copy(lastRole = r)
        }
    }

    /**
     * Whether the typing indicator should show at [nowMs]. True while a
     * non-user turn is armed and last grew within [quietWindowMs];
     * flips false once the stream has been quiet past the window.
     */
    fun isStreaming(nowMs: Long, quietWindowMs: Long = DEFAULT_QUIET_WINDOW_MS): Boolean {
        if (!streamingArmed) return false
        return (nowMs - lastChangeMs) < quietWindowMs
    }

    companion object {
        /**
         * How long after the last token to keep showing "typing…". Long
         * enough to bridge inter-token gaps, short enough that the
         * indicator disappears promptly when the turn finishes.
         */
        const val DEFAULT_QUIET_WINDOW_MS = 700L

        /** Statuses that mark the trailing assistant turn as still busy. */
        val WORKING_STATUSES = setOf("thinking", "working", "pending", "streaming", "running")

        /**
         * Pure decision for the pre-token "thinking" phase (device
         * feedback v0.0.50 #5 parity, OR-ed with the streaming model at
         * the call site). Extracted verbatim from `ChatPage`'s inline
         * `agentWorking` block so it can be pinned without a composition:
         * a null trailing event (empty log) is not busy; the user's
         * message being the trailing event (no assistant turn started
         * yet) is busy; and a working/thinking/pending/streaming/running
         * trailing status is busy ONLY while the assistant turn has no
         * content yet (the pre-first-token window). `lastRole`/`lastStatus`
         * are null only when there is no trailing event.
         *
         * Device feedback v0.0.68: the broker never transitions a finished
         * turn's status to a terminal value — the phase sticks at "running"
         * (which is in [WORKING_STATUSES]) for any live session. Gating the
         * status clause on empty content stops a settled turn (the agent
         * replied and is waiting on the user) from keeping the indicator on.
         */
        fun agentWorking(lastRole: String?, lastStatus: String?, lastContentEmpty: Boolean): Boolean {
            if (lastRole == null) return false
            return when {
                lastRole.equals("user", ignoreCase = true) -> true
                lastContentEmpty && lastStatus.orEmpty().lowercase() in WORKING_STATUSES -> true
                else -> false
            }
        }
    }
}
