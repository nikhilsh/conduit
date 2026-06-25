import Testing
import Foundation
@testable import Conduit

/// Pins the pure logic helpers for the §10 command-run Mono block
/// (commandRunBlock feature flag). All helpers live in
/// `CommandRunBlockLogic` (internal enum in ConduitChatView.swift) so
/// no SwiftUI host is needed.
@Suite("CommandRunBlockLogic")
struct CommandRunBlockLogicTests {

    // MARK: - Failed-row surfacing

    @Test func noFailedItemsReturnsEmpty() {
        let items = [
            makeItem(id: "a", status: "done", exitCode: 0),
            makeItem(id: "b", status: "done", exitCode: nil),
        ]
        #expect(CommandRunBlockLogic.failedItems(from: items).isEmpty)
    }

    @Test func failedByNonzeroExitCode() {
        let items = [
            makeItem(id: "ok",  status: "done", exitCode: 0),
            makeItem(id: "bad", status: "done", exitCode: 127),
        ]
        let failed = CommandRunBlockLogic.failedItems(from: items)
        #expect(failed.count == 1)
        #expect(failed[0].id == "bad")
    }

    @Test func failedByStatus() {
        let items = [
            makeItem(id: "ok",   status: "done",   exitCode: 0),
            makeItem(id: "fail", status: "failed",  exitCode: nil),
        ]
        let failed = CommandRunBlockLogic.failedItems(from: items)
        #expect(failed.count == 1)
        #expect(failed[0].id == "fail")
    }

    @Test func allFailedReturnsAll() {
        let items = [
            makeItem(id: "a", status: "failed", exitCode: 1),
            makeItem(id: "b", status: "done",   exitCode: 2),
        ]
        let failed = CommandRunBlockLogic.failedItems(from: items)
        #expect(failed.count == 2)
    }

    @Test func failedItemsPreservesOrder() {
        let items = [
            makeItem(id: "x", status: "failed", exitCode: nil),
            makeItem(id: "y", status: "done",   exitCode: 0),
            makeItem(id: "z", status: "failed", exitCode: 1),
        ]
        let failed = CommandRunBlockLogic.failedItems(from: items)
        #expect(failed.map { $0.id } == ["x", "z"])
    }

    // MARK: - Ticker fraction

    @Test func tickerFractionZeroTotalIsZero() {
        #expect(CommandRunBlockLogic.tickerFraction(completedCount: 5, totalCount: 0) == 0.0)
    }

    @Test func tickerFractionNoneCompleted() {
        #expect(CommandRunBlockLogic.tickerFraction(completedCount: 0, totalCount: 10) == 0.0)
    }

    @Test func tickerFractionHalf() {
        let f = CommandRunBlockLogic.tickerFraction(completedCount: 5, totalCount: 10)
        #expect(f == 0.5)
    }

    @Test func tickerFractionComplete() {
        let f = CommandRunBlockLogic.tickerFraction(completedCount: 10, totalCount: 10)
        #expect(f == 1.0)
    }

    @Test func tickerFractionClampedAt1() {
        // Should never exceed 1.0 even if completed > total.
        let f = CommandRunBlockLogic.tickerFraction(completedCount: 12, totalCount: 10)
        #expect(f == 1.0)
    }

    @Test func tickerFractionRealWorldCase() {
        // Screen 14 shows "41 / 73" -- fraction = 41/73.
        let f = CommandRunBlockLogic.tickerFraction(completedCount: 41, totalCount: 73)
        #expect(abs(f - 41.0 / 73.0) < 1e-9)
    }

    // MARK: - Feature-flag persistence

    @Test func commandRunBlockDefaultsOn() {
        let flags = FeatureFlags(defaults: freshDefaults())
        #expect(flags.commandRunBlock == true)
    }

    @Test func commandRunBlockPersists() {
        let defaults = freshDefaults()
        let first = FeatureFlags(defaults: defaults)
        first.commandRunBlock = true
        let second = FeatureFlags(defaults: defaults)
        #expect(second.commandRunBlock == true)
    }

    // MARK: - Helpers

    private func makeItem(id: String, status: String, exitCode: Int32?) -> ConversationItem {
        ConversationItem(
            id: id,
            role: "tool",
            kind: "tool",
            status: status,
            content: "output",
            ts: "2026-06-22T12:00:00Z",
            files: [],
            toolName: "Bash",
            command: "ls",
            exitCode: exitCode,
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

    private func freshDefaults() -> UserDefaults {
        let suite = "conduit.tests.commandrunblock.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }
}
