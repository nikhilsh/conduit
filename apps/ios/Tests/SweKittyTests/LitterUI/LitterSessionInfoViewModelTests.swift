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
            lastActivityAt: nil,
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

    @Test func detailsAlwaysIncludeModelAndOmitTimestampsWhenAbsent() {
        var snap = LitterUI.SessionInfoSnapshot.empty
        snap.assistant = "claude"
        snap.reasoningEffort = "high"
        let details = LitterUI.SessionInfoViewModel.details(snap)
        let dict = Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) })
        // Model is always present (qualified by reasoning effort).
        #expect(dict["Model"] == "claude · high")
        // No timestamps → no Started / Last Activity / Uptime rows.
        #expect(dict["Started"] == nil)
        #expect(dict["Last Activity"] == nil)
        #expect(dict["Uptime"] == nil)
    }

    @Test func detailsComputeUptimeFromStartedToLastActivity() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let last = started.addingTimeInterval(125) // 2m 5s
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var snap = LitterUI.SessionInfoSnapshot.empty
        snap.assistant = "claude"
        snap.startedAt = iso.string(from: started)
        snap.lastActivityAt = iso.string(from: last)
        let details = LitterUI.SessionInfoViewModel.details(snap, now: last.addingTimeInterval(3600))
        let dict = Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) })
        #expect(dict["Uptime"] == "2m 5s")
        #expect(details.contains { $0.label == "Started" })
        #expect(details.contains { $0.label == "Last Activity" })
    }

    @Test func relativeFormatsCompactBuckets() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(LitterUI.SessionInfoViewModel.relative(now.addingTimeInterval(-30), now: now) == "just now")
        #expect(LitterUI.SessionInfoViewModel.relative(now.addingTimeInterval(-300), now: now) == "5m ago")
        #expect(LitterUI.SessionInfoViewModel.relative(now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(LitterUI.SessionInfoViewModel.relative(now.addingTimeInterval(-172_800), now: now) == "2d ago")
    }
}
