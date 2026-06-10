package sh.nikhil.conduit.ui

/**
 * Pure decision for the reply haptics — the tap that punctuates an agent
 * reply when it *starts* and when it *finishes* (ChatGPT-style, but tasteful:
 * no continuous buzz-while-generating, which ChatGPT shipped and users widely
 * asked to disable). Android parity of iOS `ReplyHapticsModel`.
 *
 * Fed the chat's `showTyping` busy flag (`TypingIndicatorModel.isStreaming ||
 * agentWorking`) on each change. Returns the [ReplyHapticEvent] to play, if
 * any:
 *   - **TurnStart**  — first time a turn goes busy (`false → true`).
 *   - **TurnFinish** — when the turn settles (`true → false`).
 *
 * Pure + Compose-free so [ReplyHapticsModelTest] can pin the contract without
 * a composition. The Compose layer holds one instance per session, feeds it
 * the flag + a monotonic clock, and hands any returned event to
 * `View.performHapticFeedback` (the impure side). Suppression while
 * backgrounded / flag-off is the caller's job (it passes `enabled = false`),
 * keeping this a pure state machine.
 *
 * Debounce: flips closer together than [minIntervalMs] are swallowed so a
 * status that blips busy/idle/busy in a few hundred ms doesn't machine-gun.
 */
enum class ReplyHapticEvent { TurnStart, TurnFinish }

data class ReplyHapticsModel(
    /** Last busy state observed; null before the first observation so a
     *  mid-turn open (already busy) does NOT fire — we only fire on a
     *  transition we witnessed. */
    private val lastBusy: Boolean? = null,
    /** Monotonic ms of the last event we emitted (for debounce). */
    private val lastFiredMs: Long = Long.MIN_VALUE,
    private val minIntervalMs: Long = DEFAULT_MIN_INTERVAL_MS,
) {
    /**
     * Fold a fresh busy observation in. Returns the model to keep AND the
     * event to play (or null). Pure — no side effects.
     *
     * @param busy current `showTyping` value.
     * @param enabled master gate (flag AND app-foreground AND chat visible).
     *   When false we still track [busy] so the next transition is computed
     *   correctly, but never emit.
     * @param nowMs monotonic clock, injected for testability.
     */
    fun observe(busy: Boolean, enabled: Boolean, nowMs: Long): Pair<ReplyHapticsModel, ReplyHapticEvent?> {
        val was = lastBusy
        // First observation seeds state only — never fires.
        if (was == null || was == busy) {
            return copy(lastBusy = busy) to null
        }
        val event = if (busy) ReplyHapticEvent.TurnStart else ReplyHapticEvent.TurnFinish
        if (!enabled) {
            return copy(lastBusy = busy) to null
        }
        // Debounce: swallow flips within minIntervalMs of the last emit.
        if (nowMs - lastFiredMs < minIntervalMs) {
            return copy(lastBusy = busy) to null
        }
        return copy(lastBusy = busy, lastFiredMs = nowMs) to event
    }

    companion object {
        /** Flips closer together than this are swallowed (debounce). */
        const val DEFAULT_MIN_INTERVAL_MS = 400L
    }
}
