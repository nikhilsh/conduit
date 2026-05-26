package sh.nikhil.swekitty.ui

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

    // --- Bug 2: button visibility is distance-driven, with a fade ---

    @Test fun buttonHiddenWhenPracticallyAtBottom() {
        // Pinned / tiny overscroll inside the band → button faded out.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onBottomProximityChanged(10f)
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun buttonHiddenExactlyAtThreshold() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onBottomProximityChanged(80f)
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun buttonShowsWhenScrolledUpMeaningfully() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(400f)
        assertTrue(m.showScrollToBottomButton)
        assertEquals("fully ramped past a band's worth", 1f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun alphaRampsBetweenThresholdAndFullBand() {
        // Half a band past the threshold → ~0.5 alpha.
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onUserDragged()
            .onBottomProximityChanged(120f) // 40px over threshold, band=80
        assertTrue(m.showScrollToBottomButton)
        assertEquals(0.5f, m.scrollToBottomButtonAlpha, 0.001f)
    }

    @Test fun overscrollPastBottomKeepsButtonHidden() {
        val m = ChatAutoScrollModel(nearBottomThresholdPx = 80f)
            .onBottomProximityChanged(-50f) // clamped to 0
        assertFalse(m.showScrollToBottomButton)
        assertEquals(0f, m.scrollToBottomButtonAlpha, 0.001f)
    }
}
