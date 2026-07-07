// Package pipeline implements the Sequential Agent Pipeline subsystem.
// Pipelines are broker-owned state: definitions and live state live under
// <conduitRoot>/pipelines/<id>/pipeline.json; handoff artifacts live under
// <conduitRoot>/pipelines/<id>/steps/<n>/.
package pipeline

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

// PipelineState is the overall state of a pipeline.
type PipelineState string

const (
	PipelinePending      PipelineState = "pending"
	PipelineRunning      PipelineState = "running"
	PipelineStepDone     PipelineState = "step_done"
	PipelineAwaitingGate PipelineState = "awaiting_gate"
	// PipelineAwaitingPick is entered when all runs of a fanout step have
	// settled and at least one succeeded. The human must POST …/pick to
	// select the winner before the pipeline advances.
	PipelineAwaitingPick PipelineState = "awaiting_pick"
	PipelineComplete     PipelineState = "complete"
	PipelineFailed       PipelineState = "failed"
	PipelineCancelled    PipelineState = "cancelled"
)

// InputFromPrev describes how a step ingests the previous step's output.
type InputFromPrev string

const (
	InputNone         InputFromPrev = "none"
	InputOutput       InputFromPrev = "output"
	InputMemory       InputFromPrev = "memory"
	InputMemoryOutput InputFromPrev = "memory+output"
)

// FanoutRun holds per-run state for a fanout step.
type FanoutRun struct {
	Index     int    `json:"index"`
	AgentType string `json:"agent_type"`
	SessionID string `json:"session_id,omitempty"`
	Branch    string `json:"branch,omitempty"`
	Phase     string `json:"phase,omitempty"`
	Started   string `json:"started,omitempty"`
	Ended     string `json:"ended,omitempty"`
}

// FanoutConfig declares and tracks the state of a fanout step.
// A step is a fanout step when Fanout != nil && Fanout.Count > 0.
type FanoutConfig struct {
	// Count is the number of parallel runs. Required. 1–6.
	Count int `json:"count"`
	// AgentTypes is an optional index-aligned list of agent types, one per run.
	// When absent all runs use the step's own AgentType.
	AgentTypes []string `json:"agent_types,omitempty"`
	// Models, ReasoningEfforts, PermissionModes, and Instructions are optional
	// index-aligned parallel arrays mirroring AgentTypes, one per run. Per-run
	// resolution: arr[i] (if non-empty) falls back to the step's own
	// StepConfig field, which falls back to the adapter default.
	Models           []string `json:"models,omitempty"`
	ReasoningEfforts []string `json:"reasoning_efforts,omitempty"`
	PermissionModes  []string `json:"permission_modes,omitempty"`
	Instructions     []string `json:"instructions,omitempty"`
	// Runs is populated as runs are spawned. Mirrors how SessionID/Phase are
	// populated on a normal step.
	Runs []FanoutRun `json:"runs,omitempty"`
	// Winner is the picked run index. Nil until the human picks.
	Winner *int `json:"winner,omitempty"`
}

// Step is a single agent invocation within a pipeline.
type Step struct {
	Index          int           `json:"index"`
	AgentType      string        `json:"agent_type"`
	Role           string        `json:"role"`
	PromptTemplate string        `json:"prompt_template"`
	InputFromPrev  InputFromPrev `json:"input_from_prev"`
	GateAfter      bool          `json:"gate_after"`
	// StepConfig (embedded) carries the optional per-block model/reasoning-
	// effort/permission-mode/instructions. See StepConfig for field docs.
	StepConfig
	// ControlFlow (embedded) carries the optional kind/branch/loop
	// discriminator (docs/PLAN-HARNESS-BUILDER.md §4.1/§4.2). See
	// ControlFlow for field docs. Also embedded in TemplateStep — the same
	// lockstep guard as StepConfig.
	ControlFlow
	SessionID string `json:"session_id,omitempty"`
	Phase     string `json:"phase,omitempty"`
	Started   string `json:"started,omitempty"`
	Ended     string `json:"ended,omitempty"`
	// Retries counts how many times this step has been re-spawned via Resume.
	// 0 means the step has never been retried. Each Resume increments this and
	// uses it to construct a unique branch name (pipeline-<id>-step-<k>-r<n>).
	Retries int `json:"retries,omitempty"`
	// PrevSessionIDs holds the session IDs of previous (failed) attempts for
	// this step, appended in order before each re-spawn. Preserved for inspection.
	PrevSessionIDs []string `json:"prev_session_ids,omitempty"`
	// Fanout, when non-nil, declares this step as a fanout step. Its presence
	// is the discriminator — no separate agent_type sentinel.
	Fanout *FanoutConfig `json:"fanout,omitempty"`
	// SplicedFrom is provenance metadata set when this step was produced by
	// resolving a branch's condition (Orchestrator.spliceBranchAt): which
	// branch step and arm ("then"/"else") produced it. Empty for a step that
	// was never spliced. Persisted so a reader of pipeline.json can see which
	// arm actually ran — pipeline.json only ever holds the POST-splice
	// flattened form (see spliceBranchAt's doc comment for the recovery
	// invariant this implies).
	SplicedFrom string `json:"spliced_from,omitempty"`
	// Output is this step's harvested last-assistant text, captured at the
	// same point (afterStepSuccess) the orchestrator already reads it for
	// {{prev}}/gate-preview handoff — i.e. BEFORE the step's session is
	// reaped (see terminateStepSession). Truncated defensively via
	// truncateOutput so pipeline.json cannot balloon on a chatty step.
	// For a fanout step this is the WINNER's output (set via Pick ->
	// afterStepSuccess); for a loop step it is the adopted final body
	// step's output (via advanceLoop -> afterStepSuccess).
	Output string `json:"output,omitempty"`
}

// IsFanout returns true when this step is a fanout step.
func (s *Step) IsFanout() bool {
	return s.Fanout != nil && s.Fanout.Count > 0
}

// GatePreview holds the computed handoff preview populated when the pipeline
// enters AWAITING_GATE. It is persisted in pipeline.json so GET
// /api/pipeline/{id} serves it for free. The apps show Output (step k's
// last assistant text) and Prev (the computed {{prev}} for step k+1) so the
// user can review before tapping Continue. The Continue handler accepts an
// optional amended Prev, which overwrites this field before advancing.
type GatePreview struct {
	Step   int    `json:"step"`             // index of the completed gated step k
	Prev   string `json:"prev"`             // computed {{prev}} for step k+1; "" when none
	Output string `json:"output,omitempty"` // step k's last assistant text
}

// PipelineResult is the end-of-run summary populated once a pipeline reaches
// PipelineComplete (owner feature: a completed pipeline should show its end
// result). Nil for a pipeline that has not completed (running/failed/
// cancelled/awaiting-*) — apps must gate the result card on both State ==
// "complete" AND Result != nil (an older broker, or a pipeline completed
// before this feature shipped, has no Result even though State is complete).
type PipelineResult struct {
	// Output is the final step's harvested last-assistant text (same value
	// as that step's Step.Output).
	Output string `json:"output"`
	// Finished is the RFC3339 completion timestamp.
	Finished string `json:"finished"`
	// FilesChanged/Insertions/Deletions are `git diff --stat <base>...HEAD`
	// counts for the final step's worktree against the pipeline's base
	// branch, via session.DiffSummary — the same helper the fan-out compare
	// endpoint uses (internal/ws/fanout.go). Best-effort: a git error (e.g.
	// empty Base, missing worktree) leaves these at zero rather than
	// blocking completion.
	FilesChanged int `json:"files_changed"`
	Insertions   int `json:"insertions"`
	Deletions    int `json:"deletions"`
	// Branches lists the pipeline-<id>-step-* branch names that actually
	// backed the steps that ran, in step order. Best-effort — a step whose
	// exact backing branch cannot be reconstructed from persisted state
	// (e.g. an intermediate pass of a loop, superseded by the next pass in
	// the same reused body slice) is simply omitted rather than guessed.
	Branches []string `json:"branches,omitempty"`
}

// Pipeline is the top-level pipeline definition + live state.
type Pipeline struct {
	ID          string        `json:"id"`
	Title       string        `json:"title"`
	Task        string        `json:"task"`
	CWD         string        `json:"cwd"`
	Base        string        `json:"base"`
	State       PipelineState `json:"state"`
	CurrentStep int           `json:"current_step"`
	Created     string        `json:"created"`
	Steps       []Step        `json:"steps"`
	// Gate is populated when State == PipelineAwaitingGate. It holds the
	// preview the app displays and the pre-computed {{prev}} for the next
	// step. Nil in all other states.
	Gate *GatePreview `json:"gate,omitempty"`
	// Result is populated once State == PipelineComplete. See PipelineResult.
	Result *PipelineResult `json:"result,omitempty"`
	// Archived hides this pipeline from the default GET /api/pipelines list
	// (the Flow home UI shows "non-archived" flows). Set only via
	// Orchestrator.Archive, which requires a terminal state (complete/
	// failed/cancelled) — a live pipeline cannot be archived out from under
	// its running child. omitempty keeps pre-existing pipeline.json files
	// (and their unarchived siblings) byte-for-byte unchanged.
	Archived bool `json:"archived,omitempty"`
}

// NewID generates a pipeline ID: "p_" + 8 random hex chars.
func NewID() string {
	var b [4]byte
	_, _ = rand.Read(b[:])
	return "p_" + hex.EncodeToString(b[:])
}

// pipelineDir returns the directory for a pipeline's files.
func pipelineDir(conduitRoot, id string) string {
	return filepath.Join(conduitRoot, "pipelines", id)
}

// pipelinePath returns the path to a pipeline's JSON file.
func pipelinePath(conduitRoot, id string) string {
	return filepath.Join(pipelineDir(conduitRoot, id), "pipeline.json")
}

// Save persists the pipeline to <conduitRoot>/pipelines/<id>/pipeline.json.
func (p *Pipeline) Save(conduitRoot string) error {
	dir := pipelineDir(conduitRoot, p.ID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("pipeline %s: mkdir: %w", p.ID, err)
	}
	path := pipelinePath(conduitRoot, p.ID)
	data, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return fmt.Errorf("pipeline %s: marshal: %w", p.ID, err)
	}
	// Write atomically via temp file + rename.
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return fmt.Errorf("pipeline %s: write: %w", p.ID, err)
	}
	if err := os.Rename(tmp, path); err != nil {
		_ = os.Remove(tmp)
		return fmt.Errorf("pipeline %s: rename: %w", p.ID, err)
	}
	return nil
}

// Load reads a pipeline from <conduitRoot>/pipelines/<id>/pipeline.json.
func Load(conduitRoot, id string) (*Pipeline, error) {
	if id == "" {
		return nil, fmt.Errorf("pipeline id is required")
	}
	data, err := os.ReadFile(pipelinePath(conduitRoot, id))
	if err != nil {
		return nil, fmt.Errorf("pipeline %s: read: %w", id, err)
	}
	var p Pipeline
	if err := json.Unmarshal(data, &p); err != nil {
		return nil, fmt.Errorf("pipeline %s: unmarshal: %w", id, err)
	}
	return &p, nil
}

// List scans <conduitRoot>/pipelines/ and loads all pipelines.
// Missing or malformed entries are skipped with a log message.
func List(conduitRoot string) ([]*Pipeline, error) {
	dir := filepath.Join(conduitRoot, "pipelines")
	entries, err := os.ReadDir(dir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("list pipelines: %w", err)
	}
	var out []*Pipeline
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		p, err := Load(conduitRoot, e.Name())
		if err != nil {
			// Skip corrupt or partial entries.
			continue
		}
		out = append(out, p)
	}
	return out, nil
}
