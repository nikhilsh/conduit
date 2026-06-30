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

// Step is a single agent invocation within a pipeline.
type Step struct {
	Index          int           `json:"index"`
	AgentType      string        `json:"agent_type"`
	Role           string        `json:"role"`
	PromptTemplate string        `json:"prompt_template"`
	InputFromPrev  InputFromPrev `json:"input_from_prev"`
	GateAfter      bool          `json:"gate_after"`
	SessionID      string        `json:"session_id,omitempty"`
	Phase          string        `json:"phase,omitempty"`
	Started        string        `json:"started,omitempty"`
	Ended          string        `json:"ended,omitempty"`
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
