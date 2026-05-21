import Testing
import Foundation
@testable import SweKitty

/// Covers the state machine that drives the Live Activity (audit A.2).
///
/// The model is intentionally pure-data — no ActivityKit imports — so the
/// transitions can be asserted directly without faking out the system
/// `Activity<>` type or registering a widget extension. The controller
/// that wraps it adds the actual ActivityKit calls; those are covered
/// (eventually) by a snapshot test gated on a Mac.
@Suite("TurnActivityModel state machine")
struct TurnLiveActivityModelTests {

    // MARK: - Start

    @Test func toolItemStartsActivity() {
        var model = TurnActivityModel()
        let item = TurnActivityItem(
            id: "i1",
            kind: .tool,
            toolName: "Bash",
            command: nil,
            status: "running",
            timestamp: Date(timeIntervalSince1970: 100)
        )

        let effect = model.apply(item: item, sessionID: "s1", agentName: "claude")

        guard case let .start(attrs, state) = effect else {
            Issue.record("expected .start, got \(effect)")
            return
        }
        #expect(attrs.agentName == "claude")
        #expect(attrs.sessionID == "s1")
        #expect(state.currentTool == "Bash")
        #expect(state.status == "running")
        #expect(model.isActive)
    }

    @Test func commandItemAlsoStartsActivity() {
        // Commands (terminal-style shell calls) are first-class triggers
        // alongside tools — Litter treats them the same.
        var model = TurnActivityModel()
        let item = TurnActivityItem(
            id: "i1",
            kind: .command,
            command: "ls -la",
            timestamp: Date()
        )

        let effect = model.apply(item: item, sessionID: "s1", agentName: "codex")

        if case .start = effect { } else {
            Issue.record("expected .start for command kind, got \(effect)")
        }
    }

    @Test func messageItemDoesNotStartActivity() {
        // A plain chat message alone shouldn't pop a Live Activity —
        // only tool/command items represent a "turn in progress".
        var model = TurnActivityModel()
        let item = TurnActivityItem(id: "i1", kind: .message, timestamp: Date())

        let effect = model.apply(item: item, sessionID: "s1", agentName: "claude")

        #expect(effect == .noop)
        #expect(!model.isActive)
    }

    // MARK: - Update

    @Test func secondToolItemUpdatesActivity() {
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let effect = model.apply(
            item: TurnActivityItem(id: "i2", kind: .tool, toolName: "Edit", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        guard case let .update(state) = effect else {
            Issue.record("expected .update, got \(effect)")
            return
        }
        #expect(state.currentTool == "Edit")
        #expect(state.status == "running")
    }

    @Test func tokenUpdatesAfterStartProduceUpdateEffect() {
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let effect = model.updateTokens(tokensIn: 1200, tokensOut: 400)

        guard case let .update(state) = effect else {
            Issue.record("expected .update, got \(effect)")
            return
        }
        #expect(state.tokensIn == 1200)
        #expect(state.tokensOut == 400)
    }

    @Test func tokenUpdatesBeforeStartAreNoop() {
        var model = TurnActivityModel()
        let effect = model.updateTokens(tokensIn: 50, tokensOut: 10)
        #expect(effect == .noop)
    }

    // MARK: - End on exit kind

    @Test func exitItemEndsActivity() {
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let effect = model.apply(
            item: TurnActivityItem(id: "i2", kind: .exit, exitCode: 0, timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        guard case let .end(state) = effect else {
            Issue.record("expected .end, got \(effect)")
            return
        }
        #expect(state.status == "exited")
        #expect(!model.isActive)
    }

    @Test func toolItemWithStatusExitedEndsActivity() {
        // The harness can mark the *same* tool item as exited rather
        // than emitting a separate exit row. Both shapes must end.
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let effect = model.apply(
            item: TurnActivityItem(
                id: "i2",
                kind: .tool,
                toolName: "Bash",
                status: "exited",
                timestamp: Date()
            ),
            sessionID: "s1",
            agentName: "claude"
        )

        if case .end = effect { } else {
            Issue.record("expected .end on status=exited, got \(effect)")
        }
        #expect(!model.isActive)
    }

    // MARK: - End on idle / session exit

    @Test func idleTickAfterTimeoutEndsActivity() {
        var model = TurnActivityModel(idleTimeout: 5)
        let start = Date(timeIntervalSince1970: 1000)
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: start),
            sessionID: "s1",
            agentName: "claude"
        )

        // 4 s after the last tool — still inside the window.
        let withinWindow = model.tick(now: start.addingTimeInterval(4))
        #expect(withinWindow == .noop)
        #expect(model.isActive)

        // 6 s after — past the 5 s threshold, activity ends.
        let pastWindow = model.tick(now: start.addingTimeInterval(6))
        if case .end = pastWindow { } else {
            Issue.record("expected .end past idle window, got \(pastWindow)")
        }
        #expect(!model.isActive)
    }

    @Test func sessionExitedSignalEndsActivity() {
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let effect = model.sessionExited()

        if case .end = effect { } else {
            Issue.record("expected .end on sessionExited, got \(effect)")
        }
        #expect(!model.isActive)
    }

    @Test func sessionExitedOnInactiveModelIsNoop() {
        var model = TurnActivityModel()
        let effect = model.sessionExited()
        #expect(effect == .noop)
    }

    @Test func tickOnInactiveModelIsNoop() {
        var model = TurnActivityModel()
        let effect = model.tick(now: Date())
        #expect(effect == .noop)
    }

    // MARK: - One concurrent activity per session

    @Test func startEndStartProducesTwoSeparateActivities() {
        // After an end, the next tool item should produce a fresh start
        // (with a new attributes block), not an update — verifies the
        // model resets cleanly so the controller's activity-id table
        // doesn't carry a stale handle.
        var model = TurnActivityModel()
        _ = model.apply(
            item: TurnActivityItem(id: "i1", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )
        _ = model.apply(
            item: TurnActivityItem(id: "i2", kind: .exit, timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        let restart = model.apply(
            item: TurnActivityItem(id: "i3", kind: .tool, toolName: "Bash", timestamp: Date()),
            sessionID: "s1",
            agentName: "claude"
        )

        if case .start = restart { } else {
            Issue.record("expected .start after restart, got \(restart)")
        }
    }
}
