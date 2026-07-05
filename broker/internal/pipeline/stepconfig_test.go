package pipeline

import (
	"encoding/json"
	"testing"
)

// TestStepConfigRoundTripThroughStep verifies the embedded StepConfig fields
// (model/reasoning_effort/permission_mode/instructions) survive a JSON
// marshal/unmarshal round trip through Step — this is the lockstep guard for
// the embed described in docs/PLAN-HARNESS-BUILDER.md §2.1.
func TestStepConfigRoundTripThroughStep(t *testing.T) {
	s := Step{
		Index:          0,
		AgentType:      "claude",
		PromptTemplate: "do: {{task}}",
		InputFromPrev:  InputNone,
		StepConfig: StepConfig{
			Model:           "opus",
			ReasoningEffort: "high",
			PermissionMode:  "plan",
			Instructions:    "Be terse. Only touch the parser.",
		},
	}
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	// The four fields must appear at the top level (flattened embed), not
	// nested under a "StepConfig" key.
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal to map: %v", err)
	}
	for _, key := range []string{"model", "reasoning_effort", "permission_mode", "instructions"} {
		if _, ok := raw[key]; !ok {
			t.Errorf("marshaled Step missing top-level key %q; got %s", key, data)
		}
	}
	if _, ok := raw["StepConfig"]; ok {
		t.Errorf("marshaled Step has a nested \"StepConfig\" key (embed not flattened): %s", data)
	}

	var got Step
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Model != "opus" || got.ReasoningEffort != "high" || got.PermissionMode != "plan" ||
		got.Instructions != "Be terse. Only touch the parser." {
		t.Errorf("round trip mismatch: got %+v", got.StepConfig)
	}
}

// TestStepConfigOmittedWhenEmpty verifies a Step with no per-block config set
// marshals byte-identical to a Step defined before StepConfig existed (no
// model/reasoning_effort/permission_mode/instructions keys at all).
func TestStepConfigOmittedWhenEmpty(t *testing.T) {
	s := Step{Index: 0, AgentType: "claude", PromptTemplate: "p", InputFromPrev: InputNone}
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal to map: %v", err)
	}
	for _, key := range []string{"model", "reasoning_effort", "permission_mode", "instructions"} {
		if _, ok := raw[key]; ok {
			t.Errorf("empty StepConfig field %q present in marshaled JSON (should be omitempty): %s", key, data)
		}
	}
}

// TestStepConfigRoundTripThroughTemplateStep verifies the same embed on
// TemplateStep — the lockstep guard applies to both types.
func TestStepConfigRoundTripThroughTemplateStep(t *testing.T) {
	ts := TemplateStep{
		AgentType:      "codex",
		PromptTemplate: "Implement: {{prev}}",
		InputFromPrev:  InputMemoryOutput,
		StepConfig: StepConfig{
			Model:           "gpt-5-codex",
			ReasoningEffort: "medium",
			PermissionMode:  "",
			Instructions:    "focus on tests",
		},
	}
	data, err := json.Marshal(ts)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var raw map[string]any
	if err := json.Unmarshal(data, &raw); err != nil {
		t.Fatalf("unmarshal to map: %v", err)
	}
	if raw["model"] != "gpt-5-codex" {
		t.Errorf("model=%v, want gpt-5-codex", raw["model"])
	}
	if raw["reasoning_effort"] != "medium" {
		t.Errorf("reasoning_effort=%v, want medium", raw["reasoning_effort"])
	}
	if _, ok := raw["permission_mode"]; ok {
		t.Errorf("empty permission_mode present (should be omitempty): %s", data)
	}
	if raw["instructions"] != "focus on tests" {
		t.Errorf("instructions=%v, want %q", raw["instructions"], "focus on tests")
	}

	var got TemplateStep
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if got.Model != "gpt-5-codex" || got.ReasoningEffort != "medium" || got.Instructions != "focus on tests" {
		t.Errorf("round trip mismatch: got %+v", got.StepConfig)
	}
}

// TestFanoutConfigParallelArraysRoundTrip verifies the new fanout parallel
// arrays (models/reasoning_efforts/permission_modes/instructions) survive a
// JSON round trip alongside the existing agent_types array.
func TestFanoutConfigParallelArraysRoundTrip(t *testing.T) {
	fc := FanoutConfig{
		Count:            3,
		AgentTypes:       []string{"claude", "codex", "gemini"},
		Models:           []string{"opus", "gpt-5-codex", ""},
		ReasoningEfforts: []string{"high", "high", ""},
		PermissionModes:  []string{"", "", "plan"},
		Instructions:     []string{"", "", "focus on tests"},
	}
	data, err := json.Marshal(fc)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	var got FanoutConfig
	if err := json.Unmarshal(data, &got); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if len(got.Models) != 3 || got.Models[0] != "opus" || got.Models[1] != "gpt-5-codex" || got.Models[2] != "" {
		t.Errorf("Models round trip mismatch: got %v", got.Models)
	}
	if len(got.ReasoningEfforts) != 3 || got.ReasoningEfforts[0] != "high" {
		t.Errorf("ReasoningEfforts round trip mismatch: got %v", got.ReasoningEfforts)
	}
	if len(got.PermissionModes) != 3 || got.PermissionModes[2] != "plan" {
		t.Errorf("PermissionModes round trip mismatch: got %v", got.PermissionModes)
	}
	if len(got.Instructions) != 3 || got.Instructions[2] != "focus on tests" {
		t.Errorf("Instructions round trip mismatch: got %v", got.Instructions)
	}
}
