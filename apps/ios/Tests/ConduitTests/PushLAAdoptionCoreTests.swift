import Testing
@testable import Conduit

/// Covers `PushLAAdoptionCore.decide` -- the pure decision step
/// `TurnLiveActivityController.adoptPushStartedActivities()` runs for every
/// `Activity` it discovers, on EVERY foreground (not just app launch).
///
/// Root cause this guards against (Sentry: "push-to-start adoption: update
/// token not registered within 30s" / `ios.push_la` Code 1): adoption used
/// to run once at first launch, gated by an `activeActivityIDs[sid] == nil`
/// check that also gated the update-token *observation* loop. A
/// push-started activity created while the app was merely backgrounded
/// (not relaunched) either never got observed at all, or its single 30s
/// observation window could elapse while the app had no foreground
/// execution time -- and a hard Sentry error fired for what is a
/// perfectly recoverable, expected miss. `decide` separates "should we
/// seed/adopt this session" from "should we (re)start observing its
/// update token", so a session that's already adopted but still missing
/// its token gets retried on the next foreground instead of being treated
/// as a terminal failure.
@Suite("PushLAAdoptionCore.decide")
struct PushLAAdoptionCoreTests {
    @Test func neverSeenSessionAdoptsAndObserves() {
        let decision = PushLAAdoptionCore.decide(
            alreadyAdopted: false, tokenAlreadyReceived: false
        )
        #expect(decision.shouldAdopt)
        #expect(decision.shouldObserveToken)
        #expect(!decision.isReArm)
    }

    @Test func adoptedButTokenMissingReArmsObservationOnly() {
        let decision = PushLAAdoptionCore.decide(
            alreadyAdopted: true, tokenAlreadyReceived: false
        )
        #expect(!decision.shouldAdopt)
        #expect(decision.shouldObserveToken)
        #expect(decision.isReArm)
    }

    @Test func adoptedWithTokenReceivedIsSteadyStateNoop() {
        let decision = PushLAAdoptionCore.decide(
            alreadyAdopted: true, tokenAlreadyReceived: true
        )
        #expect(!decision.shouldAdopt)
        #expect(!decision.shouldObserveToken)
        #expect(!decision.isReArm)
    }

    /// Not reachable in practice (a session only has a received token once
    /// it's been adopted), but the decision must still not be treated as a
    /// "first observe" when the token has already arrived.
    @Test func tokenReceivedWithoutPriorAdoptionStillSkipsObserve() {
        let decision = PushLAAdoptionCore.decide(
            alreadyAdopted: false, tokenAlreadyReceived: true
        )
        #expect(decision.shouldAdopt)
        #expect(!decision.shouldObserveToken)
        #expect(!decision.isReArm)
    }
}
