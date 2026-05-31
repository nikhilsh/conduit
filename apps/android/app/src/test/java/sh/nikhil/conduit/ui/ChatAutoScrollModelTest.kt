package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-data tests for the streaming auto-scroll state machine
 * (task #39). Android mirror of iOS `ChatAutoScrollControllerTests` —
 * same contract, same near-bottom semantics, so a user who scrolls up
 * to read scrollback is never yanked back to the bottom on either
 * platform.
 */
class ChatAutoScrollModelTest {

    @Test fun defaultsToFollowingAndNoFab() {
        val m = ChatAutoScrollModel()
        assertTrue(m.shouldFollow)
        assertFalse(m.showScrollToBottomButton)
        assertFalse(m.userScrolledUp)
    }

    @Test fun freshModelIsNotAssumedNearBottom() {
        assertFalse(ChatAutoScrollModel().isNearBottom)
    }

    @Test fun dragLatchesScrolledUpAndStopsFollow() {
        val m = ChatAutoScrollModel().onUserDragged()
        assertTrue(m.userScrolledUp)
        assertFalse(m.shouldFollow)
        assertTrue(m.showScrollToBottomButton)
    }

    @Test fun returningNearBottomRearmsFollow() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(40f)
        assertFalse(m.userScrolledUp)
        assertTrue(m.shouldFollow)
        assertFalse(m.showScrollToBottomButton)
    }

    @Test fun stayingAboveThresholdKeepsLatch() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(200f)
        assertTrue(m.userScrolledUp)
        assertFalse(m.shouldFollow)
    }

    @Test fun thresholdIsInclusive() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(80f)
        assertFalse(m.userScrolledUp)
    }

    @Test fun proximityWhileFollowingKeepsState() {
        val m = ChatAutoScrollModel().onBottomProximityChanged(10f)
        assertFalse(m.userScrolledUp)
        assertTrue(m.isNearBottom)
    }

    @Test fun scrollToBottomRequestedClearsLatchAndPins() {
        val m = ChatAutoScrollModel()
            .onUserDragged()
            .onBottomProximityChanged(500f) // still scrolled up
            .onScrollToBottomRequested()
        assertFalse(m.userScrolledUp)
        assertTrue(m.isNearBottom)
        assertTrue(m.shouldFollow)
    }

    @Test fun negativeOverscrollIsClampedToZero() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(-30f)
        assertEquals(0f, m.distanceFromBottomPx, 0.001f)
        assertTrue(m.isNearBottom)
        assertFalse(m.userScrolledUp)
    }

    @Test fun customThresholdIsHonoured() {
        var m = ChatAutoScrollModel(nearBottomThresholdPx = 20f).onUserDragged()
        m = m.onBottomProximityChanged(40f) // outside 20px band
        assertTrue(m.userScrolledUp)
        m = m.onBottomProximityChanged(15f) // inside
        assertFalse(m.userScrolledUp)
    }

    @Test fun dragWhenAlreadyScrolledUpIsIdempotent() {
        val once = ChatAutoScrollModel().onUserDragged()
        val twice = once.onUserDragged()
        assertEquals(once, twice)
    }

    @Test fun defaultThresholdConstant() {
        assertEquals(80f, ChatAutoScrollModel.DEFAULT_THRESHOLD_PX, 0.001f)
    }

    // --- Button visibility: separate buttonVisibleThresholdPx (#item3) ---
    // The button is hidden below buttonVisibleThresholdPx (default 2×near =
    // 160px) so a user who is "practically at the bottom" (100-160px away)
    // never sees the arrow. It only appears after a meaningful scroll up.

    @Test fun buttonHiddenWhenPracticallyAtBottom() {
        // Pinned / inside near-bottom band → button faded out.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(10f)
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun buttonHiddenBetweenNearBottomAndVisibleThreshold() {
        // 120px is past the near-bottom band (80px) but inside
        // buttonVisibleThresholdPx (160px) → button hidden, matching iOS.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(120f)
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun buttonHiddenExactlyAtVisibleThreshold() {
        // Exactly at buttonVisibleThresholdPx (160px) → still hidden.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(160f)
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun buttonShowsWhenScrolledUpMeaningfully() {
        // 400px is well past buttonVisibleThresholdPx (160px) → full alpha.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(400f)
        assertTrue(m.showScrollToBottomButton)
        assertEquals("fully ramped past a band's worth", 1f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun alphaRampsBetweenVisibleThresholdAndFullBand() {
        // Half a band past buttonVisibleThresholdPx → ~0.5 alpha.
        // With near=80, visible=160, ramp band=80: at 200px:
        //   over = 200 - 160 = 40; ramp = 80; alpha = 40/80 = 0.5
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(200f)
        assertTrue(m.showScrollToBottomButton)
        assertEquals(0.5f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun overscrollPastBottomKeepsButtonHidden() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onBottomProximityChanged(-50f) // clamped to 0
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun customButtonVisibleThresholdIsHonoured() {
        // Explicit buttonVisibleThresholdPx overrides the 2× default.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f, buttonVisibleThresholdPx = 50f)
            .onUserDragged()
            .onBottomProximityChanged(100f)
        assertTrue(m.showScrollToBottomButton)
    }
}
