package session

import (
	"strings"
	"testing"
)

func TestSpawnOverrideIsZero(t *testing.T) {
	if !(SpawnOverride{}).IsZero() {
		t.Fatal("empty override should be zero")
	}
	if !(SpawnOverride{ReasoningEffort: "  ", Model: " "}).IsZero() {
		t.Fatal("whitespace-only override should be zero")
	}
	if (SpawnOverride{ReasoningEffort: "high"}).IsZero() {
		t.Fatal("effort override should not be zero")
	}
	if (SpawnOverride{Model: "opus"}).IsZero() {
		t.Fatal("model override should not be zero")
	}
}

func TestSpawnOverrideExtraArgsClaude(t *testing.T) {
	cases := []struct {
		name string
		o    SpawnOverride
		want string
	}{
		{"empty", SpawnOverride{}, ""},
		{"effort only", SpawnOverride{ReasoningEffort: "high"}, "--effort high"},
		{"model only", SpawnOverride{Model: "opus"}, "--model opus"},
		{"both", SpawnOverride{ReasoningEffort: "low", Model: "sonnet"}, "--effort low --model sonnet"},
		{"xhigh", SpawnOverride{ReasoningEffort: "xhigh"}, "--effort xhigh"},
		// Unknown effort is dropped (model still applies).
		{"bad effort", SpawnOverride{ReasoningEffort: "ludicrous", Model: "opus"}, "--model opus"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := strings.Join(c.o.extraArgsFor("claude"), " ")
			if got != c.want {
				t.Fatalf("extraArgsFor(claude) = %q, want %q", got, c.want)
			}
		})
	}
}

func TestSpawnOverrideExtraArgsCodex(t *testing.T) {
	cases := []struct {
		name string
		o    SpawnOverride
		want string
	}{
		{"empty", SpawnOverride{}, ""},
		{"effort only", SpawnOverride{ReasoningEffort: "high"}, "-c model_reasoning_effort=high"},
		{"both", SpawnOverride{ReasoningEffort: "medium", Model: "gpt-5-codex"}, "-c model_reasoning_effort=medium --model gpt-5-codex"},
		// codex does not accept xhigh/max — dropped.
		{"xhigh dropped", SpawnOverride{ReasoningEffort: "xhigh"}, ""},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := strings.Join(c.o.extraArgsFor("codex"), " ")
			if got != c.want {
				t.Fatalf("extraArgsFor(codex) = %q, want %q", got, c.want)
			}
		})
	}
}

func TestSpawnOverrideExtraArgsUnknownAssistant(t *testing.T) {
	if got := (SpawnOverride{ReasoningEffort: "high", Model: "x"}).extraArgsFor("gemini"); got != nil {
		t.Fatalf("unknown assistant should yield nil, got %v", got)
	}
}

func TestSpawnOverrideEffectiveEffort(t *testing.T) {
	// No override → adapter default passes through.
	if got := (SpawnOverride{}).effectiveEffort("claude", "medium"); got != "medium" {
		t.Fatalf("default passthrough = %q", got)
	}
	// Valid override wins.
	if got := (SpawnOverride{ReasoningEffort: "high"}).effectiveEffort("claude", "medium"); got != "high" {
		t.Fatalf("valid override = %q", got)
	}
	// Invalid override falls back to adapter default (pill never shows a
	// level the agent didn't actually receive).
	if got := (SpawnOverride{ReasoningEffort: "ludicrous"}).effectiveEffort("claude", "medium"); got != "medium" {
		t.Fatalf("invalid override fallback = %q", got)
	}
	// codex rejects xhigh → falls back.
	if got := (SpawnOverride{ReasoningEffort: "xhigh"}).effectiveEffort("codex", "low"); got != "low" {
		t.Fatalf("codex xhigh fallback = %q", got)
	}
}

// Permission-mode mapping (mode selector, task #16). Verified live against
// claude-code 2.1.168: --dangerously-skip-permissions overrides
// --permission-mode, so plan mode requires DROPPING the dangerous flag.
func TestApplyClaudePermissionMode(t *testing.T) {
	base := []string{"claude", "--dangerously-skip-permissions"}

	// Default / auto / empty: unchanged (full-auto bypass).
	for _, mode := range []string{"", "auto", "default", "bogus"} {
		got := applyClaudePermissionMode(base, mode)
		if len(got) != 2 || got[1] != "--dangerously-skip-permissions" {
			t.Fatalf("mode %q: expected unchanged, got %v", mode, got)
		}
	}

	// Plan: drop the dangerous flag, add --permission-mode plan.
	got := applyClaudePermissionMode(base, "plan")
	joined := strings.Join(got, " ")
	if strings.Contains(joined, "--dangerously-skip-permissions") {
		t.Fatalf("plan mode must drop the dangerous flag: %v", got)
	}
	if !strings.Contains(joined, "--permission-mode plan") {
		t.Fatalf("plan mode must add --permission-mode plan: %v", got)
	}
	// The base binary arg is preserved.
	if got[0] != "claude" {
		t.Fatalf("plan mode dropped the binary arg: %v", got)
	}
}

func TestApplyCodexPermissionMode(t *testing.T) {
	base := []string{"codex", "exec", "--json"}
	// Default: unchanged.
	if got := applyCodexPermissionMode(base, "auto"); len(got) != 3 {
		t.Fatalf("auto should be unchanged: %v", got)
	}
	// Plan: add --sandbox read-only.
	got := strings.Join(applyCodexPermissionMode(base, "plan"), " ")
	if !strings.Contains(got, "--sandbox read-only") {
		t.Fatalf("plan must add read-only sandbox: %v", got)
	}
}

// codex plan applies --sandbox ONLY on the first-turn exec; resume rejects it.
func TestCodexTurnArgvPlanFirstTurnOnly(t *testing.T) {
	first := strings.Join(codexTurnArgv("codex", "/w", "", nil, "plan", "go"), " ")
	if !strings.Contains(first, "--sandbox read-only") {
		t.Fatalf("first turn must carry the sandbox flag: %v", first)
	}
	resume := strings.Join(codexTurnArgv("codex", "/w", "t-1", nil, "plan", "go"), " ")
	if strings.Contains(resume, "--sandbox") {
		t.Fatalf("resume must NOT carry --sandbox (codex rejects it): %v", resume)
	}
}
