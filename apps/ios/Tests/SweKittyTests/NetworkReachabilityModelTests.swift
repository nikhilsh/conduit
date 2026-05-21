import Testing
import Foundation
@testable import SweKitty

/// Pure-data tests for `ReachabilityStatus` + the transition policy
/// that drives the WS-reconnect signal in A.9 ("reachability-observer").
/// We don't spin up `NWPathMonitor` here — the live monitor is exercised
/// implicitly at app launch by `SweKittyApp`; this suite locks the
/// state machine so a future "tighten transitions" refactor can't
/// silently break LTE↔Wi-Fi roaming.
@Suite("NetworkReachability")
struct NetworkReachabilityModelTests {

    // MARK: - Status helpers

    @Test func unknownIsNotSatisfied() {
        #expect(ReachabilityStatus.unknown.isSatisfied == false)
        #expect(ReachabilityStatus.unknown.interface == nil)
    }

    @Test func unsatisfiedIsNotSatisfied() {
        #expect(ReachabilityStatus.unsatisfied.isSatisfied == false)
        #expect(ReachabilityStatus.unsatisfied.interface == nil)
    }

    @Test func satisfiedExposesInterface() {
        let s: ReachabilityStatus = .satisfied(.wifi)
        #expect(s.isSatisfied == true)
        #expect(s.interface == .wifi)
    }

    // MARK: - Initial subscription (unknown → satisfied)

    @Test func firstSatisfiedAfterUnknownDoesNotFire() {
        // NWPathMonitor delivers a current snapshot immediately after
        // .start(). Treating that as a "reconnect" would dial the
        // server twice at launch — once from connect(), once from the
        // bogus reachable edge. The state machine must swallow the
        // first transition out of .unknown.
        let events = NetworkReachabilityObserver.events(
            from: .unknown,
            to: .satisfied(.wifi),
        )
        #expect(events.isEmpty)
    }

    @Test func unknownToUnsatisfiedIsSilent() {
        let events = NetworkReachabilityObserver.events(
            from: .unknown,
            to: .unsatisfied,
        )
        #expect(events.isEmpty)
    }

    // MARK: - The reconnect-worthy edges

    @Test func unsatisfiedToSatisfiedPostsBecameReachable() {
        let events = NetworkReachabilityObserver.events(
            from: .unsatisfied,
            to: .satisfied(.wifi),
        )
        #expect(events == [.networkBecameReachable])
    }

    @Test func unsatisfiedToSatisfiedCellularPostsBecameReachable() {
        // The interface doesn't matter for the "came back online" edge
        // — only the satisfied/unsatisfied flip does.
        let events = NetworkReachabilityObserver.events(
            from: .unsatisfied,
            to: .satisfied(.cellular),
        )
        #expect(events == [.networkBecameReachable])
    }

    @Test func wifiToCellularPostsInterfaceChanged() {
        // LTE↔Wi-Fi roaming. The socket is bound to the old interface
        // and will silently time out — we need to drop+redial.
        let events = NetworkReachabilityObserver.events(
            from: .satisfied(.wifi),
            to: .satisfied(.cellular),
        )
        #expect(events == [.networkInterfaceChanged])
    }

    @Test func cellularToWifiPostsInterfaceChanged() {
        let events = NetworkReachabilityObserver.events(
            from: .satisfied(.cellular),
            to: .satisfied(.wifi),
        )
        #expect(events == [.networkInterfaceChanged])
    }

    @Test func wiredToWifiPostsInterfaceChanged() {
        let events = NetworkReachabilityObserver.events(
            from: .satisfied(.wired),
            to: .satisfied(.wifi),
        )
        #expect(events == [.networkInterfaceChanged])
    }

    // MARK: - Quiet edges (no reconnect)

    @Test func goingOfflineIsSilent() {
        // We don't fire when the network drops — nothing to reconnect
        // to. The Rust core's heartbeat handles the offline → failed
        // transition on its own timeline.
        let events = NetworkReachabilityObserver.events(
            from: .satisfied(.wifi),
            to: .unsatisfied,
        )
        #expect(events.isEmpty)
    }

    @Test func sameInterfaceIsSilent() {
        // Path snapshots can repeat — e.g. Wi-Fi router renegotiates
        // a lease but doesn't actually change the active interface.
        // No reconnect, no notification.
        let events = NetworkReachabilityObserver.events(
            from: .satisfied(.wifi),
            to: .satisfied(.wifi),
        )
        #expect(events.isEmpty)
    }

    @Test func unsatisfiedToUnsatisfiedIsSilent() {
        let events = NetworkReachabilityObserver.events(
            from: .unsatisfied,
            to: .unsatisfied,
        )
        #expect(events.isEmpty)
    }

    // MARK: - apply() integration

    @MainActor
    @Test func applyPostsCorrectNotificationOnReachableEdge() async {
        // Drives the observer through a deterministic transition and
        // confirms the public-facing `status` flips + the
        // NotificationCenter listener fires exactly once.
        let observer = NetworkReachabilityObserver()
        observer.apply(.unsatisfied)
        let exp = await waitForNotification(.networkBecameReachable) {
            observer.apply(.satisfied(.wifi))
        }
        #expect(exp == true)
        #expect(observer.status == .satisfied(.wifi))
    }

    @MainActor
    @Test func applyIsIdempotentOnNoChange() async {
        let observer = NetworkReachabilityObserver()
        observer.apply(.satisfied(.wifi))
        // Re-applying the same state must not refire the interface
        // change notification — that'd cause runaway reconnect loops
        // on a noisy path-update stream.
        let fired = await waitForNotification(
            .networkInterfaceChanged,
            timeout: 0.05,
        ) {
            observer.apply(.satisfied(.wifi))
        }
        #expect(fired == false)
    }

    // MARK: - Helpers

    /// Block, with a short timeout, until `name` is posted on the
    /// default center. Returns false on timeout so tests can assert
    /// "did NOT fire" cases.
    @MainActor
    private func waitForNotification(
        _ name: Notification.Name,
        timeout: TimeInterval = 0.5,
        trigger: () -> Void,
    ) async -> Bool {
        var observer: NSObjectProtocol?
        let received = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var finished = false
            observer = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main,
            ) { _ in
                if !finished {
                    finished = true
                    cont.resume(returning: true)
                }
            }
            trigger()
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
                if !finished {
                    finished = true
                    cont.resume(returning: false)
                }
            }
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        return received
    }
}
