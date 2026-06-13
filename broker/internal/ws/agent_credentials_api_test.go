package ws

import (
	"bytes"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/credentials"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// newTestServerWithCreds builds a test server with a real on-disk
// credentials store wired (rooted at a temp dir) so the session-less
// HTTP push/clear endpoints can be exercised end to end. Returns the
// httptest server, the bearer token, and the store for assertions.
func newTestServerWithCreds(t *testing.T) (*httptest.Server, string, *credentials.Store) {
	t.Helper()
	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	store := credentials.NewStore(filepath.Join(t.TempDir(), "creds"), []byte(tok))
	wsSrv := New(a, m).WithCredentials(store)
	srv := httptest.NewServer(wsSrv.Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok, store
}

func postJSON(t *testing.T, srv *httptest.Server, path, tok string, body any) *http.Response {
	t.Helper()
	b, err := json.Marshal(body)
	if err != nil {
		t.Fatalf("marshal body: %v", err)
	}
	req, _ := http.NewRequest(http.MethodPost, srv.URL+path+"?token="+url.QueryEscape(tok), bytes.NewReader(b))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	return resp
}

// TestServeAgentCredentialsStoreSessionLess is the crux of the
// auto-propagate fix: a credential can be stored for a box via HTTP with
// NO session created first. After the POST the store must hold the blob.
func TestServeAgentCredentialsStoreSessionLess(t *testing.T) {
	srv, tok, store := newTestServerWithCreds(t)

	resp := postJSON(t, srv, "/api/agent/credentials", tok, map[string]any{
		"provider":   "anthropic",
		"kind":       "oauth",
		"credential": json.RawMessage(`{"claudeAiOauth":{"accessToken":"AT"}}`),
	})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}
	var body struct {
		Stored   bool   `json:"stored"`
		Provider string `json:"provider"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.Stored || body.Provider != "anthropic" {
		t.Fatalf("body=%+v, want stored=true provider=anthropic", body)
	}
	// The blob must be on disk, encrypted-at-rest, decryptable by the store.
	if !store.Has("anthropic") {
		t.Fatalf("store.Has(anthropic) = false after HTTP push")
	}
	got, err := store.Get("anthropic")
	if err != nil {
		t.Fatalf("store.Get: %v", err)
	}
	if !bytes.Contains(got, []byte("AT")) {
		t.Fatalf("stored blob lost its payload: %s", got)
	}
}

// TestServeAgentCredentialsValidation covers the reject paths: bad method,
// unknown provider, unsupported kind, empty credential, bad JSON.
func TestServeAgentCredentialsValidation(t *testing.T) {
	srv, tok, _ := newTestServerWithCreds(t)

	cases := []struct {
		name string
		body map[string]any
		want int
	}{
		{"unknown_provider", map[string]any{"provider": "evil", "kind": "oauth", "credential": json.RawMessage(`{"x":1}`)}, http.StatusBadRequest},
		{"unsupported_kind", map[string]any{"provider": "anthropic", "kind": "api_key", "credential": json.RawMessage(`{"x":1}`)}, http.StatusBadRequest},
		{"empty_credential", map[string]any{"provider": "anthropic", "kind": "oauth"}, http.StatusBadRequest},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			resp := postJSON(t, srv, "/api/agent/credentials", tok, tc.body)
			resp.Body.Close()
			if resp.StatusCode != tc.want {
				t.Fatalf("status=%d, want %d", resp.StatusCode, tc.want)
			}
		})
	}

	// Wrong method → 405.
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/agent/credentials?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("GET status=%d, want 405", resp.StatusCode)
	}
}

// TestServeAgentCredentialsUnauthorized rejects a missing/bad bearer.
func TestServeAgentCredentialsUnauthorized(t *testing.T) {
	srv, _, _ := newTestServerWithCreds(t)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/agent/credentials", bytes.NewReader([]byte(`{"provider":"anthropic","kind":"oauth","credential":{"x":1}}`)))
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("status=%d, want 401", resp.StatusCode)
	}
}

// TestServeAgentCredentialsNoStore returns 503 when the broker was started
// without a credentials store.
func TestServeAgentCredentialsNoStore(t *testing.T) {
	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	srv := httptest.NewServer(New(a, m).Handler()) // no WithCredentials
	t.Cleanup(func() { srv.Close(); m.Close() })

	resp := postJSON(t, srv, "/api/agent/credentials", tok, map[string]any{
		"provider": "anthropic", "kind": "oauth", "credential": json.RawMessage(`{"x":1}`),
	})
	resp.Body.Close()
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("status=%d, want 503", resp.StatusCode)
	}
}

// TestServeAgentCredentialsClear covers per-box sign-out: store then clear,
// idempotent re-clear, and that readiness no longer reports the cred.
func TestServeAgentCredentialsClear(t *testing.T) {
	srv, tok, store := newTestServerWithCreds(t)

	// Seed a credential, then clear it.
	if err := store.Set("openai", json.RawMessage(`{"tokens":{"access_token":"b"}}`)); err != nil {
		t.Fatalf("seed Set: %v", err)
	}
	resp := postJSON(t, srv, "/api/agent/credentials/clear", tok, map[string]any{"provider": "openai"})
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("clear status=%d, want 200", resp.StatusCode)
	}
	if store.Has("openai") {
		t.Fatalf("store.Has(openai) = true after clear")
	}

	// Idempotent second clear is still 200.
	resp2 := postJSON(t, srv, "/api/agent/credentials/clear", tok, map[string]any{"provider": "openai"})
	resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("idempotent clear status=%d, want 200", resp2.StatusCode)
	}

	// Unknown provider → 400.
	resp3 := postJSON(t, srv, "/api/agent/credentials/clear", tok, map[string]any{"provider": "evil"})
	resp3.Body.Close()
	if resp3.StatusCode != http.StatusBadRequest {
		t.Fatalf("clear unknown status=%d, want 400", resp3.StatusCode)
	}
}

// TestReadinessReflectsPushedCred ties items 1+2 together: after an HTTP
// credential push (no session), GET /api/capabilities reports the matching
// agent as signed_in=true even with no host login file present. This is the
// exact signal an auto-propagated box needs to stop showing the 401-prone
// "not signed in" state.
func TestReadinessReflectsPushedCred(t *testing.T) {
	srv, tok, _ := newTestServerWithCreds(t)
	// Empty host HOME so the only sign-in signal is the pushed cred.
	// (agentSignInState is computed fresh per request; only the box-global
	// cli/node/tmux bits are cached, so no cache reset is needed here.)
	t.Setenv("CONDUIT_HOST_HOME", t.TempDir())

	// Push a claude (anthropic) credential session-lessly.
	resp := postJSON(t, srv, "/api/agent/credentials", tok, map[string]any{
		"provider": "anthropic", "kind": "oauth", "credential": json.RawMessage(`{"claudeAiOauth":{"accessToken":"AT"}}`),
	})
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("push status=%d", resp.StatusCode)
	}

	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	cap, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer cap.Body.Close()
	var body struct {
		Readiness struct {
			Agents map[string]struct {
				SignedIn bool `json:"signed_in"`
			} `json:"agents"`
		} `json:"readiness"`
	}
	if err := json.NewDecoder(cap.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	claude, ok := body.Readiness.Agents["claude"]
	if !ok {
		t.Fatalf("claude missing from readiness")
	}
	if !claude.SignedIn {
		t.Fatalf("claude signed_in=false after pushed cred, want true")
	}
}
