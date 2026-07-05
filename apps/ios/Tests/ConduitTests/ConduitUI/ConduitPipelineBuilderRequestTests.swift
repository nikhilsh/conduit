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

    // MARK: - PLAN-HARNESS-BUILDER Phase 3: branch/loop recursive encoding

    @Test func branchStepEncodesConditionAndNestedThenElse() throws {
        var step = ConduitUI.PipelineStep()
        step.kind = "branch"
        step.branchConditionSource = "prev_output"
        step.branchConditionPredicate = "contains"
        step.branchConditionValue = "APPROVED"
        var then1 = ConduitUI.PipelineSubStep()
        then1.agentType = "codex"
        then1.role = "engineer"
        var then2 = ConduitUI.PipelineSubStep()
        then2.agentType = "claude"
        then2.model = "opus"
        step.branchThen = [then1, then2]
        var elseStep = ConduitUI.PipelineSubStep()
        elseStep.agentType = "claude"
        elseStep.role = "researcher"
        step.branchElse = [elseStep]

        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        #expect(obj["kind"] as? String == "branch")
        #expect(obj["loop"] == nil)
        let branch = try #require(obj["branch"] as? [String: Any])
        let condition = try #require(branch["condition"] as? [String: Any])
        #expect(condition["source"] as? String == "prev_output")
        #expect(condition["predicate"] as? String == "contains")
        #expect(condition["value"] as? String == "APPROVED")
        let then = try #require(branch["then"] as? [[String: Any]])
        #expect(then.count == 2)
        #expect(then[0]["agent_type"] as? String == "codex")
        #expect(then[1]["model"] as? String == "opus")
        let elseArm = try #require(branch["else"] as? [[String: Any]])
        #expect(elseArm.count == 1)
        #expect(elseArm[0]["role"] as? String == "researcher")
    }

    @Test func branchExitStatusConditionOmitsValue() throws {
        var step = ConduitUI.PipelineStep()
        step.kind = "branch"
        step.branchConditionSource = "exit_status"
        step.branchConditionPredicate = "succeeded"
        step.branchConditionValue = "" // unused for exit_status
        step.branchThen = [ConduitUI.PipelineSubStep()]

        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        let branch = try #require(obj["branch"] as? [String: Any])
        let condition = try #require(branch["condition"] as? [String: Any])
        #expect(condition["source"] as? String == "exit_status")
        #expect(condition["predicate"] as? String == "succeeded")
        #expect(condition["value"] == nil)
    }

    @Test func loopStepEncodesBodyUntilAndMaxIterations() throws {
        var step = ConduitUI.PipelineStep()
        step.kind = "loop"
        var body1 = ConduitUI.PipelineSubStep()
        body1.agentType = "claude"
        body1.instructions = "Iterate until tests pass."
        step.loopBody = [body1]
        step.loopUntilSource = "prev_output"
        step.loopUntilPredicate = "contains"
        step.loopUntilValue = "DONE"
        step.loopMaxIterations = 4

        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        #expect(obj["kind"] as? String == "loop")
        #expect(obj["branch"] == nil)
        let loop = try #require(obj["loop"] as? [String: Any])
        let body = try #require(loop["body"] as? [[String: Any]])
        #expect(body.count == 1)
        #expect(body[0]["instructions"] as? String == "Iterate until tests pass.")
        let until = try #require(loop["until"] as? [String: Any])
        #expect(until["value"] as? String == "DONE")
        #expect(loop["max_iterations"] as? Int == 4)
    }

    @Test func agentStepOmitsControlFlowFields() throws {
        var step = ConduitUI.PipelineStep()
        step.agentType = "claude"
        let obj = try jsonObject(ConduitUI.PipelineRequestStep(step))
        #expect(obj["kind"] == nil)
        #expect(obj["branch"] == nil)
        #expect(obj["loop"] == nil)
    }

    // MARK: - Depth-2 guard (enforced by construction -- PipelineSubStep has
    // no kind/branch/loop/fanout fields at all). A broker response with a
    // nested branch inside a Then arm (which the broker itself would never
    // produce -- PrepareSteps rejects depth > 2 at create time) still
    // decodes safely: the extra keys are ignored, proving the type system
    // bound rather than a runtime check.

    @Test func templateSubStepIgnoresNestedControlFlowKeys() throws {
        let raw = """
        {"agent_type":"claude","role":"engineer","prompt_template":"x",
         "input_from_prev":"none","gate_after":false,
         "kind":"branch","branch":{"condition":{"source":"prev_output","predicate":"contains","value":"x"}}}
        """.data(using: .utf8)!
        let sub = try JSONDecoder().decode(ConduitUI.PipelineTemplateSubStep.self, from: raw)
        #expect(sub.agent_type == "claude")
        // No kind/branch/loop properties exist on PipelineTemplateSubStep at
        // all -- this compiles only because the type has no such fields.
    }

    @Test func templateBranchDecodesNestedThenElseSubSteps() throws {
        let raw = """
        {"agent_type":"claude","role":"engineer","prompt_template":"x",
         "input_from_prev":"none","gate_after":false,
         "kind":"branch",
         "branch":{
           "condition":{"source":"prev_output","predicate":"matches","value":"^OK$"},
           "then":[{"agent_type":"codex","role":"engineer","prompt_template":"","input_from_prev":"none","gate_after":false}],
           "else":[{"agent_type":"claude","role":"researcher","prompt_template":"","input_from_prev":"none","gate_after":false}]
         }}
        """.data(using: .utf8)!
        let step = try JSONDecoder().decode(ConduitUI.PipelineTemplateStep.self, from: raw)
        #expect(step.kind == "branch")
        let branch = try #require(step.branch)
        #expect(branch.condition.predicate == "matches")
        #expect(branch.then?.first?.agent_type == "codex")
        #expect(branch.elseArm?.first?.role == "researcher")
    }

    @Test func templateLoopDecodesBodyAndUntil() throws {
        let raw = """
        {"agent_type":"claude","role":"engineer","prompt_template":"x",
         "input_from_prev":"none","gate_after":false,
         "kind":"loop",
         "loop":{
           "body":[{"agent_type":"claude","role":"engineer","prompt_template":"","input_from_prev":"none","gate_after":false}],
           "until":{"source":"exit_status","predicate":"succeeded"},
           "max_iterations":5
         }}
        """.data(using: .utf8)!
        let step = try JSONDecoder().decode(ConduitUI.PipelineTemplateStep.self, from: raw)
        #expect(step.kind == "loop")
        let loop = try #require(step.loop)
        #expect(loop.body.count == 1)
        #expect(loop.until.source == "exit_status")
        #expect(loop.max_iterations == 5)
    }

    // MARK: - Gemini model row visibility (PLAN-HARNESS-BUILDER Phase 3 §4.3/§4.5)

    @Test func modelRowHiddenWhenModelOverrideFalseEvenWithCatalog() {
        #expect(ConduitUI.pipelineModelRowHidden(modelOverride: false, catalogEmpty: false) == true)
    }

    @Test func modelRowHiddenWhenCatalogEmptyRegardlessOfModelOverride() {
        #expect(ConduitUI.pipelineModelRowHidden(modelOverride: true, catalogEmpty: true) == true)
        #expect(ConduitUI.pipelineModelRowHidden(modelOverride: false, catalogEmpty: true) == true)
    }

    @Test func modelRowShownWhenModelOverrideTrueAndCatalogNonEmpty() {
        #expect(ConduitUI.pipelineModelRowHidden(modelOverride: true, catalogEmpty: false) == false)
    }
}
