import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

#if canImport(ActivityKit)
/// ActivityKit-facing attributes for the turn Live Activity.
///
/// Mirrors `TurnActivityAttributesData` / `TurnActivityContentState` from
/// the pure model so the same shape ships through the system. Split into
/// its own file (separate from `TurnLiveActivityController`) so the widget
/// extension target can compile this declaration without also pulling in
/// the controller class — which transitively references `SessionStore`,
/// `ConversationItem`, and other host-only types.
///
/// Both the main app target and the `ConduitWidgets` extension target
/// include this source file (see `apps/ios/project.yml`) so the generic
/// `Activity<TurnActivityAttributes>` resolves to the same concrete type
/// on both sides of the system boundary — that's the contract iOS uses
/// to route lock-screen / Dynamic Island updates to the right widget.
public struct TurnActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public var currentTool: String?
        public var currentCommand: String?
        public var startedAt: Date
        public var tokensIn: Int
        public var tokensOut: Int
        public var status: String
        /// When this snapshot was pushed — the widget's "synced Xm ago"
        /// honesty stamp (round-3 §2).
        public var syncedAt: Date
        /// Done-state closing line ("exit 0"), nil while running.
        public var summary: String?
        /// Pending interrupt shape (choice / permission), nil otherwise.
        public var interruptKind: TurnInterruptKind?
        /// Pending question / permission prompt, nil otherwise.
        public var prompt: String?
        /// Pending `.choice` option count for the "N options" pill.
        public var optionCount: Int

        public init(from state: TurnActivityContentState) {
            self.currentTool = state.currentTool
            self.currentCommand = state.currentCommand
            self.startedAt = state.startedAt
            self.tokensIn = state.tokensIn
            self.tokensOut = state.tokensOut
            self.status = state.status
            self.syncedAt = state.syncedAt
            self.summary = state.summary
            self.interruptKind = state.interruptKind
            self.prompt = state.prompt
            self.optionCount = state.optionCount
        }

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

    public var agentName: String
    public var sessionID: String
    /// Session display name for the activity title.
    public var sessionName: String

    public init(from data: TurnActivityAttributesData) {
        self.agentName = data.agentName
        self.sessionID = data.sessionID
        self.sessionName = data.sessionName
    }

    public init(agentName: String, sessionID: String, sessionName: String = "") {
        self.agentName = agentName
        self.sessionID = sessionID
        self.sessionName = sessionName
    }
}
#endif
