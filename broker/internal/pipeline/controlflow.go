package pipeline

import (
	"fmt"
	"regexp"
	"strings"
)

// Step "kind" discriminator values. "" (StepKindAgent) is the default and
// back-compatible: a step with no kind is an ordinary agent invocation,
// exactly as before this feature existed.
const (
	StepKindAgent  = ""
	StepKindBranch = "branch"
	StepKindLoop   = "loop"
)

// maxNestDepth bounds branch/loop nesting (docs/PLAN-HARNESS-BUILDER.md
// §4.1, owner decision §8.4): top-level steps are depth 1; a branch's
// then/else arms or a loop's body are depth 2. A branch or loop found
// INSIDE one of those depth-2 arms would itself need depth 3 and is
// rejected at create — so a branch/loop's nested content is always plain
// agent steps. This is the "nesting depth ≤ 2, no branch inside a
// condition" bound from the plan.
const maxNestDepth = 2

// maxLoopIterations bounds Loop.MaxIterations (§4.2/§8.5, owner decision):
// runaway protection — an until-condition that never matches must not
// re-spawn paid agent turns forever. Hitting the cap is treated as SUCCESS
// (best-effort), so this is a ceiling on spend, not a correctness limit.
const maxLoopIterations = 5

// Condition is a deterministic, no-LLM-judge predicate (§7 non-goal: no
// model-judges-model auto-advance) evaluated against either the previous
// step's harvested output/exit status (branch) or the last loop-body step
// of the most recent pass (loop's `until`). See evalCondition.
type Condition struct {
	// Source is "prev_output" (the last assistant text) or "exit_status"
	// (did the referenced step succeed).
	Source string `json:"source"`
	// Predicate depends on Source:
	//   prev_output -> contains | not_contains | matches (regex)
	//   exit_status -> succeeded | failed
	Predicate string `json:"predicate"`
	// Value is the string/regex operand for prev_output predicates. Unused
	// for exit_status.
	Value string `json:"value,omitempty"`
}

// BranchConfig declares an If/Else block (§4.1). Condition is evaluated
// ONCE, deterministically, against the PREVIOUS step's harvested output/exit
// status — no agent is spawned to decide. The chosen arm's steps are
// spliced inline into the run; see Orchestrator.resolveBranches.
type BranchConfig struct {
	Condition Condition `json:"condition"`
	Then      []Step    `json:"then,omitempty"`
	Else      []Step    `json:"else,omitempty"`
}

// LoopConfig declares a bounded Loop-until block (§4.2). Body runs
// sequentially each pass; Until is evaluated against the last body step's
// output/exit-status after each pass. Iteration/BodyStep are live state,
// persisted so the Monitor UI (and a restarted broker inspecting
// pipeline.json) can see progress.
type LoopConfig struct {
	Body          []Step    `json:"body"`
	Until         Condition `json:"until"`
	MaxIterations int       `json:"max_iterations"`
	// Iteration is live state: the number of completed passes so far.
	Iteration int `json:"iteration,omitempty"`
	// BodyStep is live state: index within Body of the step currently
	// running (or, once a pass completes, the last one that ran).
	BodyStep int `json:"body_step,omitempty"`
}

// ControlFlow carries the optional kind/branch/loop discriminator shared by
// Step and TemplateStep. Embedded (not duplicated) in both so they cannot
// drift out of lockstep — the same guard StepConfig applies to
// model/reasoning_effort/permission_mode/instructions (#888/stepconfig.go).
type ControlFlow struct {
	// Kind is "" (implicit agent step, back-compatible), "branch", or "loop".
	Kind string `json:"kind,omitempty"`
	// Branch is set (and required) when Kind == "branch".
	Branch *BranchConfig `json:"branch,omitempty"`
	// Loop is set (and required) when Kind == "loop".
	Loop *LoopConfig `json:"loop,omitempty"`
}

// PrepareSteps validates and normalizes a freshly-decoded top-level step
// tree at pipeline/template create time. It:
//   - defaults an empty AgentType to "claude", recursively, so a loop
//     body/branch arm step behaves identically to a top-level step;
//   - clears any client-supplied live-state fields (a create request should
//     never carry session_id/phase/etc — defensive, costs nothing);
//   - enforces the bounds from docs/PLAN-HARNESS-BUILDER.md §4.1/§4.2:
//     nesting depth <= 2, max_iterations in [1,5], well-formed conditions;
//   - rejects fanout combined with kind=branch/loop on the same step
//     (nonsensical — fanout would be silently ignored, the exact "silent
//     drop" trap CLAUDE.md warns about) and fanout nested inside ANY branch
//     arm or loop body (unvalidated by the top-level fanout count/array
//     checks in ws/pipeline.go, and out of scope for this feature).
func PrepareSteps(steps []Step) error {
	return prepareSteps(steps, 1)
}

func prepareSteps(steps []Step, depth int) error {
	for i := range steps {
		s := &steps[i]
		// Defensive: a create request should never carry live state.
		s.SessionID, s.Phase, s.Started, s.Ended = "", "", "", ""
		s.Retries, s.PrevSessionIDs, s.SplicedFrom = 0, nil, ""
		s.Output = ""
		if s.AgentType == "" {
			s.AgentType = "claude"
		}
		if s.Fanout != nil {
			if s.Kind != StepKindAgent {
				return fmt.Errorf("step %d: fanout cannot be combined with kind=%q", i, s.Kind)
			}
			if depth > 1 {
				return fmt.Errorf("step %d: fanout is not supported inside a branch arm or loop body", i)
			}
		}
		switch s.Kind {
		case StepKindAgent:
			// Plain agent step — nothing further to validate here.
		case StepKindBranch:
			if s.Branch == nil {
				return fmt.Errorf("step %d: kind=branch requires a branch config", i)
			}
			if err := validateCondition(s.Branch.Condition); err != nil {
				return fmt.Errorf("step %d: branch condition: %w", i, err)
			}
			if depth+1 > maxNestDepth {
				return fmt.Errorf("step %d: branch nesting exceeds depth %d", i, maxNestDepth)
			}
			if err := prepareSteps(s.Branch.Then, depth+1); err != nil {
				return err
			}
			if err := prepareSteps(s.Branch.Else, depth+1); err != nil {
				return err
			}
		case StepKindLoop:
			if s.Loop == nil {
				return fmt.Errorf("step %d: kind=loop requires a loop config", i)
			}
			if len(s.Loop.Body) == 0 {
				return fmt.Errorf("step %d: loop body must have at least one step", i)
			}
			if s.Loop.MaxIterations < 1 || s.Loop.MaxIterations > maxLoopIterations {
				return fmt.Errorf("step %d: loop max_iterations must be between 1 and %d", i, maxLoopIterations)
			}
			if err := validateCondition(s.Loop.Until); err != nil {
				return fmt.Errorf("step %d: loop until: %w", i, err)
			}
			if depth+1 > maxNestDepth {
				return fmt.Errorf("step %d: loop nesting exceeds depth %d", i, maxNestDepth)
			}
			if err := prepareSteps(s.Loop.Body, depth+1); err != nil {
				return err
			}
		default:
			return fmt.Errorf("step %d: unknown kind %q", i, s.Kind)
		}
	}
	return nil
}

// validateCondition rejects a malformed Condition at create time — before
// any agent spends a paid turn on a branch/loop whose condition could never
// evaluate.
func validateCondition(c Condition) error {
	switch c.Source {
	case "prev_output":
		switch c.Predicate {
		case "contains", "not_contains", "matches":
		default:
			return fmt.Errorf("invalid predicate %q for source prev_output", c.Predicate)
		}
		if c.Value == "" {
			return fmt.Errorf("value is required for source prev_output")
		}
		if c.Predicate == "matches" {
			if _, err := regexp.Compile(c.Value); err != nil {
				return fmt.Errorf("invalid matches regex %q: %w", c.Value, err)
			}
		}
	case "exit_status":
		switch c.Predicate {
		case "succeeded", "failed":
		default:
			return fmt.Errorf("invalid predicate %q for source exit_status", c.Predicate)
		}
	default:
		return fmt.Errorf("invalid condition source %q (want prev_output or exit_status)", c.Source)
	}
	return nil
}

// evalCondition evaluates c deterministically — no agent spawned, no LLM
// judge (§7 non-goal). prevOutput is the previous step's (or loop pass's)
// harvested last-assistant text; prevPhase is its terminal phase string
// (e.g. "exited(0)", "turn_complete", "exited(1)"), used to derive
// exit_status via the existing exitCodeFromPhase.
func evalCondition(c Condition, prevOutput, prevPhase string) (bool, error) {
	switch c.Source {
	case "prev_output":
		switch c.Predicate {
		case "contains":
			return strings.Contains(prevOutput, c.Value), nil
		case "not_contains":
			return !strings.Contains(prevOutput, c.Value), nil
		case "matches":
			re, err := regexp.Compile(c.Value)
			if err != nil {
				return false, fmt.Errorf("invalid matches regex %q: %w", c.Value, err)
			}
			return re.MatchString(prevOutput), nil
		}
	case "exit_status":
		succeeded := exitCodeFromPhase(prevPhase) == 0
		switch c.Predicate {
		case "succeeded":
			return succeeded, nil
		case "failed":
			return !succeeded, nil
		}
	}
	return false, fmt.Errorf("cannot evaluate condition source=%q predicate=%q", c.Source, c.Predicate)
}
