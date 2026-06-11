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
        /// When this snapshot was pushed -- the widget's "synced Xm ago"
        /// honesty stamp (round-3 SS2).
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

        // MARK: - Custom Codable (push-decodable, epoch-millis timestamps)
        //
        // APNs push content-state JSON uses epoch-millis Int keys
        // "startedAtMs" / "syncedAtMs" (broker contract). Swift's default
        // Date Codable expects a Double timeIntervalSinceReferenceDate,
        // which would silently misparse the broker's millis values.
        // We encode/decode using those Int millis keys so:
        //   - push-decoded content-state (broker -> APNs -> iOS) works,
        //   - local Activity.update round-trips through the same shape,
        //   - the existing local-update path keeps using Date values.

        enum CodingKeys: String, CodingKey {
            case currentTool, currentCommand
            case startedAtMs
            case syncedAtMs
            case tokensIn, tokensOut
            case status, summary
            case interruptKind, prompt, optionCount
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            currentTool     = try c.decodeIfPresent(String.self, forKey: .currentTool)
            currentCommand  = try c.decodeIfPresent(String.self, forKey: .currentCommand)
            let startMs     = try c.decode(Int.self, forKey: .startedAtMs)
            let syncMs      = try c.decode(Int.self, forKey: .syncedAtMs)
            startedAt       = Date(timeIntervalSince1970: Double(startMs) / 1000.0)
            syncedAt        = Date(timeIntervalSince1970: Double(syncMs) / 1000.0)
            tokensIn        = try c.decodeIfPresent(Int.self, forKey: .tokensIn) ?? 0
            tokensOut       = try c.decodeIfPresent(Int.self, forKey: .tokensOut) ?? 0
            status          = try c.decodeIfPresent(String.self, forKey: .status) ?? "running"
            summary         = try c.decodeIfPresent(String.self, forKey: .summary)
            interruptKind   = try c.decodeIfPresent(TurnInterruptKind.self, forKey: .interruptKind)
            prompt          = try c.decodeIfPresent(String.self, forKey: .prompt)
            optionCount     = try c.decodeIfPresent(Int.self, forKey: .optionCount) ?? 0
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encodeIfPresent(currentTool,    forKey: .currentTool)
            try c.encodeIfPresent(currentCommand, forKey: .currentCommand)
            try c.encode(Int(startedAt.timeIntervalSince1970 * 1000), forKey: .startedAtMs)
            try c.encode(Int(syncedAt.timeIntervalSince1970 * 1000),  forKey: .syncedAtMs)
            try c.encode(tokensIn,    forKey: .tokensIn)
            try c.encode(tokensOut,   forKey: .tokensOut)
            try c.encode(status,      forKey: .status)
            try c.encodeIfPresent(summary,       forKey: .summary)
            try c.encodeIfPresent(interruptKind, forKey: .interruptKind)
            try c.encodeIfPresent(prompt,        forKey: .prompt)
            try c.encode(optionCount, forKey: .optionCount)
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
