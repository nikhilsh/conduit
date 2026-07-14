package session

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/credentials"
)

func anthropicBlob(expiresAt int64) []byte {
	return []byte(fmt.Sprintf(`{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":%d,"subscriptionType":"max"}}`, expiresAt))
}

func openaiBlob(exp int64) []byte {
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"none"}`))
	payload := enc.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, exp)))
	return []byte(fmt.Sprintf(`{"tokens":{"access_token":"%s.%s.sig"}}`, header, payload))
}

func TestCredentialExpiryMillis(t *testing.T) {
	if got, ok := credentialExpiryMillis("anthropic", anthropicBlob(1780763004455)); !ok || got != 1780763004455 {
		t.Fatalf("anthropic: got (%d,%v), want (1780763004455,true)", got, ok)
	}
	if got, ok := credentialExpiryMillis("openai", openaiBlob(1780763004)); !ok || got != 1780763004000 {
		t.Fatalf("openai jwt exp: got (%d,%v), want (1780763004000,true)", got, ok)
	}
	if got, ok := credentialExpiryMillis("openai", []byte(`{"tokens":{"access_token":"not-a-jwt"},"last_refresh":"2026-05-29T07:47:01.698078980Z"}`)); !ok || got != time.Date(2026, 5, 29, 7, 47, 1, 698078980, time.UTC).UnixMilli() {
		t.Fatalf("openai last_refresh fallback: got (%d,%v)", got, ok)
	}
	for _, bad := range [][]byte{nil, []byte("{"), []byte(`{}`), []byte(`{"claudeAiOauth":{}}`)} {
		if _, ok := credentialExpiryMillis("anthropic", bad); ok {
			t.Fatalf("anthropic %q: want ok=false", bad)
		}
	}
	if _, ok := credentialExpiryMillis("ollama", anthropicBlob(1)); ok {
		t.Fatal("unknown provider: want ok=false")
	}
}

// seedHostClaude writes a host-login credentials file with the given
// expiry under a temp CONDUIT_HOST_HOME.
func seedHostClaude(t *testing.T, expiresAt int64) string {
	t.Helper()
	hostHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	if err := os.MkdirAll(filepath.Join(hostHome, ".claude"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".claude", ".credentials.json"), anthropicBlob(expiresAt), 0o600); err != nil {
		t.Fatalf("write host creds: %v", err)
	}
	return hostHome
}

func TestUseHostOverAppBlob_ExpiredBlobLosesToFresherHost(t *testing.T) {
	now := time.Now().UnixMilli()
	seedHostClaude(t, now+3*time.Hour.Milliseconds())
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(now-time.Hour.Milliseconds()))
	if !skip {
		t.Fatal("expired blob + fresh host: want skip=true")
	}
}

func TestUseHostOverAppBlob_ValidBlobAlwaysWins(t *testing.T) {
	// Host is fresher, but the blob is still valid — the app account
	// may be a deliberately different identity, so it must be honored.
	now := time.Now().UnixMilli()
	seedHostClaude(t, now+5*time.Hour.Milliseconds())
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(now+time.Hour.Milliseconds()))
	if skip {
		t.Fatal("valid blob: want skip=false even when host is fresher")
	}
}

func TestUseHostOverAppBlob_NoHostKeepsBlob(t *testing.T) {
	hostHome := t.TempDir() // empty — no .claude login on the host
	t.Setenv("CONDUIT_HOST_HOME", hostHome)
	skip, _, _ := useHostOverAppBlob("anthropic", anthropicBlob(1))
	if skip {
		t.Fatal("expired blob but no host login: want skip=false (blob is all we have)")
	}
}

// envMap collapses the commandEnv []string ("K=V") into a map for asserting.
func envMap(t *testing.T, env []string) map[string]string {
	t.Helper()
	m := map[string]string{}
	for _, kv := range env {
		if i := strings.IndexByte(kv, '='); i > 0 {
			m[kv[:i]] = kv[i+1:]
		}
	}
	return m
}

// emptyHostHome points CONDUIT_HOST_HOME at a fresh empty dir so neither
// provider has a host login (the login-less SSH-box shape).
func emptyHostHome(t *testing.T) string {
	t.Helper()
	h := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", h)
	return h
}

// --- credLookupHome always resolves to the shared canonical home ---

func TestSharedCreds_CredLookupHomeIsSharedHome(t *testing.T) {
	home := t.TempDir()
	s := &Session{ID: "cred-lookup", Assistant: "claude", agentHomeDir: "/should/be/ignored", sharedCredHome: home}
	if got := s.credLookupHome(); got != home {
		t.Fatalf("credLookupHome=%q, want sharedCredHome %q", got, home)
	}
}

// --- host login present: Option A, env == host dir, no copy ---

func TestSharedCreds_HostLogin_OptionA(t *testing.T) {
	now := time.Now().UnixMilli()
	hostHome := seedHostClaude(t, now+3*time.Hour.Milliseconds()) // writes ~/.claude/.credentials.json
	// Also give the host a codex login so both providers resolve Option A.
	if err := os.MkdirAll(filepath.Join(hostHome, ".codex"), 0o700); err != nil {
		t.Fatalf("mkdir host codex: %v", err)
	}
	if err := os.WriteFile(filepath.Join(hostHome, ".codex", "auth.json"), openaiBlob(now/1000+3*3600), 0o600); err != nil {
		t.Fatalf("write host codex: %v", err)
	}

	conduitRoot := t.TempDir()
	res, err := ensureSharedCred(conduitRoot, nil)
	if err != nil {
		t.Fatalf("ensureSharedCred: %v", err)
	}
	if !res.optionA {
		t.Fatal("host login present, no blob: want Option A")
	}
	if res.home != hostHome {
		t.Fatalf("Option A home=%q, want host home %q", res.home, hostHome)
	}
	// NO broker-owned copy must have been created.
	brokerHome := brokerOwnedCredHome(conduitRoot)
	if _, statErr := os.Stat(filepath.Join(brokerHome, ".claude", ".credentials.json")); statErr == nil {
		t.Fatal("Option A must not create a broker-owned credential copy")
	}

	env, configDirs := sharedCredEnvFrom(res)
	wantClaude := filepath.Join(hostHome, ".claude")
	wantCodex := filepath.Join(hostHome, ".codex")
	if env["CLAUDE_CONFIG_DIR"] != wantClaude {
		t.Fatalf("CLAUDE_CONFIG_DIR=%q, want host %q", env["CLAUDE_CONFIG_DIR"], wantClaude)
	}
	if env["CODEX_HOME"] != wantCodex {
		t.Fatalf("CODEX_HOME=%q, want host %q", env["CODEX_HOME"], wantCodex)
	}
	if configDirs["anthropic"] != wantClaude || configDirs["openai"] != wantCodex {
		t.Fatalf("configDirs wrong: %v", configDirs)
	}
	// The credential_source for the session's provider is "box".
	if res.sourceLabel["anthropic"] != "box" {
		t.Fatalf("anthropic sourceLabel=%q, want box", res.sourceLabel["anthropic"])
	}

	// And commandEnv (the integration seam) carries the retarget.
	s := &Session{ID: "on-a", Assistant: "claude", agentHomeDir: t.TempDir(), sharedCredConfigEnv: env}
	got := envMap(t, s.commandEnv(nil))
	if got["CLAUDE_CONFIG_DIR"] != wantClaude {
		t.Fatalf("commandEnv CLAUDE_CONFIG_DIR=%q, want %q", got["CLAUDE_CONFIG_DIR"], wantClaude)
	}
	// commandEnv must OVERRIDE any per-session CODEX_HOME with the shared one.
	if got["CODEX_HOME"] != wantCodex {
		t.Fatalf("commandEnv CODEX_HOME=%q, want shared %q", got["CODEX_HOME"], wantCodex)
	}
}

// --- no host + valid app blob: Option B seeded from blob ---

func TestSharedCreds_AppBlob_OptionB_SeedsCanonical(t *testing.T) {
	emptyHostHome(t) // no host login at all
	now := time.Now().UnixMilli()

	storeDir := t.TempDir()
	store := credentials.NewStore(storeDir, nil)
	blob := anthropicBlob(now + 3*time.Hour.Milliseconds())
	if err := store.Set("anthropic", json.RawMessage(blob)); err != nil {
		t.Fatalf("store.Set: %v", err)
	}

	conduitRoot := t.TempDir()
	res, err := ensureSharedCred(conduitRoot, store)
	if err != nil {
		t.Fatalf("ensureSharedCred: %v", err)
	}
	if res.optionA {
		t.Fatal("valid app blob: want Option B (broker-owned home)")
	}
	if res.home != brokerOwnedCredHome(conduitRoot) {
		t.Fatalf("Option B home=%q, want %q", res.home, brokerOwnedCredHome(conduitRoot))
	}
	// Canonical claude file seeded from the blob, at the provider-native subpath.
	canon := filepath.Join(res.home, ".claude", ".credentials.json")
	got, rerr := os.ReadFile(canon)
	if rerr != nil {
		t.Fatalf("canonical file not seeded: %v", rerr)
	}
	if exp, ok := credentialExpiryMillis("anthropic", got); !ok || exp != now+3*time.Hour.Milliseconds() {
		t.Fatalf("seeded blob has wrong expiry: (%d,%v)", exp, ok)
	}
	// Mode 0600.
	if info, _ := os.Stat(canon); info != nil && info.Mode().Perm() != 0o600 {
		t.Fatalf("canonical cred mode=%o, want 0600", info.Mode().Perm())
	}
	if res.sourceLabel["anthropic"] != "app_forwarded" {
		t.Fatalf("anthropic sourceLabel=%q, want app_forwarded", res.sourceLabel["anthropic"])
	}

	env, _ := sharedCredEnvFrom(res)
	wantClaude := filepath.Join(res.home, ".claude")
	if env["CLAUDE_CONFIG_DIR"] != wantClaude {
		t.Fatalf("CLAUDE_CONFIG_DIR=%q, want %q", env["CLAUDE_CONFIG_DIR"], wantClaude)
	}
	// The fetchers read credLookupHome=res.home → res.home/.claude/.credentials.json,
	// which is exactly the seeded canonical file.
	s := &Session{ID: "on-b", Assistant: "claude", agentHomeDir: t.TempDir(), sharedCredHome: res.home}
	if s.credLookupHome() != res.home {
		t.Fatalf("credLookupHome=%q, want %q", s.credLookupHome(), res.home)
	}
}

// --- no host + no blob: clean no-creds state, no crash ---

func TestSharedCreds_NoHost_NoBlob_CleanNoCreds(t *testing.T) {
	emptyHostHome(t)
	conduitRoot := t.TempDir()

	res, err := ensureSharedCred(conduitRoot, nil)
	if err != nil {
		t.Fatalf("ensureSharedCred must not error with no creds: %v", err)
	}
	// No host login → optionA with an empty host home is acceptable; but the
	// env vars must still resolve to a non-empty, stable directory so the CLI
	// has a target and prompts /login cleanly.
	env, _ := sharedCredEnvFrom(res)
	if strings.TrimSpace(env["CLAUDE_CONFIG_DIR"]) == "" {
		t.Fatal("CLAUDE_CONFIG_DIR must point at a stable dir even with no creds")
	}
	if strings.TrimSpace(env["CODEX_HOME"]) == "" {
		t.Fatal("CODEX_HOME must point at a stable dir even with no creds")
	}
	// No canonical credential file should exist (nothing to seed).
	if res.sourceLabel["anthropic"] != "" || res.sourceLabel["openai"] != "" {
		t.Fatalf("no creds: sourceLabel must be empty, got %v", res.sourceLabel)
	}
}

// --- precedence: valid app blob WINS over a present host login (→ B) ---

func TestSharedCreds_Precedence_ValidBlobBeatsHostLogin(t *testing.T) {
	now := time.Now().UnixMilli()
	// Host IS logged into claude AND fresher than the blob...
	hostHome := seedHostClaude(t, now+5*time.Hour.Milliseconds())

	storeDir := t.TempDir()
	store := credentials.NewStore(storeDir, nil)
	// ...but the app pushed a still-VALID blob (deliberately-different account).
	blob := anthropicBlob(now + time.Hour.Milliseconds())
	if err := store.Set("anthropic", json.RawMessage(blob)); err != nil {
		t.Fatalf("store.Set: %v", err)
	}

	conduitRoot := t.TempDir()
	res, err := ensureSharedCred(conduitRoot, store)
	if err != nil {
		t.Fatalf("ensureSharedCred: %v", err)
	}
	if res.optionA {
		t.Fatal("valid app blob must WIN over host login → Option B, not A")
	}
	// The canonical claude file is the BLOB's, not the host's (expiry differs).
	canon := filepath.Join(res.home, ".claude", ".credentials.json")
	got, rerr := os.ReadFile(canon)
	if rerr != nil {
		t.Fatalf("canonical not seeded from blob: %v", rerr)
	}
	exp, _ := credentialExpiryMillis("anthropic", got)
	if exp != now+time.Hour.Milliseconds() {
		t.Fatalf("canonical seeded from host (expiry %d), want blob (expiry %d)", exp, now+time.Hour.Milliseconds())
	}
	if res.sourceLabel["anthropic"] != "app_forwarded" {
		t.Fatalf("anthropic sourceLabel=%q, want app_forwarded", res.sourceLabel["anthropic"])
	}
	// The OTHER provider (codex) had no blob; with a host codex login absent
	// here it gets no seed and an empty label — but the broker NEVER writes
	// into the operator's real host home on this path.
	hostClaudeCred := filepath.Join(hostHome, ".claude", ".credentials.json")
	hostBefore, _ := os.ReadFile(hostClaudeCred)
	// Re-run to assert idempotence + that the host file is untouched.
	if _, err := ensureSharedCred(conduitRoot, store); err != nil {
		t.Fatalf("ensureSharedCred (2nd): %v", err)
	}
	hostAfter, _ := os.ReadFile(hostClaudeCred)
	if string(hostBefore) != string(hostAfter) {
		t.Fatal("ensureSharedCred mutated the operator's host login file")
	}
}

// --- expired blob falls through to Option A (host wins, useHostOverAppBlob) ---

func TestSharedCreds_ExpiredBlob_FallsToHostOptionA(t *testing.T) {
	now := time.Now().UnixMilli()
	hostHome := seedHostClaude(t, now+3*time.Hour.Milliseconds()) // fresh host

	storeDir := t.TempDir()
	store := credentials.NewStore(storeDir, nil)
	// Expired blob — must LOSE to the fresher host login (useHostOverAppBlob).
	if err := store.Set("anthropic", json.RawMessage(anthropicBlob(now-time.Hour.Milliseconds()))); err != nil {
		t.Fatalf("store.Set: %v", err)
	}

	conduitRoot := t.TempDir()
	res, err := ensureSharedCred(conduitRoot, store)
	if err != nil {
		t.Fatalf("ensureSharedCred: %v", err)
	}
	if !res.optionA {
		t.Fatal("expired blob + fresher host: want Option A (host wins)")
	}
	if res.home != hostHome {
		t.Fatalf("Option A home=%q, want host %q", res.home, hostHome)
	}
}

// --- multi-session structural proof: all sessions share one canonical dir ---

func TestSharedCreds_MultiSession_SameCanonicalDir(t *testing.T) {
	emptyHostHome(t)
	now := time.Now().UnixMilli()

	storeDir := t.TempDir()
	store := credentials.NewStore(storeDir, nil)
	if err := store.Set("anthropic", json.RawMessage(anthropicBlob(now+3*time.Hour.Milliseconds()))); err != nil {
		t.Fatalf("store.Set: %v", err)
	}
	conduitRoot := t.TempDir()

	var dirs []string
	for i := 0; i < 3; i++ {
		res, err := ensureSharedCred(conduitRoot, store)
		if err != nil {
			t.Fatalf("ensureSharedCred[%d]: %v", i, err)
		}
		env, _ := sharedCredEnvFrom(res)
		dirs = append(dirs, env["CLAUDE_CONFIG_DIR"])
	}
	for i := 1; i < len(dirs); i++ {
		if dirs[i] != dirs[0] {
			t.Fatalf("sessions resolved DIFFERENT canonical dirs (%q vs %q) — the lineage is forked", dirs[0], dirs[i])
		}
	}
}
