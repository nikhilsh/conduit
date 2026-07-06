import Foundation
import Testing
@testable import Conduit

/// Pins `ConduitUI.PipelineResult` / `Step.output` decode (tolerant of
/// absence on an old broker) and `ConduitUI.PipelineResultViewModel`'s
/// pure collapse-threshold logic -- the Monitor's Result card (#906/#907).
/// Mirror of Android `PipelineResultViewModelTest`.
@Suite("ConduitUI pipeline result")
struct ConduitPipelineResultViewModelTests {

    // MARK: - Decode: PipelineStatus.result

    @Test func decodesCompleteResponseWithResult() throws {
        let json = """
        {"id":"p_1","title":"t","task":"t","cwd":"/","base":"main",
         "state":"complete","current_step":1,
         "steps":[{"index":0,"agent_type":"claude","role":"worker",
                   "prompt_template":"","input_from_prev":"none","gate_after":false,
                   "output":"did the thing"}],
         "result":{"output":"final output","finished":"2026-07-01T00:00:00Z",
                    "files_changed":3,"insertions":10,"deletions":2,
                    "branches":["pipeline-p_1-step-0"]}}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConduitUI.PipelineStatus.self, from: json)
        #expect(decoded.isComplete)
        #expect(decoded.result?.output == "final output")
        #expect(decoded.result?.files_changed == 3)
        #expect(decoded.result?.insertions == 10)
        #expect(decoded.result?.deletions == 2)
        #expect(decoded.result?.branches == ["pipeline-p_1-step-0"])
        #expect(decoded.steps[0].output == "did the thing")
    }

    @Test func toleratesMissingResultOnOldBroker() throws {
        // An older broker (or a pipeline that completed before #906
        // shipped) has state == "complete" but no result field at all.
        let json = """
        {"id":"p_2","title":"t","task":"t","cwd":"/","base":"main",
         "state":"complete","current_step":1,"steps":[]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConduitUI.PipelineStatus.self, from: json)
        #expect(decoded.isComplete)
        #expect(decoded.result == nil)
    }

    @Test func toleratesMissingStepOutput() throws {
        let json = """
        {"id":"p_3","title":"t","task":"t","cwd":"/","base":"main",
         "state":"running","current_step":0,
         "steps":[{"index":0,"agent_type":"claude","role":"worker",
                   "prompt_template":"","input_from_prev":"none","gate_after":false}]}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConduitUI.PipelineStatus.self, from: json)
        #expect(decoded.steps[0].output == nil)
    }

    @Test func resultDecodeToleratesMissingBranches() throws {
        let json = """
        {"output":"x","finished":"2026-07-01T00:00:00Z",
         "files_changed":0,"insertions":0,"deletions":0}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ConduitUI.PipelineResult.self, from: json)
        #expect(decoded.branches == nil)
    }

    // MARK: - Collapse threshold

    @Test func shortOutputNeedsNoCollapse() {
        let text = (0..<5).map { "line \($0)" }.joined(separator: "\n")
        #expect(!ConduitUI.PipelineResultViewModel.needsCollapse(text))
        #expect(ConduitUI.PipelineResultViewModel.collapsed(text) == text)
    }

    @Test func longOutputNeedsCollapse() {
        let lines = (0..<40).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        #expect(ConduitUI.PipelineResultViewModel.needsCollapse(text))
        let collapsed = ConduitUI.PipelineResultViewModel.collapsed(text)
        #expect(collapsed == lines.prefix(12).joined(separator: "\n"))
    }

    @Test func exactlyAtThresholdDoesNotCollapse() {
        let lines = (0..<12).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        #expect(!ConduitUI.PipelineResultViewModel.needsCollapse(text))
    }

    @Test func oneOverThresholdCollapses() {
        let lines = (0..<13).map { "line \($0)" }
        let text = lines.joined(separator: "\n")
        #expect(ConduitUI.PipelineResultViewModel.needsCollapse(text))
        #expect(ConduitUI.PipelineResultViewModel.collapsed(text) == lines.prefix(12).joined(separator: "\n"))
    }
}
