import Testing
import Foundation
@testable import SweKitty

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
}
