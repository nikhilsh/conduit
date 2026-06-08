import Foundation
#if canImport(AppIntents)
import AppIntents

/// In-place "Approve" for the Live Activity's needs-you state (round-3
/// §2 follow-up). A `LiveActivityIntent` executes **in the app's
/// process** (iOS launches it in the background if needed), so tapping
/// Approve on the lock screen answers the agent's pending question
/// without opening the UI.
///
/// This type is compiled into BOTH the host app and the
/// `ConduitWidgets` extension (see `apps/ios/project.yml`) — the widget
/// needs the type to build `Button(intent:)`, the host needs it to
/// execute `perform()`. The body stays free of host-only types
/// (SessionStore etc.); the host installs the actual approval logic via
/// `ConduitApprovalBridge.handler` at launch.
public struct ApproveSessionIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Approve" }
    public static var description: IntentDescription {
        IntentDescription("Approve the agent's pending permission request in a Conduit session.")
    }
    /// Headless — the whole point is approving without opening the app.
    /// Only a binary permission gate uses this; an n-way choice opens the
    /// app instead (it needs the picker UI).
    public static var openAppWhenRun: Bool { false }

    @Parameter(title: "Session ID")
    public var sessionID: String

    public init() {
        self.sessionID = ""
    }

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public func perform() async throws -> some IntentResult {
        // No-op in the widget process (handler nil there) — but
        // LiveActivityIntent always performs in the app process, where
        // the host installed the handler at launch.
        await ConduitApprovalBridge.decide(sessionID: sessionID, decision: .approve)
        return .result()
    }
}

/// Headless "Reject" twin of `ApproveSessionIntent` for the permission
/// gate (handoff Part B). Same non-opening `LiveActivityIntent` contract —
/// posts the rejection to the broker in the background, no app launch.
public struct RejectSessionIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource { "Reject" }
    public static var description: IntentDescription {
        IntentDescription("Reject the agent's pending permission request in a Conduit session.")
    }
    public static var openAppWhenRun: Bool { false }

    @Parameter(title: "Session ID")
    public var sessionID: String

    public init() {
        self.sessionID = ""
    }

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    public func perform() async throws -> some IntentResult {
        await ConduitApprovalBridge.decide(sessionID: sessionID, decision: .reject)
        return .result()
    }
}

/// Runtime seam between the shared intent types and the host-only
/// stores. The host app assigns `handler` once at launch; the widget
/// binary compiles this with `handler == nil` and never calls it.
public enum ConduitApprovalBridge {
    /// A binary permission decision from the lock-screen gate.
    public enum Decision: String, Sendable {
        case approve
        case reject
    }

    /// MainActor-isolated closure so the host can capture its
    /// main-actor stores without sendability gymnastics.
    @MainActor public static var handler: (@MainActor (String, Decision) async -> Void)?

    @MainActor public static func decide(sessionID: String, decision: Decision) async {
        await handler?(sessionID, decision)
    }
}
#endif
