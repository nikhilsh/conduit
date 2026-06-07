import Testing
import Foundation
@testable import Conduit

/// Pins the contiguous-tool-run grouping (#4): runs of `minRun`+ groupable
/// tool events collapse into one `.toolGroup`; everything else stays a
/// `.single`, and a non-tool event breaks the run.
@Suite("ConduitUI.ChatGrouping")
struct ConduitChatGroupingTests {

    private func item(_ role: String, _ id: String, toolName: String? = nil) -> ConversationItem {
        ConversationItem(
            id: id,
            role: role,
            kind: role.lowercased() == "tool" ? "tool" : "message",
            status: "done",
            content: "x",
            ts: "2026-06-05T10:00:00Z",
            files: [],
            toolName: toolName,
            command: nil,
            exitCode: nil,
            durationMs: nil,
            diffSummary: nil,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: nil,
            resultSummary: nil,
            planSteps: []
        )
    }

    // Treat any tool event as groupable for these tests.
    private func group(_ events: [ConversationItem], minRun: Int = 3) -> [ConduitUI.ChatRow] {
        ConduitUI.ChatViewModel.groupedRows(events, minRun: minRun) { $0.role.lowercased() == "tool" }
    }

    @Test func collapsesRunAtOrAboveThreshold() {
        let rows = group([
            item("user", "u1"),
            item("tool", "t1"), item("tool", "t2"), item("tool", "t3"),
            item("assistant", "a1"),
        ])
        #expect(rows.count == 3)
        guard case .single = rows[0] else { Issue.record("row0 should be single"); return }
        guard case .toolGroup(let g) = rows[1] else { Issue.record("row1 should be group"); return }
        #expect(g.count == 3)
        guard case .single = rows[2] else { Issue.record("row2 should be single"); return }
    }

    @Test func shortRunStaysSingles() {
        // Two tools (below the default threshold of 3) are not collapsed.
        let rows = group([item("tool", "t1"), item("tool", "t2")])
        #expect(rows.count == 2)
        for row in rows {
            guard case .single = row else { Issue.record("should stay single"); return }
        }
    }

    @Test func nonToolBreaksTheRun() {
        // tool,tool,assistant,tool,tool → no run reaches 3 → all singles.
        let rows = group([
            item("tool", "t1"), item("tool", "t2"),
            item("assistant", "a1"),
            item("tool", "t3"), item("tool", "t4"),
        ])
        #expect(rows.count == 5)
    }

    @Test func groupIdIsStable() {
        let rows = group([item("tool", "t1"), item("tool", "t2"), item("tool", "t3")])
        #expect(rows.count == 1)
        #expect(rows[0].id == "toolgroup-t1-3")
    }
}
