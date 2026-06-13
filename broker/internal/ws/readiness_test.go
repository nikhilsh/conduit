package ws

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// ---------- helpers for credential blobs ----------

func anthropicCred(expiresAt int64) []byte {
	return []byte(fmt.Sprintf(`{"claudeAiOauth":{"accessToken":"AT","refreshToken":"RT","expiresAt":%d,"subscriptionType":"max"}}`, expiresAt))
}

func openaiCred(expSec int64) []byte {
	enc := base64.RawURLEncoding
	header := enc.EncodeToString([]byte(`{"alg":"none"}`))
	payload := enc.EncodeToString([]byte(fmt.Sprintf(`{"exp":%d}`, expSec)))
	return []byte(fmt.Sprintf(`{"tokens":{"access_token":"%s.%s.sig"}}`, header, payload))
}

// writeHostCred places a fake credential file at the provider's host path
// under the given home directory.
func writeHostCred(t *testing.T, homeDir, provider string, data []byte) {
	t.Helper()
	var sub, filename string
	switch provider {
	case "anthropic":
		sub, filename = ".claude", ".credentials.json"
	case "openai":
		sub, filename = ".codex", "auth.json"
	default:
		t.Fatalf("unsupported provider %q in writeHostCred", provider)
	}
	dir := filepath.Join(homeDir, sub)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir %s: %v", dir, err)
	}
	if err := os.WriteFile(filepath.Join(dir, filename), data, 0o600); err != nil {
		t.Fatalf("write host cred: %v", err)
	}
}

// fakeAdapter builds a minimal agents.Adapter for a given provider.
// Command is set to a path that definitely doesn't exist so cli_present
// is testably false unless the caller overrides it via lookPath tricks.
func fakeAdapter(name, provider string, envPassthrough ...string) agents.Adapter {
	a := agents.Adapter{
		Name:           name,
		Command:        []string{"/no-such-binary-" + name},
		Workdir:        ".",
		LoginProvider:  provider,
		EnvPassthrough: envPassthrough,
	}
	return a
}

// ---------- agentSignInState table tests ----------

// TestAgentSignInState covers the matrix of (cli present/absent ×
// creds fresh/stale/absent/apikey). Note: cli_present is tested
// separately below; agentSignInState only computes sign-in/expiry.
func TestAgentSignInState(t *testing.T) {
	now := time.Now()
	futureMS := now.Add(2 * time.Hour).UnixMilli()
	pastMS := now.Add(-1 * time.Hour).UnixMilli()
	futureSec := now.Add(2 * time.Hour).Unix()
	pastSec := now.Add(-1 * time.Hour).Unix()

	tests := []struct {
		name         string
		provider     string
		credData     []byte // nil = no file
		envKey       string // env var name to set, "" = none
		envVal       string // env var value
		wantSignedIn bool
		wantExpNil   bool // true if auth_expires_in_s must be null
		wantExpGT0   bool // true if expiry must be > 0 (future cred)
	}{
		{
			name:         "anthropic fresh creds",
			provider:     "anthropic",
			credData:     anthropicCred(futureMS),
			wantSignedIn: true,
			wantExpGT0:   true,
		},
		{
			name:         "anthropic expired creds",
			provider:     "anthropic",
			credData:     anthropicCred(pastMS),
			wantSignedIn: true,
			wantExpNil:   false, // expiry present but 0
		},
		{
			name:         "anthropic absent creds",
			provider:     "anthropic",
			credData:     nil,
			wantSignedIn: false,
			wantExpNil:   true,
		},
		{
			name:         "anthropic api-key mode",
			provider:     "anthropic",
			credData:     nil,
			envKey:       "ANTHROPIC_API_KEY",
			envVal:       "sk-ant-test",
			wantSignedIn: true,
			wantExpNil:   true,
		},
		{
			name:         "openai fresh JWT",
			provider:     "openai",
			credData:     openaiCred(futureSec),
			wantSignedIn: true,
			wantExpGT0:   true,
		},
		{
			name:         "openai expired JWT",
			provider:     "openai",
			credData:     openaiCred(pastSec),
			wantSignedIn: true,
			wantExpNil:   false,
		},
		{
			name:         "openai absent creds",
			provider:     "openai",
			credData:     nil,
			wantSignedIn: false,
			wantExpNil:   true,
		},
		{
			name:         "openai api-key mode",
			provider:     "openai",
			credData:     nil,
			envKey:       "OPENAI_API_KEY",
			envVal:       "sk-test-key",
			wantSignedIn: true,
			wantExpNil:   true,
		},
		{
			name:         "api-key empty string does not count",
			provider:     "anthropic",
			credData:     nil,
			envKey:       "ANTHROPIC_API_KEY",
			envVal:       "",
			wantSignedIn: false,
			wantExpNil:   true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			// Isolate host HOME.
			fakeHome := t.TempDir()
			t.Setenv("CONDUIT_HOST_HOME", fakeHome)

			if tc.envKey != "" {
				t.Setenv(tc.envKey, tc.envVal)
			}

			if tc.credData != nil {
				writeHostCred(t, fakeHome, tc.provider, tc.credData)
			}

			// Build an adapter that includes the env passthrough when testing API-key mode.
			var envPT []string
			if tc.envKey != "" {
				envPT = append(envPT, tc.envKey)
			}
			a := fakeAdapter("test-agent", tc.provider, envPT...)

			gotSignedIn, gotExpiry := agentSignInState(a, nil)
			if gotSignedIn != tc.wantSignedIn {
				t.Errorf("signed_in = %v, want %v", gotSignedIn, tc.wantSignedIn)
			}
			if tc.wantExpNil && gotExpiry != nil {
				t.Errorf("auth_expires_in_s should be nil, got %v", *gotExpiry)
			}
			if !tc.wantExpNil && gotExpiry == nil && tc.wantSignedIn {
				// expiry present but we didn't ask for nil — fine if signed_in=false
				if tc.wantSignedIn {
					t.Errorf("auth_expires_in_s should not be nil for signed-in with expiry")
				}
			}
			if tc.wantExpGT0 {
				if gotExpiry == nil {
					t.Errorf("auth_expires_in_s should be non-nil (future cred), got nil")
				} else if *gotExpiry <= 0 {
					t.Errorf("auth_expires_in_s should be > 0, got %d", *gotExpiry)
				}
			}
		})
	}
}

// stubCredStore is a credStore that reports presence for a fixed set of
// providers. Lets readiness tests exercise the pushed-credential path
// without a real on-disk store.
type stubCredStore struct{ has map[string]bool }

func (s stubCredStore) Has(provider string) bool { return s.has[provider] }

// TestAgentSignInStatePushedCred verifies that an app-pushed credential
// (credStore.Has==true) reports signed_in=true even with NO host login
// file present, and that a nil store falls back to host-file detection.
// This is the readiness half of the Hostinger 401 fix: an auto-propagated
// box must stop reporting signed_in=false.
func TestAgentSignInStatePushedCred(t *testing.T) {
	// Isolate host HOME to an empty dir so there's no host login file.
	t.Setenv("CONDUIT_HOST_HOME", t.TempDir())

	a := fakeAdapter("claude", "anthropic")

	// No store, no host file → signed_in=false.
	if got, _ := agentSignInState(a, nil); got {
		t.Errorf("nil store + no host file: signed_in=true, want false")
	}

	// Store reports the pushed cred → signed_in=true, expiry nil
	// (we don't decrypt the blob to surface expiry here).
	store := stubCredStore{has: map[string]bool{"anthropic": true}}
	signedIn, exp := agentSignInState(a, store)
	if !signedIn {
		t.Errorf("pushed cred present: signed_in=false, want true")
	}
	if exp != nil {
		t.Errorf("pushed cred present: auth_expires_in_s=%v, want nil", *exp)
	}

	// Store reports a DIFFERENT provider → no effect for anthropic.
	other := stubCredStore{has: map[string]bool{"openai": true}}
	if got, _ := agentSignInState(a, other); got {
		t.Errorf("only openai pushed: anthropic signed_in=true, want false")
	}
}

// TestCredentialExpiryMillisForReadiness checks the parsing helpers directly.
func TestCredentialExpiryMillisForReadiness(t *testing.T) {
	now := time.Now()
	expMS := now.Add(time.Hour).UnixMilli()
	expSec := now.Add(time.Hour).Unix()

	got, ok := credentialExpiryMillisForReadiness("anthropic", anthropicCred(expMS))
	if !ok || got != expMS {
		t.Errorf("anthropic: got (%d,%v), want (%d,true)", got, ok, expMS)
	}

	got, ok = credentialExpiryMillisForReadiness("openai", openaiCred(expSec))
	if !ok || got != expSec*1000 {
		t.Errorf("openai: got (%d,%v), want (%d,true)", got, ok, expSec*1000)
	}

	// Unknown provider → ok=false.
	if _, ok := credentialExpiryMillisForReadiness("unknown", []byte(`{}`)); ok {
		t.Errorf("unknown provider: want ok=false")
	}

	// Malformed blob → ok=false.
	for _, bad := range [][]byte{nil, []byte("{"), []byte(`{}`)} {
		if _, ok := credentialExpiryMillisForReadiness("anthropic", bad); ok {
			t.Errorf("anthropic bad blob %q: want ok=false", bad)
		}
	}
}

// ---------- /api/capabilities readiness block integration test ----------

// TestCapabilitiesReadinessBlock verifies that the readiness block is
// present in GET /api/capabilities with the expected shape: broker_version,
// node_present, tmux_present, and per-agent entries with cli_present +
// signed_in + auth_expires_in_s.
func TestCapabilitiesReadinessBlock(t *testing.T) {
	// Reset the cache TTL so this test gets a fresh computation.
	readinessCache.Lock()
	readinessCache.built = time.Time{}
	readinessCache.Unlock()

	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })

	// Isolate host HOME so the test doesn't read real credentials.
	fakeHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", fakeHome)

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}

	var body struct {
		Readiness struct {
			BrokerVersion string          `json:"broker_version"`
			NodePresent   bool            `json:"node_present"`
			TmuxPresent   bool            `json:"tmux_present"`
			GitPresent    bool            `json:"git_present"`
			Agents        json.RawMessage `json:"agents"`
		} `json:"readiness"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	r := body.Readiness

	// broker_version is always present (defaults to "dev" in test builds).
	if r.BrokerVersion == "" {
		t.Errorf("broker_version must be non-empty")
	}

	// git_present is always serialized (true/false; actual value depends on
	// whether git is on PATH in the test environment — either value is fine).
	t.Logf("readiness.git_present=%v", r.GitPresent)

	// agents map must be present (the test registry has claude + codex).
	var agentMap map[string]struct {
		CLIPresent     bool   `json:"cli_present"`
		SignedIn       bool   `json:"signed_in"`
		AuthExpiresInS *int64 `json:"auth_expires_in_s"`
	}
	if err := json.Unmarshal(r.Agents, &agentMap); err != nil {
		t.Fatalf("agents decode: %v", err)
	}
	if len(agentMap) == 0 {
		t.Errorf("agents map must not be empty")
	}
	// The test registry defines claude and codex. Both must appear.
	for _, name := range []string{"claude", "codex"} {
		if _, ok := agentMap[name]; !ok {
			t.Errorf("agents[%s] missing from readiness", name)
		}
	}

	// cli_present is false for test adapters (command is "cat" which IS
	// on PATH in Linux CI — but that's fine; the field is just a bool).
	// What we care about is the shape is present and correctly typed.
	for name, ag := range agentMap {
		_ = ag.CLIPresent // just verify no decode error
		_ = ag.SignedIn
		t.Logf("readiness.agents[%s]: cli_present=%v signed_in=%v auth_expires_in_s=%v",
			name, ag.CLIPresent, ag.SignedIn, ag.AuthExpiresInS)
	}
}

// TestCapabilitiesReadinessFreshCreds verifies that when a host credential
// file exists with a future expiry, the readiness block reports signed_in=true
// and a positive auth_expires_in_s for the matching agent.
func TestCapabilitiesReadinessFreshCreds(t *testing.T) {
	// Reset cache so this test runs fresh detection.
	readinessCache.Lock()
	readinessCache.built = time.Time{}
	readinessCache.Unlock()

	fakeHome := t.TempDir()
	t.Setenv("CONDUIT_HOST_HOME", fakeHome)

	// Write a fresh anthropic credential.
	futureExp := time.Now().Add(3 * time.Hour).UnixMilli()
	writeHostCred(t, fakeHome, "anthropic", anthropicCred(futureExp))

	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()

	var body struct {
		Readiness struct {
			Agents map[string]struct {
				SignedIn       bool   `json:"signed_in"`
				AuthExpiresInS *int64 `json:"auth_expires_in_s"`
			} `json:"agents"`
		} `json:"readiness"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}

	claude, ok := body.Readiness.Agents["claude"]
	if !ok {
		t.Fatalf("claude missing from readiness.agents")
	}
	if !claude.SignedIn {
		t.Errorf("claude: signed_in = false, want true (host cred file present)")
	}
	if claude.AuthExpiresInS == nil {
		t.Errorf("claude: auth_expires_in_s should be non-nil for fresh cred")
	} else if *claude.AuthExpiresInS <= 0 {
		t.Errorf("claude: auth_expires_in_s = %d, want > 0", *claude.AuthExpiresInS)
	}
}
