import Foundation
import Testing
@testable import Conduit

/// Pins `ConduitUI.PipelineStepDisplayViewModel.state(for:pipeline:)` -- the
/// step phase -> display-state mapping the Monitor's step rows render.
/// Regression coverage for the "completed pipeline shows QUEUED" bug: the
/// broker persists `phase: "turn_complete"` for structured-chat steps
/// (claude/codex never exit between turns), and a naive mapping that only
/// special-cased "exited(*)" fell through every branch straight to
/// "queued" even though the step had a session_id, `started`, and `ended`
/// all set. Mirror of Android `PipelineStepDisplayViewModelTest`.
@Suite("ConduitUI pipeline step display state")
struct ConduitPipelineStepDisplayViewModelTests {

    private func pipeline(
        state: String = "running",
        currentStep: Int = 0,
        steps: [ConduitUI.PipelineStepStatus]
    ) -> ConduitUI.PipelineStatus {
        ConduitUI.PipelineStatus(
            id: "p_1", title: "t", task: "t", cwd: "/", base: "main",
            state: state, current_step: currentStep, steps: steps, gate: nil
        )
    }

    private func step(
        index: Int = 0,
        agentType: String = "claude",
        role: String = "worker",
        sessionID: String? = "s_1",
        phase: String?,
        started: String? = "2026-07-01T00:00:00Z",
        ended: String? = nil,
        fanout: ConduitUI.FanoutStatus? = nil,
        kind: String? = nil
    ) -> ConduitUI.PipelineStepStatus {
        ConduitUI.PipelineStepStatus(
            index: index, agent_type: agentType, role: role,
            prompt_template: "", input_from_prev: "none", gate_after: false,
            session_id: sessionID, phase: phase, started: started, ended: ended,
            retries: nil, prev_session_ids: nil, fanout: fanout, kind: kind,
            spliced_from: nil, loop: nil
        )
    }

    // MARK: - The core regression: turn_complete must be "done", not "queued"

    @Test func turnCompleteWithEndedIsDone() {
        let s = step(phase: "turn_complete", ended: "2026-07-01T00:05:00Z")
        let p = pipeline(state: "complete", currentStep: 1, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    @Test func turnCompleteWithoutEndedStillDone() {
        // Even without an `ended` timestamp, "turn_complete" itself must
        // map to done -- it's not relying on the fallback.
        let s = step(phase: "turn_complete", ended: nil)
        let p = pipeline(state: "running", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    // MARK: - Known phases

    @Test func exitedZeroIsDone() {
        let s = step(phase: "exited(0)", ended: "2026-07-01T00:05:00Z")
        let p = pipeline(state: "complete", currentStep: 1, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    @Test func exitedNonZeroIsFailed() {
        let s = step(phase: "exited(1)", ended: "2026-07-01T00:05:00Z")
        let p = pipeline(state: "failed", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .failed)
    }

    @Test func runningIsRunning() {
        let s = step(phase: "running")
        let p = pipeline(state: "running", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .running)
    }

    @Test func noPhaseYetIsQueued() {
        // Step is at (not behind) the pipeline's current_step -- a
        // phaseless step behind current_step is DONE (fallback rule c),
        // so this fixture must keep index >= current_step to actually
        // exercise "hasn't started yet".
        let s = step(sessionID: nil, phase: nil, started: nil)
        let p = pipeline(state: "running", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .queued)
    }

    // MARK: - Unmapped/future phase -- the robustness half of the fix

    @Test func unknownPhaseOnFinishedStepIsDoneNotQueued() {
        // A step with `ended` set must never render as queued, even for a
        // phase this build has never seen.
        let s = step(phase: "some_future_phase", ended: "2026-07-01T00:05:00Z")
        let p = pipeline(state: "running", currentStep: 1, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    @Test func unknownPhaseOnPastStepIndexIsDoneNotQueued() {
        let s = step(index: 0, phase: "some_future_phase", ended: nil)
        let p = pipeline(state: "running", currentStep: 2, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    @Test func unknownPhaseOnTerminalPipelineIsDoneNotQueued() {
        let s = step(phase: "some_future_phase", ended: nil)
        let p = pipeline(state: "complete", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .done)
    }

    @Test func unknownPhaseOnFutureStepStaysQueued() {
        // Sanity check the fallback isn't over-broad: a step that's
        // genuinely still ahead (no session, no ended, index >= current,
        // pipeline not terminal) stays queued.
        let s = step(index: 2, sessionID: nil, phase: nil, started: nil)
        let p = pipeline(state: "running", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .queued)
    }

    @Test func unknownPhaseOnFailedPipelineAtCurrentStepIsFailed() {
        // Fallback rule (d): a phaseless/unmapped step AT the pipeline's
        // current_step, when the pipeline itself failed, must render as
        // failed -- not done (rules b/c don't apply) and not queued.
        let s = step(index: 1, phase: "some_future_phase", ended: nil)
        let p = pipeline(state: "failed", currentStep: 1, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .failed)
    }

    // MARK: - Loop-in-progress carve-out (pre-existing, must survive the fix)

    @Test func loopInProgressWithNoSessionIsRunning() {
        let s = step(sessionID: nil, phase: nil, started: nil, kind: "loop")
        let p = pipeline(state: "running", currentStep: 0, steps: [s])
        #expect(ConduitUI.PipelineStepDisplayViewModel.state(for: s, pipeline: p) == .running)
    }
}
