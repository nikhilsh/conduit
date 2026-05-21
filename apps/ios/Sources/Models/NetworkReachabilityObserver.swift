import Foundation
import Network
import Observation

/// Coarse-grained reachability state surfaced from `NWPathMonitor`. The
/// SessionStore only ever needs to know "did the network just come back
/// or change interface" so we collapse the rich `NWPath` into four
/// buckets and a single satisfied-with-interface enum.
enum ReachabilityStatus: Equatable {
    case unknown
    case unsatisfied
    case satisfied(Interface)

    /// Mirrors the subset of `NWInterface.InterfaceType` we care about
    /// for the immediate-reconnect heuristic. Anything we don't
    /// recognise (loopback, etc.) maps to `.other`.
    enum Interface: Equatable {
        case wifi
        case cellular
        case wired
        case other
    }

    /// True iff the network is currently considered reachable. Useful
    /// for `unsatisfied → satisfied` edge detection.
    var isSatisfied: Bool {
        if case .satisfied = self { return true }
        return false
    }

    /// The interface we're currently riding on, if any.
    var interface: Interface? {
        if case .satisfied(let iface) = self { return iface }
        return nil
    }
}

extension Notification.Name {
    /// Posted on the main queue when the path monitor transitions from
    /// `unsatisfied` (or unknown) → `satisfied`. SessionStore listens
    /// for this and asks the Rust core to drop its socket and retry
    /// instead of waiting for the heartbeat timeout to surface the
    /// previously-broken link.
    static let networkBecameReachable = Notification.Name("swekitty.networkBecameReachable")

    /// Posted when the network stays satisfied but the active interface
    /// changes (e.g. LTE → Wi-Fi roam, hotspot toggle, VPN flap). The
    /// existing socket is technically alive but bound to an interface
    /// the OS has already torn down underneath it — same remediation as
    /// `networkBecameReachable`.
    static let networkInterfaceChanged = Notification.Name("swekitty.networkInterfaceChanged")
}

/// Wraps `NWPathMonitor` behind an `@Observable` `status` property and a
/// pair of `NotificationCenter` events. Owners (the app root) keep one
/// instance for the process lifetime; consumers (SessionStore) subscribe
/// to the notifications and react with an immediate reconnect.
///
/// Why a separate observer instead of inlining the monitor inside
/// SessionStore? Two reasons:
///  1. Testability — the pure `ReachabilityStatus` state machine has its
///     own test suite without dragging the SessionStore + Rust core in.
///  2. Lifetime — `NWPathMonitor` is process-scoped; SessionStore is
///     theoretically replaceable. Hoisting the monitor out lets the
///     reconnect signal survive a SessionStore reset.
@Observable
@MainActor
final class NetworkReachabilityObserver {
    /// Current coarse status. Mutated on the main actor from inside
    /// the path-update callback after the bounce off the monitor queue.
    private(set) var status: ReachabilityStatus = .unknown

    // `nonisolated(unsafe)` so the (nonisolated) deinit can call
    // `monitor.cancel()` without crossing the actor boundary. The
    // monitor is hot-immutable after init and NWPathMonitor itself is
    // thread-safe for the operations we use (cancel / pathUpdateHandler
    // delivery on a dedicated queue), so the `unsafe` is justified.
    private nonisolated(unsafe) let monitor: NWPathMonitor
    private nonisolated(unsafe) let queue: DispatchQueue

    init(monitor: NWPathMonitor = NWPathMonitor(),
         queue: DispatchQueue = DispatchQueue(label: "swekitty.nwpath")) {
        self.monitor = monitor
        self.queue = queue
        self.monitor.pathUpdateHandler = { [weak self] path in
            let next = Self.classify(path)
            Task { @MainActor [weak self] in
                self?.apply(next)
            }
        }
        self.monitor.start(queue: queue)
    }

    deinit {
        // `NWPathMonitor.cancel()` is thread-safe per Apple's docs, so
        // a nonisolated deinit can release the OS-level subscription
        // even though `self` lives on the main actor.
        monitor.cancel()
    }

    /// Pure function: collapse an `NWPath` into our coarse status.
    /// `nonisolated` so the path-update callback (which fires on the
    /// monitor's own queue, not the main actor) can call it without a
    /// hop. Extracted so the test suite can drive transitions through
    /// `apply(_:)` without touching the live monitor.
    private nonisolated static func classify(_ path: NWPath) -> ReachabilityStatus {
        guard path.status == .satisfied else { return .unsatisfied }
        let iface: ReachabilityStatus.Interface
        if path.usesInterfaceType(.wifi) {
            iface = .wifi
        } else if path.usesInterfaceType(.cellular) {
            iface = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            iface = .wired
        } else {
            iface = .other
        }
        return .satisfied(iface)
    }

    /// Internal hook used by tests to drive transitions deterministically
    /// without spinning up `NWPathMonitor`. Mirrors what the real path
    /// handler does once it has classified the incoming `NWPath`.
    func apply(_ next: ReachabilityStatus) {
        let prev = status
        guard prev != next else { return }
        status = next
        for event in Self.events(from: prev, to: next) {
            NotificationCenter.default.post(name: event, object: nil)
        }
    }

    /// Pure state-machine: which (zero, one, or more) notifications
    /// should fire on a `prev → next` transition. `nonisolated` because
    /// it touches no instance state — exposed to tests so a future
    /// "tighten the reconnect policy" change has to defeat the suite
    /// rather than slipping through silently.
    nonisolated static func events(from prev: ReachabilityStatus,
                                   to next: ReachabilityStatus) -> [Notification.Name] {
        switch (prev, next) {
        // First-ever satisfied state after launch isn't a transition
        // worth a reconnect — there's nothing to reconnect yet.
        case (.unknown, .satisfied):
            return []
        case (.unknown, .unsatisfied), (.unknown, .unknown):
            return []
        // Came back online.
        case (.unsatisfied, .satisfied):
            return [.networkBecameReachable]
        // Went offline — no point posting; SessionStore can't dial out.
        case (.satisfied, .unsatisfied), (.unsatisfied, .unsatisfied):
            return []
        // Roamed between interfaces. The existing socket is bound to
        // the old interface and will silently 60s-timeout otherwise.
        case (.satisfied(let a), .satisfied(let b)) where a != b:
            return [.networkInterfaceChanged]
        // Same satisfied state — `apply` already filtered this, but
        // keeping the case explicit makes the switch exhaustive in a
        // future-proof way.
        case (.satisfied, .satisfied):
            return []
        case (_, .unknown):
            return []
        }
    }
}
