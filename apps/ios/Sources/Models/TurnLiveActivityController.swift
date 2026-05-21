import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
/// ActivityKit-facing attributes for the turn Live Activity.
///
/// Mirrors `TurnActivityAttributesData` / `TurnActivityContentState` from
/// the pure model so the same shape ships through the system. Split into
/// its own type because `ActivityAttributes` is only available with
/// ActivityKit imported — the model file stays portable and unit-testable.
public struct TurnActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var currentTool: String?
        public var currentCommand: String?
        public var startedAt: Date
        public var tokensIn: Int
        public var tokensOut: Int
        public var status: String

        public init(from state: TurnActivityContentState) {
            self.currentTool = state.currentTool
            self.currentCommand = state.currentCommand
            self.startedAt = state.startedAt
            self.tokensIn = state.tokensIn
            self.tokensOut = state.tokensOut
            self.status = state.status
        }
    }

    public var agentName: String
    public var sessionID: String

    public init(from data: TurnActivityAttributesData) {
        self.agentName = data.agentName
        self.sessionID = data.sessionID
    }
}
#endif

/// Bridges the `TurnActivityModel` state machine to ActivityKit.
///
/// Responsibilities:
///   - own a `TurnActivityModel` per session,
///   - subscribe to `SessionStore` changes (selected session + latest
///     conversation item) and feed them into the model,
///   - translate the model's `TurnActivityEffect`s into
///     `Activity.request` / `Activity.update` / `Activity.end` calls,
///   - persist the active `Activity.id` keyed by sessionID so we keep at
///     most one Live Activity per session even across re-binds.
///
/// **Scope note**: this PR ships the controller + state machine + tests.
/// The widget target (`SweKittyWidgets`) that renders the lock-screen card
/// + Dynamic Island is queued for the next PR — see the audit A.2 row.
/// Without the widget target the controller is functionally a no-op at
/// runtime on a real device, but it keeps the bridge code, lifecycle
/// hooks, and the `NSSupportsLiveActivities` plist key in tree so the
/// follow-up PR is a pure UI add.
@MainActor
public final class TurnLiveActivityController {
    /// Singleton shared with `SweKittyApp` — there's exactly one active-turn
    /// surface per device, so a global is the right shape.
    public static let shared = TurnLiveActivityController()

    /// Per-session state machine. Most installs see one entry (the active
    /// session) but we keep a dictionary so concurrent sessions on iPad
    /// don't trample each other.
    private var models: [String: TurnActivityModel] = [:]

    /// `Activity.id` keyed by sessionID. Used to enforce a single
    /// concurrent activity per session: if a `.start` effect arrives
    /// while an entry exists, we end the prior activity first.
    private var activeActivityIDs: [String: String] = [:]

    /// Last-seen conversation item id per session so re-emitting the same
    /// item (idempotent stream refresh) doesn't produce duplicate updates.
    private var lastSeenItemID: [String: String] = [:]

    /// Last-seen lifecycle phase per session for the session-exit signal.
    private var lastSeenPhase: [String: String] = [:]

    private init() {}

    /// Drive the controller from a `SessionStore` snapshot. Idempotent —
    /// safe to call on every store change.
    ///
    /// `conversationItem` is the most recent typed item the store is
    /// holding for the session, projected into the pure-data shape so
    /// this signature doesn't drag in the UniFFI types and break the
    /// build when ActivityKit isn't available.
    public func ingest(
        sessionID: String,
        agentName: String,
        latestItem: TurnActivityItem?,
        sessionPhase: String?
    ) {
        var model = models[sessionID, default: TurnActivityModel()]

        // Session-level exits end the activity even if the conversation
        // item stream hasn't surfaced an `.exit` row yet.
        if let phase = sessionPhase {
            let prev = lastSeenPhase[sessionID]
            lastSeenPhase[sessionID] = phase
            if phase.hasPrefix("exited") && prev != phase {
                let effect = model.sessionExited()
                apply(effect: effect, sessionID: sessionID)
                models[sessionID] = model
                return
            }
        }

        guard let item = latestItem else {
            models[sessionID] = model
            return
        }

        if lastSeenItemID[sessionID] == item.id {
            // Same item we already processed — only run the idle tick so a
            // long pause after the last tool still closes the activity.
            let effect = model.tick(now: Date())
            apply(effect: effect, sessionID: sessionID)
            models[sessionID] = model
            return
        }
        lastSeenItemID[sessionID] = item.id

        let effect = model.apply(item: item, sessionID: sessionID, agentName: agentName)
        apply(effect: effect, sessionID: sessionID)
        models[sessionID] = model
    }

    /// External "session was reaped" signal (user tapped Exit, or the
    /// harness reported `onExit`). Ends the activity without waiting for
    /// the idle timeout.
    public func sessionExited(sessionID: String) {
        guard var model = models[sessionID] else { return }
        let effect = model.sessionExited()
        apply(effect: effect, sessionID: sessionID)
        models[sessionID] = model
    }

    /// Periodic tick — called from a timer in the app or driven by the
    /// store's @Observable change feed. Closes activities that have been
    /// idle past their timeout.
    public func tickAll(now: Date = Date()) {
        for (sessionID, var model) in models {
            let effect = model.tick(now: now)
            apply(effect: effect, sessionID: sessionID)
            models[sessionID] = model
        }
    }

    // MARK: - Effect application

    private func apply(effect: TurnActivityEffect, sessionID: String) {
        switch effect {
        case .noop:
            return
        case let .start(attributes, state):
            startActivity(attributes: attributes, state: state, sessionID: sessionID)
        case let .update(state):
            updateActivity(state: state, sessionID: sessionID)
        case let .end(state):
            endActivity(state: state, sessionID: sessionID)
        }
    }

    private func startActivity(
        attributes: TurnActivityAttributesData,
        state: TurnActivityContentState,
        sessionID: String
    ) {
        #if canImport(ActivityKit)
        // Defensive: if a previous activity is still alive (e.g. app was
        // backgrounded mid-turn and a stale handle leaked), tear it down
        // before requesting a new one. Mirrors Litter's behaviour.
        if let priorID = activeActivityIDs[sessionID] {
            Task { await Self.terminateActivity(id: priorID) }
            activeActivityIDs[sessionID] = nil
        }

        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attrs = TurnActivityAttributes(from: attributes)
        let content = TurnActivityAttributes.ContentState(from: state)
        do {
            let activity = try Activity<TurnActivityAttributes>.request(
                attributes: attrs,
                content: ActivityContent(state: content, staleDate: nil),
                pushType: nil
            )
            activeActivityIDs[sessionID] = activity.id
        } catch {
            // Live Activities can fail to start when the widget target
            // isn't registered (which is the current state of this PR).
            // Swallow and continue — the controller stays functional;
            // the lock-screen card just won't render until the widget
            // target lands in the follow-up PR.
        }
        #endif
    }

    private func updateActivity(state: TurnActivityContentState, sessionID: String) {
        #if canImport(ActivityKit)
        guard let activityID = activeActivityIDs[sessionID] else { return }
        let content = TurnActivityAttributes.ContentState(from: state)
        Task {
            for activity in Activity<TurnActivityAttributes>.activities where activity.id == activityID {
                await activity.update(ActivityContent(state: content, staleDate: nil))
            }
        }
        #endif
    }

    private func endActivity(state: TurnActivityContentState, sessionID: String) {
        #if canImport(ActivityKit)
        guard let activityID = activeActivityIDs[sessionID] else { return }
        activeActivityIDs[sessionID] = nil
        let content = TurnActivityAttributes.ContentState(from: state)
        Task {
            for activity in Activity<TurnActivityAttributes>.activities where activity.id == activityID {
                await activity.end(ActivityContent(state: content, staleDate: nil), dismissalPolicy: .default)
            }
        }
        #endif
    }

    #if canImport(ActivityKit)
    private static func terminateActivity(id: String) async {
        for activity in Activity<TurnActivityAttributes>.activities where activity.id == id {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
    #endif
}

/// Adapter helpers that convert the UniFFI-shaped `ConversationItem` into
/// the pure-data `TurnActivityItem` the model accepts. Kept in a separate
/// type so the model file stays decoupled from the Rust-core types and
/// the test target doesn't have to pull in any FFI.
public enum TurnLiveActivityMapping {
    /// Find the most recent item that should drive the activity: prefer
    /// a running tool/command, fall back to an exit so the controller
    /// can close the activity, then otherwise the newest tool/command
    /// regardless of status.
    public static func latestRelevantItem(from items: [ConversationItem]) -> TurnActivityItem? {
        guard !items.isEmpty else { return nil }
        // Scan newest → oldest. We surface the freshest tool/command so a
        // chat-only tail (assistant messages after the last tool) doesn't
        // re-open the activity.
        for raw in items.reversed() {
            if let mapped = TurnLiveActivityMapping.map(raw),
               mapped.kind == .tool || mapped.kind == .command || mapped.kind == .exit {
                return mapped
            }
        }
        return nil
    }

    static func map(_ item: ConversationItem) -> TurnActivityItem? {
        let kind: TurnActivityItem.Kind
        switch item.kind {
        case "tool":     kind = .tool
        case "command":  kind = .command
        case "message":  kind = .message
        case "exit":     kind = .exit
        default:         kind = .other
        }
        let timestamp = TurnLiveActivityMapping.parseTimestamp(item.ts) ?? Date()
        return TurnActivityItem(
            id: item.id,
            kind: kind,
            toolName: item.toolName,
            command: item.command,
            status: item.status,
            exitCode: item.exitCode,
            timestamp: timestamp
        )
    }

    /// Parse the ISO-8601 timestamps the Rust core emits. Falls back to
    /// `nil` so the controller can default to `Date()` rather than
    /// blocking the lifecycle on a malformed string.
    static func parseTimestamp(_ raw: String) -> Date? {
        // ISO8601DateFormatter doesn't accept fractional seconds without
        // an explicit option, and the harness emits both shapes.
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFractional.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

#if DEBUG
extension TurnLiveActivityController {
    /// Test-only inspection of the per-session model.
    func _debugModel(sessionID: String) -> TurnActivityModel? {
        models[sessionID]
    }
}
#endif
