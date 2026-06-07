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
        IntentDescription("Approve the agent's pending request in a Conduit session.")
    }
    /// Headless — the whole point is approving without opening the app.
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
        await ConduitApprovalBridge.approve(sessionID: sessionID)
        return .result()
    }
}

/// Runtime seam between the shared intent type and the host-only
/// stores. The host app assigns `handler` once at launch; the widget
/// binary compiles this with `handler == nil` and never calls it.
public enum ConduitApprovalBridge {
    /// MainActor-isolated closure so the host can capture its
    /// main-actor stores without sendability gymnastics.
    @MainActor public static var handler: (@MainActor (String) async -> Void)?

    @MainActor public static func approve(sessionID: String) async {
        await handler?(sessionID)
    }
}
#endif
