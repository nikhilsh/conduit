package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Pins [PipelineStepDisplayViewModel.state] -- the step phase -> display-
 * state mapping the Monitor's step rows render. Regression coverage for
 * the "completed pipeline shows QUEUED" bug: the broker persists
 * `phase: "turn_complete"` for structured-chat steps (claude/codex never
 * exit between turns), and a naive mapping that only special-cased
 * "exited(*)" fell through every branch straight to "queued" even though
 * the step had a sessionId, `started`, and `ended` all set. Mirror of iOS
 * `ConduitPipelineStepDisplayViewModelTests`.
 */
class PipelineStepDisplayViewModelTest {

    private fun pipeline(
        state: String = "running",
        currentStep: Int = 0,
        steps: List<PipelineStep>,
    ) = Pipeline(
        id = "p_1", title = "t", task = "t", cwd = "/", base = "main",
        state = state, currentStep = currentStep, steps = steps, gate = null,
    )

    private fun step(
        index: Int = 0,
        agentType: String = "claude",
        role: String = "worker",
        sessionId: String? = "s_1",
        phase: String?,
        started: String? = "2026-07-01T00:00:00Z",
        ended: String? = null,
        fanout: FanoutStatus? = null,
        kind: String = "",
    ) = PipelineStep(
        index = index, agentType = agentType, role = role,
        promptTemplate = "", inputFromPrev = "none", gateAfter = false,
        sessionId = sessionId, phase = phase, started = started, ended = ended,
        fanout = fanout, kind = kind,
    )

    // ---- The core regression: turn_complete must be DONE, not QUEUED ------

    @Test
    fun turnCompleteWithEndedIsDone() {
        val s = step(phase = "turn_complete", ended = "2026-07-01T00:05:00Z")
        val p = pipeline(state = "complete", currentStep = 1, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun turnCompleteWithoutEndedStillDone() {
        val s = step(phase = "turn_complete", ended = null)
        val p = pipeline(state = "running", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    // ---- Known phases -------------------------------------------------------

    @Test
    fun exitedZeroIsDone() {
        val s = step(phase = "exited(0)", ended = "2026-07-01T00:05:00Z")
        val p = pipeline(state = "complete", currentStep = 1, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun exitedNonZeroIsFailed() {
        val s = step(phase = "exited(1)", ended = "2026-07-01T00:05:00Z")
        val p = pipeline(state = "failed", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.FAILED, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun runningIsRunning() {
        val s = step(phase = "running")
        val p = pipeline(state = "running", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.RUNNING, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun noPhaseYetIsQueued() {
        // Step is at (not behind) the pipeline's currentStep -- a
        // phaseless step behind currentStep is DONE (fallback rule c), so
        // this fixture must keep index >= currentStep to actually
        // exercise "hasn't started yet".
        val s = step(sessionId = null, phase = null, started = null)
        val p = pipeline(state = "running", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.QUEUED, PipelineStepDisplayViewModel.state(s, p))
    }

    // ---- Unmapped/future phase -- the robustness half of the fix -----------

    @Test
    fun unknownPhaseOnFinishedStepIsDoneNotQueued() {
        val s = step(phase = "some_future_phase", ended = "2026-07-01T00:05:00Z")
        val p = pipeline(state = "running", currentStep = 1, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun unknownPhaseOnPastStepIndexIsDoneNotQueued() {
        val s = step(index = 0, phase = "some_future_phase", ended = null)
        val p = pipeline(state = "running", currentStep = 2, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun unknownPhaseOnTerminalPipelineIsDoneNotQueued() {
        val s = step(phase = "some_future_phase", ended = null)
        val p = pipeline(state = "complete", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.DONE, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun unknownPhaseOnFutureStepStaysQueued() {
        val s = step(index = 2, sessionId = null, phase = null, started = null)
        val p = pipeline(state = "running", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.QUEUED, PipelineStepDisplayViewModel.state(s, p))
    }

    @Test
    fun unknownPhaseOnFailedPipelineAtCurrentStepIsFailed() {
        // Fallback rule (d): a phaseless/unmapped step AT the pipeline's
        // currentStep, when the pipeline itself failed, must render as
        // FAILED -- not DONE (rules b/c don't apply) and not QUEUED.
        val s = step(index = 1, phase = "some_future_phase", ended = null)
        val p = pipeline(state = "failed", currentStep = 1, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.FAILED, PipelineStepDisplayViewModel.state(s, p))
    }

    // ---- Loop-in-progress carve-out (pre-existing, must survive the fix) ---

    @Test
    fun loopInProgressWithNoSessionIsRunning() {
        val s = step(sessionId = null, phase = null, started = null, kind = "loop")
        val p = pipeline(state = "running", currentStep = 0, steps = listOf(s))
        assertEquals(PipelineStepDisplayViewModel.State.RUNNING, PipelineStepDisplayViewModel.state(s, p))
    }
}
