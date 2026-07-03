package pipeline

import (
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeSession holds the state of a session created by the fake manager.
type fakeSession struct {
	agentType string
	cwd       string
	prompt    string
	branch    string
	phase     string
	worktree  string
	lastText  string
}

// fakeSessionManager is a test double for SessionManager.
type fakeSessionManager struct {
	sessions map[string]*fakeSession
	nextID   int
	// created records branch args in order for Feature 3 assertions.
	created []struct{ id, branch string }
}

func newFakeSessionManager() *fakeSessionManager {
	return &fakeSessionManager{sessions: make(map[string]*fakeSession)}
}

func (f *fakeSessionManager) CreateSession(agentType, cwd, initialPrompt, branch string) (string, error) {
	f.nextID++
	id := strings.Repeat("0", 7) + string(rune('0'+f.nextID))
	sess := &fakeSession{
		agentType: agentType,
		cwd:       cwd,
		prompt:    initialPrompt,
		branch:    branch,
		phase:     "running",
	}
	f.sessions[id] = sess
	f.created = append(f.created, struct{ id, branch string }{id, branch})
	return id, nil
}

func (f *fakeSessionManager) GetPhase(sessionID string) string {
	s, ok := f.sessions[sessionID]
	if !ok {
		return ""
	}
	return s.phase
}

func (f *fakeSessionManager) GetWorktreeDir(sessionID string) string {
	s, ok := f.sessions[sessionID]
	if !ok {
		return ""
	}
	return s.worktree
}

func (f *fakeSessionManager) GetLastAssistantText(sessionID string) string {
	s, ok := f.sessions[sessionID]
	if !ok {
		return ""
	}
	return s.lastText
}

func (f *fakeSessionManager) CancelSession(sessionID string) error {
	if s, ok := f.sessions[sessionID]; ok {
		s.phase = "cancelled"
	}
	return nil
}

// makeTestPipeline creates a minimal pipeline.json in conduitRoot for testing.
func makeTestPipeline(t *testing.T, conduitRoot string, steps []Step) *Pipeline {
	t.Helper()
	p := &Pipeline{
		ID:    NewID(),
		Title: "test pipeline",
		Task:  "do things",
		CWD:   "/tmp",
		State: PipelinePending,
		Steps: steps,
	}
	if err := p.Save(conduitRoot); err != nil {
		t.Fatalf("save pipeline: %v", err)
	}
	return p
}

// TestGateEntryPopulatesGatePreview verifies Feature 1: Advance with gate_after=true
// sets p.Gate (with Prev + Output) and persists it; input.md is written.
func TestGateEntryPopulatesGatePreview(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone, GateAfter: true},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1: {{prev}}", InputFromPrev: InputOutput},
	})

	// Spawn step 0.
	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	step0SessID := p.Steps[0].SessionID
	if step0SessID == "" {
		t.Fatal("step 0 has no session ID after spawn")
	}
	// Set fake output for step 0.
	sm.sessions[step0SessID].lastText = "the result of step 0"

	// Advance with gate_after=true.
	p.Steps[0].Phase = "running" // simulate running
	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}

	if p.State != PipelineAwaitingGate {
		t.Fatalf("state=%s, want awaiting_gate", p.State)
	}
	if p.Gate == nil {
		t.Fatal("Gate is nil after gate entry")
	}
	if p.Gate.Step != 0 {
		t.Errorf("Gate.Step=%d, want 0", p.Gate.Step)
	}
	if p.Gate.Output != "the result of step 0" {
		t.Errorf("Gate.Output=%q, want %q", p.Gate.Output, "the result of step 0")
	}
	// Prev for step 1 with InputOutput = transcript text.
	if p.Gate.Prev != "the result of step 0" {
		t.Errorf("Gate.Prev=%q, want %q", p.Gate.Prev, "the result of step 0")
	}

	// Verify input.md was written for step 1.
	inputPath := filepath.Join(dir, "pipelines", p.ID, "steps", "1", "input.md")
	data, err := os.ReadFile(inputPath)
	if err != nil {
		t.Fatalf("input.md not written: %v", err)
	}
	if string(data) != "the result of step 0" {
		t.Errorf("input.md content=%q, want %q", string(data), "the result of step 0")
	}

	// Verify pipeline.json persisted with gate.
	reloaded, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load after gate: %v", err)
	}
	if reloaded.Gate == nil {
		t.Fatal("reloaded pipeline.Gate is nil — not persisted")
	}
	if reloaded.Gate.Prev != "the result of step 0" {
		t.Errorf("reloaded Gate.Prev=%q", reloaded.Gate.Prev)
	}
}

// TestContinueWithAmendedPrev verifies Feature 2: providing an amended prev in
// Continue overwrites Gate.Prev before spawning the next step; p.Gate is cleared
// after spawn; the spawned prompt contains the amended text.
func TestContinueWithAmendedPrev(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone, GateAfter: true},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1: {{prev}}", InputFromPrev: InputOutput},
	})

	// Spawn step 0 and advance to gate.
	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sm.sessions[p.Steps[0].SessionID].lastText = "original output"
	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}

	// Confirm we are at gate with original prev.
	if p.Gate == nil {
		t.Fatal("expected Gate after Advance")
	}
	if p.Gate.Prev != "original output" {
		t.Errorf("pre-continue Gate.Prev=%q", p.Gate.Prev)
	}

	// Continue with amended prev.
	if err := orch.Continue(p, "amended handoff text"); err != nil {
		t.Fatalf("Continue: %v", err)
	}

	// Gate should be cleared after spawn succeeds.
	if p.Gate != nil {
		t.Errorf("Gate not cleared after successful Continue: %+v", p.Gate)
	}
	if p.State != PipelineRunning {
		t.Errorf("state=%s, want running after continue", p.State)
	}

	// The spawned step 1 prompt must contain amended text, not original.
	step1SessID := p.Steps[1].SessionID
	if step1SessID == "" {
		t.Fatal("step 1 has no session ID after Continue")
	}
	spawnedPrompt := sm.sessions[step1SessID].prompt
	if !strings.Contains(spawnedPrompt, "amended handoff text") {
		t.Errorf("step 1 prompt does not contain amended text; got %q", spawnedPrompt)
	}
	if strings.Contains(spawnedPrompt, "original output") {
		t.Errorf("step 1 prompt still contains original output; got %q", spawnedPrompt)
	}

	// input.md must have been overwritten with the amended text.
	inputPath := filepath.Join(dir, "pipelines", p.ID, "steps", "1", "input.md")
	data, err := os.ReadFile(inputPath)
	if err != nil {
		t.Fatalf("input.md read: %v", err)
	}
	if string(data) != "amended handoff text" {
		t.Errorf("input.md=%q, want %q", string(data), "amended handoff text")
	}
}

// TestContinueWithEmptyPrevUsesOriginal verifies Feature 2: an empty amendedPrev
// leaves Gate.Prev unchanged; the step is spawned with the original computed prev.
func TestContinueWithEmptyPrevUsesOriginal(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone, GateAfter: true},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1: {{prev}}", InputFromPrev: InputOutput},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sm.sessions[p.Steps[0].SessionID].lastText = "original output"
	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}

	// Continue with empty amendedPrev → original is used.
	if err := orch.Continue(p, ""); err != nil {
		t.Fatalf("Continue: %v", err)
	}

	step1SessID := p.Steps[1].SessionID
	if step1SessID == "" {
		t.Fatal("step 1 has no session ID")
	}
	spawnedPrompt := sm.sessions[step1SessID].prompt
	if !strings.Contains(spawnedPrompt, "original output") {
		t.Errorf("step 1 prompt does not contain original output; got %q", spawnedPrompt)
	}
}

// TestCreateSessionReceivesBranch verifies Feature 3: CreateSession is called with
// the branch name "pipeline-<id>-step-<k>".
func TestCreateSessionReceivesBranch(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1: {{prev}}", InputFromPrev: InputOutput},
	})

	// Spawn step 0.
	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	if len(sm.created) < 1 {
		t.Fatal("no CreateSession calls recorded")
	}
	wantBranch0 := "pipeline-" + p.ID + "-step-0"
	if sm.created[0].branch != wantBranch0 {
		t.Errorf("step 0 branch=%q, want %q", sm.created[0].branch, wantBranch0)
	}

	// Advance and spawn step 1.
	sm.sessions[p.Steps[0].SessionID].lastText = "output"
	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	// step 1 has no gate_after so spawnNext was called by Advance.
	if len(sm.created) < 2 {
		t.Fatal("step 1 CreateSession not called")
	}
	wantBranch1 := "pipeline-" + p.ID + "-step-1"
	if sm.created[1].branch != wantBranch1 {
		t.Errorf("step 1 branch=%q, want %q", sm.created[1].branch, wantBranch1)
	}
}

// TestGateClearedOnCancel verifies Feature 1: Gate is nil after Cancel.
func TestGateClearedOnCancel(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone, GateAfter: true},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1", InputFromPrev: InputOutput},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sm.sessions[p.Steps[0].SessionID].lastText = "output"
	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.Gate == nil {
		t.Fatal("expected Gate after advance to gate")
	}

	if err := orch.Cancel(p); err != nil {
		t.Fatalf("Cancel: %v", err)
	}
	if p.Gate != nil {
		t.Errorf("Gate not nil after Cancel: %+v", p.Gate)
	}

	reloaded, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load after cancel: %v", err)
	}
	if reloaded.Gate != nil {
		t.Errorf("reloaded Gate not nil after Cancel")
	}
}

// TestGateClearedOnFailed verifies Feature 1: Gate is nil after a failed step.
func TestGateClearedOnFailed(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
	})

	// Manually set a stale Gate to simulate a recover scenario.
	p.Gate = &GatePreview{Step: 0, Prev: "stale", Output: "stale"}
	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	// Advance with non-zero exit.
	if err := orch.Advance(p, 0, "exited(1)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.State != PipelineFailed {
		t.Errorf("state=%s, want failed", p.State)
	}
	if p.Gate != nil {
		t.Errorf("Gate not nil after FAILED: %+v", p.Gate)
	}
}

// TestPipelineJSONRoundtrip verifies that GatePreview survives a Save/Load cycle.
func TestPipelineJSONRoundtrip(t *testing.T) {
	dir := t.TempDir()
	p := &Pipeline{
		ID:    "p_test01",
		Title: "roundtrip",
		State: PipelineAwaitingGate,
		Steps: []Step{{Index: 0}},
		Gate:  &GatePreview{Step: 0, Prev: "prev text", Output: "out text"},
	}
	if err := p.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Gate == nil {
		t.Fatal("Gate nil after Load")
	}
	if got.Gate.Step != 0 || got.Gate.Prev != "prev text" || got.Gate.Output != "out text" {
		t.Errorf("Gate mismatch: %+v", got.Gate)
	}
}

// TestResumeFailedPipeline verifies that Resume on a failed pipeline re-spawns
// the failed step with Retries=1, uses the branch suffix -r1, preserves the
// old session id in PrevSessionIDs, and transitions state back to running.
func TestResumeFailedPipeline(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0: {{task}}", InputFromPrev: InputNone},
	})

	// Start the pipeline to get step 0 spawned with its initial session.
	if err := orch.Start(p); err != nil {
		t.Fatalf("Start: %v", err)
	}
	origSessID := p.Steps[0].SessionID
	if origSessID == "" {
		t.Fatal("step 0 has no session ID after Start")
	}
	if len(sm.created) != 1 {
		t.Fatalf("expected 1 CreateSession call; got %d", len(sm.created))
	}

	// Simulate failure.
	if err := orch.Advance(p, 0, "exited(1)"); err != nil {
		t.Fatalf("Advance(failed): %v", err)
	}
	if p.State != PipelineFailed {
		t.Fatalf("state=%s, want failed", p.State)
	}

	// Reload so we're working with the persisted state.
	p, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	// Resume without an amended prompt.
	if err := orch.Resume(p, ""); err != nil {
		t.Fatalf("Resume: %v", err)
	}

	// State should be running again.
	if p.State != PipelineRunning {
		t.Errorf("state=%s, want running after resume", p.State)
	}

	// Retries should be 1.
	if p.Steps[0].Retries != 1 {
		t.Errorf("Retries=%d, want 1", p.Steps[0].Retries)
	}

	// PrevSessionIDs must contain the original session id.
	if len(p.Steps[0].PrevSessionIDs) != 1 || p.Steps[0].PrevSessionIDs[0] != origSessID {
		t.Errorf("PrevSessionIDs=%v, want [%s]", p.Steps[0].PrevSessionIDs, origSessID)
	}

	// A new session must have been created.
	if p.Steps[0].SessionID == origSessID {
		t.Errorf("SessionID unchanged after resume; want a new id")
	}
	if p.Steps[0].SessionID == "" {
		t.Error("SessionID is empty after resume")
	}

	// Branch suffix must be -r1.
	if len(sm.created) < 2 {
		t.Fatal("expected 2 CreateSession calls total; second call missing")
	}
	wantBranch := "pipeline-" + p.ID + "-step-0-r1"
	if sm.created[1].branch != wantBranch {
		t.Errorf("retry branch=%q, want %q", sm.created[1].branch, wantBranch)
	}

	// Persisted pipeline must reflect the updated step.
	reloaded, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load after resume: %v", err)
	}
	if reloaded.Steps[0].Retries != 1 {
		t.Errorf("reloaded Retries=%d, want 1", reloaded.Steps[0].Retries)
	}
	if len(reloaded.Steps[0].PrevSessionIDs) != 1 {
		t.Errorf("reloaded PrevSessionIDs=%v, want 1 entry", reloaded.Steps[0].PrevSessionIDs)
	}
}

// TestResumeWithAmendedPrompt verifies that when amendedPrompt is non-empty it
// is delivered verbatim to the new session without template rendering.
func TestResumeWithAmendedPrompt(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "original template: {{task}}", InputFromPrev: InputNone},
	})

	if err := orch.Start(p); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := orch.Advance(p, 0, "exited(1)"); err != nil {
		t.Fatalf("Advance(failed): %v", err)
	}

	p, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}

	const amended = "completely different custom prompt"
	if err := orch.Resume(p, amended); err != nil {
		t.Fatalf("Resume: %v", err)
	}

	// The new session must have received the amended prompt verbatim.
	newSessID := p.Steps[0].SessionID
	if newSessID == "" {
		t.Fatal("new session ID is empty")
	}
	gotPrompt := sm.sessions[newSessID].prompt
	if gotPrompt != amended {
		t.Errorf("prompt=%q, want %q", gotPrompt, amended)
	}
}

// TestResumeNotFailedReturnsError verifies that Resume returns ErrNotFailed
// when the pipeline is not in the failed state (e.g. running).
func TestResumeNotFailedReturnsError(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
	})

	// Pipeline is in pending state — Resume must reject.
	if err := orch.Resume(p, ""); !errors.Is(err, ErrNotFailed) {
		t.Errorf("Resume on pending: got %v, want ErrNotFailed", err)
	}

	// Start it so it's running.
	if err := orch.Start(p); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := orch.Resume(p, ""); !errors.Is(err, ErrNotFailed) {
		t.Errorf("Resume on running: got %v, want ErrNotFailed", err)
	}
}

// TestGateNilSerializesOmitted verifies that Gate=nil omits the field in JSON
// (json:"gate,omitempty" check).
func TestGateNilSerializesOmitted(t *testing.T) {
	p := &Pipeline{
		ID:    "p_test02",
		Title: "no gate",
		State: PipelineRunning,
		Steps: []Step{},
		Gate:  nil,
	}
	data, err := json.Marshal(p)
	if err != nil {
		t.Fatalf("Marshal: %v", err)
	}
	if strings.Contains(string(data), `"gate"`) {
		t.Errorf("gate field present in JSON when nil; got %s", string(data))
	}
}
