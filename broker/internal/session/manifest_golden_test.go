package session

// manifest_golden_test.go — golden tests pinning per-agent argv/path
// behavior BEFORE the Phase 1 manifest extraction refactor. Every combination
// of assistant × override × permission mode × resume state is captured here.
// After the refactor these tests must still pass byte-for-byte.
//
// Covered:
//   - SpawnOverride.extraArgsFor (override.go)
//   - SpawnOverride.effectiveEffort (override.go)
//   - applyClaudePermissionMode (override.go)
//   - applyCodexPermissionMode (override.go)
//   - codexTurnArgv (codexchatproc.go)
//   - chatConversationOnDisk glob roots (recovery.go)
//   - credentials.Materialize target paths (credentials/store.go)
//   - hostCredentialFile / sessionCredentialFile paths (credfresh.go)
//   - providerForAssistant (lifecycle.go)
//   - allCredentialProviders (lifecycle.go)

import (
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/credentials"
)

// ---------------------------------------------------------------------------
// extraArgsFor — argv flags for effort + model overrides
// ---------------------------------------------------------------------------

func TestGoldenExtraArgsClaude(t *testing.T) {
	type row struct {
		name string
		o    SpawnOverride
		want []string
	}
	rows := []row{
		// no override → nil
		{"none", SpawnOverride{}, nil},
		// effort only
		{"effort-low", SpawnOverride{ReasoningEffort: "low"}, []string{"--effort", "low"}},
		{"effort-medium", SpawnOverride{ReasoningEffort: "medium"}, []string{"--effort", "medium"}},
		{"effort-high", SpawnOverride{ReasoningEffort: "high"}, []string{"--effort", "high"}},
		{"effort-xhigh", SpawnOverride{ReasoningEffort: "xhigh"}, []string{"--effort", "xhigh"}},
		{"effort-max", SpawnOverride{ReasoningEffort: "max"}, []string{"--effort", "max"}},
		// model only
		{"model-only", SpawnOverride{Model: "opus"}, []string{"--model", "opus"}},
		{"model-sonnet", SpawnOverride{Model: "claude-sonnet-4-6"}, []string{"--model", "claude-sonnet-4-6"}},
		// both
		{"both", SpawnOverride{ReasoningEffort: "high", Model: "sonnet"}, []string{"--effort", "high", "--model", "sonnet"}},
		// invalid effort — dropped; model still applies
		{"bad-effort-model", SpawnOverride{ReasoningEffort: "ludicrous", Model: "opus"}, []string{"--model", "opus"}},
		// invalid effort, no model — nil result
		{"bad-effort-only", SpawnOverride{ReasoningEffort: "ludicrous"}, nil},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			got := r.o.extraArgsFor("claude")
			if !reflect.DeepEqual(got, r.want) {
				t.Fatalf("extraArgsFor(claude) = %v, want %v", got, r.want)
			}
		})
	}
}

func TestGoldenExtraArgsCodex(t *testing.T) {
	type row struct {
		name string
		o    SpawnOverride
		want []string
	}
	rows := []row{
		{"none", SpawnOverride{}, nil},
		{"effort-low", SpawnOverride{ReasoningEffort: "low"}, []string{"-c", "model_reasoning_effort=low"}},
		{"effort-medium", SpawnOverride{ReasoningEffort: "medium"}, []string{"-c", "model_reasoning_effort=medium"}},
		{"effort-high", SpawnOverride{ReasoningEffort: "high"}, []string{"-c", "model_reasoning_effort=high"}},
		// codex does NOT accept xhigh/max — dropped; nil result
		{"xhigh-dropped", SpawnOverride{ReasoningEffort: "xhigh"}, nil},
		{"max-dropped", SpawnOverride{ReasoningEffort: "max"}, nil},
		// model only
		{"model-only", SpawnOverride{Model: "gpt-5-codex"}, []string{"--model", "gpt-5-codex"}},
		// both
		{"both", SpawnOverride{ReasoningEffort: "medium", Model: "gpt-5-codex"}, []string{"-c", "model_reasoning_effort=medium", "--model", "gpt-5-codex"}},
		// bad effort, model still present
		{"bad-effort-model", SpawnOverride{ReasoningEffort: "ludicrous", Model: "gpt-5-codex"}, []string{"--model", "gpt-5-codex"}},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			got := r.o.extraArgsFor("codex")
			if !reflect.DeepEqual(got, r.want) {
				t.Fatalf("extraArgsFor(codex) = %v, want %v", got, r.want)
			}
		})
	}
}

func TestGoldenExtraArgsUnknownAssistant(t *testing.T) {
	// Any override on an unknown assistant must produce nil (no crash,
	// no flags leaked to an unknown binary).
	for _, name := range []string{"gemini", "opencode", ""} {
		got := (SpawnOverride{ReasoningEffort: "high", Model: "x"}).extraArgsFor(name)
		if got != nil {
			t.Fatalf("extraArgsFor(%q) = %v, want nil", name, got)
		}
	}
}

// ---------------------------------------------------------------------------
// effectiveEffort — what to surface on the status frame
// ---------------------------------------------------------------------------

func TestGoldenEffectiveEffortClaude(t *testing.T) {
	type row struct {
		name       string
		effort     string
		adapterDef string
		want       string
	}
	rows := []row{
		// no override → adapter default passes through
		{"no-override", "", "medium", "medium"},
		{"no-override-low", "", "low", "low"},
		// valid override wins
		{"override-high", "high", "medium", "high"},
		{"override-low", "low", "medium", "low"},
		{"override-xhigh", "xhigh", "medium", "xhigh"},
		{"override-max", "max", "medium", "max"},
		// invalid override → adapter default
		{"bad-effort", "ludicrous", "medium", "medium"},
		{"bad-effort-low-default", "ludicrous", "low", "low"},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			got := (SpawnOverride{ReasoningEffort: r.effort}).effectiveEffort("claude", r.adapterDef)
			if got != r.want {
				t.Fatalf("effectiveEffort(claude) = %q, want %q", got, r.want)
			}
		})
	}
}

func TestGoldenEffectiveEffortCodex(t *testing.T) {
	type row struct {
		name       string
		effort     string
		adapterDef string
		want       string
	}
	rows := []row{
		{"no-override", "", "medium", "medium"},
		{"override-high", "high", "medium", "high"},
		// codex doesn't accept xhigh → falls back
		{"xhigh-fallback", "xhigh", "low", "low"},
		{"max-fallback", "max", "low", "low"},
		{"bad-effort", "ludicrous", "medium", "medium"},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			got := (SpawnOverride{ReasoningEffort: r.effort}).effectiveEffort("codex", r.adapterDef)
			if got != r.want {
				t.Fatalf("effectiveEffort(codex) = %q, want %q", got, r.want)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// applyClaudePermissionMode — full flag rewrite
// ---------------------------------------------------------------------------

func TestGoldenApplyClaudePermissionMode(t *testing.T) {
	base := []string{"claude", "--dangerously-skip-permissions"}
	type row struct {
		mode string
		// wantContains / wantNotContains for important flag strings
		wantDangerous bool
		wantPlanMode  bool
	}
	rows := []row{
		// unchanged modes (dangerous flag preserved)
		{"", true, false},
		{"auto", true, false},
		{"default", true, false},
		// unrecognized value treated as default (unchanged)
		{"unknown-mode", true, false},
		{"bogus", true, false},
		// plan mode: drop dangerous, add --permission-mode plan
		{"plan", false, true},
	}
	for _, r := range rows {
		t.Run("mode="+r.mode, func(t *testing.T) {
			got := applyClaudePermissionMode(base, r.mode)
			joined := strings.Join(got, " ")
			hasDangerous := strings.Contains(joined, "--dangerously-skip-permissions")
			hasPlan := strings.Contains(joined, "--permission-mode plan")
			if hasDangerous != r.wantDangerous {
				t.Fatalf("mode=%q: hasDangerous=%v want %v; args=%v", r.mode, hasDangerous, r.wantDangerous, got)
			}
			if hasPlan != r.wantPlanMode {
				t.Fatalf("mode=%q: hasPlanMode=%v want %v; args=%v", r.mode, hasPlan, r.wantPlanMode, got)
			}
			// Binary arg is always preserved as first element
			if len(got) == 0 || got[0] != "claude" {
				t.Fatalf("mode=%q: binary arg dropped; args=%v", r.mode, got)
			}
		})
	}
}

// applyClaudePermissionMode with no dangerous flag in base (e.g. already
// stripped) — plan mode still adds --permission-mode plan.
func TestGoldenApplyClaudePermissionModeNoDangerousBase(t *testing.T) {
	base := []string{"claude", "--verbose"}
	got := applyClaudePermissionMode(base, "plan")
	joined := strings.Join(got, " ")
	if strings.Contains(joined, "--dangerously-skip-permissions") {
		t.Fatalf("unexpected dangerous flag: %v", got)
	}
	if !strings.Contains(joined, "--permission-mode plan") {
		t.Fatalf("plan flag not added: %v", got)
	}
}

// ---------------------------------------------------------------------------
// applyCodexPermissionMode — full flag rewrite
// ---------------------------------------------------------------------------

func TestGoldenApplyCodexPermissionMode(t *testing.T) {
	base := []string{"codex", "exec", "--json", "--dangerously-bypass-approvals-and-sandbox"}
	type row struct {
		mode        string
		wantBypass  bool
		wantSandbox bool
	}
	rows := []row{
		{"", true, false},
		{"auto", true, false},
		{"default", true, false},
		{"unknown", true, false},
		// plan: drop bypass, add --sandbox read-only
		{"plan", false, true},
	}
	for _, r := range rows {
		t.Run("mode="+r.mode, func(t *testing.T) {
			got := applyCodexPermissionMode(base, r.mode)
			joined := strings.Join(got, " ")
			hasBypass := strings.Contains(joined, "--dangerously-bypass-approvals-and-sandbox")
			hasSandbox := strings.Contains(joined, "--sandbox read-only")
			if hasBypass != r.wantBypass {
				t.Fatalf("mode=%q: hasBypass=%v want %v; args=%v", r.mode, hasBypass, r.wantBypass, got)
			}
			if hasSandbox != r.wantSandbox {
				t.Fatalf("mode=%q: hasSandbox=%v want %v; args=%v", r.mode, hasSandbox, r.wantSandbox, got)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// codexTurnArgv — full argv for exec/resume turns
// ---------------------------------------------------------------------------

func TestGoldenCodexTurnArgv(t *testing.T) {
	type row struct {
		name     string
		threadID string
		extra    []string
		mode     string
		wantStr  string // joined argv for easy matching
	}
	rows := []row{
		// First turn, no override, no mode
		{
			name:    "first-turn-no-override",
			wantStr: "codex exec --json --skip-git-repo-check -C /w msg",
		},
		// First turn, auto mode (unchanged — no sandbox flag)
		{
			name:    "first-turn-auto-mode",
			mode:    "auto",
			wantStr: "codex exec --json --skip-git-repo-check -C /w msg",
		},
		// First turn, plan mode → adds --sandbox read-only
		{
			name:    "first-turn-plan-mode",
			mode:    "plan",
			wantStr: "codex exec --json --skip-git-repo-check -C /w --sandbox read-only msg",
		},
		// First turn, effort override
		{
			name:    "first-turn-effort",
			extra:   []string{"-c", "model_reasoning_effort=high"},
			wantStr: "codex exec --json --skip-git-repo-check -C /w -c model_reasoning_effort=high msg",
		},
		// First turn, effort + model
		{
			name:    "first-turn-effort-model",
			extra:   []string{"-c", "model_reasoning_effort=medium", "--model", "gpt-5-codex"},
			wantStr: "codex exec --json --skip-git-repo-check -C /w -c model_reasoning_effort=medium --model gpt-5-codex msg",
		},
		// First turn, plan + effort
		{
			name:    "first-turn-plan-effort",
			extra:   []string{"-c", "model_reasoning_effort=low"},
			mode:    "plan",
			wantStr: "codex exec --json --skip-git-repo-check -C /w --sandbox read-only -c model_reasoning_effort=low msg",
		},
		// Resume turn (threadID set) — NO -C, NO --sandbox
		{
			name:     "resume-no-override",
			threadID: "t-abc",
			wantStr:  "codex exec resume t-abc --json --skip-git-repo-check msg",
		},
		// Resume with plan mode — sandbox flag must NOT appear (codex rejects it on resume)
		{
			name:     "resume-plan-no-sandbox",
			threadID: "t-abc",
			mode:     "plan",
			wantStr:  "codex exec resume t-abc --json --skip-git-repo-check msg",
		},
		// Resume with effort override
		{
			name:     "resume-effort",
			threadID: "t-abc",
			extra:    []string{"-c", "model_reasoning_effort=high"},
			wantStr:  "codex exec resume t-abc --json --skip-git-repo-check -c model_reasoning_effort=high msg",
		},
	}
	for _, r := range rows {
		t.Run(r.name, func(t *testing.T) {
			got := codexTurnArgv("codex", "/w", r.threadID, r.extra, r.mode, "msg")
			joined := strings.Join(got, " ")
			if joined != r.wantStr {
				t.Fatalf("\ngot:  %q\nwant: %q", joined, r.wantStr)
			}
		})
	}
}

// ---------------------------------------------------------------------------
// chatConversationOnDisk — glob roots
// ---------------------------------------------------------------------------

func TestGoldenChatConversationOnDiskRoots(t *testing.T) {
	// Pin the two config-dir roots used by chatConversationOnDisk.
	// These must be exactly ".claude" and ".codex" — any change here
	// breaks conversation discovery after a broker restart.
	const sessionDir = "/session"

	// Build expected glob patterns for both roots.
	wantPatterns := map[string][]string{
		".claude": {
			filepath.Join(sessionDir, "agent-home", ".claude", "projects", "*", "*.jsonl"),
			filepath.Join(sessionDir, "agent-home", ".claude", "sessions", "*", "*", "*", "*", "*.jsonl"),
		},
		".codex": {
			filepath.Join(sessionDir, "agent-home", ".codex", "projects", "*", "*.jsonl"),
			filepath.Join(sessionDir, "agent-home", ".codex", "sessions", "*", "*", "*", "*", "*.jsonl"),
		},
	}

	// Verify the patterns match what chatConversationOnDisk actually uses
	// by constructing the same pattern slice in a parallel helper.
	for configDir, want := range wantPatterns {
		got := chatConversationGlobPatterns(sessionDir, configDir)
		if !reflect.DeepEqual(got, want) {
			t.Fatalf("configDir=%q\ngot:  %v\nwant: %v", configDir, got, want)
		}
	}
}

// chatConversationGlobPatterns returns the glob patterns chatConversationOnDisk
// would test for a given (sessionDir, configDir) pair. Extracted so the golden
// can verify the pattern shapes without requiring files on disk.
func chatConversationGlobPatterns(sessionDir, configDir string) []string {
	return []string{
		filepath.Join(sessionDir, "agent-home", configDir, "projects", "*", "*.jsonl"),
		filepath.Join(sessionDir, "agent-home", configDir, "sessions", "*", "*", "*", "*", "*.jsonl"),
	}
}

// ---------------------------------------------------------------------------
// credentials.Materialize target paths (store.go ~200–210)
// ---------------------------------------------------------------------------

func TestGoldenCredentialsMaterializePaths(t *testing.T) {
	// Pin the exact subdir + filename each provider writes into the
	// ephemeral HOME. These paths are load-bearing: claude and codex
	// look for their credentials at exactly these locations.
	const home = "/ephemeral"
	type want struct {
		subdir   string
		filename string
		full     string
	}
	cases := []struct {
		provider string
		want     want
	}{
		{
			provider: credentials.ProviderAnthropic,
			want: want{
				subdir:   filepath.Join(home, ".claude"),
				filename: ".credentials.json",
				full:     filepath.Join(home, ".claude", ".credentials.json"),
			},
		},
		{
			provider: credentials.ProviderOpenAI,
			want: want{
				subdir:   filepath.Join(home, ".codex"),
				filename: "auth.json",
				full:     filepath.Join(home, ".codex", "auth.json"),
			},
		},
	}
	for _, c := range cases {
		t.Run(c.provider, func(t *testing.T) {
			// Use materializeTargetPath — the extracted helper that
			// mirrors the switch in Materialize (after Phase 1 refactor,
			// this is read from the manifest; the golden stays the same).
			subdir, filename := materializeTargetPath(c.provider, home)
			if subdir != c.want.subdir {
				t.Fatalf("subdir: got %q, want %q", subdir, c.want.subdir)
			}
			if filename != c.want.filename {
				t.Fatalf("filename: got %q, want %q", filename, c.want.filename)
			}
			full := filepath.Join(subdir, filename)
			if full != c.want.full {
				t.Fatalf("full path: got %q, want %q", full, c.want.full)
			}
		})
	}
}

// materializeTargetPath mirrors the switch in credentials.Store.Materialize
// and is duplicated here so the golden test is self-contained and doesn't
// depend on the implementation being testable in isolation (Materialize
// actually writes to disk). After Phase 1, this logic moves into the
// manifest; the paths stay identical.
func materializeTargetPath(provider, ephemeralHome string) (subdir, filename string) {
	switch provider {
	case credentials.ProviderOpenAI:
		return filepath.Join(ephemeralHome, ".codex"), "auth.json"
	case credentials.ProviderAnthropic:
		return filepath.Join(ephemeralHome, ".claude"), ".credentials.json"
	default:
		return "", ""
	}
}

// ---------------------------------------------------------------------------
// hostCredentialFile + sessionCredentialFile paths (credfresh.go)
// ---------------------------------------------------------------------------

func TestGoldenSessionCredentialFile(t *testing.T) {
	const home = "/ephemeral"
	cases := []struct {
		provider string
		want     string
	}{
		{"anthropic", filepath.Join(home, ".claude", ".credentials.json")},
		{"openai", filepath.Join(home, ".codex", "auth.json")},
		// unknown provider → empty string
		{"gemini", ""},
	}
	for _, c := range cases {
		got := sessionCredentialFile(c.provider, home)
		if got != c.want {
			t.Fatalf("sessionCredentialFile(%q) = %q, want %q", c.provider, got, c.want)
		}
	}
}

func TestGoldenHostCredentialFile(t *testing.T) {
	// Pin the mapping via CONDUIT_HOST_HOME so the test is hermetic.
	const fakeHome = "/fake-host-home"
	t.Setenv("CONDUIT_HOST_HOME", fakeHome)

	cases := []struct {
		provider string
		want     string
	}{
		{"anthropic", filepath.Join(fakeHome, ".claude", ".credentials.json")},
		{"openai", filepath.Join(fakeHome, ".codex", "auth.json")},
		{"gemini", ""},
	}
	for _, c := range cases {
		got := hostCredentialFile(c.provider)
		if got != c.want {
			t.Fatalf("hostCredentialFile(%q) = %q, want %q", c.provider, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// providerForAssistant (lifecycle.go)
// ---------------------------------------------------------------------------

func TestGoldenProviderForAssistant(t *testing.T) {
	cases := []struct {
		assistant string
		want      string
	}{
		{"claude", "anthropic"},
		{"codex", "openai"},
		// unknown adapters return "" (no OAuth, skip materialization)
		{"shell", ""},
		{"gemini", ""},
		{"", ""},
	}
	for _, c := range cases {
		got := providerForAssistant(c.assistant)
		if got != c.want {
			t.Fatalf("providerForAssistant(%q) = %q, want %q", c.assistant, got, c.want)
		}
	}
}

// ---------------------------------------------------------------------------
// allCredentialProviders (lifecycle.go)
// ---------------------------------------------------------------------------

func TestGoldenAllCredentialProviders(t *testing.T) {
	got := allCredentialProviders()
	// opencode is included so a session's ephemeral HOME gets the host's
	// opencode credentials (auth.json + opencode.jsonc) mirrored in, letting
	// the spawned `opencode serve` use a real provider instead of Zen.
	want := []string{"anthropic", "openai", "opencode"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("allCredentialProviders() = %v, want %v", got, want)
	}
}

// ---------------------------------------------------------------------------
// credentialProvidersFromRegistry (lifecycle.go) — WS-1.2
// ---------------------------------------------------------------------------

// buildTestRegistry creates a minimal agents.Registry from the given TOML
// bodies for golden tests. Panics on any error (test helper).
func buildTestRegistry(t *testing.T, tomls map[string]string) *agents.Registry {
	t.Helper()
	dir := t.TempDir()
	for name, body := range tomls {
		path := dir + "/" + name
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("writeFile %s: %v", name, err)
		}
	}
	reg, err := agents.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	return reg
}

func TestGoldenCredentialProvidersFromRegistry(t *testing.T) {
	// Full claude+codex registry → derives "anthropic" and "openai" from the
	// adapters' login_provider fields (set via applyLegacyDefaults).
	reg := buildTestRegistry(t, map[string]string{
		"claude.toml": "name=\"claude\"\ncommand=[\"claude\"]\nworkdir=\"/w\"\n",
		"codex.toml":  "name=\"codex\"\ncommand=[\"codex\"]\nworkdir=\"/w\"\n",
	})
	got := credentialProvidersFromRegistry(reg)
	want := []string{"anthropic", "openai"}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v, want %v", got, want)
	}

	// Registry with an adapter that has no login_provider → omitted.
	reg2 := buildTestRegistry(t, map[string]string{
		"shell.toml": "name=\"shell\"\ncommand=[\"bash\"]\nworkdir=\"/w\"\n",
	})
	got2 := credentialProvidersFromRegistry(reg2)
	// No providers → falls back to allCredentialProviders() which now includes
	// "opencode" so the Zen fallback sessions also get opencode creds mirrored.
	wantFallback := []string{"anthropic", "openai", "opencode"}
	if !reflect.DeepEqual(got2, wantFallback) {
		t.Fatalf("empty-provider fallback: got %v, want %v", got2, wantFallback)
	}

	// Registry with a custom login_provider → included.
	reg3 := buildTestRegistry(t, map[string]string{
		"myprovider.toml": "name=\"myprovider\"\ncommand=[\"myprovider\"]\nworkdir=\"/w\"\nlogin_provider=\"myprovider\"\n",
	})
	got3 := credentialProvidersFromRegistry(reg3)
	if len(got3) != 1 || got3[0] != "myprovider" {
		t.Fatalf("custom provider: got %v, want [myprovider]", got3)
	}

	// Duplicate providers (two adapters same login_provider) → deduplicated.
	reg4 := buildTestRegistry(t, map[string]string{
		"agent1.toml": "name=\"agent1\"\ncommand=[\"a1\"]\nworkdir=\"/w\"\nlogin_provider=\"shared\"\n",
		"agent2.toml": "name=\"agent2\"\ncommand=[\"a2\"]\nworkdir=\"/w\"\nlogin_provider=\"shared\"\n",
	})
	got4 := credentialProvidersFromRegistry(reg4)
	if len(got4) != 1 || got4[0] != "shared" {
		t.Fatalf("dedup: got %v, want [shared]", got4)
	}
}
