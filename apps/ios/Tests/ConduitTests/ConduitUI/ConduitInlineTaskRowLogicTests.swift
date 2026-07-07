import Testing
import Foundation
@testable import Conduit

/// Pins `ConduitInlineTaskLogic` (design handoff session_tasks PR4): the
/// transcript's `kind == "subagent"` event has no shared id with a live
/// `SubagentEntry`, so these tests exercise the name/description +
/// nearest-timestamp fallback match, and the static last-resort mapping
/// when nothing in the roster matches.
@Suite("ConduitInlineTaskLogic")
struct ConduitInlineTaskRowLogicTests {

    private func item(
        content: String,
        status: String = "done",
        ts: String = "2026-07-01T10:00:10Z"
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            role: "system",
            kind: "subagent",
            status: status,
            content: content,
            ts: ts,
            files: [],
            toolName: nil,
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

    private func entry(
        taskId: String = "t1",
        name: String = "",
        description: String = "",
        status: String = "working",
        lastTool: String = "",
        startedAt: String = "2026-07-01T10:00:00Z",
        endedAt: String = ""
    ) -> SubagentEntry {
        SubagentEntry(
            taskId: taskId,
            name: name,
            description: description,
            status: status,
            lastTool: lastTool,
            tokens: 0,
            toolUses: 0,
            durationMs: 0,
            startedAt: startedAt,
            endedAt: endedAt
        )
    }

    // MARK: - extractedTitle

    @Test func extractsTitleAfterSubagentStartedPrefix() {
        let title = ConduitInlineTaskLogic.extractedTitle(
            from: "subagent started: investigating the build failure"
        )
        #expect(title == "investigating the build failure")
    }

    @Test func extractsTitleAfterSpawningAgentPrefix() {
        let title = ConduitInlineTaskLogic.extractedTitle(
            from: "Spawning agent for parallel investigation"
        )
        #expect(title == "for parallel investigation")
    }

    @Test func extractsTitleAfterHyphenatedPrefix() {
        let title = ConduitInlineTaskLogic.extractedTitle(from: "sub-agent failed: build broke")
        #expect(title == "build broke")
    }

    @Test func fallsBackToFirstLineWhenNoKnownPrefix() {
        let title = ConduitInlineTaskLogic.extractedTitle(from: "some other system text\nsecond line")
        #expect(title == "some other system text")
    }

    @Test func fallsBackToPlaceholderForEmptyContent() {
        let title = ConduitInlineTaskLogic.extractedTitle(from: "   ")
        #expect(title == "Subagent activity")
    }

    // MARK: - matchingRosterEntry

    @Test func matchesByNameSubstring() {
        let roster = [
            entry(taskId: "a", name: "ci-reviewer"),
            entry(taskId: "b", name: "build-fixer"),
        ]
        let match = ConduitInlineTaskLogic.matchingRosterEntry(
            title: "build-fixer is investigating the build failure",
            eventTs: "2026-07-01T10:00:05Z",
            roster: roster
        )
        #expect(match?.taskId == "b")
    }

    @Test func matchesByDescriptionSubstring() {
        let roster = [
            entry(taskId: "a", description: "investigating the build failure"),
        ]
        let match = ConduitInlineTaskLogic.matchingRosterEntry(
            title: "investigating the build failure",
            eventTs: "2026-07-01T10:00:05Z",
            roster: roster
        )
        #expect(match?.taskId == "a")
    }

    @Test func breaksTiesByNearestStartedAt() {
        let roster = [
            entry(taskId: "far", name: "worker", startedAt: "2026-07-01T09:00:00Z"),
            entry(taskId: "near", name: "worker", startedAt: "2026-07-01T10:00:08Z"),
        ]
        let match = ConduitInlineTaskLogic.matchingRosterEntry(
            title: "worker",
            eventTs: "2026-07-01T10:00:10Z",
            roster: roster
        )
        #expect(match?.taskId == "near")
    }

    @Test func returnsNilForEmptyRoster() {
        let match = ConduitInlineTaskLogic.matchingRosterEntry(
            title: "anything",
            eventTs: "2026-07-01T10:00:10Z",
            roster: []
        )
        #expect(match == nil)
    }

    @Test func fallsBackToFirstEntryWhenNoTextMatch() {
        let roster = [entry(taskId: "only", name: "totally-unrelated-name")]
        let match = ConduitInlineTaskLogic.matchingRosterEntry(
            title: "investigating the build failure",
            eventTs: "2026-07-01T10:00:10Z",
            roster: roster
        )
        #expect(match?.taskId == "only")
    }

    // MARK: - rowModel

    @Test func rowModelBindsLiveRunningEntryWithElapsedAndTail() {
        let now = Date(timeIntervalSince1970: 100)
        let roster = [
            entry(
                taskId: "t1",
                name: "build-fixer",
                status: "working",
                lastTool: "swift build",
                startedAt: conduitConversationTsString(epoch: 30)
            ),
        ]
        let event = item(content: "subagent started: build-fixer", ts: conduitConversationTsString(epoch: 30))
        let model = ConduitInlineTaskLogic.rowModel(for: event, roster: roster, now: now)
        #expect(model.isLive == true)
        #expect(model.status == .running)
        #expect(model.title == "build-fixer")
        #expect(model.tail == "swift build")
        #expect(model.elapsed == ConduitTasksSheetLogic.elapsedLabel(seconds: 70))
    }

    @Test func rowModelBindsLiveDoneEntryWithNoElapsed() {
        let roster = [entry(taskId: "t1", name: "build-fixer", status: "done")]
        let event = item(content: "subagent done: build-fixer", status: "done")
        let model = ConduitInlineTaskLogic.rowModel(for: event, roster: roster, now: Date())
        #expect(model.isLive == true)
        #expect(model.status == .done)
        #expect(model.elapsed == nil)
    }

    @Test func rowModelFallsBackToStaticDoneWithNoRosterMatch() {
        let event = item(content: "subagent started: orphaned task", status: "done")
        let model = ConduitInlineTaskLogic.rowModel(for: event, roster: [], now: Date())
        #expect(model.isLive == false)
        #expect(model.status == .done)
        #expect(model.title == "orphaned task")
        #expect(model.elapsed == nil)
    }

    @Test func rowModelFallsBackToStaticErrorWhenEventStatusFailed() {
        let event = item(content: "subagent failed: orphaned task", status: "failed")
        let model = ConduitInlineTaskLogic.rowModel(for: event, roster: [], now: Date())
        #expect(model.isLive == false)
        #expect(model.status == .error)
    }

    @Test func rowModelStaticTailUsesSecondContentLine() {
        let event = item(content: "subagent started: orphaned task\n$ swift build ... 214/280 files")
        let model = ConduitInlineTaskLogic.rowModel(for: event, roster: [], now: Date())
        #expect(model.tail == "$ swift build ... 214/280 files")
    }
}
