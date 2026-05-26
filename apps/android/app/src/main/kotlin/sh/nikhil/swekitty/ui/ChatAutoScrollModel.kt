package sh.nikhil.swekitty.ui

/**
 * Pure-data state machine deciding whether the chat list should
 * auto-scroll to the latest message (task #39). Android mirror of iOS
 * `ChatAutoScrollController` — same contract, same thresholds, so the
 * two platforms behave identically.
 *
 * The problem: while the agent streams we want to follow the stream and
 * keep the latest text pinned to the bottom — but the moment the user
 * drags up to read scrollback we must stop yanking them down. The
 * naive `animateScrollToItem(last)` on every change fights the user.
 *
 * This is an immutable value type: each transition returns a new model,
 * so it's trivially unit-testable with no Compose host. The Compose
 * layer holds it in a `mutableStateOf` and feeds it three signals:
 *
 *   - [onUserDragged]            — a drag began; latch `userScrolledUp`.
 *   - [onBottomProximityChanged] — the live distance (px) from the
 *                                  bottom; crossing back inside
 *                                  [nearBottomThresholdPx] re-arms.
 *   - new-message / streaming changes are read off [shouldFollow].
 */
data class ChatAutoScrollModel(
    /**
     * Distance (in *pixels*) from the bottom within which the list is
     * treated as pinned and auto-follow resumes. The iOS counterpart
     * uses ~80pt; on Android the `LazyListState` reports pixels, so the
     * Compose layer converts 80.dp → px before feeding [onBottomProximityChanged].
     */
    val nearBottomThresholdPx: Float = DEFAULT_THRESHOLD_PX,
    /**
     * Latched when the user drags. While set, streaming + new messages
     * do NOT auto-scroll. Cleared when the user returns near the bottom.
     */
    val userScrolledUp: Boolean = false,
    /**
     * Most recent measured distance from the bottom edge in pixels.
     * Seeded large so an unmeasured model isn't assumed pinned.
     */
    val distanceFromBottomPx: Float = Float.MAX_VALUE,
) {

    /** Within the near-bottom band. */
    val isNearBottom: Boolean
        get() = distanceFromBottomPx <= nearBottomThresholdPx

    /** Whether streaming / new-message updates should auto-scroll. */
    val shouldFollow: Boolean
        get() = !userScrolledUp

    /**
     * Whether the scroll-to-bottom button should be present at all. The
     * user must have actually taken manual control ([userScrolledUp])
     * AND be a meaningful amount above the bottom. A fresh / pinned /
     * tiny-overscroll model never shows it; returning within the band
     * clears [userScrolledUp] (in [onBottomProximityChanged]) and hides
     * it. See [scrollToBottomButtonAlpha] for the smooth fade the
     * Compose layer animates toward.
     */
    val showScrollToBottomButton: Boolean
        get() = userScrolledUp && distanceFromBottomPx > showButtonThresholdPx

    /**
     * Target opacity for the scroll-to-bottom button. 0 when not
     * scrolled up or practically at the bottom (faded out), ramping to 1
     * once the user has scrolled up past [showButtonThresholdPx] by a
     * full near-bottom band. The Compose layer feeds this into
     * `animateFloatAsState` so the button fades in/out smoothly rather
     * than popping.
     */
    val scrollToBottomButtonAlpha: Float
        get() {
            if (!userScrolledUp) return 0f
            if (distanceFromBottomPx <= showButtonThresholdPx) return 0f
            val ramp = nearBottomThresholdPx.coerceAtLeast(1f)
            val over = distanceFromBottomPx - showButtonThresholdPx
            return (over / ramp).coerceIn(0f, 1f)
        }

    /**
     * Distance past which the button becomes meaningful. Sits at the
     * near-bottom band edge so a tiny overscroll / being pinned keeps
     * the button faded out; scrolling up a meaningful amount fades it in.
     */
    private val showButtonThresholdPx: Float
        get() = nearBottomThresholdPx

    /** The user began a drag: latch manual control. */
    fun onUserDragged(): ChatAutoScrollModel =
        if (userScrolledUp) this else copy(userScrolledUp = true)

    /**
     * Feed the live distance-from-bottom (px, clamped at 0 for
     * overscroll). Re-arms follow when the user returns within the band.
     */
    fun onBottomProximityChanged(distancePx: Float): ChatAutoScrollModel {
        val clamped = distancePx.coerceAtLeast(0f)
        val next = copy(distanceFromBottomPx = clamped)
        return if (userScrolledUp && next.isNearBottom) {
            next.copy(userScrolledUp = false)
        } else {
            next
        }
    }

    /** Programmatic jump to bottom (FAB tap / fresh send): re-arm. */
    fun onScrollToBottomRequested(): ChatAutoScrollModel =
        copy(userScrolledUp = false, distanceFromBottomPx = 0f)

    companion object {
        /**
         * ~80dp at mdpi (density 1.0). The Compose layer recomputes the
         * real px threshold from the live density; this default keeps a
         * sane value for models constructed in tests.
         */
        const val DEFAULT_THRESHOLD_PX = 80f
    }
}
