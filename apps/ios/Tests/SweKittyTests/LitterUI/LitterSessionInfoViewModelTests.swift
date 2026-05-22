import Testing
import Foundation
@testable import SweKitty

@Suite("LitterUI.SessionInfoViewModel")
struct LitterSessionInfoViewModelTests {

    @Test func statsReadDirectlyFromSnapshotCounts() {
        let snap = LitterUI.SessionInfoSnapshot(
            sessionID: "x",
            displayName: "x",
            assistant: "claude",
            reasoningEffort: "medium",
            cwd: "/work",
            startedAt: nil,
            messagesCount: 42,
            turnsCount: 7,
            commandsCount: 3,
            filesChangedCount: 11,
            mcpCallsCount: 2,
            execTimeMs: 73_000
        )
        let stats = LitterUI.SessionInfoViewModel.stats(snap)
        let dict = Dictionary(uniqueKeysWithValues: stats.map { ($0.title, $0.value) })
        #expect(dict["Messages"] == "42")
        #expect(dict["Turns"] == "7")
        #expect(dict["Commands"] == "3")
        #expect(dict["Files Changed"] == "11")
        #expect(dict["MCP Calls"] == "2")
        #expect(dict["Exec Time"] == "1m 13s")
    }

    @Test func execTimeRendersHumanReadable() {
        #expect(LitterUI.SessionInfoViewModel.formatDuration(0) == "—")
        #expect(LitterUI.SessionInfoViewModel.formatDuration(500) == "0s")
        #expect(LitterUI.SessionInfoViewModel.formatDuration(45_000) == "45s")
        #expect(LitterUI.SessionInfoViewModel.formatDuration(125_000) == "2m 5s")
        #expect(LitterUI.SessionInfoViewModel.formatDuration(3_725_000) == "1h 2m")
    }
}
