import Testing
import Foundation
@testable import SweKitty

/// Pure derivation tests for `StatsGridModel.compute(from:)`. SwiftUI
/// isn't involved — these exercise the counter logic that backs the
/// 2×3 "Conversation Stats" grid on `SessionInfoView`. The model was
/// lifted out of the view in PR litter-stage3-session-info precisely
/// so it could be unit-tested without booting a host app.
@Suite("StatsGridModel derivation")
struct StatsGridModelTests {

    // MARK: - Helpers

    private func msg(
        id: String = UUID().uuidString,
        role: String,
        content: String = "",
        kind: String = "message",
        toolName: String? = nil,
        command: String? = nil,
        exitCode: Int32? = nil,
        durationMs: UInt64? = nil,
        files: [String] = []
    ) -> ConversationItem {
        ConversationItem(
            id: id,
            role: role,
            kind: kind,
            status: "done",
            content: content,
            ts: "2026-05-22T00:00:00Z",
            files: files.map { ViewEventFile(path: $0, rev: "HEAD") },
            toolName: toolName,
            command: command,
            exitCode: exitCode,
            durationMs: durationMs,
            diffSummary: nil,
            pendingOptions: []
        )
    }

    // MARK: - Empty input

    @Test func emptyInputProducesAllZeros() {
        let model = StatsGridModel.compute(from: [])
        #expect(model == StatsGridModel.empty)
        #expect(model.execTimeLabel == "—")
    }

    // MARK: - Message counts

    @Test func messagesAndTurnsAndUserAssistantBreakdown() {
        let events = [
            msg(role: "user", content: "hi"),
            msg(role: "assistant", content: "hello"),
            msg(role: "user", content: "ping"),
            msg(role: "assistant", content: "pong"),
            msg(role: "system", content: "ignored"),
        ]
        let model = StatsGridModel.compute(from: events)

        #expect(model.messages == 5)
        #expect(model.userMessages == 2)
        #expect(model.assistantMessages == 2)
        // Turns counts user messages only — each user turn fans out
        // into one or more assistant + tool items.
        #expect(model.turns == 2)
    }

    // MARK: - Commands

    @Test func commandsBucketOkAndFailByExitCode() {
        let events = [
            msg(role: "tool", kind: "tool", command: "ls", exitCode: 0),
            msg(role: "tool", kind: "tool", command: "false", exitCode: 1),
            msg(role: "tool", kind: "tool", command: "grep foo", exitCode: 2),
            // No exit code → treated as ok so the secondary line sums to total.
            msg(role: "tool", kind: "tool", command: "cat", exitCode: nil),
            // Empty command should not be counted.
            msg(role: "tool", kind: "tool", command: ""),
            // Tool item with no command at all is not a "Command".
            msg(role: "tool", kind: "tool", toolName: "Edit"),
        ]
        let model = StatsGridModel.compute(from: events)

        #expect(model.commands == 4)
        #expect(model.commandsOk == 2)
        #expect(model.commandsFail == 2)
        #expect(model.commandsOk + model.commandsFail == model.commands)
    }

    // MARK: - MCP

    @Test func mcpCallsCountedByToolName() {
        let events = [
            msg(role: "tool", kind: "tool", toolName: "mcp__github__list_issues"),
            msg(role: "tool", kind: "tool", toolName: "MCP_supabase_query"),
            msg(role: "tool", kind: "tool", toolName: "Edit"),
            // Non-tool kind, even with "mcp" in name, must not count.
            msg(role: "assistant", kind: "message", toolName: "mcp_anywhere"),
        ]
        let model = StatsGridModel.compute(from: events)

        #expect(model.mcpCalls == 2)
    }

    // MARK: - Files

    @Test func filesChangedDeduplicatesPaths() {
        let events = [
            msg(role: "tool", kind: "tool", command: "edit", files: ["a.swift", "b.swift"]),
            msg(role: "tool", kind: "tool", command: "edit", files: ["a.swift", "c.swift"]),
            // Files attached to a plain message still count toward the set.
            msg(role: "assistant", kind: "message", files: ["d.swift"]),
        ]
        let model = StatsGridModel.compute(from: events)

        #expect(model.filesChanged == 4) // a, b, c, d
    }

    // MARK: - Exec time

    @Test func execTimeSumsDurationsAndFormatsCorrectly() {
        let secondsCase = StatsGridModel.compute(from: [
            msg(role: "tool", kind: "tool", command: "x", durationMs: 1500),
            msg(role: "tool", kind: "tool", command: "y", durationMs: 500),
        ])
        #expect(secondsCase.execTimeMs == 2000)
        #expect(secondsCase.execTimeLabel == "2.0s")

        let minutesCase = StatsGridModel.compute(from: [
            msg(role: "tool", kind: "tool", command: "x", durationMs: 90_000),
        ])
        #expect(minutesCase.execTimeLabel == "1.5m")

        let hoursCase = StatsGridModel.compute(from: [
            msg(role: "tool", kind: "tool", command: "x", durationMs: 3_600_000 + 1_800_000),
        ])
        #expect(hoursCase.execTimeLabel == "1.5h")
    }
}
