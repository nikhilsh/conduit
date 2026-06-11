import Testing
import Foundation
@testable import Conduit

/// Unit tests for SubagentEntry decoding from the view_event("agents") payload.
/// Verifies that the exact JSON keys from the broker contract (subagent-panel-spec.md)
/// decode correctly into SubagentEntry values used by the Information tab Agents section.
@Suite("SubagentEntry decode")
struct SubagentRosterDecodeTests {

    // MARK: - SubagentEntry.roster(from:) — payload round-trip

    @Test func decodesFullRosterFromPayload() throws {
        // Wire payload: the core flattens the agents array to a single
        // "agents" key whose value is a JSON-array string.
        let agentsJSON = """
        [
          {
            "task_id": "a85166712f62b002d",
            "name": "ci-reviewer",
            "description": "Read a.txt contents",
            "status": "working",
            "last_tool": "Read",
            "tokens": 10226,
            "tool_uses": 1,
            "duration_ms": 2843,
            "started_at": "2026-06-11T10:00:00Z",
            "ended_at": ""
          },
          {
            "task_id": "b12345678abcdef01",
            "name": "test-runner",
            "description": "Run the test suite",
            "status": "done",
            "last_tool": "Bash",
            "tokens": 5120,
            "tool_uses": 3,
            "duration_ms": 12000,
            "started_at": "2026-06-11T10:01:00Z",
            "ended_at": "2026-06-11T10:01:12Z"
          }
        ]
        """
        let payload = ["agents": agentsJSON]
        let roster = SubagentEntry.roster(from: payload)
        #expect(roster != nil)
        #expect(roster?.count == 2)

        let first = try #require(roster?.first)
        #expect(first.taskId == "a85166712f62b002d")
        #expect(first.name == "ci-reviewer")
        #expect(first.description == "Read a.txt contents")
        #expect(first.status == "working")
        #expect(first.lastTool == "Read")
        #expect(first.tokens == 10226)
        #expect(first.toolUses == 1)
        #expect(first.durationMs == 2843)
        #expect(first.startedAt == "2026-06-11T10:00:00Z")
        #expect(first.endedAt == "")

        let second = try #require(roster?.last)
        #expect(second.taskId == "b12345678abcdef01")
        #expect(second.status == "done")
        #expect(second.endedAt == "2026-06-11T10:01:12Z")
    }

    @Test func returnsNilForMissingAgentsKey() {
        let payload: [String: String] = [:]
        #expect(SubagentEntry.roster(from: payload) == nil)
    }

    @Test func returnsNilForMalformedJSON() {
        let payload = ["agents": "not-valid-json"]
        #expect(SubagentEntry.roster(from: payload) == nil)
    }

    @Test func skipsEntriesWithNoTaskId() {
        let agentsJSON = """
        [
          {"task_id": "", "name": "bad", "status": "working"},
          {"task_id": "valid-id", "name": "good", "status": "done"}
        ]
        """
        let payload = ["agents": agentsJSON]
        let roster = SubagentEntry.roster(from: payload)
        #expect(roster?.count == 1)
        #expect(roster?.first?.taskId == "valid-id")
    }

    @Test func defaultsOptionalFieldsGracefully() {
        // A minimal entry with only task_id — all optional fields get defaults.
        let agentsJSON = """
        [{"task_id": "minimal-id"}]
        """
        let payload = ["agents": agentsJSON]
        let roster = SubagentEntry.roster(from: payload)
        let entry = roster?.first
        #expect(entry?.taskId == "minimal-id")
        #expect(entry?.name == "")
        #expect(entry?.description == "")
        #expect(entry?.status == "working")
        #expect(entry?.lastTool == "")
        #expect(entry?.tokens == 0)
        #expect(entry?.toolUses == 0)
        #expect(entry?.durationMs == 0)
        #expect(entry?.startedAt == "")
        #expect(entry?.endedAt == "")
    }

    // MARK: - SessionStore.ingestAgents integration

    @Test
    @MainActor
    func ingestAgentsPopulatesRoster() {
        let store = SessionStore()
        let sessionID = "test-agents-\(UUID().uuidString)"
        let agentsJSON = """
        [{"task_id": "tid1", "name": "worker", "status": "working"}]
        """
        store.ingestAgents(sessionID, payload: ["agents": agentsJSON])
        #expect(store.subagentRosters[sessionID]?.count == 1)
        #expect(store.subagentRosters[sessionID]?.first?.name == "worker")
    }

    @Test
    @MainActor
    func ingestAgentsReplacesExistingRoster() {
        let store = SessionStore()
        let sessionID = "test-agents-replace-\(UUID().uuidString)"

        let first = """
        [{"task_id": "t1", "name": "alpha", "status": "working"}]
        """
        store.ingestAgents(sessionID, payload: ["agents": first])
        #expect(store.subagentRosters[sessionID]?.count == 1)

        let second = """
        [
          {"task_id": "t1", "name": "alpha", "status": "done"},
          {"task_id": "t2", "name": "beta",  "status": "working"}
        ]
        """
        store.ingestAgents(sessionID, payload: ["agents": second])
        #expect(store.subagentRosters[sessionID]?.count == 2)
        #expect(store.subagentRosters[sessionID]?.first?.status == "done")
    }

    @Test
    @MainActor
    func ingestAgentsNoOpOnBadPayload() {
        let store = SessionStore()
        let sessionID = "test-agents-noop-\(UUID().uuidString)"
        store.ingestAgents(sessionID, payload: [:])
        #expect(store.subagentRosters[sessionID] == nil)
    }
}
