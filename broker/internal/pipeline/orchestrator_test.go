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
	agentType    string
	cwd          string
	prompt       string
	branch       string
	phase        string
	worktree     string
	lastText     string
	turnComplete bool // simulates structured-chat turn completion
}

// createdCall records the args of a single CreateSession call, in order, for
// assertions (branch names, resolved StepOverride, rendered prompt).
type createdCall struct {
	id     string
	branch string
	prompt string
	ov     StepOverride
}

// fakeSessionManager is a test double for SessionManager.
type fakeSessionManager struct {
	sessions map[string]*fakeSession
	nextID   int
	// created records each CreateSession call in order for assertions.
	created []createdCall
}

func newFakeSessionManager() *fakeSessionManager {
	return &fakeSessionManager{sessions: make(map[string]*fakeSession)}
}

func (f *fakeSessionManager) CreateSession(agentType, cwd, initialPrompt, branch string, ov StepOverride) (string, error) {
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
	f.created = append(f.created, createdCall{id: id, branch: branch, prompt: initialPrompt, ov: ov})
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

func (f *fakeSessionManager) TurnComplete(sessionID string) bool {
	s, ok := f.sessions[sessionID]
	if !ok {
		return false
	}
	return s.turnComplete && s.lastText != ""
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

// ── TurnComplete signal tests ─────────────────────────────────────────────────

// TestTurnCompleteAdvancesStep verifies that pollStep (via Advance with
// "turn_complete") correctly advances a step when TurnComplete returns true.
// This is the fix for structured-chat sessions (claude) that never exited.
func TestTurnCompleteAdvancesStep(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1", InputFromPrev: InputNone},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sessID := p.Steps[0].SessionID

	// Simulate turn complete: phase stays "running", but lastText set + turnComplete.
	sm.sessions[sessID].lastText = "done"
	sm.sessions[sessID].turnComplete = true
	// phase is still "running" (not exited) — this is the claude case.
	sm.sessions[sessID].phase = "running"

	// Advance with "turn_complete" phase signal.
	if err := orch.Advance(p, 0, "turn_complete"); err != nil {
		t.Fatalf("Advance(turn_complete): %v", err)
	}

	// Pipeline should advance to running step 1.
	if p.State != PipelineRunning {
		t.Errorf("state=%s, want running", p.State)
	}
	if p.CurrentStep != 1 {
		t.Errorf("current_step=%d, want 1", p.CurrentStep)
	}
	// Step 0's session must now be reaped: its handoff was already read
	// while rendering step 1's prompt inside spawnStep, so the process is
	// no longer needed (v1.1 RAM-leak follow-up fix).
	if sm.sessions[sessID].phase != "cancelled" {
		t.Errorf("step 0 session phase=%q, want cancelled (reaped after advance)", sm.sessions[sessID].phase)
	}
}

// TestTurnCompleteNoReplyDoesNotAdvance verifies that TurnComplete returns
// false when turn_active is false but no assistant reply exists yet
// (pre-first-turn window).
func TestTurnCompleteNoReplyDoesNotAdvance(t *testing.T) {
	sm := newFakeSessionManager()
	// Synthesize a session with turnComplete=true but lastText="" — the guard.
	sm.nextID++
	id := strings.Repeat("0", 7) + string(rune('0'+sm.nextID))
	sm.sessions[id] = &fakeSession{
		phase:        "running",
		turnComplete: true,
		lastText:     "", // no reply yet
	}
	if sm.TurnComplete(id) {
		t.Error("TurnComplete returned true with no assistant reply; want false")
	}
}

// TestTurnCompleteWithGateEntry verifies that a turn_complete advance with
// gate_after=true populates GatePreview correctly.
func TestTurnCompleteWithGateEntry(t *testing.T) {
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
	sm.sessions[p.Steps[0].SessionID].lastText = "turn output"

	if err := orch.Advance(p, 0, "turn_complete"); err != nil {
		t.Fatalf("Advance(turn_complete): %v", err)
	}

	if p.State != PipelineAwaitingGate {
		t.Fatalf("state=%s, want awaiting_gate", p.State)
	}
	if p.Gate == nil {
		t.Fatal("Gate is nil after turn_complete gate entry")
	}
	if p.Gate.Output != "turn output" {
		t.Errorf("Gate.Output=%q, want %q", p.Gate.Output, "turn output")
	}
}

// ── Fanout step tests ─────────────────────────────────────────────────────────

// TestFanoutSpawnsNRuns verifies that spawnFanout creates count sessions
// with -run-<i> branches and that step.SessionID is empty until pick.
func TestFanoutSpawnsNRuns(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout: &FanoutConfig{
				Count:      3,
				AgentTypes: []string{"claude", "codex", "opencode"},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	// Must have spawned exactly 3 sessions.
	if len(sm.created) != 3 {
		t.Fatalf("expected 3 CreateSession calls; got %d", len(sm.created))
	}

	// Verify branch names.
	for i, c := range sm.created {
		want := "pipeline-" + p.ID + "-step-0-run-" + string(rune('0'+i))
		if c.branch != want {
			t.Errorf("run %d branch=%q, want %q", i, c.branch, want)
		}
	}

	// Step.SessionID must be empty until pick.
	if p.Steps[0].SessionID != "" {
		t.Errorf("step.SessionID=%q, want empty before pick", p.Steps[0].SessionID)
	}

	// Fanout.Runs must be populated.
	fc := p.Steps[0].Fanout
	if len(fc.Runs) != 3 {
		t.Fatalf("fanout.Runs len=%d, want 3", len(fc.Runs))
	}
	for i, run := range fc.Runs {
		if run.Phase != "running" {
			t.Errorf("run %d Phase=%q, want running", i, run.Phase)
		}
		if run.SessionID == "" {
			t.Errorf("run %d SessionID is empty", i)
		}
	}
}

// TestFanoutAllFailedIsFailed verifies that when every run exits non-zero
// the pipeline transitions to FAILED.
func TestFanoutAllFailedIsFailed(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 2},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	// Set all runs to failed.
	for _, run := range p.Steps[0].Fanout.Runs {
		sm.sessions[run.SessionID].phase = "exited(1)"
	}
	// Manually settle the runs (simulating pollFanout seeing all settled).
	for i := range p.Steps[0].Fanout.Runs {
		p.Steps[0].Fanout.Runs[i].Phase = "exited(1)"
	}

	if err := orch.advanceFanout(p, 0); err != nil {
		t.Fatalf("advanceFanout: %v", err)
	}

	if p.State != PipelineFailed {
		t.Errorf("state=%s, want failed", p.State)
	}
	// All runs' processes must be reaped — Resume never reuses them.
	for i, run := range p.Steps[0].Fanout.Runs {
		if sm.sessions[run.SessionID].phase != "cancelled" {
			t.Errorf("run %d session phase=%q, want cancelled", i, sm.sessions[run.SessionID].phase)
		}
	}
}

// TestFanoutPartialFailureAwaitsPick verifies that when at least one run
// exits(0) the pipeline enters AWAITING_PICK.
func TestFanoutPartialFailureAwaitsPick(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 3},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	// Run 0: success; run 1: failed; run 2: success.
	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(1)"
	p.Steps[0].Fanout.Runs[2].Phase = "turn_complete"

	if err := orch.advanceFanout(p, 0); err != nil {
		t.Fatalf("advanceFanout: %v", err)
	}

	if p.State != PipelineAwaitingPick {
		t.Errorf("state=%s, want awaiting_pick", p.State)
	}
}

// TestPickSetsWinnerAndAdvances verifies that Pick sets fanout.winner,
// step.session_id, and spawns the next step when there is no gate.
func TestPickSetsWinnerAndAdvances(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 2},
		},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1", InputFromPrev: InputNone},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	run0SessID := p.Steps[0].Fanout.Runs[0].SessionID
	run1SessID := p.Steps[0].Fanout.Runs[1].SessionID
	_ = run1SessID

	// Settle both runs; run 0 wins.
	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(0)"
	p.State = PipelineAwaitingPick

	if err := orch.Pick(p, 0); err != nil {
		t.Fatalf("Pick(0): %v", err)
	}

	// Winner must be set.
	if p.Steps[0].Fanout.Winner == nil || *p.Steps[0].Fanout.Winner != 0 {
		t.Errorf("Fanout.Winner=%v, want 0", p.Steps[0].Fanout.Winner)
	}
	// step.SessionID must equal run 0's session ID.
	if p.Steps[0].SessionID != run0SessID {
		t.Errorf("step.SessionID=%q, want %q (run 0)", p.Steps[0].SessionID, run0SessID)
	}
	// Pipeline must advance to step 1.
	if p.CurrentStep != 1 {
		t.Errorf("current_step=%d, want 1", p.CurrentStep)
	}
	if p.State != PipelineRunning {
		t.Errorf("state=%s, want running", p.State)
	}
}

// TestPickRejectsFailedRun verifies that picking a non-exited(0) run → ErrRunFailed.
func TestPickRejectsFailedRun(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 2},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(1)"
	p.State = PipelineAwaitingPick

	if err := orch.Pick(p, 1); !errors.Is(err, ErrRunFailed) {
		t.Errorf("Pick(1) err=%v, want ErrRunFailed", err)
	}
}

// TestPickRejectsOutOfRange verifies that an out-of-range run index returns an error.
func TestPickRejectsOutOfRange(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 2},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(0)"
	p.State = PipelineAwaitingPick

	if err := orch.Pick(p, 5); err == nil {
		t.Error("Pick(5) returned nil error; want out-of-range error")
	}
	if err := orch.Pick(p, -1); err == nil {
		t.Error("Pick(-1) returned nil error; want out-of-range error")
	}
}

// TestPickNotAtPick verifies that Pick when not in awaiting_pick returns ErrNotAtPick.
func TestPickNotAtPick(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
	})
	p.State = PipelineRunning

	if err := orch.Pick(p, 0); !errors.Is(err, ErrNotAtPick) {
		t.Errorf("Pick on running state: got %v, want ErrNotAtPick", err)
	}
}

// TestFanoutGateAfterEntersGateWithWinnerPreview verifies that when a fanout
// step has gate_after=true, picking the winner transitions to AWAITING_GATE
// with a GatePreview computed from the winner's session.
func TestFanoutGateAfterEntersGateWithWinnerPreview(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			GateAfter:      true,
			Fanout:         &FanoutConfig{Count: 2},
		},
		{Index: 1, AgentType: "claude", PromptTemplate: "{{prev}}", InputFromPrev: InputOutput},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	winnerSessID := p.Steps[0].Fanout.Runs[0].SessionID
	sm.sessions[winnerSessID].lastText = "winner output"

	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(0)"
	p.State = PipelineAwaitingPick

	if err := orch.Pick(p, 0); err != nil {
		t.Fatalf("Pick(0): %v", err)
	}

	if p.State != PipelineAwaitingGate {
		t.Fatalf("state=%s, want awaiting_gate", p.State)
	}
	if p.Gate == nil {
		t.Fatal("Gate is nil after fanout pick with gate_after=true")
	}
	if p.Gate.Output != "winner output" {
		t.Errorf("Gate.Output=%q, want %q", p.Gate.Output, "winner output")
	}
	if p.Steps[0].SessionID != winnerSessID {
		t.Errorf("step.SessionID=%q, want winner=%q", p.Steps[0].SessionID, winnerSessID)
	}
}

// TestCancelKillsAllFanoutRuns verifies that Cancel during a fanout step
// kills every live run session.
func TestCancelKillsAllFanoutRuns(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 3},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}

	runSessIDs := make([]string, 3)
	for i, run := range p.Steps[0].Fanout.Runs {
		runSessIDs[i] = run.SessionID
	}

	p.State = PipelineRunning
	if err := orch.Cancel(p); err != nil {
		t.Fatalf("Cancel: %v", err)
	}

	if p.State != PipelineCancelled {
		t.Errorf("state=%s, want cancelled", p.State)
	}
	for i, sessID := range runSessIDs {
		if sm.sessions[sessID].phase != "cancelled" {
			t.Errorf("run %d session %s not cancelled (phase=%q)", i, sessID, sm.sessions[sessID].phase)
		}
	}
}

// ── Completed-step session reaping (v1.1 RAM-leak follow-up) ────────────────

// TestGateEntryTerminatesStepSession verifies that entering AWAITING_GATE
// reaps the gated step's live session — its handoff (Output/Prev) has
// already been harvested into the persisted GatePreview by that point, so
// the process is no longer needed.
func TestGateEntryTerminatesStepSession(t *testing.T) {
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
	sessID := p.Steps[0].SessionID
	sm.sessions[sessID].lastText = "the result of step 0"

	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.State != PipelineAwaitingGate {
		t.Fatalf("state=%s, want awaiting_gate", p.State)
	}
	if sm.sessions[sessID].phase != "cancelled" {
		t.Errorf("gated step 0 session phase=%q, want cancelled", sm.sessions[sessID].phase)
	}
}

// TestGateAmendStillWorksAfterSessionReaped verifies the Continue-with-amend
// flow (edit handoff) still works even though the gated step's session was
// already terminated on gate entry — Continue must read exclusively from
// the persisted Gate, never re-read the (now-dead) live session.
func TestGateAmendStillWorksAfterSessionReaped(t *testing.T) {
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
	step0SessID := p.Steps[0].SessionID
	sm.sessions[step0SessID].lastText = "original output"

	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if sm.sessions[step0SessID].phase != "cancelled" {
		t.Fatalf("precondition failed: step 0 session should already be reaped, phase=%q", sm.sessions[step0SessID].phase)
	}

	// Continue with an amendment — must succeed purely off persisted Gate
	// state, with no read of the dead step-0 session.
	if err := orch.Continue(p, "amended after reap"); err != nil {
		t.Fatalf("Continue: %v", err)
	}
	step1SessID := p.Steps[1].SessionID
	if step1SessID == "" {
		t.Fatal("step 1 has no session ID after Continue")
	}
	spawnedPrompt := sm.sessions[step1SessID].prompt
	if !strings.Contains(spawnedPrompt, "amended after reap") {
		t.Errorf("step 1 prompt does not contain amended text; got %q", spawnedPrompt)
	}
}

// TestFailedStepTerminatesSession verifies that a step failing (non-zero
// exit) reaps its own session — Resume always spawns a fresh session for
// the retry and never reuses the failed one.
func TestFailedStepTerminatesSession(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sessID := p.Steps[0].SessionID

	if err := orch.Advance(p, 0, "exited(1)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.State != PipelineFailed {
		t.Fatalf("state=%s, want failed", p.State)
	}
	if sm.sessions[sessID].phase != "cancelled" {
		t.Errorf("failed step 0 session phase=%q, want cancelled", sm.sessions[sessID].phase)
	}
}

// TestCompleteTerminatesFinalStepSession verifies that reaching COMPLETE
// reaps the last step's session.
func TestCompleteTerminatesFinalStepSession(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0", InputFromPrev: InputNone},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sessID := p.Steps[0].SessionID
	sm.sessions[sessID].lastText = "final output"

	if err := orch.Advance(p, 0, "exited(0)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.State != PipelineComplete {
		t.Fatalf("state=%s, want complete", p.State)
	}
	if sm.sessions[sessID].phase != "cancelled" {
		t.Errorf("final step session phase=%q, want cancelled", sm.sessions[sessID].phase)
	}
}

// TestPickTerminatesLosersOnly verifies that Pick reaps the losing fanout
// runs' sessions immediately, while the winner's session stays alive until
// its own handoff is harvested (afterStepSuccess/spawnNext, or gate entry).
func TestPickTerminatesLosersOnly(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			Fanout:         &FanoutConfig{Count: 3},
		},
		{Index: 1, AgentType: "claude", PromptTemplate: "step 1", InputFromPrev: InputNone},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	run0 := p.Steps[0].Fanout.Runs[0].SessionID
	run1 := p.Steps[0].Fanout.Runs[1].SessionID
	run2 := p.Steps[0].Fanout.Runs[2].SessionID

	p.Steps[0].Fanout.Runs[0].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[1].Phase = "exited(0)"
	p.Steps[0].Fanout.Runs[2].Phase = "exited(0)"
	p.State = PipelineAwaitingPick

	if err := orch.Pick(p, 0); err != nil {
		t.Fatalf("Pick(0): %v", err)
	}

	// Losers (run 1, run 2) must be terminated immediately.
	if sm.sessions[run1].phase != "cancelled" {
		t.Errorf("loser run 1 session phase=%q, want cancelled", sm.sessions[run1].phase)
	}
	if sm.sessions[run2].phase != "cancelled" {
		t.Errorf("loser run 2 session phase=%q, want cancelled", sm.sessions[run2].phase)
	}
	// The winner (run 0) has now been carried through afterStepSuccess ->
	// spawnNext, which harvests step 1's {{prev}} from it then reaps it —
	// so by the time Pick returns it is ALSO terminated (no gate_after on
	// step 0 here, so it advances immediately rather than parking at a gate).
	if sm.sessions[run0].phase != "cancelled" {
		t.Errorf("winner run 0 session phase=%q, want cancelled after step advanced", sm.sessions[run0].phase)
	}
	if p.State != PipelineRunning || p.CurrentStep != 1 {
		t.Fatalf("state=%s current_step=%d, want running/1", p.State, p.CurrentStep)
	}
}

// TestFanoutJSONRoundtrip verifies FanoutConfig + Winner survive a Save/Load.
func TestFanoutJSONRoundtrip(t *testing.T) {
	dir := t.TempDir()
	winner := 1
	p := &Pipeline{
		ID:    "p_fanout01",
		Title: "fanout roundtrip",
		State: PipelineAwaitingPick,
		Steps: []Step{
			{
				Index: 0,
				Fanout: &FanoutConfig{
					Count:      2,
					AgentTypes: []string{"claude", "codex"},
					Runs: []FanoutRun{
						{Index: 0, Phase: "exited(0)", SessionID: "s_a"},
						{Index: 1, Phase: "turn_complete", SessionID: "s_b"},
					},
					Winner: &winner,
				},
			},
		},
	}
	if err := p.Save(dir); err != nil {
		t.Fatalf("Save: %v", err)
	}
	got, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if got.Steps[0].Fanout == nil {
		t.Fatal("Fanout nil after Load")
	}
	fc := got.Steps[0].Fanout
	if fc.Count != 2 {
		t.Errorf("Count=%d, want 2", fc.Count)
	}
	if fc.Winner == nil || *fc.Winner != 1 {
		t.Errorf("Winner=%v, want 1", fc.Winner)
	}
	if len(fc.Runs) != 2 || fc.Runs[1].Phase != "turn_complete" {
		t.Errorf("Runs=%+v", fc.Runs)
	}
}

// ── Phase 1 block-config plumbing (docs/PLAN-HARNESS-BUILDER.md §2) ─────────

// TestSpawnStepPassesResolvedStepOverride verifies a normal (non-fanout) step
// resolves its Model/ReasoningEffort/PermissionMode onto the StepOverride
// CreateSession receives.
func TestSpawnStepPassesResolvedStepOverride(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			StepConfig: StepConfig{
				Model:           "opus",
				ReasoningEffort: "high",
				PermissionMode:  "plan",
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	if len(sm.created) != 1 {
		t.Fatalf("expected 1 CreateSession call; got %d", len(sm.created))
	}
	ov := sm.created[0].ov
	if ov.Model != "opus" || ov.ReasoningEffort != "high" || ov.PermissionMode != "plan" {
		t.Errorf("StepOverride=%+v, want {opus high plan}", ov)
	}
}

// TestSpawnFanoutPerRunOverrideFallback verifies fanout per-run resolution:
// fc.Models[i] (when non-empty) wins; otherwise the step's own Model is used
// as the fallback. Same chain for ReasoningEfforts/PermissionModes/
// Instructions.
func TestSpawnFanoutPerRunOverrideFallback(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			StepConfig: StepConfig{
				Model:           "step-default-model",
				ReasoningEffort: "step-default-effort",
				PermissionMode:  "step-default-mode",
				Instructions:    "step-default-instructions",
			},
			Fanout: &FanoutConfig{
				Count:            3,
				AgentTypes:       []string{"claude", "codex", "opencode"},
				Models:           []string{"opus", "", "gpt-5-codex"},
				ReasoningEfforts: []string{"", "high", ""},
				PermissionModes:  []string{"plan", "", ""},
				Instructions:     []string{"", "run 1 instructions", ""},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	if len(sm.created) != 3 {
		t.Fatalf("expected 3 CreateSession calls; got %d", len(sm.created))
	}

	cases := []struct {
		i                          int
		wantModel, wantEffort      string
		wantMode, wantInstructions string
	}{
		// run 0: model+mode set, effort+instructions fall back to step default.
		{0, "opus", "step-default-effort", "plan", "step-default-instructions"},
		// run 1: effort+instructions set, model+mode fall back to step default.
		{1, "step-default-model", "high", "step-default-mode", "run 1 instructions"},
		// run 2: only model set, everything else falls back to step default.
		{2, "gpt-5-codex", "step-default-effort", "step-default-mode", "step-default-instructions"},
	}
	for _, tc := range cases {
		ov := sm.created[tc.i].ov
		if ov.Model != tc.wantModel {
			t.Errorf("run %d: Model=%q, want %q", tc.i, ov.Model, tc.wantModel)
		}
		if ov.ReasoningEffort != tc.wantEffort {
			t.Errorf("run %d: ReasoningEffort=%q, want %q", tc.i, ov.ReasoningEffort, tc.wantEffort)
		}
		if ov.PermissionMode != tc.wantMode {
			t.Errorf("run %d: PermissionMode=%q, want %q", tc.i, ov.PermissionMode, tc.wantMode)
		}
		if ov.Instructions != tc.wantInstructions {
			t.Errorf("run %d: Instructions=%q, want %q", tc.i, ov.Instructions, tc.wantInstructions)
		}
	}
}

// TestInstructionsPreamblePresentOnNormalSpawn verifies a step with
// Instructions set gets the <block-instructions> preamble prepended to its
// rendered prompt on a normal spawn.
func TestInstructionsPreamblePresentOnNormalSpawn(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			StepConfig:     StepConfig{Instructions: "Be terse. Only touch the parser."},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	prompt := sm.created[0].prompt
	want := "<block-instructions>\nBe terse. Only touch the parser.\n</block-instructions>\n\ndo: do things"
	if prompt != want {
		t.Errorf("prompt=%q, want %q", prompt, want)
	}
}

// TestInstructionsPreambleAbsentOnResume verifies the resume/overridePrompt
// path does NOT re-prepend the preamble — the amended prompt is delivered
// verbatim, even when the step's Instructions field is still set from before
// the failure.
func TestInstructionsPreambleAbsentOnResume(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			StepConfig:     StepConfig{Instructions: "Be terse. Only touch the parser."},
		},
	})

	// Spawn, then fail it so Resume is legal.
	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep: %v", err)
	}
	if err := orch.Advance(p, 0, "exited(1)"); err != nil {
		t.Fatalf("Advance: %v", err)
	}
	if p.State != PipelineFailed {
		t.Fatalf("state=%s, want failed", p.State)
	}

	if err := orch.Resume(p, "verbatim amended prompt"); err != nil {
		t.Fatalf("Resume: %v", err)
	}
	if len(sm.created) != 2 {
		t.Fatalf("expected 2 CreateSession calls; got %d", len(sm.created))
	}
	prompt := sm.created[1].prompt
	if prompt != "verbatim amended prompt" {
		t.Errorf("resumed prompt=%q, want verbatim %q (no preamble)", prompt, "verbatim amended prompt")
	}
	if strings.Contains(prompt, "block-instructions") {
		t.Errorf("resumed prompt unexpectedly contains the instructions preamble: %q", prompt)
	}
}

// TestBogusModelStillReachesRunning verifies a malformed/unknown model or
// effort does not fail the spawn — the override layer (session package)
// silently drops bad values; the pipeline orchestrator itself must never
// validate or reject StepOverride contents.
func TestBogusModelStillReachesRunning(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			Index: 0, AgentType: "claude",
			PromptTemplate: "do: {{task}}",
			InputFromPrev:  InputNone,
			StepConfig: StepConfig{
				Model:           "totally-bogus-model-xyz",
				ReasoningEffort: "ludicrous-effort",
			},
		},
	})

	if err := orch.Start(p); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if p.State != PipelineRunning {
		t.Fatalf("state=%s, want running", p.State)
	}
	if p.Steps[0].SessionID == "" {
		t.Fatal("step 0 has no session ID after Start with a bogus model")
	}
	ov := sm.created[0].ov
	if ov.Model != "totally-bogus-model-xyz" {
		t.Errorf("ov.Model=%q, want the bogus value passed through unchanged", ov.Model)
	}
}
