import Testing
import Foundation
@testable import Conduit

/// Pins the pure recap derivation (handoff §B.9): the honest outcome chip,
/// the "what changed" priority ladder (agent prose → file paths → commit
/// count → empty), distinct-file ordering, wall-clock parsing, and `fmtK`.
/// Mirror of the Android `SessionRecapModelTest`.
@Suite("ConduitUI.Recap")
struct ConduitSessionRecapTests {

    private func item(
        role: String = "tool",
        files: [ViewEventFile] = [],
        command: String? = nil,
        diffSummary: String? = nil,
        taskText: String? = nil,
        resultSummary: String? = nil
    ) -> ConversationItem {
        ConversationItem(
            id: UUID().uuidString,
            role: role,
            kind: role.lowercased() == "tool" ? "tool" : "message",
            status: "done",
            content: "",
            ts: "2026-06-05T10:00:00Z",
            files: files,
            toolName: nil,
            command: command,
            exitCode: nil,
            durationMs: nil,
            diffSummary: diffSummary,
            pendingOptions: [],
            sourceAgent: nil,
            targetAgent: nil,
            taskText: taskText,
            resultSummary: resultSummary,
            planSteps: []
        )
    }

    // MARK: Outcome

    @Test func outcomeMergedWins() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: 12, prState: "merged", lifecycle: .exited(0)) == .merged)
    }

    @Test func outcomeOpenPR() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: 12, prState: "open", lifecycle: nil) == .pr)
    }

    @Test func outcomePRNumberWithoutState() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: 7, prState: nil, lifecycle: nil) == .pr)
    }

    @Test func outcomeFailedLifecycle() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: nil, prState: nil, lifecycle: .failed("boom")) == .failed)
    }

    @Test func outcomeEndedLifecycle() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: nil, prState: nil, lifecycle: .exited(0)) == .ended)
    }

    @Test func outcomeNeutralWhenUnknown() {
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: nil, prState: nil, lifecycle: .live) == .neutral)
        #expect(ConduitUI.Recap.deriveOutcome(prNumber: 0, prState: nil, lifecycle: nil) == .neutral)
    }

    // MARK: What changed

    @Test func whatChangedPrefersAgentProse() {
        let log = [
            item(resultSummary: "Replaced the retry-less fetch with exponential backoff"),
            item(files: [ViewEventFile(path: "a.swift", rev: "1")]),
        ]
        let files = ConduitUI.Recap.distinctFiles(log)
        let bullets = ConduitUI.Recap.deriveWhatChanged(log: log, displayName: "x", filePaths: files, commits: 3)
        #expect(bullets == ["Replaced the retry-less fetch with exponential backoff"])
    }

    @Test func whatChangedFirstLineOnlyAndDeduped() {
        let log = [
            item(resultSummary: "Fixed auth\n\nlong details here"),
            item(resultSummary: "Fixed auth"),
        ]
        let bullets = ConduitUI.Recap.deriveWhatChanged(log: log, displayName: "x", filePaths: [], commits: 0)
        #expect(bullets == ["Fixed auth"])
    }

    @Test func whatChangedFallsBackToFilePaths() {
        let log = [
            item(files: [ViewEventFile(path: "src/a.rs", rev: "1"), ViewEventFile(path: "src/b.rs", rev: "1")]),
        ]
        let files = ConduitUI.Recap.distinctFiles(log)
        let bullets = ConduitUI.Recap.deriveWhatChanged(log: log, displayName: "x", filePaths: files, commits: 0)
        #expect(bullets == ["src/a.rs", "src/b.rs"])
    }

    @Test func whatChangedFallsBackToCommitCount() {
        let bullets = ConduitUI.Recap.deriveWhatChanged(log: [], displayName: "x", filePaths: [], commits: 2)
        #expect(bullets == ["2 commits landed"])
    }

    @Test func whatChangedEmptyWhenNoSignal() {
        let bullets = ConduitUI.Recap.deriveWhatChanged(log: [], displayName: "x", filePaths: [], commits: 0)
        #expect(bullets.isEmpty)
    }

    // MARK: Distinct files

    @Test func distinctFilesOrderedAndDeduped() {
        let log = [
            item(files: [ViewEventFile(path: "a", rev: "1"), ViewEventFile(path: "b", rev: "1")]),
            item(files: [ViewEventFile(path: "a", rev: "2")]),
        ]
        #expect(ConduitUI.Recap.distinctFiles(log) == ["a", "b"])
    }

    // MARK: Parse

    @Test func parseISOAcceptsBothForms() {
        #expect(ConduitUI.Recap.parseISO("2026-06-05T10:00:00Z") != nil)
        #expect(ConduitUI.Recap.parseISO("2026-06-05T10:00:00.123Z") != nil)
        #expect(ConduitUI.Recap.parseISO(nil) == nil)
    }

    // MARK: fmtK

    @Test func fmtK() {
        #expect(ConduitUI.SessionRecapView.fmtK(950) == "950")
        #expect(ConduitUI.SessionRecapView.fmtK(1_500) == "2k")
        #expect(ConduitUI.SessionRecapView.fmtK(2_000_000) == "2.0M")
    }
}
