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

// Cancel kills the live child session and sets state=cancelled.
func (o *Orchestrator) Cancel(p *Pipeline) error {
	// Kill live session if any.
	k := p.CurrentStep
	if k < len(p.Steps) {
		sessID := p.Steps[k].SessionID
		if sessID != "" {
			if err := o.sessions.CancelSession(sessID); err != nil {
				log.Printf("pipeline %s: cancel session %s: %v", p.ID, sessID, err)
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
		return nil
	}

	// Step succeeded. Move to STEP_DONE conceptually.
	p.State = PipelineStepDone

	if step.GateAfter {
		// Human gate: compute and persist GatePreview BEFORE saving state.
		// This lets the app render the handoff without a separate round-trip.
		gp := &GatePreview{Step: stepIndex}
		gp.Output = o.sessions.GetLastAssistantText(step.SessionID)
		k := stepIndex
		if k+1 < len(p.Steps) && p.Steps[k+1].InputFromPrev != InputNone {
			nextStep := &p.Steps[k+1]
			workdir := ""
			if step.SessionID != "" {
				workdir = o.sessions.GetWorktreeDir(step.SessionID)
			}
			gp.Prev = BuildPrev(workdir, gp.Output, nextStep.InputFromPrev)
			// Write the audit trail immediately so it is available even
			// before the user taps Continue.
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
			p.ID, stepIndex, len(gp.Prev), len(gp.Output))
		o.sendGatePush(p, stepIndex)
		return nil
	}

	// No gate: spawn next step or complete.
	return o.spawnNext(p)
}

// spawnNext spawns step k+1 (or marks COMPLETE if k was the last step).
func (o *Orchestrator) spawnNext(p *Pipeline) error {
	next := p.CurrentStep + 1
	if next >= len(p.Steps) {
		// All steps done.
		p.Gate = nil // clear gate preview on completion
		p.State = PipelineComplete
		if err := p.Save(o.conduitRoot); err != nil {
			return fmt.Errorf("pipeline %s: save complete: %w", p.ID, err)
		}
		log.Printf("pipeline %s: COMPLETE", p.ID)
		return nil
	}
	p.CurrentStep = next
	p.State = PipelineRunning
	if err := o.spawnStep(p, next); err != nil {
		p.Gate = nil // clear gate preview on spawn failure
		p.State = PipelineFailed
		_ = p.Save(o.conduitRoot)
		return fmt.Errorf("pipeline %s: spawn step %d: %w", p.ID, next, err)
	}
	// Clear gate preview after the step is successfully spawned.
	p.Gate = nil
	if err := p.Save(o.conduitRoot); err != nil {
		return fmt.Errorf("pipeline %s: save after spawn step %d: %w", p.ID, next, err)
	}
	log.Printf("pipeline %s: spawned step %d session=%s", p.ID, next, p.Steps[next].SessionID)
	go o.pollStep(p.ID, next)
	return nil
}

// spawnStep creates the child session for step k using the standard rendering
// path ({{task}} and {{prev}} substituted from pipeline state and previous
// step output). It is the normal first-attempt entry point.
func (o *Orchestrator) spawnStep(p *Pipeline, k int) error {
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
// advance so it works across process lifetimes.
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
		phase := o.sessions.GetPhase(sessID)
		if !strings.HasPrefix(phase, "exited") {
			continue
		}

		// Session has exited.
		log.Printf("pipeline %s: step %d session %s exited with phase=%s", pipelineID, stepIndex, sessID, phase)
		if advErr := o.Advance(p, stepIndex, phase); advErr != nil {
			log.Printf("pipeline %s: advance step %d: %v", pipelineID, stepIndex, advErr)
		}
		return
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

// exitCodeFromPhase parses the exit code from a phase string like "exited(0)" or "exited(1)".
// Returns 0 for "exited(0)" and any non-zero for anything else.
func exitCodeFromPhase(phase string) int {
	if phase == "exited(0)" || phase == "exited" {
		return 0
	}
	// Any other exited(*) — e.g. "exited(1)", "exited(2)" — is a failure.
	return 1
}
