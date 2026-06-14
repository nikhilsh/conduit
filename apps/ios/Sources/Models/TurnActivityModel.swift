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
    /// Display name of the session ("Code Review · PaperTrail") for the
    /// activity title. Defaulted so older call sites keep compiling.
    public var sessionName: String

    public init(agentName: String, sessionID: String, sessionName: String = "") {
        self.agentName = agentName
        self.sessionID = sessionID
        self.sessionName = sessionName
    }
}

/// Which kind of "needs you" interrupt the agent raised (handoff Part B).
/// A pending turn is one of two honest shapes — they get different
/// lock-screen CTAs:
///   - `.choice`     — an n-way question; the answer UI lives in the app,
///                     so the only honest CTA is "Open to choose".
///   - `.permission` — a binary tool gate (e.g. `git push --force`); a
///                     simple yes/no the lock screen CAN answer in the
///                     background via a non-opening App Intent.
public enum TurnInterruptKind: String, Codable, Hashable, Sendable {
    case choice
    case permission
}

/// The mutable per-turn state mirrored into the lock-screen card.
public struct TurnActivityContentState: Equatable, Hashable, Codable, Sendable {
    public var currentTool: String?
    public var currentCommand: String?
    public var startedAt: Date
    public var tokensIn: Int
    public var tokensOut: Int
    /// "running", "pending" (needs the user — an approval is waiting),
    /// or "exited" — matches Conduit's vocabulary so the widget renderer
    /// can switch on a known string set.
    public var status: String
    /// When this snapshot was pushed — the widget's honesty stamp
    /// ("synced just now" / "synced 6m ago"). Round-3 §2: content only
    /// refreshes when the app gets execution time, so the stamp is the
    /// user-visible truth about how live the card is.
    public var syncedAt: Date
    /// Short closing line for the done state ("exit 0"). Nil until end.
    public var summary: String?
    /// For a `pending` turn: which interrupt shape it is (drives the CTA).
    /// Nil while running / done.
    public var interruptKind: TurnInterruptKind?
    /// For a `pending` turn: the question / permission prompt to surface on
    /// the card. Nil while running / done.
    public var prompt: String?
    /// For a `pending` `.choice` turn: how many options the question has,
    /// shown as the "N options" pill. 0 when unknown / not a choice.
    public var optionCount: Int

    public init(
        currentTool: String? = nil,
        currentCommand: String? = nil,
        startedAt: Date,
        tokensIn: Int = 0,
        tokensOut: Int = 0,
        status: String = "running",
        syncedAt: Date? = nil,
        summary: String? = nil,
        interruptKind: TurnInterruptKind? = nil,
        prompt: String? = nil,
        optionCount: Int = 0
    ) {
        self.currentTool = currentTool
        self.currentCommand = currentCommand
        self.startedAt = startedAt
        self.tokensIn = tokensIn
        self.tokensOut = tokensOut
        self.status = status
        self.syncedAt = syncedAt ?? startedAt
        self.summary = summary
        self.interruptKind = interruptKind
        self.prompt = prompt
        self.optionCount = optionCount
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
        /// The agent is blocked on the user (AskUserQuestion / approval).
        /// Drives the "needs you" Live-Activity state (round-3 §2).
        case pendingInput
        case other
    }

    public var id: String
    public var kind: Kind
    public var toolName: String?
    public var command: String?
    public var status: String
    public var exitCode: Int32?
    public var timestamp: Date
    /// For a `.pendingInput` item: the classified interrupt shape (choice
    /// vs permission). Nil for every other kind.
    public var interruptKind: TurnInterruptKind?
    /// For a `.pendingInput` item: the question / permission prompt text.
    public var prompt: String?
    /// For a `.pendingInput` item: number of answer options (drives the
    /// "N options" pill on a choice). 0 when unknown.
    public var optionCount: Int

    public init(
        id: String,
        kind: Kind,
        toolName: String? = nil,
        command: String? = nil,
        status: String = "running",
        exitCode: Int32? = nil,
        timestamp: Date,
        interruptKind: TurnInterruptKind? = nil,
        prompt: String? = nil,
        optionCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.toolName = toolName
        self.command = command
        self.status = status
        self.exitCode = exitCode
        self.timestamp = timestamp
        self.interruptKind = interruptKind
        self.prompt = prompt
        self.optionCount = optionCount
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
/// **Transitions** (mirrors Conduit's `TurnLiveActivityController`):
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

    /// Items older than this can UPDATE a live activity but never START
    /// one. After a reconnect/recovery the store re-surfaces the whole
    /// conversation, and hours-old tool events were opening lock-screen
    /// cards whose elapsed timers read "598m" for sessions doing nothing
    /// (device feedback, round 4). History is not a live turn.
    public static let maxStartAge: TimeInterval = 10 * 60

    public private(set) var attributes: TurnActivityAttributesData?
    public private(set) var contentState: TurnActivityContentState?
    public private(set) var lastActivityAt: Date?
    public private(set) var idleTimeout: TimeInterval

    public var isActive: Bool { attributes != nil && contentState != nil }

    public init(idleTimeout: TimeInterval = TurnActivityModel.defaultIdleTimeout) {
        self.idleTimeout = idleTimeout
    }

    /// Seeding initializer for push-to-start adoption (§1.6,
    /// PLAN-push-to-start-la.md). Sets the model to "active" so the
    /// bridge's next evaluate() takes the UPDATE branch rather than
    /// emitting a `.start` (which would open a duplicate card).
    ///
    /// `lastActivityAt` is intentionally nil — the adopted activity's
    /// age is unknown, and we don't want the idle-timeout tick to
    /// immediately close it. The first real item from the bridge
    /// will set `lastActivityAt` via the normal `apply` path.
    public init(
        seededAttributes: TurnActivityAttributesData,
        contentState: TurnActivityContentState,
        idleTimeout: TimeInterval = TurnActivityModel.defaultIdleTimeout
    ) {
        self.idleTimeout = idleTimeout
        self.attributes = seededAttributes
        self.contentState = contentState
        self.lastActivityAt = nil
    }

    /// Apply a new conversation item to the state machine and return the
    /// effect the controller should perform. `agentName` is captured at
    /// `start` time and not re-read after — the activity carries the
    /// agent that owned the turn even if the session switches.
    public mutating func apply(
        item: TurnActivityItem,
        sessionID: String,
        agentName: String,
        sessionName: String = ""
    ) -> TurnActivityEffect {
        // Terminal kinds end the activity unconditionally.
        if item.kind == .exit {
            return endActivity(at: item.timestamp, status: "exited")
        }
        if item.status == "exited", contentState != nil {
            return endActivity(at: item.timestamp, status: "exited")
        }

        // Tool/command items drive start/update; a pending-input item
        // flips the activity to "needs you" (round-3 §2) — and is
        // important enough to START one if none is live (an approval
        // waiting on the lock screen is the whole point). Plain chat
        // messages alone don't justify a card.
        let isPending = item.kind == .pendingInput
        guard item.kind == .tool || item.kind == .command || isPending else {
            return .noop
        }

        lastActivityAt = item.timestamp

        if !isActive {
            // Stale items are history, not a live turn — never OPEN a
            // card for them (a re-surfaced old conversation after a
            // reconnect would otherwise show an hours-long timer).
            if Date().timeIntervalSince(item.timestamp) > Self.maxStartAge {
                return .noop
            }
            let attrs = TurnActivityAttributesData(
                agentName: agentName, sessionID: sessionID, sessionName: sessionName
            )
            let state = TurnActivityContentState(
                currentTool: item.toolName,
                currentCommand: item.command,
                startedAt: item.timestamp,
                tokensIn: 0,
                tokensOut: 0,
                status: isPending ? "pending" : "running",
                interruptKind: isPending ? item.interruptKind : nil,
                prompt: isPending ? item.prompt : nil,
                optionCount: isPending ? item.optionCount : 0
            )
            attributes = attrs
            contentState = state
            return .start(attributes: attrs, state: state)
        }

        // Same session: produce an update with the new tool/command.
        var next = contentState ?? TurnActivityContentState(startedAt: item.timestamp)
        next.currentTool = item.toolName ?? next.currentTool
        next.currentCommand = item.command ?? next.currentCommand
        next.status = isPending ? "pending" : "running"
        // Carry the interrupt payload only while pending; a resuming
        // tool/command clears it so the card drops back to "running".
        if isPending {
            next.interruptKind = item.interruptKind
            next.prompt = item.prompt
            next.optionCount = item.optionCount
        } else {
            next.interruptKind = nil
            next.prompt = nil
            next.optionCount = 0
        }
        contentState = next
        return .update(state: next)
    }

    /// Externally-signalled end (session lifecycle exit, controller reset,
    /// app teardown). Idempotent — calling on an inactive model is a noop.
    /// `summary` is the done-state closing line ("exit 0"), when known.
    public mutating func sessionExited(
        at when: Date = Date(), status: String = "exited", summary: String? = nil
    ) -> TurnActivityEffect {
        return endActivity(at: when, status: status, summary: summary)
    }

    /// Time-driven step. Called periodically (or on any external nudge) so
    /// the model can end the activity after `idleTimeout` without a new tool.
    /// Returns `.end` exactly once per active turn. A "pending" activity
    /// (the agent is blocked on the user) is exempt — an approval can wait
    /// minutes, and the lock-screen card asking for it is the feature
    /// (round-3 §2); only a fresh item or a session exit closes it.
    public mutating func tick(now: Date) -> TurnActivityEffect {
        guard let last = lastActivityAt, isActive else { return .noop }
        if contentState?.status == "pending" { return .noop }
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

    private mutating func endActivity(
        at when: Date, status: String, summary: String? = nil
    ) -> TurnActivityEffect {
        guard var final = contentState else {
            attributes = nil
            return .noop
        }
        final.status = status
        final.summary = summary ?? final.summary
        let effect = TurnActivityEffect.end(state: final)
        attributes = nil
        contentState = nil
        lastActivityAt = nil
        return effect
    }
}
