import Testing
@testable import SweKitty

/// Pins the pure classification logic the neon tool / command / diff
/// cards lean on (no SwiftUI host): bash-vs-other detection, the tool
/// icon / tint mapping, the human label, and the `+N −M` diff-summary
/// parser. The VIEWS restyle freely; these mappings are the contract.
@Suite("Neon tool-card logic")
struct NeonToolCardLogicTests {

    // MARK: isCommand

    @Test func commandPresentIsCommand() {
        #expect(NeonToolClassifier.isCommand(toolName: "anything", command: "ls -la"))
    }

    @Test func shellNameIsCommand() {
        #expect(NeonToolClassifier.isCommand(toolName: "Bash", command: nil))
        #expect(NeonToolClassifier.isCommand(toolName: "exec", command: nil))
        #expect(NeonToolClassifier.isCommand(toolName: "terminal", command: ""))
    }

    @Test func nonShellWithoutCommandIsNotCommand() {
        #expect(!NeonToolClassifier.isCommand(toolName: "Read", command: nil))
        #expect(!NeonToolClassifier.isCommand(toolName: "Search", command: "   "))
        #expect(!NeonToolClassifier.isCommand(toolName: nil, command: nil))
    }

    // MARK: tint role

    @Test func tintRoleMapping() {
        #expect(NeonToolClassifier.tintRole(forToolName: "Grep") == .purple)
        #expect(NeonToolClassifier.tintRole(forToolName: "search_codebase") == .purple)
        #expect(NeonToolClassifier.tintRole(forToolName: "Read") == .blue)
        #expect(NeonToolClassifier.tintRole(forToolName: "Edit") == .claude)
        #expect(NeonToolClassifier.tintRole(forToolName: "Write") == .claude)
        #expect(NeonToolClassifier.tintRole(forToolName: "Bash") == .green)
        #expect(NeonToolClassifier.tintRole(forToolName: "MysteryTool") == .accent)
        #expect(NeonToolClassifier.tintRole(forToolName: nil) == .accent)
    }

    // MARK: human label

    @Test func humanLabels() {
        #expect(NeonToolClassifier.humanLabel(toolName: "Grep", fileCount: 0) == "Searched the codebase")
        #expect(NeonToolClassifier.humanLabel(toolName: "Read", fileCount: 1) == "Read 1 file")
        #expect(NeonToolClassifier.humanLabel(toolName: "Read", fileCount: 2) == "Read 2 files")
        #expect(NeonToolClassifier.humanLabel(toolName: "Edit", fileCount: 1) == "Edited 1 file")
        #expect(NeonToolClassifier.humanLabel(toolName: "Bash", fileCount: 0) == "Ran a command")
        // Unknown tool → title-cased name.
        #expect(NeonToolClassifier.humanLabel(toolName: "fetch", fileCount: 0) == "Fetch")
        #expect(NeonToolClassifier.humanLabel(toolName: nil, fileCount: 0) == "Tool activity")
    }

    // MARK: diff-summary parsing

    @Test func diffStatPlusMinus() {
        let s = NeonDiffStat.parse("+12 -3")
        #expect(s.added == 12)
        #expect(s.removed == 3)
    }

    @Test func diffStatSlashForm() {
        let s = NeonDiffStat.parse("+8/-2")
        #expect(s.added == 8)
        #expect(s.removed == 2)
    }

    @Test func diffStatUnicodeMinus() {
        let s = NeonDiffStat.parse("+5 \u{2212}1")
        #expect(s.added == 5)
        #expect(s.removed == 1)
    }

    @Test func diffStatWordForm() {
        let s = NeonDiffStat.parse("12 additions, 3 deletions")
        #expect(s.added == 12)
        #expect(s.removed == 3)
    }

    @Test func diffStatEmpty() {
        let s = NeonDiffStat.parse(nil)
        #expect(s.added == nil)
        #expect(s.removed == nil)
        let blank = NeonDiffStat.parse("")
        #expect(blank.added == nil)
        #expect(blank.removed == nil)
    }
}
