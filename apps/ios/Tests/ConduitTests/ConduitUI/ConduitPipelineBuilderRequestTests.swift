import Foundation
import Testing
@testable import Conduit

/// Pins the PLAN-HARNESS-BUILDER Phase 1 wire encoding/decoding for the
/// pipeline Builder: `PipelineRequestStep` (shared by the create-pipeline
/// and save-template requests) must emit the four per-block config fields
/// (+ fanout parallel arrays) only when non-empty, and `PipelineTemplateStep`
/// must tolerate their absence (old broker / template saved before this
/// shipped). Mirror of Android `PipelineBuilderScreenTest`.
@Suite("ConduitUI pipeline request wire types")
struct ConduitPipelineBuilderRequestTests {

    private func jsonObject(_ step: ConduitUI.PipelineRequestStep) throws -> [String: Any] {
        let data = try JSONEncoder().encode(step)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj ?? [:]
    }

    @Test func omitsConfigFieldsWhenEmpty() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "claude"
        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        #expect(obj["model"] == nil)
        #expect(obj["reasoning_effort"] == nil)
        #expect(obj["permission_mode"] == nil)
        #expect(obj["instructions"] == nil)
        #expect(obj["fanout"] == nil)
    }

    @Test func emitsConfigFieldsWhenSet() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "claude"
        step.model = "opus"
        step.reasoningEffort = "high"
        step.permissionMode = "plan"
        step.instructions = "Be terse."
        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        #expect(obj["model"] as? String == "opus")
        #expect(obj["reasoning_effort"] as? String == "high")
        #expect(obj["permission_mode"] as? String == "plan")
        #expect(obj["instructions"] as? String == "Be terse.")
    }

    @Test func emitsFanoutParallelArraysWhenSet() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "claude"
        step.fanoutEnabled = true
        step.fanoutCount = 3
        step.fanoutAgentTypes = ["claude", "codex", "gemini"]
        step.fanoutModels = ["opus", "", ""]
        step.fanoutReasoningEfforts = ["high", "", ""]
        step.fanoutPermissionModes = ["", "", "plan"]
        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        let fanout = obj["fanout"] as? [String: Any]
        #expect(fanout?["count"] as? Int == 3)
        #expect((fanout?["models"] as? [String])?.first == "opus")
        #expect((fanout?["reasoning_efforts"] as? [String])?.first == "high")
        #expect((fanout?["permission_modes"] as? [String])?.last == "plan")
        // No per-run instructions field -- runs share the block's
        // instructions (owner decision §8.1). PipelineRequestFanout has no
        // instructions property at all, so this is a compile-time guarantee;
        // this assertion documents the wire contract for a JSON reader too.
        #expect(fanout?["instructions"] == nil)
    }

    @Test func omitsFanoutArraysWhenEmpty() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "claude"
        step.fanoutEnabled = true
        step.fanoutCount = 2
        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        let fanout = obj["fanout"] as? [String: Any]
        #expect(fanout?["models"] == nil)
        #expect(fanout?["reasoning_efforts"] == nil)
        #expect(fanout?["permission_modes"] == nil)
    }

    // MARK: - PipelineTemplateStep decode tolerance

    @Test func templateStepToleratesAbsentConfigFields() throws {
        // A template saved before PLAN-HARNESS-BUILDER Phase 1 shipped.
        let raw = """
        {"agent_type":"claude","role":"engineer","prompt_template":"x",
         "input_from_prev":"none","gate_after":false}
        """.data(using: .utf8)!
        let step = try JSONDecoder().decode(ConduitUI.PipelineTemplateStep.self, from: raw)
        #expect(step.model == nil)
        #expect(step.reasoning_effort == nil)
        #expect(step.permission_mode == nil)
        #expect(step.instructions == nil)
    }

    @Test func templateStepDecodesConfigFieldsWhenPresent() throws {
        let raw = """
        {"agent_type":"claude","role":"engineer","prompt_template":"x",
         "input_from_prev":"none","gate_after":true,
         "model":"sonnet","reasoning_effort":"low",
         "permission_mode":"plan","instructions":"Only touch the parser."}
        """.data(using: .utf8)!
        let step = try JSONDecoder().decode(ConduitUI.PipelineTemplateStep.self, from: raw)
        #expect(step.model == "sonnet")
        #expect(step.reasoning_effort == "low")
        #expect(step.permission_mode == "plan")
        #expect(step.instructions == "Only touch the parser.")
    }
}
