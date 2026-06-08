import Testing
import Foundation
@testable import Conduit

/// Pure-data tests for the streaming auto-scroll state machine
/// (task #39). The controller decides whether the chat list should
/// follow the stream / new messages, and whether the scroll-to-bottom
/// affordance shows — all without yanking a user who scrolled up.
@Suite("ChatAutoScrollController")
struct ChatAutoScrollControllerTests {

    @Test func defaultsToFollowingAndNoFAB() {
        let c = ChatAutoScrollController()
        #expect(c.shouldFollowStreaming)
        #expect(c.shouldFollowNewMessage)
        #expect(!c.showScrollToBottomButton)
        #expect(!c.userScrolledUp)
    }

    @Test func freshControllerIsNotAssumedNearBottom() {
        // distanceFromBottom seeds large so an unmeasured controller
        // doesn't claim the user is pinned to the bottom.
        let c = ChatAutoScrollController()
        #expect(!c.isNearBottom)
    }

    @Test func dragLatchesScrolledUpAndStopsFollow() {
        var c = ChatAutoScrollController()
        c.userDragged()
        #expect(c.userScrolledUp)
        #expect(!c.shouldFollowStreaming)
        #expect(!c.shouldFollowNewMessage)
        #expect(c.showScrollToBottomButton)
    }

    @Test func returningNearBottomRearmsFollow() {
        var c = ChatAutoScrollController(nearBottomThreshold: 80)
        c.userDragged()
        // Scroll back to within the band — follow re-arms.
        let rearmed = c.bottomProximityChanged(40)
        #expect(rearmed)
        #expect(!c.userScrolledUp)
        #expect(c.shouldFollowStreaming)
        #expect(!c.showScrollToBottomButton)
    }

    @Test func stayingAboveThresholdKeepsLatch() {
        var c = ChatAutoScrollController(nearBottomThreshold: 80)
        c.userDragged()
        let rearmed = c.bottomProximityChanged(200)
        #expect(!rearmed)
        #expect(c.userScrolledUp)
        #expect(!c.shouldFollowStreaming)
    }

    @Test func thresholdIsInclusive() {
        var c = ChatAutoScrollController(nearBottomThreshold: 80)
        c.userDragged()
        // Exactly at the threshold counts as near-bottom.
        let nearAt80 = c.bottomProximityChanged(80)
        #expect(nearAt80)
        #expect(!c.userScrolledUp)
    }

    @Test func proximityWhileFollowingDoesNotRearmRedundantly() {
        // Not scrolled up → bottomProximityChanged returns false (it only
        // reports a *transition* back into follow), but state stays sane.
        var c = ChatAutoScrollController()
        let rearmed = c.bottomProximityChanged(10)
        #expect(!rearmed)
        #expect(!c.userScrolledUp)
        #expect(c.isNearBottom)
    }

    @Test func scrollToBottomRequestedClearsLatchAndPins() {
        var c = ChatAutoScrollController()
        c.userDragged()
        _ = c.bottomProximityChanged(500) // still scrolled up
        c.scrollToBottomRequested()
        #expect(!c.userScrolledUp)
        #expect(c.isNearBottom)
        #expect(c.shouldFollowStreaming)
    }

    @Test func negativeOverscrollIsClampedToZero() {
        // Rubber-band overscroll past the bottom reports a negative
        // distance; clamp so it still reads as near-bottom, not as a
        // huge distance.
        var c = ChatAutoScrollController(nearBottomThreshold: 80)
        c.userDragged()
        let nearOverscroll = c.bottomProximityChanged(-30)
        #expect(nearOverscroll)
        #expect(c.distanceFromBottom == 0)
        #expect(c.isNearBottom)
    }

    // MARK: - Scroll-to-bottom button visibility (BUG 2)

    @Test func buttonHiddenWhenPracticallyAtBottom() {
        // BUG 2: the button fades out when the user is practically at
        // the bottom (within buttonVisibleThreshold), even after a drag.
        var c = ChatAutoScrollController(nearBottomThreshold: 80, buttonVisibleThreshold: 160)
        c.userDragged()
        _ = c.bottomProximityChanged(20) // basically at bottom
        #expect(!c.showScrollToBottomButton)
    }

    @Test func buttonShownAfterScrollingUpMeaningfully() {
        var c = ChatAutoScrollController(nearBottomThreshold: 80, buttonVisibleThreshold: 160)
        _ = c.bottomProximityChanged(400) // scrolled well up
        #expect(c.showScrollToBottomButton)
    }

    @Test func tinyOverscrollPastBottomKeepsButtonHidden() {
        // A rubber-band overscroll reports a negative distance; it must
        // not flash the button on.
        var c = ChatAutoScrollController(buttonVisibleThreshold: 160)
        _ = c.bottomProximityChanged(-40)
        #expect(!c.showScrollToBottomButton)
    }

    @Test func buttonHiddenBetweenNearBottomAndVisibleThreshold() {
        // 120pt is past the near-bottom band (80) but inside the
        // button-visible band (160), so the button stays hidden — it
        // only appears once the user scrolls a meaningful amount.
        var c = ChatAutoScrollController(nearBottomThreshold: 80, buttonVisibleThreshold: 160)
        _ = c.bottomProximityChanged(120)
        #expect(!c.showScrollToBottomButton)
    }

    @Test func scrollToBottomRequestedHidesButton() {
        var c = ChatAutoScrollController(buttonVisibleThreshold: 160)
        _ = c.bottomProximityChanged(500)
        #expect(c.showScrollToBottomButton)
        c.scrollToBottomRequested()
        #expect(!c.showScrollToBottomButton)
    }

    @Test func customThresholdIsHonoured() {
        var c = ChatAutoScrollController(nearBottomThreshold: 20)
        c.userDragged()
        // 40pt is outside a 20pt band → stays scrolled up.
        let near40 = c.bottomProximityChanged(40)
        #expect(!near40)
        #expect(c.userScrolledUp)
        // 15pt is inside → re-arms.
        let near15 = c.bottomProximityChanged(15)
        #expect(near15)
        #expect(!c.userScrolledUp)
    }

    /// With the corrected scroll-distance formula (no double-counted
    /// `contentInsets.bottom`), the resting distance at the genuine bottom
    /// is ≤ 0. Verify the button stays hidden at zero and at small negative
    /// distances that arise from rubber-band overscroll (#251 follow-up).
    @Test func buttonHiddenAtNearZeroRestingDistance() {
        var c = ChatAutoScrollController(nearBottomThreshold: 80, buttonVisibleThreshold: 160)
        _ = c.bottomProximityChanged(0)
        #expect(!c.showScrollToBottomButton)
        _ = c.bottomProximityChanged(-10) // overscroll → clamped to 0
        #expect(!c.showScrollToBottomButton)
    }

    // MARK: - Proximity banding (long-chat overheat fix)

    /// The scroll observer forwards to the controller only when the
    /// band changes. Pin that the three bands map to the thresholds, so
    /// a scroll WITHIN a band produces no state write (no body
    /// invalidation per frame).
    @Test func proximityBandsMapToThresholds() {
        let c = ChatAutoScrollController(nearBottomThreshold: 80, buttonVisibleThreshold: 160)
        #expect(c.proximityBand(for: 0) == 0)
        #expect(c.proximityBand(for: 80) == 0)   // inclusive near-bottom
        #expect(c.proximityBand(for: 81) == 1)
        #expect(c.proximityBand(for: 160) == 1)  // inclusive button band
        #expect(c.proximityBand(for: 161) == 2)
        #expect(c.proximityBand(for: 9999) == 2)
        // Every distance inside a band yields the SAME band — that's what
        // lets the view gate the per-frame @State write.
        #expect(c.proximityBand(for: 500) == c.proximityBand(for: 5000))
    }
}
