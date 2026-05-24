import Foundation
import Observation

/// Intent the bridge wants the live-activity controller to apply, in
/// terms of the controller's public verbs. Sits between the pure
/// "diff the store" step and the side-effecting `Activity.request` /
/// `Activity.update` / `Activity.end` calls so the diff logic stays
/// unit-testable without any ActivityKit / SessionStore plumbing.
public enum TurnLiveActivityIntent: Equatable {
    /// A new tool/command item should drive the activity. The
    /// controller decides start-vs-update based on its own per-session
    /// state — the bridge doesn't need to know which.
    case observe(sessionID: String, agentName: String, item: TurnActivityItem)
    /// Session has exited (lifecycle exit, status frame, or 5 s idle
    /// past the last tool item). The controller ends the activity.
    case end(sessionID: String)
    /// Periodic tick so the controller can fire its own idle-timeout
    /// path for sessions that fell silent without a fresh item.
    case tick
}

/// Pure-data view of the SessionStore slice the bridge cares about.
/// Lifted into its own type so unit tests can build a sequence of
/// frames and drive the bridge core deterministically — no
/// `@Observable` plumbing, no SessionStore, no Activity calls.
public struct TurnLiveActivityFrame: Equatable {
    public struct Session: Equatable {
        public var sessionID: String
        public var agentName: String
        /// Phase string from SessionStatus, e.g. "running",
        /// "exited(0)", "exited". Matches the shape ingestExit
        /// writes into statusBySession.
        public var phase: String?
        public var conversation: [TurnActivityItem]

        public init(
            sessionID: String,
            agentName: String,
            phase: String?,
            conversation: [TurnActivityItem]
        ) {
            self.sessionID = sessionID
            self.agentName = agentName
            self.phase = phase
            self.conversation = conversation
        }
    }

    public var sessions: [Session]

    public init(sessions: [Session]) {
        self.sessions = sessions
    }
}

/// Pure state-machine core for the bridge. Decides which intents to
/// emit given a new frame from the store + the wall clock for idle
/// timing. Owns no Activity calls — the bridge's outer shell pipes
/// intents into `TurnLiveActivityController`.
///
/// Idle policy: 5 s after the most recent tool/command item for a
/// session, emit `.end`. Mirrors `TurnActivityModel.defaultIdleTimeout`
/// so the bridge and the per-session model agree on the closing edge.
/// Either side firing first is fine — the controller's `ingest` /
/// `sessionExited` paths are idempotent.
public struct TurnLiveActivityBridgeCore {
    public static let defaultIdleTimeout: TimeInterval = TurnActivityModel.defaultIdleTimeout

    /// Last observed conversation-item id per session, so a re-emit of
    /// the same item (idempotent ingest) doesn't replay an `.observe`.
    public private(set) var lastSeenItemID: [String: String] = [:]
    /// Last observed phase per session, so we only emit `.end` on the
    /// edge into "exited", not on every status frame that carries it.
    public private(set) var lastSeenPhase: [String: String] = [:]
    /// Wall-clock timestamp of the most recent tool/command emission
    /// per session — input to the idle-timeout decision.
    public private(set) var lastActivityAt: [String: Date] = [:]
    /// Sessions we've already ended once. Stays set until a fresh tool
    /// item arrives (which clears the entry on observe). Prevents the
    /// idle-tick path from emitting `.end` repeatedly.
    public private(set) var endedSessions: Set<String> = []

    public let idleTimeout: TimeInterval

    public init(idleTimeout: TimeInterval = TurnLiveActivityBridgeCore.defaultIdleTimeout) {
        self.idleTimeout = idleTimeout
    }

    /// Fold a fresh store frame into the bridge state and return the
    /// intents the controller should apply, in order.
    public mutating func ingest(frame: TurnLiveActivityFrame, now: Date) -> [TurnLiveActivityIntent] {
        var intents: [TurnLiveActivityIntent] = []
        for session in frame.sessions {
            let sid = session.sessionID

            // Exit edge: a fresh "exited..." phase ends the activity
            // independent of whether the conversation log carried an
            // `.exit` row. The controller already collapses both.
            if let phase = session.phase, phase.hasPrefix("exited") {
                let prev = lastSeenPhase[sid]
                lastSeenPhase[sid] = phase
                if prev != phase, !endedSessions.contains(sid) {
                    intents.append(.end(sessionID: sid))
                    endedSessions.insert(sid)
                    // Don't fall through into the conversation-log
                    // scan — the session is dead, any stragglers in
                    // the log were already in flight.
                    continue
                }
            } else if let phase = session.phase {
                lastSeenPhase[sid] = phase
            }

            // Walk the conversation forward. Once we've passed the
            // last-seen id, every fresh tool/command/exit drives one
            // intent. Plain `.message` rows don't surface.
            let conversation = session.conversation
            var pastLastSeen = (lastSeenItemID[sid] == nil)
            for item in conversation {
                if !pastLastSeen {
                    if item.id == lastSeenItemID[sid] {
                        pastLastSeen = true
                    }
                    continue
                }
                if item.kind == .tool || item.kind == .command {
                    intents.append(.observe(
                        sessionID: sid,
                        agentName: session.agentName,
                        item: item
                    ))
                    lastActivityAt[sid] = item.timestamp
                    endedSessions.remove(sid)
                } else if item.kind == .exit {
                    if !endedSessions.contains(sid) {
                        intents.append(.end(sessionID: sid))
                        endedSessions.insert(sid)
                    }
                }
                lastSeenItemID[sid] = item.id
            }
            // NOTE: we deliberately do NOT seed lastSeenItemID for an
            // empty first frame. Seeding it to "" strands the session:
            // the cursor-walk above skips every item up to and including
            // `lastSeenItemID`, and since no real item has id "", a "" seed
            // would skip all future items — so the activity never starts
            // for a session whose first observed frame was empty (common,
            // since a session appears in statusBySession before its first
            // tool item). Leaving the cursor unset means the next non-empty
            // frame is processed from the start. Matches the Android port
            // in `TurnActivityBridgeCore` (PR #151).
        }

        // Idle-timeout sweep: any session that's past the window
        // without a fresh tool item and hasn't already been ended.
        for (sid, last) in lastActivityAt {
            guard !endedSessions.contains(sid) else { continue }
            if now.timeIntervalSince(last) >= idleTimeout {
                intents.append(.end(sessionID: sid))
                endedSessions.insert(sid)
            }
        }

        // The controller runs its own per-session idle ticker too —
        // surface a `.tick` so it can close anything the bridge isn't
        // tracking (e.g. activity started before the bridge attached).
        intents.append(.tick)
        return intents
    }
}

/// Outer shell that wires the bridge core to `SessionStore` + the
/// `TurnLiveActivityController`. Owns:
///   - a weak ref to the store (the bridge lives for the app's
///     lifetime — same scope as the store — but weak keeps the
///     ownership graph one-way and survives a test-time tear-down),
///   - an observation re-subscribe loop driven by
///     `withObservationTracking` so changes to the store's typed
///     conversation log + per-session status fan into one diff,
///   - a 1-second polling timer that nudges the idle-timeout path —
///     the store doesn't emit a change when wall-clock time advances,
///     so without the timer a turn that ends silently would sit on
///     the lock screen until the next unrelated store change.
@MainActor
public final class TurnLiveActivityBridge {
    private weak var store: SessionStore?
    private let controller: TurnLiveActivityController
    private var core: TurnLiveActivityBridgeCore
    private var idleTimer: Timer?

    /// Cadence at which we re-evaluate idle timeouts. Faster than
    /// the timeout itself so the close edge lands within ~1 s of the
    /// real boundary; slow enough not to wake the main runloop every
    /// frame on devices where the user isn't actively in a session.
    public static let defaultIdleTickInterval: TimeInterval = 1

    // Class is public so tests can @testable-import it; the init
    // takes an internal `TurnLiveActivityController`, so it must be
    // internal too (Swift rejects a public init whose parameter
    // types are internal). Constructors at the SweKittyApp call site
    // live in the same module, so the access drop is invisible
    // outside tests.
    init(
        store: SessionStore,
        controller: TurnLiveActivityController = .shared,
        idleTimeout: TimeInterval = TurnLiveActivityBridgeCore.defaultIdleTimeout
    ) {
        self.store = store
        self.controller = controller
        self.core = TurnLiveActivityBridgeCore(idleTimeout: idleTimeout)
    }

    /// Start observing the store + arm the idle timer. Idempotent —
    /// calling twice rearms cleanly.
    public func start() {
        scheduleObservation()
        idleTimer?.invalidate()
        let timer = Timer(timeInterval: Self.defaultIdleTickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        idleTimer = timer
    }

    public func stop() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    /// Re-subscribe to the store's `@Observable` keypaths. SwiftUI
    /// uses the same `withObservationTracking` primitive under the
    /// hood; calling it manually here lets a non-view object listen
    /// for the exact slice it cares about without a Combine subject.
    private func scheduleObservation() {
        guard let store else { return }
        withObservationTracking {
            // Reads inside this block register the keypaths. The
            // change handler fires once on the *first* mutation of
            // any of them, at which point we re-evaluate and
            // re-subscribe.
            _ = store.conversationLog
            _ = store.statusBySession
            _ = store.sessionLifecycle
            _ = store.sessions
        } onChange: { [weak self] in
            // onChange fires on a background actor by contract. Hop
            // back to the main actor before touching the store.
            Task { @MainActor [weak self] in
                self?.evaluate()
                self?.scheduleObservation()
            }
        }
    }

    /// Build a frame from the current store snapshot, fold it through
    /// the bridge core, and apply the resulting intents.
    private func evaluate() {
        guard let store else { return }
        let frame = Self.frame(from: store)
        let intents = core.ingest(frame: frame, now: Date())
        for intent in intents {
            apply(intent: intent)
        }
    }

    /// Project the store's typed maps + lifecycle dictionary into the
    /// pure-data frame shape the bridge core consumes. Pulled out so
    /// tests can exercise the same projection without standing up a
    /// SessionStore.
    static func frame(from store: SessionStore) -> TurnLiveActivityFrame {
        var sessions: [TurnLiveActivityFrame.Session] = []
        // Union of every session id the store knows about — running,
        // exited, or pending — so we don't miss a tool fired while the
        // user is on a different tab.
        var ids = Set(store.conversationLog.keys)
        for s in store.sessions { ids.insert(s.id) }
        for sid in store.statusBySession.keys { ids.insert(sid) }
        for sid in store.sessionLifecycle.keys { ids.insert(sid) }

        for sid in ids.sorted() {
            let session = store.sessions.first(where: { $0.id == sid })
            let agentName = session?.assistant
                ?? store.statusBySession[sid]?.assistant
                ?? "agent"
            let phase: String?
            if case let .exited(code) = store.sessionLifecycle[sid] {
                phase = "exited(\(code))"
            } else {
                phase = store.statusBySession[sid]?.phase
            }
            let conversation = (store.conversationLog[sid] ?? [])
                .compactMap(TurnLiveActivityMapping.map)
            sessions.append(
                TurnLiveActivityFrame.Session(
                    sessionID: sid,
                    agentName: agentName,
                    phase: phase,
                    conversation: conversation
                )
            )
        }
        return TurnLiveActivityFrame(sessions: sessions)
    }

    private func apply(intent: TurnLiveActivityIntent) {
        switch intent {
        case let .observe(sessionID, agentName, item):
            controller.observe(item: item, in: sessionID, agentName: agentName)
        case let .end(sessionID):
            controller.sessionExited(sessionID: sessionID)
        case .tick:
            controller.tickAll()
        }
    }

}
