package pipeline

import (
	"encoding/json"
	"testing"
)

// ── Condition evaluation table (§4.6: contains/not_contains/matches × then/
// else × prev_output/exit_status) ───────────────────────────────────────────

func TestEvalConditionTable(t *testing.T) {
	cases := []struct {
		name       string
		cond       Condition
		prevOutput string
		prevPhase  string
		want       bool
	}{
		{"prev_output contains match", Condition{Source: "prev_output", Predicate: "contains", Value: "APPROVED"}, "status: APPROVED", "exited(0)", true},
		{"prev_output contains no match", Condition{Source: "prev_output", Predicate: "contains", Value: "APPROVED"}, "status: REJECTED", "exited(0)", false},
		{"prev_output not_contains match", Condition{Source: "prev_output", Predicate: "not_contains", Value: "APPROVED"}, "status: REJECTED", "exited(0)", true},
		{"prev_output not_contains no match", Condition{Source: "prev_output", Predicate: "not_contains", Value: "APPROVED"}, "status: APPROVED", "exited(0)", false},
		{"prev_output matches regex match", Condition{Source: "prev_output", Predicate: "matches", Value: "^VERDICT: PASS$"}, "VERDICT: PASS", "exited(0)", true},
		{"prev_output matches regex no match", Condition{Source: "prev_output", Predicate: "matches", Value: "^VERDICT: PASS$"}, "VERDICT: FAIL", "exited(0)", false},
		{"exit_status succeeded true", Condition{Source: "exit_status", Predicate: "succeeded"}, "", "exited(0)", true},
		{"exit_status succeeded false", Condition{Source: "exit_status", Predicate: "succeeded"}, "", "exited(1)", false},
		{"exit_status failed true", Condition{Source: "exit_status", Predicate: "failed"}, "", "exited(1)", true},
		{"exit_status failed false", Condition{Source: "exit_status", Predicate: "failed"}, "", "exited(0)", false},
		{"exit_status succeeded via turn_complete", Condition{Source: "exit_status", Predicate: "succeeded"}, "", "turn_complete", true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := evalCondition(tc.cond, tc.prevOutput, tc.prevPhase)
			if err != nil {
				t.Fatalf("evalCondition: %v", err)
			}
			if got != tc.want {
				t.Errorf("got %v, want %v", got, tc.want)
			}
		})
	}
}

// ── PrepareSteps validation (depth, max_iterations, malformed conditions) ───

// TestPrepareStepsAllowsDepth2 verifies a branch's then/else arms (depth 2)
// are valid, and that AgentType is defaulted recursively into nested steps.
func TestPrepareStepsAllowsDepth2(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
					Then:      []Step{{PromptTemplate: "do it"}},
					Else:      []Step{{PromptTemplate: "fallback"}},
				},
			},
		},
	}
	if err := PrepareSteps(steps); err != nil {
		t.Fatalf("expected depth-2 nesting to be valid, got: %v", err)
	}
	if steps[0].Branch.Then[0].AgentType != "claude" {
		t.Errorf("nested Then step AgentType not defaulted: %+v", steps[0].Branch.Then[0])
	}
	if steps[0].Branch.Else[0].AgentType != "claude" {
		t.Errorf("nested Else step AgentType not defaulted: %+v", steps[0].Branch.Else[0])
	}
}

// TestPrepareStepsRejectsDepth3 verifies a branch nested two levels deep
// inside another branch's Then arm (depth 3) is rejected.
func TestPrepareStepsRejectsDepth3(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
					Then: []Step{
						{
							ControlFlow: ControlFlow{
								Kind: StepKindBranch, // depth-2 branch -> its own Then would be depth 3
								Branch: &BranchConfig{
									Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
									Then:      []Step{{PromptTemplate: "too deep"}},
								},
							},
						},
					},
				},
			},
		},
	}
	if err := PrepareSteps(steps); err == nil {
		t.Fatal("expected error for depth-3 nesting, got nil")
	}
}

// TestPrepareStepsRejectsMaxIterationsAbove5 verifies the loop iteration
// ceiling (§8.5 owner decision: 5).
func TestPrepareStepsRejectsMaxIterationsAbove5(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{PromptTemplate: "x"}},
					Until:         Condition{Source: "exit_status", Predicate: "succeeded"},
					MaxIterations: 6,
				},
			},
		},
	}
	if err := PrepareSteps(steps); err == nil {
		t.Fatal("expected error for max_iterations=6 (> 5), got nil")
	}
}

// TestPrepareStepsAllowsMaxIterationsAt5 verifies exactly 5 is accepted (the
// boundary, not just values below it).
func TestPrepareStepsAllowsMaxIterationsAt5(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{PromptTemplate: "x"}},
					Until:         Condition{Source: "exit_status", Predicate: "succeeded"},
					MaxIterations: 5,
				},
			},
		},
	}
	if err := PrepareSteps(steps); err != nil {
		t.Errorf("expected max_iterations=5 to be valid, got: %v", err)
	}
}

// TestPrepareStepsRejectsFanoutInsideBranchArm verifies a fanout step
// nested inside a branch arm is rejected (unvalidated by the top-level
// fanout count/array checks; out of scope for this feature).
func TestPrepareStepsRejectsFanoutInsideBranchArm(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
					Then:      []Step{{PromptTemplate: "x", Fanout: &FanoutConfig{Count: 2}}},
				},
			},
		},
	}
	if err := PrepareSteps(steps); err == nil {
		t.Fatal("expected error for fanout nested inside a branch arm, got nil")
	}
}

// TestPrepareStepsRejectsMalformedCondition verifies an unknown predicate is
// rejected at create time (before any agent spends a paid turn on it).
func TestPrepareStepsRejectsMalformedCondition(t *testing.T) {
	steps := []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "prev_output", Predicate: "regexes_everything"},
					Then:      []Step{{PromptTemplate: "x"}},
				},
			},
		},
	}
	if err := PrepareSteps(steps); err == nil {
		t.Fatal("expected error for unknown predicate, got nil")
	}
}

// ── Branch resolution (splicing) ─────────────────────────────────────────────

// TestResolveBranchesTakesMatchedThen verifies a matched condition splices
// in the Then arm.
func TestResolveBranchesTakesMatchedThen(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0"},
		{
			Index: 1,
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "prev_output", Predicate: "contains", Value: "APPROVED"},
					Then:      []Step{{AgentType: "claude", PromptTemplate: "then step"}},
					Else:      []Step{{AgentType: "claude", PromptTemplate: "else step"}},
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sm.sessions[p.Steps[0].SessionID].lastText = "status: APPROVED"
	p.Steps[0].Phase = "exited(0)"

	if err := orch.resolveBranches(p, 1); err != nil {
		t.Fatalf("resolveBranches: %v", err)
	}
	if len(p.Steps) != 2 {
		t.Fatalf("expected 2 steps after splice, got %d: %+v", len(p.Steps), p.Steps)
	}
	if p.Steps[1].PromptTemplate != "then step" {
		t.Errorf("expected then arm spliced in, got prompt=%q", p.Steps[1].PromptTemplate)
	}
	if p.Steps[1].Kind != StepKindAgent {
		t.Errorf("spliced step Kind=%q, want plain agent step", p.Steps[1].Kind)
	}
	if p.Steps[1].SplicedFrom == "" {
		t.Error("expected SplicedFrom provenance to be set on the spliced step")
	}
	if p.Steps[1].Index != 1 {
		t.Errorf("spliced step Index=%d, want 1 (renumbered)", p.Steps[1].Index)
	}
}

// TestResolveBranchesTakesElseWhenNotMatched verifies an unmatched condition
// takes the Else arm (§4.6: "a branch with no matching agent output takes
// else").
func TestResolveBranchesTakesElseWhenNotMatched(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0"},
		{
			Index: 1,
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "prev_output", Predicate: "contains", Value: "APPROVED"},
					Then:      []Step{{AgentType: "claude", PromptTemplate: "then step"}},
					Else:      []Step{{AgentType: "claude", PromptTemplate: "else step"}},
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	sm.sessions[p.Steps[0].SessionID].lastText = "status: REJECTED"
	p.Steps[0].Phase = "exited(0)"

	if err := orch.resolveBranches(p, 1); err != nil {
		t.Fatalf("resolveBranches: %v", err)
	}
	if len(p.Steps) != 2 {
		t.Fatalf("expected 2 steps after splice, got %d: %+v", len(p.Steps), p.Steps)
	}
	if p.Steps[1].PromptTemplate != "else step" {
		t.Errorf("expected else arm spliced in, got prompt=%q", p.Steps[1].PromptTemplate)
	}
}

// TestResolveBranchesChainsAdjacentBranches verifies an empty matched arm
// leaves the NEXT top-level branch step to also be resolved (adjacent
// branches, not nested — resolveBranches loops until a non-branch step).
func TestResolveBranchesChainsAdjacentBranches(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0"},
		{
			Index: 1,
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
					Then:      nil, // matched arm is empty
					Else:      []Step{{AgentType: "claude", PromptTemplate: "unreachable"}},
				},
			},
		},
		{
			Index: 2,
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "exit_status", Predicate: "succeeded"},
					Then:      []Step{{AgentType: "claude", PromptTemplate: "second branch then"}},
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	p.Steps[0].Phase = "exited(0)"

	if err := orch.resolveBranches(p, 1); err != nil {
		t.Fatalf("resolveBranches: %v", err)
	}
	if len(p.Steps) != 2 {
		t.Fatalf("expected 2 steps after chained splice, got %d: %+v", len(p.Steps), p.Steps)
	}
	if p.Steps[1].PromptTemplate != "second branch then" {
		t.Errorf("expected second branch's then arm spliced in at position 1, got prompt=%q", p.Steps[1].PromptTemplate)
	}
}

// ── Loop behavior ────────────────────────────────────────────────────────────

// TestLoopStopsOnUntilMatch verifies the loop re-spawns the body when
// `until` doesn't match, reaping the previous pass's session, and stops
// (adopting the final session) once it does match.
func TestLoopStopsOnUntilMatch(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{AgentType: "claude", PromptTemplate: "iterate: {{task}}"}},
					Until:         Condition{Source: "prev_output", Predicate: "contains", Value: "DONE"},
					MaxIterations: 5,
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	lc := p.Steps[0].Loop
	pass1SessID := lc.Body[0].SessionID
	sm.sessions[pass1SessID].lastText = "still working"

	if err := orch.advanceLoop(p, 0, "exited(0)"); err != nil {
		t.Fatalf("advanceLoop (pass 1): %v", err)
	}
	if lc.Iteration != 1 {
		t.Fatalf("Iteration=%d after pass 1, want 1", lc.Iteration)
	}
	pass2SessID := lc.Body[0].SessionID
	if pass2SessID == pass1SessID {
		t.Fatal("expected a new session spawned for iteration 2")
	}
	if sm.sessions[pass1SessID].phase != "cancelled" {
		t.Error("expected pass 1's body session reaped between iterations")
	}
	// makeTestPipeline leaves State=pending (it doesn't call Start, which
	// would set Running) — the only thing under test here is that an
	// in-progress pass does NOT reach a terminal state.
	if p.State == PipelineFailed || p.State == PipelineComplete || p.State == PipelineCancelled {
		t.Errorf("state=%s after an in-progress pass, want non-terminal", p.State)
	}

	sm.sessions[pass2SessID].lastText = "DONE"
	if err := orch.advanceLoop(p, 0, "exited(0)"); err != nil {
		t.Fatalf("advanceLoop (pass 2): %v", err)
	}
	if lc.Iteration != 2 {
		t.Errorf("Iteration=%d after until-match, want 2", lc.Iteration)
	}
	// Single top-level step pipeline: once the loop finishes, the pipeline
	// completes and adopts the final pass's session as the step's own.
	if p.State != PipelineComplete {
		t.Errorf("state=%s, want complete", p.State)
	}
	if p.Steps[0].SessionID != pass2SessID {
		t.Errorf("step.SessionID=%q, want the final pass's session %q", p.Steps[0].SessionID, pass2SessID)
	}
}

// TestLoopStopsAtMaxIterationsAsSuccess verifies reaching max_iterations
// without an until-match is treated as SUCCESS (§4.2/§8.5), not failure.
func TestLoopStopsAtMaxIterationsAsSuccess(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{AgentType: "claude", PromptTemplate: "iterate"}},
					Until:         Condition{Source: "prev_output", Predicate: "contains", Value: "DONE"},
					MaxIterations: 2,
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	lc := p.Steps[0].Loop

	sess1 := lc.Body[0].SessionID
	sm.sessions[sess1].lastText = "never matches"
	if err := orch.advanceLoop(p, 0, "exited(0)"); err != nil {
		t.Fatalf("advanceLoop (pass 1): %v", err)
	}
	if lc.Iteration != 1 {
		t.Fatalf("Iteration=%d after pass 1, want 1", lc.Iteration)
	}

	sess2 := lc.Body[0].SessionID
	sm.sessions[sess2].lastText = "still never matches"
	if err := orch.advanceLoop(p, 0, "exited(0)"); err != nil {
		t.Fatalf("advanceLoop (pass 2): %v", err)
	}
	if lc.Iteration != 2 {
		t.Fatalf("Iteration=%d after hitting max_iterations, want 2", lc.Iteration)
	}
	if p.State != PipelineComplete {
		t.Errorf("state=%s, want complete (max_iterations reached = success, not failure)", p.State)
	}
}

// TestLoopBodyFailurePropagatesAsPipelineFailure verifies a non-zero exit
// from a body step fails the whole pipeline, exactly like a normal step.
func TestLoopBodyFailurePropagatesAsPipelineFailure(t *testing.T) {
	dir := t.TempDir()
	sm := newFakeSessionManager()
	orch := NewOrchestrator(dir, sm, nil)

	p := makeTestPipeline(t, dir, []Step{
		{
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{AgentType: "claude", PromptTemplate: "iterate"}},
					Until:         Condition{Source: "prev_output", Predicate: "contains", Value: "DONE"},
					MaxIterations: 3,
				},
			},
		},
	})

	if err := orch.spawnStep(p, 0); err != nil {
		t.Fatalf("spawnStep(0): %v", err)
	}
	if err := orch.advanceLoop(p, 0, "exited(1)"); err != nil {
		t.Fatalf("advanceLoop: %v", err)
	}
	if p.State != PipelineFailed {
		t.Errorf("state=%s, want failed", p.State)
	}
}

// ── Nested round-trip through JSON persistence ──────────────────────────────

// TestNestedBranchLoopRoundTripsThroughPersistence verifies a pipeline
// containing both a branch (with then/else) and a loop (with a body)
// survives Save/Load unchanged — the recovery invariant a restarted broker
// depends on.
func TestNestedBranchLoopRoundTripsThroughPersistence(t *testing.T) {
	dir := t.TempDir()
	p := makeTestPipeline(t, dir, []Step{
		{Index: 0, AgentType: "claude", PromptTemplate: "step 0"},
		{
			Index: 1,
			ControlFlow: ControlFlow{
				Kind: StepKindBranch,
				Branch: &BranchConfig{
					Condition: Condition{Source: "prev_output", Predicate: "contains", Value: "APPROVED"},
					Then:      []Step{{AgentType: "claude", PromptTemplate: "then step"}},
					Else:      []Step{{AgentType: "codex", PromptTemplate: "else step"}},
				},
			},
		},
		{
			Index: 2,
			ControlFlow: ControlFlow{
				Kind: StepKindLoop,
				Loop: &LoopConfig{
					Body:          []Step{{AgentType: "claude", PromptTemplate: "loop body: {{prev}}", InputFromPrev: InputOutput}},
					Until:         Condition{Source: "prev_output", Predicate: "contains", Value: "DONE"},
					MaxIterations: 4,
				},
			},
		},
	})

	got, err := Load(dir, p.ID)
	if err != nil {
		t.Fatalf("Load: %v", err)
	}
	if len(got.Steps) != 3 {
		t.Fatalf("expected 3 steps after round trip, got %d", len(got.Steps))
	}

	branch := got.Steps[1]
	if branch.Kind != StepKindBranch || branch.Branch == nil {
		t.Fatalf("step 1 round trip: Kind=%q Branch=%+v", branch.Kind, branch.Branch)
	}
	if branch.Branch.Condition.Value != "APPROVED" {
		t.Errorf("branch condition value=%q, want APPROVED", branch.Branch.Condition.Value)
	}
	if len(branch.Branch.Then) != 1 || branch.Branch.Then[0].PromptTemplate != "then step" {
		t.Errorf("branch Then round trip mismatch: %+v", branch.Branch.Then)
	}
	if len(branch.Branch.Else) != 1 || branch.Branch.Else[0].AgentType != "codex" {
		t.Errorf("branch Else round trip mismatch: %+v", branch.Branch.Else)
	}

	loop := got.Steps[2]
	if loop.Kind != StepKindLoop || loop.Loop == nil {
		t.Fatalf("step 2 round trip: Kind=%q Loop=%+v", loop.Kind, loop.Loop)
	}
	if loop.Loop.MaxIterations != 4 {
		t.Errorf("loop max_iterations=%d, want 4", loop.Loop.MaxIterations)
	}
	if len(loop.Loop.Body) != 1 || loop.Loop.Body[0].PromptTemplate != "loop body: {{prev}}" {
		t.Errorf("loop Body round trip mismatch: %+v", loop.Loop.Body)
	}

	// Also verify the raw JSON nests kind/branch/loop as expected (not a
	// separate top-level key — ControlFlow is embedded, same lockstep
	// pattern as StepConfig).
	data, err := json.Marshal(got)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal to map: %v", err)
	}
	if _, ok := raw["ControlFlow"]; ok {
		t.Errorf("marshaled Pipeline has a nested \"ControlFlow\" key (embed not flattened): %s", data)
	}
}
