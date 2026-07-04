package pipeline

import (
	"context"
	"errors"
	"fmt"
	"log"
	"strings"
	"time"
)

// ErrNotAtGate is returned by Continue when the pipeline is not in
// AWAITING_GATE state.
var ErrNotAtGate = errors.New("pipeline is not awaiting gate")

// ErrAlreadyTerminal is returned when an operation is attempted on a pipeline
// that has already reached a terminal state (complete/failed/cancelled).
var ErrAlreadyTerminal = errors.New("pipeline is in a terminal state")

// ErrNotFailed is returned by Resume when the pipeline is not in the failed state.
var ErrNotFailed = errors.New("pipeline is not failed")

// ErrNotAtPick is returned by Pick when the pipeline is not in AWAITING_PICK state.
var ErrNotAtPick = errors.New("pipeline is not awaiting pick")

// ErrRunFailed is returned by Pick when the selected run did not exit(0).
var ErrRunFailed = errors.New("selected run failed")

// SessionManager is the minimal interface the Orchestrator needs to interact
// with the session manager. The ws layer wires the concrete *session.Manager
// behind this interface to avoid an import cycle (pipeline → ws → pipeline).
type SessionManager interface {
	// CreateSession spawns a new session with the given agent type, CWD,
	// initial prompt, and branch name. The branch is used when worktree mode
	// is enabled (Gap A seam); ignored otherwise. Returns the new session ID.
	CreateSession(agentType, cwd, initialPrompt, branch string) (sessionID string, err error)
	// GetPhase returns the session's current phase string (e.g. "running",
	// "exited(0)", "exited(1)"). Returns "" when the session is unknown.
	GetPhase(sessionID string) string
	// TurnComplete returns true when the session's turn is no longer active
	// AND the session has produced at least one assistant reply. This is the
	// correct completion signal for structured-chat sessions (e.g. claude)
	// whose process phase stays "running" between turns. The guard on the
	// assistant-reply prevents a false positive in the pre-first-turn window
	// where turn_active is also false before the prompt lands.
	TurnComplete(sessionID string) bool
	// GetWorktreeDir returns the workspace directory for a session.
	GetWorktreeDir(sessionID string) string
	// GetLastAssistantText returns the last assistant turn text from the
	// session's conversation log.
	GetLastAssistantText(sessionID string) string
	// CancelSession terminates a live session. No-op if already gone.
	CancelSession(sessionID string) error
}

// PushNotifier is the minimal interface for sending a push notification.
// The ws layer wires the concrete *push.Dispatcher behind this.
type PushNotifier interface {
	// Notify sends a push notification with the given title and body.
	Notify(ctx context.Context, title, body string) error
}

// Orchestrator drives the pipeline state machine. It is safe for concurrent
// use: each pipeline runs in its own goroutine started by Start.
type Orchestrator struct {
	conduitRoot string
	sessions    SessionManager
	notifier    PushNotifier // may be nil
}

// NewOrchestrator creates an Orchestrator. notifier may be nil (push is best-effort).
func NewOrchestrator(conduitRoot string, sessions SessionManager, notifier PushNotifier) *Orchestrator {
	return &Orchestrator{
		conduitRoot: conduitRoot,
		sessions:    sessions,
		notifier:    notifier,
	}
}

// Start validates p, sets state=running, spawns step 0, and saves.
// A background goroutine polls the step session and calls Advance when it exits.
func (o *Orchestrator) Start(p *Pipeline) error {
	if len(p.Steps) == 0 {
		return fmt.Errorf("pipeline %s: no steps defined", p.ID)
	}
	p.State = PipelineRunning
	p.CurrentStep = 0
	if err := o.spawnStep(p, 0); err != nil {
		p.State = PipelineFailed
		_ = p.Save(o.conduitRoot)
		return fmt.Errorf("pipeline %s: spawn step 0: %w", p.ID, err)
	}
	if err := p.Save(o.conduitRoot); err != nil {
		return fmt.Errorf("pipeline %s: save after start: %w", p.ID, err)
	}
	log.Printf("pipeline %s: started, step 0 session=%s", p.ID, p.Steps[0].SessionID)
	go o.pollStep(p.ID, 0)
	return nil
}

// Continue advances a pipeline that is waiting at a gate.
// amendedPrev, when non-empty and p.Gate != nil, overwrites the stored
// Gate.Prev before spawning the next step — this is the "edit handoff"
// feature. Empty string means use the pre-computed prev unchanged.
// Returns ErrNotAtGate when the pipeline is not in AWAITING_GATE state.
func (o *Orchestrator) Continue(p *Pipeline, amendedPrev string) error {
	if p.State != PipelineAwaitingGate {
		return ErrNotAtGate
	}
	if amendedPrev != "" && p.Gate != nil {
		log.Printf("pipeline %s: continue with amended prev (len=%d)", p.ID, len(amendedPrev))
		p.Gate.Prev = amendedPrev
	}
	log.Printf("pipeline %s: continue past gate at step %d", p.ID, p.CurrentStep)
	return o.spawnNext(p)
}

// Cancel kills the live child session(s) and sets state=cancelled.
// For fanout steps, all live run sessions are killed.
func (o *Orchestrator) Cancel(p *Pipeline) error {
	k := p.CurrentStep
	if k < len(p.Steps) {
		step := &p.Steps[k]
		if step.IsFanout() && step.Fanout != nil {
			// Kill all live fanout run sessions.
			for _, run := range step.Fanout.Runs {
				if run.SessionID != "" {
					if err := o.sessions.CancelSession(run.SessionID); err != nil {
						log.Printf("pipeline %s: cancel fanout run %d session %s: %v",
							p.ID, run.Index, run.SessionID, err)
					}
				}
			}
		} else {
			// Kill the single live session.
			if step.SessionID != "" {
				if err := o.sessions.CancelSession(step.SessionID); err != nil {
					log.Printf("pipeline %s: cancel session %s: %v", p.ID, step.SessionID, err)
				}
			}
		}
	}
	p.Gate = nil // clear any pending gate preview on cancel
	p.State = PipelineCancelled
	if err := p.Save(o.conduitRoot); err != nil {
		return fmt.Errorf("pipeline %s: save after cancel: %w", p.ID, err)
	}
	log.Printf("pipeline %s: cancelled", p.ID)
	return nil
}

// Resume re-spawns the failed step k as a fresh session. The pipeline must
// be in PipelineFailed state; returns ErrNotFailed otherwise.
//
// When amendedPrompt is non-empty it is delivered verbatim as the spawned
// prompt (no re-templating). When empty the normal spawnStep rendering is
// used — {{task}} and {{prev}} are recomputed from the previous step's
// session output / HANDOFF-OUT as today (Gate is nil after a failure so
// the gate-preview path is skipped and recomputation is always correct).
//
// The failed session's ID is preserved in Step.PrevSessionIDs before being
// overwritten. Step.Retries is incremented and used as a branch-name suffix
// to avoid a git collision with the prior attempt (pipeline-<id>-step-<k>-r<n>).
func (o *Orchestrator) Resume(p *Pipeline, amendedPrompt string) error {
	if p.State != PipelineFailed {
		return ErrNotFailed
	}
	k := p.CurrentStep
	if k >= len(p.Steps) {
		return fmt.Errorf("pipeline %s: resume: current_step %d out of range", p.ID, k)
	}
	step := &p.Steps[k]

	// Preserve failed session id for inspection before overwriting.
	if step.SessionID != "" {
		step.PrevSessionIDs = append(step.PrevSessionIDs, step.SessionID)
	}
	step.Retries++
	// Reset step live-state fields so the monitor sees a fresh attempt.
	step.SessionID = ""
	step.Phase = ""
	step.Started = ""
	step.Ended = ""

	log.Printf("pipeline %s: resume step %d retry=%d amended_prompt=%v",
		p.ID, k, step.Retries, amendedPrompt != "")

	p.State = PipelineRunning
	p.Gate = nil // defensive: Gate should already be nil on a failed pipeline

	if err := o.spawnStepOpts(p, k, amendedPrompt); err != nil {
		p.State = PipelineFailed
		_ = p.Save(o.conduitRoot)
		return fmt.Errorf("pipeline %s: resume spawn step %d: %w", p.ID, k, err)
	}
	if err := p.Save(o.conduitRoot); err != nil {
		return fmt.Errorf("pipeline %s: save after resume: %w", p.ID, err)
	}
	log.Printf("pipeline %s: resumed step %d session=%s branch-suffix=-r%d",
		p.ID, k, p.Steps[k].SessionID, step.Retries)
	go o.pollStep(p.ID, k)
	return nil
}

// Advance is called when step k's session reaches an exited(*) phase.
// It determines the next state per the pipeline state machine spec §4.
// Fanout steps use their own advanceFanout path (called from pollFanout);
// Advance handles only normal (non-fanout) sequential steps.
func (o *Orchestrator) Advance(p *Pipeline, stepIndex int, phase string) error {
	if stepIndex >= len(p.Steps) {
		return fmt.Errorf("pipeline %s: advance: step index %d out of range", p.ID, stepIndex)
	}
	step := &p.Steps[stepIndex]
	step.Phase = phase
	step.Ended = time.Now().UTC().Format(time.RFC3339)

	exitCode := exitCodeFromPhase(phase)
	if exitCode != 0 {
		// Non-zero exit: pipeline fails at this step.
		p.Gate = nil // clear any stale gate preview on failure
		p.State = PipelineFailed
		if err := p.Save(o.conduitRoot); err != nil {
			log.Printf("pipeline %s: save after fail: %v", p.ID, err)
		}
		log.Printf("pipeline %s: FAILED at step %d (phase=%s)", p.ID, stepIndex, phase)
		// Resume always re-spawns a brand new session for the failed step
		// (SessionID is reset to "" before a fresh CreateSession — see
		// Resume) — the failed session's process is never read or reused
		// again, so it is safe, and better on a RAM-constrained box, to
		// reap it now rather than leak it until Cancel/GC.
		o.terminateStepSession(p, stepIndex)
		return nil
	}

	// Step succeeded — delegate to shared helper.
	return o.afterStepSuccess(p, stepIndex)
}

// spawnNext spawns step k+1 (or marks COMPLETE if k was the last step).
// prevIdx (the step that just finished, k) is reaped once the step at
// prevIdx+1 has been spawned (or, when this was the last step, once
// COMPLETE is reached) — by that point its handoff has already been read
// via BuildPrev/GetLastAssistantText/GetWorktreeDir inside spawnStep, so
// its agent process is no longer needed. See terminateStepSession.
func (o *Orchestrator) spawnNext(p *Pipeline) error {
	prevIdx := p.CurrentStep
	next := prevIdx + 1
	if next >= len(p.Steps) {
		// All steps done.
		p.Gate = nil // clear gate preview on completion
		p.State = PipelineComplete
		if err := p.Save(o.conduitRoot); err != nil {
			return fmt.Errorf("pipeline %s: save complete: %w", p.ID, err)
		}
		log.Printf("pipeline %s: COMPLETE", p.ID)
		o.terminateStepSession(p, prevIdx)
		return nil
	}
	p.CurrentStep = next
	p.State = PipelineRunning
	if err := o.spawnStep(p, next); err != nil {
		p.Gate = nil // clear gate preview on spawn failure
		p.State = PipelineFailed
		_ = p.Save(o.conduitRoot)
		o.terminateStepSession(p, prevIdx)
		return fmt.Errorf("pipeline %s: spawn step %d: %w", p.ID, next, err)
	}
	// Clear gate preview after the step is successfully spawned.
	p.Gate = nil
	if err := p.Save(o.conduitRoot); err != nil {
		return fmt.Errorf("pipeline %s: save after spawn step %d: %w", p.ID, next, err)
	}
	log.Printf("pipeline %s: spawned step %d session=%s", p.ID, next, p.Steps[next].SessionID)
	o.terminateStepSession(p, prevIdx)
	go o.pollStep(p.ID, next)
	return nil
}

// spawnStep creates the child session(s) for step k. For fanout steps this
// spawns N parallel runs; for normal steps it delegates to spawnStepOpts.
func (o *Orchestrator) spawnStep(p *Pipeline, k int) error {
	if p.Steps[k].IsFanout() {
		return o.spawnFanout(p, k)
	}
	return o.spawnStepOpts(p, k, "")
}

// spawnStepOpts is the shared implementation for spawning step k. When
// overridePrompt is non-empty it is used verbatim (no template rendering);
// otherwise the step's PromptTemplate is rendered as usual. The branch name
// incorporates Step.Retries to avoid a git collision on re-spawns:
//
//	first attempt:  pipeline-<id>-step-<k>
//	first retry:    pipeline-<id>-step-<k>-r1
//	second retry:   pipeline-<id>-step-<k>-r2
func (o *Orchestrator) spawnStepOpts(p *Pipeline, k int, overridePrompt string) error {
	step := &p.Steps[k]

	var prompt string
	if overridePrompt != "" {
		// Resume with an explicit amended prompt — skip all template rendering.
		prompt = overridePrompt
		log.Printf("pipeline %s step %d: using override prompt (len=%d)", p.ID, k, len(overridePrompt))
	} else {
		// Build the prompt by substituting {{task}} and {{prev}}.
		prompt = step.PromptTemplate
		prompt = strings.ReplaceAll(prompt, "{{task}}", p.Task)

		if k > 0 && step.InputFromPrev != InputNone {
			var prevText string
			// If a GatePreview was computed for this step (k-1 had gate_after=true),
			// use its Prev — which may have been amended by the Continue caller —
			// instead of recomputing from disk.
			if p.Gate != nil && p.Gate.Step == k-1 {
				prevText = p.Gate.Prev
				log.Printf("pipeline %s step %d: using gate preview prev (len=%d)", p.ID, k, len(prevText))
			} else {
				// For a resume after failure Gate is nil; recompute from the
				// previous step's session (which already exited successfully).
				// Use the last valid session id from the previous step.
				prev := p.Steps[k-1]
				prevSessID := prev.SessionID
				// If the previous step's current session is empty but it has a
				// PrevSessionIDs history, use the last one that succeeded. For
				// the common case (previous step finished successfully and its
				// session id is still set) this is a no-op.
				if prevSessID == "" && len(prev.PrevSessionIDs) > 0 {
					prevSessID = prev.PrevSessionIDs[len(prev.PrevSessionIDs)-1]
				}
				workdir := ""
				if prevSessID != "" {
					workdir = o.sessions.GetWorktreeDir(prevSessID)
				}
				transcriptText := ""
				if prevSessID != "" {
					transcriptText = o.sessions.GetLastAssistantText(prevSessID)
				}
				prevText = BuildPrev(workdir, transcriptText, step.InputFromPrev)
			}
			prompt = strings.ReplaceAll(prompt, "{{prev}}", prevText)
			// Save the text actually used to input.md (overwrites the audit file
			// written at gate entry if an amendment was applied).
			if saveErr := SaveInput(o.conduitRoot, p.ID, k, prevText); saveErr != nil {
				log.Printf("pipeline %s step %d: save input.md: %v", p.ID, k, saveErr)
			}
		} else {
			// No prev substitution needed; remove any {{prev}} placeholder.
			prompt = strings.ReplaceAll(prompt, "{{prev}}", "")
		}
	}

	// Branch name: incorporate Retries to avoid a git collision on re-spawns.
	branch := fmt.Sprintf("pipeline-%s-step-%d", p.ID, k)
	if step.Retries > 0 {
		branch = fmt.Sprintf("pipeline-%s-step-%d-r%d", p.ID, k, step.Retries)
	}
	sessID, err := o.sessions.CreateSession(step.AgentType, p.CWD, prompt, branch)
	if err != nil {
		return fmt.Errorf("create session (agent=%s): %w", step.AgentType, err)
	}
	step.SessionID = sessID
	step.Started = time.Now().UTC().Format(time.RFC3339)
	step.Phase = "running"
	return nil
}

// pollStep polls the session for step k every 5 seconds until it exits,
// then calls Advance. It reloads the pipeline from disk before each
// advance so it works across process lifetimes. For fanout steps, the
// per-run goroutines are launched by spawnFanout, so pollStep is only
// called for normal (non-fanout) steps.
func (o *Orchestrator) pollStep(pipelineID string, stepIndex int) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		p, err := Load(o.conduitRoot, pipelineID)
		if err != nil {
			log.Printf("pipeline %s: poll: load error: %v", pipelineID, err)
			return
		}

		// If the pipeline is no longer running at this step, stop polling.
		if p.State == PipelineCancelled || p.State == PipelineComplete || p.State == PipelineFailed {
			return
		}
		if p.CurrentStep != stepIndex {
			// A new step is being polled by its own goroutine.
			return
		}
		if stepIndex >= len(p.Steps) {
			return
		}
		sessID := p.Steps[stepIndex].SessionID
		if sessID == "" {
			continue
		}

		// Two completion signals (must check both to support all agent types):
		//
		// 1. exited(*): the process has terminated. Non-zero exit is a failure.
		//    Used by process-style adapters (codex, opencode, shell).
		//
		// 2. TurnComplete: the structured-chat backend's turn is no longer
		//    active AND at least one assistant reply exists. This is the correct
		//    signal for claude sessions whose process phase stays "running"
		//    indefinitely between turns — the process never exits; phase never
		//    becomes "exited(0)" without an explicit Close. Without this signal
		//    a claude pipeline step would NEVER advance.
		phase := o.sessions.GetPhase(sessID)
		if strings.HasPrefix(phase, "exited") {
			// Process-style exit.
			log.Printf("pipeline %s: step %d session %s exited with phase=%s", pipelineID, stepIndex, sessID, phase)
			if advErr := o.Advance(p, stepIndex, phase); advErr != nil {
				log.Printf("pipeline %s: advance step %d: %v", pipelineID, stepIndex, advErr)
			}
			return
		}
		if o.sessions.TurnComplete(sessID) {
			// Structured-chat turn completed (claude / ACP backend).
			// NOTE: the session process stays alive through this Advance call
			// (we do NOT CancelSession here) because the GetLastAssistantText/
			// GetWorktreeDir reads for the next step (BuildPrev, GatePreview)
			// still need it. Advance/afterStepSuccess/spawnNext reap it once
			// that harvest is done — see terminateStepSession. The
			// tap-to-inspect UX keeps working after that: Session.Close kills
			// only the process, not the session record or its transcript/
			// worktree.
			log.Printf("pipeline %s: step %d session %s turn_complete", pipelineID, stepIndex, sessID)
			if advErr := o.Advance(p, stepIndex, "turn_complete"); advErr != nil {
				log.Printf("pipeline %s: advance step %d (turn_complete): %v", pipelineID, stepIndex, advErr)
			}
			return
		}
	}
}

// ── Fanout support ────────────────────────────────────────────────────────────

// spawnFanout spawns N parallel runs for a fanout step, names their branches
// with the -run-<i> suffix, populates fanout.runs, and starts a pollFanout
// goroutine that waits for all runs to settle then calls advanceFanout.
func (o *Orchestrator) spawnFanout(p *Pipeline, k int) error {
	step := &p.Steps[k]
	fc := step.Fanout

	// Build the prompt once — identical for every run.
	prompt := step.PromptTemplate
	prompt = strings.ReplaceAll(prompt, "{{task}}", p.Task)

	if k > 0 && step.InputFromPrev != InputNone {
		var prevText string
		if p.Gate != nil && p.Gate.Step == k-1 {
			prevText = p.Gate.Prev
			log.Printf("pipeline %s step %d fanout: using gate preview prev (len=%d)", p.ID, k, len(prevText))
		} else {
			prev := p.Steps[k-1]
			prevSessID := prev.SessionID
			if prevSessID == "" && len(prev.PrevSessionIDs) > 0 {
				prevSessID = prev.PrevSessionIDs[len(prev.PrevSessionIDs)-1]
			}
			workdir := ""
			if prevSessID != "" {
				workdir = o.sessions.GetWorktreeDir(prevSessID)
			}
			transcriptText := ""
			if prevSessID != "" {
				transcriptText = o.sessions.GetLastAssistantText(prevSessID)
			}
			prevText = BuildPrev(workdir, transcriptText, step.InputFromPrev)
		}
		prompt = strings.ReplaceAll(prompt, "{{prev}}", prevText)
		if saveErr := SaveInput(o.conduitRoot, p.ID, k, prevText); saveErr != nil {
			log.Printf("pipeline %s step %d fanout: save input.md: %v", p.ID, k, saveErr)
		}
	} else {
		prompt = strings.ReplaceAll(prompt, "{{prev}}", "")
	}

	// Spawn N runs in parallel.
	fc.Runs = make([]FanoutRun, fc.Count)
	for i := 0; i < fc.Count; i++ {
		agentType := step.AgentType
		if i < len(fc.AgentTypes) && fc.AgentTypes[i] != "" {
			agentType = fc.AgentTypes[i]
		}
		branch := fmt.Sprintf("pipeline-%s-step-%d-run-%d", p.ID, k, i)
		sessID, err := o.sessions.CreateSession(agentType, p.CWD, prompt, branch)
		if err != nil {
			// Mark spawned runs as cancelled and return error.
			log.Printf("pipeline %s step %d fanout: run %d spawn error: %v", p.ID, k, i, err)
			for j := 0; j < i; j++ {
				_ = o.sessions.CancelSession(fc.Runs[j].SessionID)
			}
			return fmt.Errorf("fanout run %d (agent=%s): %w", i, agentType, err)
		}
		fc.Runs[i] = FanoutRun{
			Index:     i,
			AgentType: agentType,
			SessionID: sessID,
			Branch:    branch,
			Phase:     "running",
			Started:   time.Now().UTC().Format(time.RFC3339),
		}
		log.Printf("pipeline %s step %d fanout: spawned run %d session=%s branch=%s agent=%s",
			p.ID, k, i, sessID, branch, agentType)
	}

	step.Started = time.Now().UTC().Format(time.RFC3339)
	step.Phase = "running"
	go o.pollFanout(p.ID, k)
	return nil
}

// pollFanout polls all fanout runs every 5 seconds until every run has exited,
// then calls advanceFanout.
func (o *Orchestrator) pollFanout(pipelineID string, stepIndex int) {
	ticker := time.NewTicker(5 * time.Second)
	defer ticker.Stop()

	for range ticker.C {
		p, err := Load(o.conduitRoot, pipelineID)
		if err != nil {
			log.Printf("pipeline %s: pollFanout: load error: %v", pipelineID, err)
			return
		}
		if p.State == PipelineCancelled || p.State == PipelineComplete || p.State == PipelineFailed {
			return
		}
		if p.CurrentStep != stepIndex || stepIndex >= len(p.Steps) {
			return
		}
		step := &p.Steps[stepIndex]
		if !step.IsFanout() || step.Fanout == nil {
			return
		}

		// Update phase for each run. A run settles when its process exits OR
		// when TurnComplete is true (see pollStep for the rationale — same
		// signals apply to fanout runs that use structured-chat backends).
		allSettled := true
		changed := false
		for i := range step.Fanout.Runs {
			run := &step.Fanout.Runs[i]
			if isRunSettled(run.Phase) {
				continue // already settled
			}
			phase := o.sessions.GetPhase(run.SessionID)
			if strings.HasPrefix(phase, "exited") {
				run.Phase = phase
				run.Ended = time.Now().UTC().Format(time.RFC3339)
				changed = true
				log.Printf("pipeline %s step %d fanout: run %d session %s exited phase=%s",
					pipelineID, stepIndex, run.Index, run.SessionID, phase)
			} else if o.sessions.TurnComplete(run.SessionID) {
				run.Phase = "turn_complete"
				run.Ended = time.Now().UTC().Format(time.RFC3339)
				changed = true
				log.Printf("pipeline %s step %d fanout: run %d session %s turn_complete",
					pipelineID, stepIndex, run.Index, run.SessionID)
			} else {
				allSettled = false
			}
		}

		if changed {
			if saveErr := p.Save(o.conduitRoot); saveErr != nil {
				log.Printf("pipeline %s: pollFanout: save: %v", pipelineID, saveErr)
			}
		}

		if allSettled {
			log.Printf("pipeline %s step %d fanout: all runs settled", pipelineID, stepIndex)
			// Reload after save for clean state.
			p2, err := Load(o.conduitRoot, pipelineID)
			if err != nil {
				log.Printf("pipeline %s: pollFanout: reload before advance: %v", pipelineID, err)
				return
			}
			if advErr := o.advanceFanout(p2, stepIndex); advErr != nil {
				log.Printf("pipeline %s: advanceFanout step %d: %v", pipelineID, stepIndex, advErr)
			}
			return
		}
	}
}

// advanceFanout is called when all fanout runs have settled. If all runs
// failed it transitions to FAILED; if at least one succeeded it transitions
// to AWAITING_PICK and fires a push notification.
func (o *Orchestrator) advanceFanout(p *Pipeline, stepIndex int) error {
	step := &p.Steps[stepIndex]
	fc := step.Fanout

	anySucceeded := false
	for _, run := range fc.Runs {
		if exitCodeFromPhase(run.Phase) == 0 {
			anySucceeded = true
			break
		}
	}

	if !anySucceeded {
		p.State = PipelineFailed
		p.Gate = nil
		if err := p.Save(o.conduitRoot); err != nil {
			log.Printf("pipeline %s: save after fanout all-failed: %v", p.ID, err)
		}
		log.Printf("pipeline %s: FAILED at step %d (all fanout runs failed)", p.ID, stepIndex)
		// Same reasoning as the single-step FAILED path: Resume re-spawns
		// fresh runs, never these, so reap every run's process now.
		for _, run := range fc.Runs {
			if run.SessionID == "" {
				continue
			}
			if err := o.sessions.CancelSession(run.SessionID); err != nil {
				log.Printf("pipeline %s: fanout all-failed: terminate run %d session %s: %v",
					p.ID, run.Index, run.SessionID, err)
			}
		}
		return nil
	}

	p.State = PipelineAwaitingPick
	if err := p.Save(o.conduitRoot); err != nil {
		log.Printf("pipeline %s: save awaiting_pick: %v", p.ID, err)
	}
	log.Printf("pipeline %s: AWAITING_PICK at step %d (%d runs settled)", p.ID, stepIndex, len(fc.Runs))
	o.sendPickPush(p, stepIndex)
	return nil
}

// Pick validates and applies the human's run selection. It sets the winner,
// writes the step's session_id to the winner's session id, then drives the
// state machine forward (AWAITING_GATE or RUNNING(k+1)/COMPLETE).
//
// Returns ErrNotAtPick when state != awaiting_pick, ErrRunFailed when the
// selected run did not exit(0), or a standard validation error.
func (o *Orchestrator) Pick(p *Pipeline, runIdx int) error {
	if p.State != PipelineAwaitingPick {
		return ErrNotAtPick
	}
	k := p.CurrentStep
	if k >= len(p.Steps) {
		return fmt.Errorf("pipeline %s: pick: current_step %d out of range", p.ID, k)
	}
	step := &p.Steps[k]
	if !step.IsFanout() || step.Fanout == nil {
		return fmt.Errorf("pipeline %s: pick: step %d is not a fanout step", p.ID, k)
	}
	fc := step.Fanout
	if runIdx < 0 || runIdx >= len(fc.Runs) {
		return fmt.Errorf("run index %d out of range [0, %d)", runIdx, len(fc.Runs))
	}
	winner := &fc.Runs[runIdx]
	if exitCodeFromPhase(winner.Phase) != 0 {
		return ErrRunFailed
	}

	// Commit the pick.
	idx := runIdx
	fc.Winner = &idx
	step.SessionID = winner.SessionID
	step.Phase = winner.Phase
	step.Ended = time.Now().UTC().Format(time.RFC3339)

	log.Printf("pipeline %s: PICK step %d winner=run %d session=%s", p.ID, k, runIdx, winner.SessionID)

	// Terminate the losing runs' live agent processes now that the winner
	// is committed. Their worktrees/artifacts are left untouched —
	// CancelSession/Session.Close kills only the process, never the
	// session record or its workspace. The winner's own session follows
	// the normal rule (reaped once its handoff is harvested, below).
	for i := range fc.Runs {
		if i == runIdx {
			continue
		}
		loser := &fc.Runs[i]
		if loser.SessionID == "" {
			continue
		}
		if err := o.sessions.CancelSession(loser.SessionID); err != nil {
			log.Printf("pipeline %s: pick step %d: terminate loser run %d session %s: %v",
				p.ID, k, loser.Index, loser.SessionID, err)
		}
	}

	return o.afterStepSuccess(p, k)
}

// afterStepSuccess drives the state machine after a step at index k has
// succeeded (session_id is already set on the step). It is shared by
// Advance (sequential steps) and Pick (fanout steps): if gate_after is true
// it computes the GatePreview and enters AWAITING_GATE; otherwise it spawns
// the next step (or marks COMPLETE).
func (o *Orchestrator) afterStepSuccess(p *Pipeline, k int) error {
	step := &p.Steps[k]
	p.State = PipelineStepDone

	if step.GateAfter {
		gp := &GatePreview{Step: k}
		gp.Output = o.sessions.GetLastAssistantText(step.SessionID)
		if k+1 < len(p.Steps) && p.Steps[k+1].InputFromPrev != InputNone {
			nextStep := &p.Steps[k+1]
			workdir := ""
			if step.SessionID != "" {
				workdir = o.sessions.GetWorktreeDir(step.SessionID)
			}
			gp.Prev = BuildPrev(workdir, gp.Output, nextStep.InputFromPrev)
			if saveErr := SaveInput(o.conduitRoot, p.ID, k+1, gp.Prev); saveErr != nil {
				log.Printf("pipeline %s step %d: save input.md at gate: %v", p.ID, k+1, saveErr)
			}
		}
		p.Gate = gp
		p.State = PipelineAwaitingGate
		if err := p.Save(o.conduitRoot); err != nil {
			log.Printf("pipeline %s: save awaiting gate: %v", p.ID, err)
		}
		log.Printf("pipeline %s: AWAITING_GATE at step %d (prev len=%d, output len=%d)",
			p.ID, k, len(gp.Prev), len(gp.Output))
		o.sendGatePush(p, k)
		// gp.Output/gp.Prev above are the ONLY reads of step k's live
		// session for this gate; Continue (including the amend-prev path)
		// reads exclusively from the persisted Gate, never the live
		// session (see spawnStepOpts: p.Gate.Prev is used verbatim when
		// p.Gate.Step == k-1). Safe to reap step k's process now.
		o.terminateStepSession(p, k)
		return nil
	}

	return o.spawnNext(p)
}

// terminateStepSession terminates the live agent process backing step k's
// SessionID, once the pipeline no longer needs to read from it (its handoff
// text has already been harvested via GetLastAssistantText/GetWorktreeDir
// and persisted into GatePreview.Prev/Output or the next step's rendered
// prompt). Idempotent and safe if the session already exited on its own —
// CancelSession is a documented no-op when the session is already gone, and
// Session.Close itself is guarded by a sync.Once. It only kills the process;
// the session record, its transcript, and its worktree are left intact for
// tap-to-inspect and the fanout "artifacts preserved" invariant. Errors are
// logged, never fatal — failing to reap must not block pipeline progress.
func (o *Orchestrator) terminateStepSession(p *Pipeline, k int) {
	if k < 0 || k >= len(p.Steps) {
		return
	}
	sessID := p.Steps[k].SessionID
	if sessID == "" {
		return
	}
	if err := o.sessions.CancelSession(sessID); err != nil {
		log.Printf("pipeline %s: terminate step %d session %s: %v", p.ID, k, sessID, err)
	}
}

// sendPickPush sends a push notification informing the user that all fanout
// runs have settled and a pick is required. Best-effort.
func (o *Orchestrator) sendPickPush(p *Pipeline, stepIndex int) {
	if o.notifier == nil {
		return
	}
	title := fmt.Sprintf("Pipeline: pick a winner — %s", p.Title)
	body := fmt.Sprintf("Step %d: %d runs complete. Tap to pick the winner.", stepIndex+1, len(p.Steps[stepIndex].Fanout.Runs))
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := o.notifier.Notify(ctx, title, body); err != nil {
		log.Printf("pipeline %s: pick push notify: %v", p.ID, err)
	}
}

// sendGatePush sends a push notification informing the user to approve the gate.
// Best-effort: failures are logged and never block the pipeline.
func (o *Orchestrator) sendGatePush(p *Pipeline, stepIndex int) {
	if o.notifier == nil {
		return
	}
	title := fmt.Sprintf("Pipeline gate: %s", p.Title)
	body := fmt.Sprintf("Step %d complete. Tap to review and continue.", stepIndex+1)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := o.notifier.Notify(ctx, title, body); err != nil {
		log.Printf("pipeline %s: gate push notify: %v", p.ID, err)
	}
}

// isRunSettled returns true when a fanout run's phase indicates it has
// settled (either by process exit or by turn completion).
func isRunSettled(phase string) bool {
	return strings.HasPrefix(phase, "exited") || phase == "turn_complete"
}

// exitCodeFromPhase parses the exit code from a phase string like "exited(0)" or "exited(1)".
// Returns 0 for "exited(0)", "exited", or "turn_complete" (the structured-chat
// completion signal); returns 1 for any other exited(*) (process failure).
func exitCodeFromPhase(phase string) int {
	if phase == "exited(0)" || phase == "exited" || phase == "turn_complete" {
		return 0
	}
	// Any other exited(*) — e.g. "exited(1)", "exited(2)" — is a failure.
	return 1
}
