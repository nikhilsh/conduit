package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sync"
	"testing"
)

// TestMirrorHostCredentials_AnthropicCopiesBothFiles validates the
// host-mirror copy lands both `.claude/.credentials.json` and
// `~/.claude.json` into the per-session ephemeral HOME with mode 0600.
func TestMirrorHostCredentials_AnthropicCopiesBothFiles(t *testing.T) {
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)

	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir .claude: %v", err)
	}
	credBlob := []byte(`{"oauth":{"access_token":"AT","refresh_token":"RT"}}`)
	cfgBlob := []byte(`{"theme":"dark"}`)
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), credBlob, 0o600); err != nil {
		t.Fatalf("write creds: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".claude.json"), cfgBlob, 0o600); err != nil {
		t.Fatalf("write cfg: %v", err)
	}

	ephemeral := t.TempDir()
	if err := mirrorHostCredentials("anthropic", ephemeral); err != nil {
		t.Fatalf("mirrorHostCredentials: %v", err)
	}

	gotCreds, err := os.ReadFile(filepath.Join(ephemeral, ".claude", ".credentials.json"))
	if err != nil {
		t.Fatalf("read mirrored creds: %v", err)
	}
	if string(gotCreds) != string(credBlob) {
		t.Fatalf("creds blob mismatch: got %q want %q", string(gotCreds), string(credBlob))
	}
	gotCfg, err := os.ReadFile(filepath.Join(ephemeral, ".claude.json"))
	if err != nil {
		t.Fatalf("read mirrored cfg: %v", err)
	}
	if string(gotCfg) != string(cfgBlob) {
		t.Fatalf("cfg blob mismatch: got %q want %q", string(gotCfg), string(cfgBlob))
	}
	st, err := os.Stat(filepath.Join(ephemeral, ".claude", ".credentials.json"))
	if err != nil {
		t.Fatalf("stat creds: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Fatalf("creds mode = %#o, want 0600", mode)
	}
}

// TestMirrorHostCredentials_NoSourceFiles confirms the mirror reports
// an error (not a panic) when the broker's host HOME has no creds —
// callers must log + skip so the agent prompts for /login.
func TestMirrorHostCredentials_NoSourceFiles(t *testing.T) {
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	ephemeral := t.TempDir()

	err := mirrorHostCredentials("anthropic", ephemeral)
	if err == nil {
		t.Fatalf("expected error for empty host home, got nil")
	}
	// And no spurious files inside the ephemeral dir.
	if _, err := os.Stat(filepath.Join(ephemeral, ".claude", ".credentials.json")); !os.IsNotExist(err) {
		t.Fatalf("ephemeral creds unexpectedly exists: %v", err)
	}
}

// TestConcurrentSessionsGetIsolatedHomes drives the full spawn path:
// three concurrent sessions each get their own ephemeral $HOME, each
// holding its own copy of the broker host's `.credentials.json`.
// Mutating one session's copy must NOT mutate the others — that is the
// invariant the OAuth refresh-token race depended on violating.
func TestConcurrentSessionsGetIsolatedHomes(t *testing.T) {
	root := testRoot(t)

	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir host .claude: %v", err)
	}
	originalBlob := []byte(`{"refresh_token":"v0"}`)
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), originalBlob, 0o600); err != nil {
		t.Fatalf("write host creds: %v", err)
	}

	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("home-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	const n = 3
	ids := []string{"agent-home-A", "agent-home-B", "agent-home-C"}
	sessions := make([]*Session, n)

	var wg sync.WaitGroup
	wg.Add(n)
	errCh := make(chan error, n)
	for i, id := range ids {
		i, id := i, id
		go func() {
			defer wg.Done()
			s, _, err := m.GetOrCreate(id, "claude")
			if err != nil {
				errCh <- err
				return
			}
			sessions[i] = s
		}()
	}
	wg.Wait()
	close(errCh)
	for err := range errCh {
		if err != nil {
			t.Fatalf("GetOrCreate (concurrent): %v", err)
		}
	}

	// Each session has its own agent-home directory under its
	// workspaceDir/.conduit/agent-home/<id>/, populated from the
	// host-mirror copy.
	for _, s := range sessions {
		if s.agentHomeDir == "" {
			t.Fatalf("session %s: agentHomeDir is empty (HOME not isolated)", s.ID)
		}
		credsPath := filepath.Join(s.agentHomeDir, ".claude", ".credentials.json")
		blob, err := os.ReadFile(credsPath)
		if err != nil {
			t.Fatalf("session %s: read mirrored creds: %v", s.ID, err)
		}
		if string(blob) != string(originalBlob) {
			t.Fatalf("session %s: mirrored creds mismatch: got %q want %q", s.ID, string(blob), string(originalBlob))
		}
	}

	// Each ephemeral path must be distinct — otherwise the race we're
	// trying to break still exists.
	seen := map[string]string{}
	for _, s := range sessions {
		if other, dup := seen[s.agentHomeDir]; dup {
			t.Fatalf("agent-home collision: %s and %s share %q", other, s.ID, s.agentHomeDir)
		}
		seen[s.agentHomeDir] = s.ID
	}

	// Mutating session A's copy must NOT leak to session B/C nor back
	// to the broker host's $HOME — this is the property that breaks
	// the concurrent-refresh race.
	mutated := []byte(`{"refresh_token":"AAA-only"}`)
	aPath := filepath.Join(sessions[0].agentHomeDir, ".claude", ".credentials.json")
	if err := os.WriteFile(aPath, mutated, 0o600); err != nil {
		t.Fatalf("mutate A: %v", err)
	}
	for _, s := range sessions[1:] {
		blob, err := os.ReadFile(filepath.Join(s.agentHomeDir, ".claude", ".credentials.json"))
		if err != nil {
			t.Fatalf("session %s: re-read mirrored creds: %v", s.ID, err)
		}
		if string(blob) != string(originalBlob) {
			t.Fatalf("session %s: mutation in A leaked: got %q", s.ID, string(blob))
		}
	}
	hostBlob, err := os.ReadFile(filepath.Join(hostHome, ".claude", ".credentials.json"))
	if err != nil {
		t.Fatalf("re-read host creds: %v", err)
	}
	if string(hostBlob) != string(originalBlob) {
		t.Fatalf("mutation in A leaked back to host creds: got %q", string(hostBlob))
	}
}

// TestSessionCloseScrubsCredentialsKeepsHome verifies session exit
// removes the materialized credentials (rotated refresh tokens must not
// linger) while PRESERVING the home itself — the CLIs' conversation
// files inside it are what recovery's --resume depends on, and a broker
// shutdown Closes every live session (the old full RemoveAll destroyed
// every conversation on every redeploy).
func TestSessionCloseScrubsCredentialsKeepsHome(t *testing.T) {
	root := testRoot(t)
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir host .claude: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), []byte(`{"refresh_token":"X"}`), 0o600); err != nil {
		t.Fatalf("write host creds: %v", err)
	}

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
	if _, err := os.Stat(filepath.Join(dir, ".claude", ".credentials.json")); !os.IsNotExist(err) {
		t.Fatalf("materialized credential must be scrubbed on Close: %v", err)
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
