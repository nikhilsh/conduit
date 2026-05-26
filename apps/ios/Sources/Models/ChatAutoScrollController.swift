import Foundation

/// Pure-data state machine that decides whether the chat list should
/// auto-scroll to the latest message (task #39).
///
/// The hard problem this solves: while the agent is streaming we want
/// the view to *follow the stream* and keep the latest text pinned to
/// the bottom — but the moment the user drags up to read scrollback we
/// must stop yanking them back down. The naive "scroll to last item on
/// every change" approach fights the user constantly.
///
/// The controller owns no views and performs no side-effects beyond
/// mutating its own value-type state, so it's exercised directly by
/// unit tests with no SwiftUI host. The view layer feeds it three
/// kinds of signal:
///
///   - `userDragged()`            — a drag gesture began. Latches
///                                  `userScrolledUp` (pessimistically:
///                                  we assume any drag is an intent to
///                                  read back, then clear it once the
///                                  user lands near the bottom again).
///   - `bottomProximityChanged(_:)` — the live distance from the bottom
///                                  edge in points. Crossing back inside
///                                  `nearBottomThreshold` clears the
///                                  scrolled-up latch.
///   - `streamingContentChanged()` / `streamingDidEnd()` — drive the
///                                  follow-the-stream behaviour.
///
/// After each signal the view asks `shouldScrollToBottom` to learn
/// whether to issue a `proxy.scrollTo(...)`.
struct ChatAutoScrollController: Equatable {

    /// Distance (in points) from the bottom edge within which we treat
    /// the list as "pinned to the bottom" and resume auto-follow. ~80pt
    /// is roughly two lines of chat body + padding — close enough that
    /// the user clearly wants the latest, far enough that a one-line
    /// overscroll bounce doesn't re-arm follow mid-read.
    let nearBottomThreshold: CGFloat

    /// Distance (in points) past which the scroll-to-bottom button
    /// fades IN. Larger than `nearBottomThreshold` so the button only
    /// appears once the user has scrolled up a *meaningful* amount, and
    /// a tiny overscroll bounce past the bottom never flashes it on.
    /// (BUG 2: the button used to show ~always — tied to the
    /// `userScrolledUp` latch — and shifted with content.)
    let buttonVisibleThreshold: CGFloat

    /// Latched when the user drags the list. While set, streaming and
    /// new-message arrivals do NOT auto-scroll. Cleared when the user
    /// returns within `nearBottomThreshold` of the bottom.
    private(set) var userScrolledUp: Bool = false

    /// Most recent measured distance from the bottom edge. Seeded large
    /// so a controller that has never been measured doesn't claim to be
    /// pinned to the bottom.
    private(set) var distanceFromBottom: CGFloat = .greatestFiniteMagnitude

    /// Whether the view has reported a real distance-from-bottom yet.
    /// Until it has, `distanceFromBottom` is the synthetic large seed,
    /// which would otherwise make the button show on a fresh/empty chat.
    private(set) var hasMeasuredProximity: Bool = false

    init(nearBottomThreshold: CGFloat = 80, buttonVisibleThreshold: CGFloat = 160) {
        self.nearBottomThreshold = nearBottomThreshold
        self.buttonVisibleThreshold = buttonVisibleThreshold
    }

    /// `true` when the list is currently within the near-bottom band.
    var isNearBottom: Bool { distanceFromBottom <= nearBottomThreshold }

    /// `true` when the scroll-to-bottom affordance should show. BUG 2:
    /// once we have a real measurement this is driven by *distance from
    /// the bottom*, not the `userScrolledUp` latch — the button fades out
    /// as soon as the user is practically at the bottom (within
    /// `buttonVisibleThreshold`), and a tiny overscroll past the bottom
    /// keeps it hidden. It only appears once the user has scrolled up a
    /// meaningful amount.
    ///
    /// Before the view has measured anything (`distanceFromBottom` is
    /// still the synthetic large seed) we fall back to the drag latch, so
    /// a fresh/unmeasured controller shows no button and a deliberate
    /// drag still surfaces it immediately.
    var showScrollToBottomButton: Bool {
        guard hasMeasuredProximity else { return userScrolledUp }
        return distanceFromBottom > buttonVisibleThreshold
    }

    // MARK: - Signals

    /// The user began a drag. We latch `userScrolledUp` regardless of
    /// the current position: a deliberate finger-down is the strongest
    /// signal that the user wants manual control. If they were already
    /// at the bottom the next `bottomProximityChanged` (still near the
    /// bottom) immediately clears the latch, so a tap-and-release at the
    /// bottom doesn't strand them out of follow mode.
    mutating func userDragged() {
        userScrolledUp = true
    }

    /// Feed the live distance-from-bottom. Returns `true` if this update
    /// re-armed auto-follow (i.e. the user scrolled back to the bottom),
    /// which the caller may use to trigger a settle-scroll.
    @discardableResult
    mutating func bottomProximityChanged(_ distance: CGFloat) -> Bool {
        distanceFromBottom = max(0, distance)
        hasMeasuredProximity = true
        if userScrolledUp && isNearBottom {
            userScrolledUp = false
            return true
        }
        return false
    }

    /// Programmatic jump to bottom (FAB tap, or a fresh send): clear the
    /// latch and treat the list as pinned.
    mutating func scrollToBottomRequested() {
        userScrolledUp = false
        distanceFromBottom = 0
        hasMeasuredProximity = true
    }

    // MARK: - Queries

    /// Whether a streaming-content update should auto-scroll. We follow
    /// the stream only when the user hasn't scrolled away.
    var shouldFollowStreaming: Bool { !userScrolledUp }

    /// Whether the arrival of a brand-new message (e.g. the user's own
    /// send, or a fresh assistant turn) should auto-scroll. Same rule as
    /// streaming, but split out so the view can choose a different
    /// animation for "new turn" vs "streaming token".
    var shouldFollowNewMessage: Bool { !userScrolledUp }
}
