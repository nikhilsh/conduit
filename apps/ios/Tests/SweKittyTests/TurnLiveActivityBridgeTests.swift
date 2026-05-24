import Testing
import Foundation
@testable import SweKitty

/// Covers `TurnLiveActivityBridgeCore` — the pure decision step the
/// bridge runs each time SessionStore changes. Every test feeds in a
/// hand-built `TurnLiveActivityFrame` and asserts on the intents the
/// core emits. No SessionStore, no ActivityKit, no Activity.request.
@Suite("TurnLiveActivityBridgeCore intents")
struct TurnLiveActivityBridgeTests {

    // MARK: - Helpers

    private func session(
        id: String = "s1",
        agent: String = "claude",
        phase: String? = "running",
        items: [TurnActivityItem] = []
    ) -> TurnLiveActivityFrame.Session {
        TurnLiveActivityFrame.Session(
            sessionID: id, agentName: agent, phase: phase, conversation: items
        )
    }

    private func item(
        _ id: String,
        kind: TurnActivityItem.Kind,
        toolName: String? = nil,
        command: String? = nil,
        status: String = "running",
        at: TimeInterval = 0
    ) -> TurnActivityItem {
        TurnActivityItem(
            id: id, kind: kind, toolName: toolName, command: command,
            status: status, timestamp: Date(timeIntervalSince1970: at)
        )
    }

    // MARK: - First tool / command emits observe

    @Test func firstToolItemEmitsObserveAndTick() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))

        // Should be [observe, tick]. The tick at the end is unconditional.
        #expect(intents.count == 2)
        if case let .observe(sid, agent, observed) = intents[0] {
            #expect(sid == "s1")
            #expect(agent == "claude")
            #expect(observed.toolName == "Bash")
        } else {
            Issue.record("expected .observe first, got \(intents)")
        }
        #expect(intents.last == .tick)
    }

    @Test func commandItemAlsoEmitsObserve() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .command, command: "ls", at: 100)])
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        if case let .observe(_, _, observed) = intents[0] {
            #expect(observed.command == "ls")
        } else {
            Issue.record("expected .observe for command, got \(intents)")
        }
    }

    @Test func messageOnlyEmitsNoObserve() {
        // A pure assistant message shouldn't trigger a Live Activity.
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .message, at: 100)])
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        #expect(intents == [.tick])
    }

    @Test func emptyFirstFrameDoesNotStrandLaterItems() {
        // Regression: a session usually appears with an empty conversation
        // first (it's in statusBySession before its first tool item). The
        // next frame's tool item must still emit `.observe` — previously a
        // `lastSeenItemID = ""` seed caused the cursor-walk to skip every
        // later item, so the Live Activity never started. See PR #151/#152.
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let empty = TurnLiveActivityFrame(sessions: [session(items: [])])
        _ = core.ingest(frame: empty, now: Date(timeIntervalSince1970: 100))

        let withTool = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 101)])
        ])
        let intents = core.ingest(frame: withTool, now: Date(timeIntervalSince1970: 101))
        #expect(intents.contains(where: {
            if case let .observe(_, _, observed) = $0 { return observed.id == "i1" }
            return false
        }))
    }

    // MARK: - Idempotent re-ingest

    @Test func sameFrameTwiceProducesNoSecondObserve() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        let first = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        let second = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 101))
        #expect(first.contains(where: { if case .observe = $0 { return true } else { return false } }))
        #expect(!second.contains(where: { if case .observe = $0 { return true } else { return false } }))
    }

    @Test func secondToolItemEmitsAnotherObserve() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame1 = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        _ = core.ingest(frame: frame1, now: Date(timeIntervalSince1970: 100))
        let frame2 = TurnLiveActivityFrame(sessions: [
            session(items: [
                item("i1", kind: .tool, toolName: "Bash", at: 100),
                item("i2", kind: .tool, toolName: "Edit", at: 101),
            ])
        ])
        let intents = core.ingest(frame: frame2, now: Date(timeIntervalSince1970: 101))
        let observes = intents.compactMap { intent -> String? in
            if case let .observe(_, _, item) = intent { return item.toolName }
            return nil
        }
        #expect(observes == ["Edit"])
    }

    // MARK: - End on exit row

    @Test func exitRowEmitsEnd() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [
                item("i1", kind: .tool, toolName: "Bash", at: 100),
                item("i2", kind: .exit, at: 101),
            ])
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 101))
        let ends = intents.filter { intent in
            if case .end = intent { return true } else { return false }
        }
        #expect(ends.count == 1)
        #expect(ends.first == .end(sessionID: "s1"))
    }

    // MARK: - End on lifecycle exit phase

    @Test func phaseExitedEmitsEndOnEdge() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        // First: live tool item, phase running.
        _ = core.ingest(
            frame: TurnLiveActivityFrame(sessions: [
                session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
            ]),
            now: Date(timeIntervalSince1970: 100)
        )

        // Then: phase flips to exited(0). Should emit `.end` once.
        let intents = core.ingest(
            frame: TurnLiveActivityFrame(sessions: [
                session(phase: "exited(0)", items: [
                    item("i1", kind: .tool, toolName: "Bash", at: 100),
                ])
            ]),
            now: Date(timeIntervalSince1970: 101)
        )
        #expect(intents.contains(.end(sessionID: "s1")))

        // Re-ingesting the same exited frame doesn't re-emit `.end`.
        let again = core.ingest(
            frame: TurnLiveActivityFrame(sessions: [
                session(phase: "exited(0)", items: [
                    item("i1", kind: .tool, toolName: "Bash", at: 100),
                ])
            ]),
            now: Date(timeIntervalSince1970: 102)
        )
        let ends = again.filter { intent in
            if case .end = intent { return true } else { return false }
        }
        #expect(ends.isEmpty)
    }

    // MARK: - Idle-timeout end

    @Test func idleAfter5sEmitsEnd() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        // Tool at t=100. Re-ingest with no new items at t=106 — should end.
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        _ = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 106))
        #expect(intents.contains(.end(sessionID: "s1")))
    }

    @Test func idleWithinWindowDoesNotEnd() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        _ = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        // 4 s later — still inside the window.
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 104))
        #expect(!intents.contains(where: { intent in
            if case .end = intent { return true } else { return false }
        }))
    }

    @Test func idleEndFiresOnceThenRequiresFreshToolToReArm() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        _ = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        let firstIdle = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 106))
        #expect(firstIdle.contains(.end(sessionID: "s1")))
        // Another tick past the window must *not* emit another `.end`.
        let secondIdle = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 107))
        let ends = secondIdle.filter { intent in
            if case .end = intent { return true } else { return false }
        }
        #expect(ends.isEmpty)

        // A fresh tool item re-arms the activity.
        let frame2 = TurnLiveActivityFrame(sessions: [
            session(items: [
                item("i1", kind: .tool, toolName: "Bash", at: 100),
                item("i2", kind: .tool, toolName: "Edit", at: 110),
            ])
        ])
        let restart = core.ingest(frame: frame2, now: Date(timeIntervalSince1970: 110))
        #expect(restart.contains(where: { intent in
            if case let .observe(_, _, item) = intent { return item.toolName == "Edit" }
            return false
        }))
        // Idle window starts again — 4 s later still alive, 6 s later ends.
        let stillAlive = core.ingest(frame: frame2, now: Date(timeIntervalSince1970: 114))
        #expect(!stillAlive.contains(.end(sessionID: "s1")))
        let endsAgain = core.ingest(frame: frame2, now: Date(timeIntervalSince1970: 116))
        #expect(endsAgain.contains(.end(sessionID: "s1")))
    }

    // MARK: - Multi-session fan-out

    @Test func multipleSessionsTrackedIndependently() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let frame = TurnLiveActivityFrame(sessions: [
            session(id: "s1", items: [item("a1", kind: .tool, toolName: "Bash", at: 100)]),
            session(id: "s2", agent: "codex", items: [
                item("b1", kind: .command, command: "ls", at: 100),
            ]),
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        let observed = intents.compactMap { intent -> String? in
            if case let .observe(sid, _, _) = intent { return sid }
            return nil
        }
        #expect(Set(observed) == ["s1", "s2"])

        // Exit only s2 — s1 must remain alive.
        let frame2 = TurnLiveActivityFrame(sessions: [
            session(id: "s1", items: [item("a1", kind: .tool, toolName: "Bash", at: 100)]),
            session(id: "s2", agent: "codex", phase: "exited(0)", items: [
                item("b1", kind: .command, command: "ls", at: 100),
            ]),
        ])
        let intents2 = core.ingest(frame: frame2, now: Date(timeIntervalSince1970: 101))
        #expect(intents2.contains(.end(sessionID: "s2")))
        #expect(!intents2.contains(.end(sessionID: "s1")))
    }

    // MARK: - Tick is always emitted

    @Test func everyIngestEndsWithTick() {
        var core = TurnLiveActivityBridgeCore(idleTimeout: 5)
        let empty = TurnLiveActivityFrame(sessions: [])
        #expect(core.ingest(frame: empty, now: Date()) == [.tick])
        let frame = TurnLiveActivityFrame(sessions: [
            session(items: [item("i1", kind: .tool, toolName: "Bash", at: 100)])
        ])
        let intents = core.ingest(frame: frame, now: Date(timeIntervalSince1970: 100))
        #expect(intents.last == .tick)
    }
}
