package agents

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestLoadDirAndLookup(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
command = ["sh"]
args = ["-lc", "exec sh"]
workdir = "/workspace"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	adapter, err := reg.Get("claude")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if adapter.Name != "claude" || len(adapter.Command) == 0 {
		t.Fatalf("unexpected adapter: %+v", adapter)
	}
}

func TestLoadDirRejectsInvalidAdapter(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "bad.toml", `
name = "claude"
command = ["sh"]
`)
	_, err := LoadDir(dir)
	if err == nil || !strings.Contains(err.Error(), "workdir is required") {
		t.Fatalf("expected workdir validation error, got %v", err)
	}
}

func TestGetRejectsUnknownAssistant(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
image = "conduit/claude:latest"
command = ["sh"]
workdir = "/workspace"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	_, err = reg.Get("codex")
	if err == nil || !strings.Contains(err.Error(), `unknown assistant "codex"`) {
		t.Fatalf("expected unknown assistant error, got %v", err)
	}
}

func TestHiddenAdapterOmittedFromNamesButGettable(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
command = ["sh"]
workdir = "/workspace"
`)
	writeAdapter(t, dir, "shell.toml", `
name = "shell"
command = ["bash"]
args = ["-l"]
workdir = "/workspace"
hidden = true
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	names := reg.Names()
	if len(names) != 1 || names[0] != "claude" {
		t.Fatalf("Names() = %v; hidden adapter must be omitted", names)
	}
	adapter, err := reg.Get("shell")
	if err != nil {
		t.Fatalf("Get(shell): %v", err)
	}
	if !adapter.Hidden || adapter.Command[0] != "bash" {
		t.Fatalf("unexpected shell adapter: %+v", adapter)
	}
}

func writeAdapter(t *testing.T, dir, name, body string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(strings.TrimSpace(body)+"\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(%s): %v", path, err)
	}
}

// TestApplyLegacyDefaultsClaude verifies that a claude adapter loaded from
// TOML without the new Phase-1 fields gets exactly the expected defaults.
func TestApplyLegacyDefaultsClaude(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
command = ["claude"]
args = ["--dangerously-skip-permissions"]
workdir = "/workspace"
chat_mode = "stream-json"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	a, err := reg.Get("claude")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if a.Protocol != "stream-json" {
		t.Errorf("Protocol = %q, want stream-json", a.Protocol)
	}
	if a.ConfigDir != ".claude" {
		t.Errorf("ConfigDir = %q, want .claude", a.ConfigDir)
	}
	if a.LoginProvider != "anthropic" {
		t.Errorf("LoginProvider = %q, want anthropic", a.LoginProvider)
	}
	if len(a.EffortArgs) == 0 || a.EffortArgs[0] != "--effort" {
		t.Errorf("EffortArgs = %v, want [--effort {effort}]", a.EffortArgs)
	}
	if len(a.ModelArgs) == 0 || a.ModelArgs[0] != "--model" {
		t.Errorf("ModelArgs = %v, want [--model {model}]", a.ModelArgs)
	}
	if len(a.FastModeArgs) != 2 || a.FastModeArgs[0] != "--settings" || a.FastModeArgs[1] != `{"fastMode":{fast}}` {
		t.Errorf("FastModeArgs = %v, want [--settings {\"fastMode\":{fast}}]", a.FastModeArgs)
	}
	if len(a.ResumeArgs) == 0 || a.ResumeArgs[0] != "--resume" {
		t.Errorf("ResumeArgs = %v, want [--resume {session_id}]", a.ResumeArgs)
	}
	if len(a.ContinueArgs) == 0 || a.ContinueArgs[0] != "--continue" {
		t.Errorf("ContinueArgs = %v, want [--continue]", a.ContinueArgs)
	}
	planRule, ok := a.PermissionModes["plan"]
	if !ok {
		t.Fatal("PermissionModes[plan] missing")
	}
	if len(planRule.DropArgs) == 0 || planRule.DropArgs[0] != "--dangerously-skip-permissions" {
		t.Errorf("plan.DropArgs = %v", planRule.DropArgs)
	}
	if len(planRule.AddArgs) < 2 || planRule.AddArgs[0] != "--permission-mode" || planRule.AddArgs[1] != "plan" {
		t.Errorf("plan.AddArgs = %v", planRule.AddArgs)
	}
}

// TestApplyLegacyDefaultsCodex verifies that a codex adapter loaded without
// the new Phase-1 fields gets exactly the expected defaults.
func TestApplyLegacyDefaultsCodex(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "codex.toml", `
name = "codex"
command = ["codex"]
args = ["--dangerously-bypass-approvals-and-sandbox"]
workdir = "/workspace"
chat_mode = "codex-app-server"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	a, err := reg.Get("codex")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if a.Protocol != "codex-app-server" {
		t.Errorf("Protocol = %q, want codex-app-server", a.Protocol)
	}
	if a.ConfigDir != ".codex" {
		t.Errorf("ConfigDir = %q, want .codex", a.ConfigDir)
	}
	if a.LoginProvider != "openai" {
		t.Errorf("LoginProvider = %q, want openai", a.LoginProvider)
	}
	if len(a.EffortArgs) == 0 || a.EffortArgs[0] != "-c" {
		t.Errorf("EffortArgs = %v, want [-c model_reasoning_effort={effort}]", a.EffortArgs)
	}
	// codex has no fast-mode concept — the toggle must be a no-op.
	if len(a.FastModeArgs) != 0 {
		t.Errorf("FastModeArgs = %v, want [] (codex ignores fast mode)", a.FastModeArgs)
	}
	// codex resume is via protocol, not CLI args
	if len(a.ResumeArgs) != 0 {
		t.Errorf("ResumeArgs = %v, want [] (codex resumes via protocol)", a.ResumeArgs)
	}
	planRule, ok := a.PermissionModes["plan"]
	if !ok {
		t.Fatal("PermissionModes[plan] missing")
	}
	if len(planRule.DropArgs) == 0 || planRule.DropArgs[0] != "--dangerously-bypass-approvals-and-sandbox" {
		t.Errorf("plan.DropArgs = %v", planRule.DropArgs)
	}
	if len(planRule.AddArgs) < 2 || planRule.AddArgs[0] != "--sandbox" || planRule.AddArgs[1] != "read-only" {
		t.Errorf("plan.AddArgs = %v", planRule.AddArgs)
	}
}

// TestExplicitFieldsNotOverridden verifies that TOML fields present in the
// file are NOT overwritten by applyLegacyDefaults.
func TestExplicitFieldsNotOverridden(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "claude.toml", `
name = "claude"
command = ["claude"]
workdir = "/workspace"
protocol = "my-custom-protocol"
config_dir = ".my-config"
login_provider = "my-provider"
effort_args = ["--my-effort", "{effort}"]
model_args = ["--my-model", "{model}"]
resume_args = ["--my-resume", "{session_id}"]
continue_args = ["--my-continue"]
cred_files = ["path/to/creds.json"]
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	a, err := reg.Get("claude")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if a.Protocol != "my-custom-protocol" {
		t.Errorf("Protocol overridden: got %q", a.Protocol)
	}
	if a.ConfigDir != ".my-config" {
		t.Errorf("ConfigDir overridden: got %q", a.ConfigDir)
	}
	if a.LoginProvider != "my-provider" {
		t.Errorf("LoginProvider overridden: got %q", a.LoginProvider)
	}
	if len(a.EffortArgs) == 0 || a.EffortArgs[0] != "--my-effort" {
		t.Errorf("EffortArgs overridden: got %v", a.EffortArgs)
	}
}

// TestOpencodeManifestEnvPassthrough loads the real embedded opencode.toml and
// pins the env_passthrough keys that allow a real AI provider to be used when
// the broker host has a key set. The three keys are the primary way opencode
// picks up a provider over the no-auth Zen fallback; if any is missing,
// operator keys go unused and every session falls back to the flaky free tier.
func TestOpencodeManifestEnvPassthrough(t *testing.T) {
	// Load the real manifest from the embedded-agents directory.
	const tomlPath = "../../cmd/conduit-broker/embedded-agents/opencode.toml"
	dir := t.TempDir()
	raw, err := os.ReadFile(tomlPath)
	if err != nil {
		t.Fatalf("read %s: %v", tomlPath, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "opencode.toml"), raw, 0o644); err != nil {
		t.Fatalf("write temp toml: %v", err)
	}
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	a, err := reg.Get("opencode")
	if err != nil {
		t.Fatalf("Get(opencode): %v", err)
	}
	wantKeys := []string{"ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENCODE_API_KEY"}
	envSet := make(map[string]bool, len(a.EnvPassthrough))
	for _, k := range a.EnvPassthrough {
		envSet[k] = true
	}
	for _, k := range wantKeys {
		if !envSet[k] {
			t.Errorf("opencode env_passthrough missing %q (got %v); operator AI-provider keys won't reach the server", k, a.EnvPassthrough)
		}
	}
}

// TestThirdPartyAdapterNoDefaults verifies that a non-claude/codex adapter
// gets empty defaults (no panic, no crash) — third-party adapters that
// predate the manifest fields are unaffected.
func TestThirdPartyAdapterNoDefaults(t *testing.T) {
	dir := t.TempDir()
	writeAdapter(t, dir, "gemini.toml", `
name = "gemini"
command = ["gemini"]
workdir = "/workspace"
`)
	reg, err := LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	a, err := reg.Get("gemini")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	// Third-party adapters without the fields get zero values (empty strings/slices).
	if a.Protocol != "" || a.ConfigDir != "" || a.LoginProvider != "" {
		t.Errorf("unexpected defaults for third-party adapter: protocol=%q, configDir=%q, loginProvider=%q",
			a.Protocol, a.ConfigDir, a.LoginProvider)
	}
}
