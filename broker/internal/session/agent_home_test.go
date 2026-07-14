package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// TestSessionCloseKeepsHome verifies session exit PRESERVES the agent-home —
// the CLIs' conversation files inside it are what recovery's --resume
// depends on, and a broker shutdown Closes every live session (the old full
// RemoveAll destroyed every conversation on every redeploy). No per-session
// credential file is ever written into agent-home to scrub (credentials live
// in the shared canonical dir — credseed.go).
func TestSessionCloseKeepsHome(t *testing.T) {
	root := testRoot(t)

	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("close-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	s, _, err := m.GetOrCreate("agent-home-close", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, s, "close-ready")

	dir := s.agentHomeDir
	if dir == "" {
		t.Fatalf("agentHomeDir empty")
	}
	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("agent-home not created: %v", err)
	}

	// A conversation file that must survive Close.
	conv := filepath.Join(dir, ".claude", "projects", "-w", "c1.jsonl")
	if err := os.MkdirAll(filepath.Dir(conv), 0o755); err != nil {
		t.Fatalf("mkdir projects: %v", err)
	}
	if err := os.WriteFile(conv, []byte("{}"), 0o600); err != nil {
		t.Fatalf("write conv: %v", err)
	}

	s.Close()
	<-s.Done()

	if _, err := os.Stat(dir); err != nil {
		t.Fatalf("agent-home must SURVIVE Close (recovery resumes from it): %v", err)
	}
	if _, err := os.Stat(conv); err != nil {
		t.Fatalf("conversation file must survive Close: %v", err)
	}
}

// --- seedClaudeConfig ---------------------------------------------------

// TestSeedClaudeConfig_FreshHome writes a brand-new ~/.claude.json with
// the default theme + onboarding marker so the first-run theme picker
// never blocks a non-interactive PTY session.
func TestSeedClaudeConfig_FreshHome(t *testing.T) {
	ephemeral := t.TempDir()
	if err := seedClaudeConfig(ephemeral); err != nil {
		t.Fatalf("seedClaudeConfig: %v", err)
	}
	path := filepath.Join(ephemeral, ".claude.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read seeded cfg: %v", err)
	}
	var cfg map[string]any
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal seeded cfg: %v", err)
	}
	if cfg["theme"] != defaultClaudeTheme {
		t.Fatalf("theme = %v, want %q", cfg["theme"], defaultClaudeTheme)
	}
	if done, _ := cfg["hasCompletedOnboarding"].(bool); !done {
		t.Fatalf("hasCompletedOnboarding = %v, want true", cfg["hasCompletedOnboarding"])
	}
	st, err := os.Stat(path)
	if err != nil {
		t.Fatalf("stat seeded cfg: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Fatalf("seeded cfg mode = %#o, want 0600", mode)
	}
}

// TestSeedClaudeConfig_PreservesExistingTheme confirms a theme copied
// from the host (or set by the operator) is never overwritten, and that
// unrelated keys survive the merge.
func TestSeedClaudeConfig_PreservesExistingTheme(t *testing.T) {
	ephemeral := t.TempDir()
	path := filepath.Join(ephemeral, ".claude.json")
	if err := os.WriteFile(path, []byte(`{"theme":"light","numStartups":7}`), 0o600); err != nil {
		t.Fatalf("write existing cfg: %v", err)
	}
	if err := seedClaudeConfig(ephemeral); err != nil {
		t.Fatalf("seedClaudeConfig: %v", err)
	}
	var cfg map[string]any
	data, _ := os.ReadFile(path)
	if err := json.Unmarshal(data, &cfg); err != nil {
		t.Fatalf("unmarshal cfg: %v", err)
	}
	if cfg["theme"] != "light" {
		t.Fatalf("theme = %v, want light (must not overwrite)", cfg["theme"])
	}
	if done, _ := cfg["hasCompletedOnboarding"].(bool); !done {
		t.Fatalf("hasCompletedOnboarding not added")
	}
	if n, _ := cfg["numStartups"].(float64); n != 7 {
		t.Fatalf("numStartups = %v, want 7 (unrelated key dropped)", cfg["numStartups"])
	}
}

// TestSeedClaudeConfig_Idempotent confirms a config that already carries
// both keys is left byte-for-byte unchanged (no needless rewrite).
func TestSeedClaudeConfig_Idempotent(t *testing.T) {
	ephemeral := t.TempDir()
	path := filepath.Join(ephemeral, ".claude.json")
	orig := []byte(`{"hasCompletedOnboarding":true,"theme":"dark-daltonized"}`)
	if err := os.WriteFile(path, orig, 0o600); err != nil {
		t.Fatalf("write cfg: %v", err)
	}
	if err := seedClaudeConfig(ephemeral); err != nil {
		t.Fatalf("seedClaudeConfig: %v", err)
	}
	data, _ := os.ReadFile(path)
	if string(data) != string(orig) {
		t.Fatalf("config rewritten unnecessarily:\n got %q\nwant %q", string(data), string(orig))
	}
}

// TestSeedClaudeConfig_CorruptNotClobbered confirms an unparseable
// config is reported as an error and left untouched — we never destroy
// a config we don't understand.
func TestSeedClaudeConfig_CorruptNotClobbered(t *testing.T) {
	ephemeral := t.TempDir()
	path := filepath.Join(ephemeral, ".claude.json")
	junk := []byte(`{not valid json`)
	if err := os.WriteFile(path, junk, 0o600); err != nil {
		t.Fatalf("write junk: %v", err)
	}
	if err := seedClaudeConfig(ephemeral); err == nil {
		t.Fatalf("expected parse error for corrupt config, got nil")
	}
	data, _ := os.ReadFile(path)
	if string(data) != string(junk) {
		t.Fatalf("corrupt config was clobbered: got %q", string(data))
	}
}

// TestCommandEnvSetsSandbox pins IS_SANDBOX=1 in the spawned agent env.
// Claude Code refuses --dangerously-skip-permissions under root without
// it, which crash-loops claude sessions on a root broker. Verified live:
// `IS_SANDBOX=1 claude --dangerously-skip-permissions` runs as root.
func TestCommandEnvSetsSandbox(t *testing.T) {
	env := (&Session{ID: "s1", Assistant: "claude"}).commandEnv(nil)
	found := false
	for _, kv := range env {
		if kv == "IS_SANDBOX=1" {
			found = true
		}
	}
	if !found {
		t.Fatalf("commandEnv missing IS_SANDBOX=1; env=%v", env)
	}
}

// TestMirrorOpencodeCredentials_CopiesFiles validates that the "opencode"
// provider mirrors both the auth.json credential and the opencode.jsonc config
// into the ephemeral HOME, so a spawned `opencode serve` uses whatever provider
// the operator configured on the host instead of always falling back to Zen.
func TestMirrorOpencodeCredentials_CopiesFiles(t *testing.T) {
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)

	authDir := filepath.Join(hostHome, ".local", "share", "opencode")
	if err := os.MkdirAll(authDir, 0o700); err != nil {
		t.Fatalf("mkdir auth dir: %v", err)
	}
	configDir := filepath.Join(hostHome, ".config", "opencode")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}

	authBlob := []byte(`{"providers":{"anthropic":{"accessToken":"tok"}}}`)
	cfgBlob := []byte(`{"$schema":"https://opencode.ai/config.json","model":"anthropic/claude-sonnet-4-5"}`)
	if err := os.WriteFile(filepath.Join(authDir, "auth.json"), authBlob, 0o600); err != nil {
		t.Fatalf("write auth.json: %v", err)
	}
	if err := os.WriteFile(filepath.Join(configDir, "opencode.jsonc"), cfgBlob, 0o644); err != nil {
		t.Fatalf("write opencode.jsonc: %v", err)
	}

	ephemeral := t.TempDir()
	if err := mirrorOpencodeCredentials(ephemeral); err != nil {
		t.Fatalf("mirrorOpencodeCredentials: %v", err)
	}

	gotAuth, err := os.ReadFile(filepath.Join(ephemeral, ".local", "share", "opencode", "auth.json"))
	if err != nil {
		t.Fatalf("read mirrored auth.json: %v", err)
	}
	if string(gotAuth) != string(authBlob) {
		t.Fatalf("auth.json mismatch: got %q want %q", gotAuth, authBlob)
	}

	gotCfg, err := os.ReadFile(filepath.Join(ephemeral, ".config", "opencode", "opencode.jsonc"))
	if err != nil {
		t.Fatalf("read mirrored opencode.jsonc: %v", err)
	}
	if string(gotCfg) != string(cfgBlob) {
		t.Fatalf("opencode.jsonc mismatch: got %q want %q", gotCfg, cfgBlob)
	}

	// auth.json must be mode 0600 (credential file).
	st, err := os.Stat(filepath.Join(ephemeral, ".local", "share", "opencode", "auth.json"))
	if err != nil {
		t.Fatalf("stat auth.json: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Fatalf("auth.json mode = %#o, want 0600", mode)
	}
}

// TestMirrorOpencodeCredentials_NoFiles confirms that mirrorOpencodeCredentials
// returns an error (not a panic) when the host has no opencode cred or config
// files — the caller logs and continues so the agent falls back to Zen
// gracefully.
func TestMirrorOpencodeCredentials_NoFiles(t *testing.T) {
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	ephemeral := t.TempDir()

	err := mirrorOpencodeCredentials(ephemeral)
	if err == nil {
		t.Fatalf("expected error for empty host opencode creds, got nil")
	}
}

// TestStatusPayload_CredentialSource verifies credential_source is emitted
// in the status frame when set, and omitted when empty.
func TestStatusPayload_CredentialSource(t *testing.T) {
	// "box" → field present with value "box".
	s := &Session{ID: "s1", credentialSource: "box"}
	p := s.StatusPayload()
	if got, ok := p["credential_source"]; !ok || got != "box" {
		t.Fatalf("credential_source = %v (ok=%v), want \"box\"", got, ok)
	}

	// "app_forwarded" → field present with value "app_forwarded".
	s2 := &Session{ID: "s2", credentialSource: "app_forwarded"}
	p2 := s2.StatusPayload()
	if got, ok := p2["credential_source"]; !ok || got != "app_forwarded" {
		t.Fatalf("credential_source = %v (ok=%v), want \"app_forwarded\"", got, ok)
	}

	// empty → field absent entirely.
	s3 := &Session{ID: "s3"}
	p3 := s3.StatusPayload()
	if _, ok := p3["credential_source"]; ok {
		t.Fatalf("credential_source should be absent when empty, got %v", p3["credential_source"])
	}
}

// TestCredentialSourceDetection_BoxAndAppForwarded verifies that the spawn
// path sets credentialSource="box" when only host creds are present and
// "app_forwarded" when the app blob was materialized.
func TestCredentialSourceDetection_BoxAndAppForwarded(t *testing.T) {
	root := testRoot(t)

	// Set up a host home with anthropic credentials so "box" path triggers.
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir host .claude: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), []byte(`{"r":"v0"}`), 0o600); err != nil {
		t.Fatalf("write host creds: %v", err)
	}

	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("credsrc-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	s, _, err := m.GetOrCreate("credsrc-box", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if s.credentialSource != "box" {
		t.Fatalf("credentialSource = %q, want \"box\"", s.credentialSource)
	}
	if got := s.StatusPayload()["credential_source"]; got != "box" {
		t.Fatalf("StatusPayload credential_source = %v, want \"box\"", got)
	}
}

// TestCredentialSourceDetection_NoCreds verifies credentialSource stays empty
// when neither app blob nor host credential exists.
func TestCredentialSourceDetection_NoCreds(t *testing.T) {
	root := testRoot(t)

	// Empty host home → no credentials.
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)

	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("credsrc-nocreds"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	s, _, err := m.GetOrCreate("credsrc-nocreds", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if s.credentialSource != "" {
		t.Fatalf("credentialSource = %q, want \"\" when no creds", s.credentialSource)
	}
	if _, ok := s.StatusPayload()["credential_source"]; ok {
		t.Fatalf("credential_source key should be absent in status payload when empty")
	}
}

// TestMirrorOpencodeCredentials_ConfigOnly verifies that having only the
// opencode.jsonc config (but no auth.json) is still treated as "something
// mirrored" — the config can specify a provider, and the auth may arrive via
// an API key env var rather than the auth.json store.
func TestMirrorOpencodeCredentials_ConfigOnly(t *testing.T) {
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)

	configDir := filepath.Join(hostHome, ".config", "opencode")
	if err := os.MkdirAll(configDir, 0o700); err != nil {
		t.Fatalf("mkdir config dir: %v", err)
	}
	cfgBlob := []byte(`{"$schema":"https://opencode.ai/config.json"}`)
	if err := os.WriteFile(filepath.Join(configDir, "opencode.jsonc"), cfgBlob, 0o644); err != nil {
		t.Fatalf("write opencode.jsonc: %v", err)
	}

	ephemeral := t.TempDir()
	if err := mirrorOpencodeCredentials(ephemeral); err != nil {
		t.Fatalf("mirrorOpencodeCredentials (config-only): %v", err)
	}
	if _, err := os.Stat(filepath.Join(ephemeral, ".config", "opencode", "opencode.jsonc")); err != nil {
		t.Fatalf("mirrored opencode.jsonc not found: %v", err)
	}
}

// TestOpencodeProviderPath is a table test for opencodeProviderPath: the function
// that determines (and logs) which provider path opencode will use at session
// startup. The priority is: env API key → mirrored auth → mirrored config → Zen.
func TestOpencodeProviderPath(t *testing.T) {
	makeAdapter := func(passthrough ...string) agents.Adapter {
		return agents.Adapter{
			Name:           "opencode",
			Command:        []string{"opencode"},
			Workdir:        "/workspace",
			EnvPassthrough: passthrough,
		}
	}

	tests := []struct {
		name       string
		adapter    agents.Adapter
		envKey     string
		envVal     string
		setupHome  func(t *testing.T, home string)
		wantPrefix string
	}{
		{
			name:       "ANTHROPIC_API_KEY present → env:ANTHROPIC_API_KEY",
			adapter:    makeAdapter("ANTHROPIC_API_KEY", "OPENAI_API_KEY"),
			envKey:     "ANTHROPIC_API_KEY",
			envVal:     "sk-ant-test",
			wantPrefix: "env:ANTHROPIC_API_KEY",
		},
		{
			name:       "OPENAI_API_KEY present → env:OPENAI_API_KEY",
			adapter:    makeAdapter("ANTHROPIC_API_KEY", "OPENAI_API_KEY"),
			envKey:     "OPENAI_API_KEY",
			envVal:     "sk-openai-test",
			wantPrefix: "env:OPENAI_API_KEY",
		},
		{
			name:    "mirrored auth.json → mirrored-auth",
			adapter: makeAdapter("ANTHROPIC_API_KEY"),
			setupHome: func(t *testing.T, home string) {
				d := filepath.Join(home, ".local", "share", "opencode")
				if err := os.MkdirAll(d, 0o700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(d, "auth.json"), []byte(`{"providers":{}}`), 0o600); err != nil {
					t.Fatal(err)
				}
			},
			wantPrefix: "mirrored-auth",
		},
		{
			name:    "mirrored config only (no auth.json, no env key) → mirrored-config",
			adapter: makeAdapter("ANTHROPIC_API_KEY"),
			setupHome: func(t *testing.T, home string) {
				d := filepath.Join(home, ".config", "opencode")
				if err := os.MkdirAll(d, 0o700); err != nil {
					t.Fatal(err)
				}
				// Non-trivial config (>2 bytes) signals a real provider is configured.
				if err := os.WriteFile(filepath.Join(d, "opencode.jsonc"), []byte(`{"model":"anthropic/claude-opus-4-5"}`), 0o644); err != nil {
					t.Fatal(err)
				}
			},
			wantPrefix: "mirrored-config",
		},
		{
			name:       "no key, no files → zen-fallback",
			adapter:    makeAdapter("ANTHROPIC_API_KEY", "OPENAI_API_KEY"),
			wantPrefix: "zen-fallback",
		},
		{
			name:       "empty env key does not count → zen-fallback",
			adapter:    makeAdapter("ANTHROPIC_API_KEY"),
			envKey:     "ANTHROPIC_API_KEY",
			envVal:     "",
			wantPrefix: "zen-fallback",
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			if tc.envKey != "" {
				t.Setenv(tc.envKey, tc.envVal)
			}
			agentHome := ""
			if tc.setupHome != nil {
				agentHome = t.TempDir()
				tc.setupHome(t, agentHome)
			}
			got := opencodeProviderPath(tc.adapter, agentHome)
			if !strings.HasPrefix(got, tc.wantPrefix) {
				t.Errorf("opencodeProviderPath = %q, want prefix %q", got, tc.wantPrefix)
			}
		})
	}
}
