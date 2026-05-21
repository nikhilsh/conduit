import Foundation

/// Static + dynamic descriptors for the Turn Live Activity.
///
/// `TurnActivityAttributes` is split into two pieces by the same pattern
/// ActivityKit's `ActivityAttributes` requires:
///   - the "attributes" themselves (`agentName`, `sessionID`) are
///     immutable for the lifetime of the activity,
///   - `ContentState` carries everything that mutates during the turn
///     (current tool, elapsed time, status).
///
/// The pure-data shape lives here, separate from the ActivityKit-shaped
/// types in `TurnLiveActivityController.swift`, so the state machine that
/// decides when to start/update/end an activity can be exercised in unit
/// tests without paying the cost of importing ActivityKit (which doesn't
/// behave well under XCTest on the simulator without a registered widget
/// extension).
public struct TurnActivityAttributesData: Equatable, Hashable, Codable, Sendable {
    public var agentName: String
    public var sessionID: String

    public init(agentName: String, sessionID: String) {
        self.agentName = agentName
        self.sessionID = sessionID
    }
}

/// The mutable per-turn state mirrored into the lock-screen card.
public struct TurnActivityContentState: Equatable, Hashable, Codable, Sendable {
    public var currentTool: String?
    public var currentCommand: String?
    public var startedAt: Date
    public var tokensIn: Int
    public var tokensOut: Int
    /// "running", "pending", or "exited" — matches Litter's vocabulary
    /// so the widget renderer can switch on a known string set.
    public var status: String

    public init(
        currentTool: String? = nil,
        currentCommand: String? = nil,
        startedAt: Date,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        status: String = "running"
    ) {
        self.currentTool = currentTool
        self.currentCommand = currentCommand
        self.startedAt = startedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.status = status
    }
}

/// Lightweight projection of `ConversationItem` carrying just the fields
/// the state machine needs. Keeps the model free of any Rust-core types
/// so the tests don't have to depend on the generated UniFFI module.
public struct TurnActivityItem: Equatable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case tool
        case command
        case message
        case exit
        case other
    }

    public var id: String
    public var kind: Kind
    public var toolName: String?
    public var command: String?
    public var status: String
    public var exitCode: Int32?
    public var timestamp: Date

    public init(
        id: String,
        kind: Kind,
        toolName: String? = nil,
        command: String? = nil,
        status: String = "running",
        exitCode: Int32? = nil,
        timestamp: Date
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.timestamp = timestamp
    }
}

/// Side effect a `TurnActivityModel` step wants the controller to apply.
///
/// `start` / `update` / `end` map 1:1 to the three ActivityKit verbs.
/// The controller is responsible for actually calling
/// `Activity.request` / `activity.update` / `activity.end`; the model is
/// pure data so the state machine is unit-testable.
public enum TurnActivityEffect: Equatable, Sendable {
    case noop
    case start(attributes: TurnActivityAttributesData, state: TurnActivityContentState)
    case update(state: TurnActivityContentState)
    case end(state: TurnActivityContentState)
}

/// Pure state machine that decides whether to start / update / end the
/// Live Activity for a single session.
///
/// **Transitions** (mirrors Litter's `TurnLiveActivityController`):
///   - first `.tool` or `.command` item arrives → emit `.start`
///   - subsequent `.tool` / `.command` items for the active turn → `.update`
///   - `.exit` item or `status == "exited"` on the active item → `.end`
///   - tick-driven `.end` after `idleTimeout` of no tool/command activity
///   - session-exit signal from outside → `.end`
///
/// The model owns the *current* `agentName` + `sessionID` once activity
/// has started; the controller resets the model when a different session
/// becomes active.
public struct TurnActivityModel: Equatable, Sendable {
    /// Idle window after the last tool/command before the activity is ended.
    /// 5 s mirrors the spec — tuned so a chain of fast tool calls keeps
    /// the activity alive without flashing on/off between back-to-back tools.
    public static let defaultIdleTimeout: TimeInterval = 5

    public private(set) var attributes: TurnActivityAttributesData?
    public private(set) var contentState: TurnActivityContentState?
    public private(set) var lastActivityAt: Date?
    public private(set) var idleTimeout: TimeInterval

    public var isActive: Bool { attributes != nil && contentState != nil }

    public init(idleTimeout: TimeInterval = TurnActivityModel.defaultIdleTimeout) {
        self.idleTimeout = idleTimeout
    }

    /// Apply a new conversation item to the state machine and return the
    /// effect the controller should perform. `agentName` is captured at
    /// `start` time and not re-read after — the activity carries the
    /// agent that owned the turn even if the session switches.
    public mutating func apply(
        item: TurnActivityItem,
        sessionID: String,
        agentName: String
    ) -> TurnActivityEffect {
        // Terminal kinds end the activity unconditionally.
        if item.kind == .exit {
            return endActivity(at: item.timestamp, status: "exited")
        }
        if item.status == "exited", contentState != nil {
            return endActivity(at: item.timestamp, status: "exited")
        }

        // Only tool/command items drive start/update — chat messages alone
        // don't justify a lock-screen card.
        guard item.kind == .tool || item.kind == .command else {
            return .noop
        }

        lastActivityAt = item.timestamp

        if !isActive {
            let attrs = TurnActivityAttributesData(agentName: agentName, sessionID: sessionID)
            let state = TurnActivityContentState(
                currentTool: item.toolName,
                currentCommand: item.command,
                startedAt: item.timestamp,
                tokensIn: 0,
                tokensOut: 0,
                status: "running"
            )
            attributes = attrs
            contentState = state
            return .start(attributes: attrs, state: state)
        }

        // Same session: produce an update with the new tool/command.
        var next = contentState ?? TurnActivityContentState(startedAt: item.timestamp)
        next.currentTool = item.toolName ?? next.currentTool
        next.currentCommand = item.command ?? next.currentCommand
        next.status = "running"
        contentState = next
        return .update(state: next)
    }

    /// Externally-signalled end (session lifecycle exit, controller reset,
    /// app teardown). Idempotent — calling on an inactive model is a noop.
    public mutating func sessionExited(at when: Date = Date(), status: String = "exited") -> TurnActivityEffect {
        return endActivity(at: when, status: status)
    }

    /// Time-driven step. Called periodically (or on any external nudge) so
    /// the model can end the activity after `idleTimeout` without a new tool.
    /// Returns `.end` exactly once per active turn.
    public mutating func tick(now: Date) -> TurnActivityEffect {
        guard let last = lastActivityAt, isActive else { return .noop }
        if now.timeIntervalSince(last) >= idleTimeout {
            return endActivity(at: now, status: "exited")
        }
        return .noop
    }

    /// Apply a fresh token-count update without changing the active tool.
    /// Token counts arrive on a different channel from tool calls, so
    /// this is a separate input.
    public mutating func updateTokens(tokensIn: Int, tokensOut: Int) -> TurnActivityEffect {
        guard var next = contentState else { return .noop }
        next.tokensIn = tokensIn
        next.tokensOut = tokensOut
        contentState = next
        return .update(state: next)
    }

    private mutating func endActivity(at when: Date, status: String) -> TurnActivityEffect {
        guard var final = contentState else {
            attributes = nil
            return .noop
        }
        final.status = status
        let effect = TurnActivityEffect.end(state: final)
        attributes = nil
        contentState = nil
        lastActivityAt = nil
        return effect
    }
}
