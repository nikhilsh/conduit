package ws

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/push"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// newTestServerWithPush creates a test server with a full push stack wired:
// a persisted registry, a recording relay (httptest), and a dispatcher.
func newTestServerWithPush(t *testing.T) (*httptest.Server, string, *push.Registry, *recordingRelaySrv) {
	t.Helper()

	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)

	relayRec := newRecordingRelaySrv()
	relayHttp := httptest.NewServer(relayRec)
	t.Cleanup(relayHttp.Close)

	pushReg := push.NewRegistryWithPersistence(filepath.Join(t.TempDir(), "push-tokens.json"))
	installCredFile := filepath.Join(t.TempDir(), "push-install.json")

	relaySender, err := push.NewRelaySender(relayHttp.URL, installCredFile)
	if err != nil {
		t.Fatalf("NewRelaySender: %v", err)
	}
	senders := map[push.Platform]push.Sender{
		push.PlatformAPNs:        relaySender,
		push.PlatformFCM:         relaySender,
		push.PlatformUnifiedPush: push.NewUnifiedPushSender(),
	}
	disp := push.NewDispatcher(pushReg, senders)

	wsSrv := New(a, m).
		WithPush(pushReg).
		WithDispatcher(disp).
		WithPushRelayConfigured(true)

	srv := httptest.NewServer(wsSrv.Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok, pushReg, relayRec
}

// newTestServerWithPushAndLA creates a test server with a full push stack +
// an LA registry wired, so LA registration endpoints can be tested.
func newTestServerWithPushAndLA(t *testing.T) (*httptest.Server, string, *push.Registry, *push.LARegistry, *recordingRelaySrv) {
	t.Helper()

	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)

	relayRec := newRecordingRelaySrv()
	relayHttp := httptest.NewServer(relayRec)
	t.Cleanup(relayHttp.Close)

	pushReg := push.NewRegistryWithPersistence(filepath.Join(t.TempDir(), "push-tokens.json"))
	installCredFile := filepath.Join(t.TempDir(), "push-install.json")

	relaySender, err := push.NewRelaySender(relayHttp.URL, installCredFile)
	if err != nil {
		t.Fatalf("NewRelaySender: %v", err)
	}
	senders := map[push.Platform]push.Sender{
		push.PlatformAPNs:        relaySender,
		push.PlatformFCM:         relaySender,
		push.PlatformUnifiedPush: push.NewUnifiedPushSender(),
	}
	disp := push.NewDispatcher(pushReg, senders)
	laReg := push.NewLARegistry()

	wsSrv := New(a, m).
		WithPush(pushReg).
		WithDispatcher(disp).
		WithPushRelayConfigured(true).
		WithLARegistry(laReg).
		WithLASender(relaySender)

	srv := httptest.NewServer(wsSrv.Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok, pushReg, laReg, relayRec
}

// recordingRelaySrv is a fake relay that records send calls and can be
// told to return a specific status code.
type recordingRelaySrv struct {
	calls  int
	bodies []map[string]any
	status int
}

func newRecordingRelaySrv() *recordingRelaySrv {
	return &recordingRelaySrv{status: http.StatusOK}
}

func (s *recordingRelaySrv) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.calls++
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	s.bodies = append(s.bodies, body)
	w.WriteHeader(s.status)
}

// --- Capabilities ---

func TestCapabilitiesPushFeatureAlwaysTrue(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()

	var body struct {
		Features struct {
			Push                bool `json:"push"`
			PushRelayConfigured bool `json:"push_relay_configured"`
		} `json:"features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.Features.Push {
		t.Error("features.push must be true")
	}
	// Basic server has no relay configured.
	if body.Features.PushRelayConfigured {
		t.Error("features.push_relay_configured should be false on basic test server")
	}
}

func TestCapabilitiesPushRelayConfigured(t *testing.T) {
	srv, tok, _, _ := newTestServerWithPush(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET capabilities: %v", err)
	}
	defer resp.Body.Close()

	var body struct {
		Features struct {
			Push                bool `json:"push"`
			PushRelayConfigured bool `json:"push_relay_configured"`
		} `json:"features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.Features.Push {
		t.Error("features.push must be true")
	}
	if !body.Features.PushRelayConfigured {
		t.Error("features.push_relay_configured should be true when relay is configured")
	}
}

// TestCapabilitiesNtfyURL verifies that features.ntfy_url is populated
// from WithNtfyURL and absent (omitempty) when not set. This is the seam
// the Android UnifiedPush auto-config reads in the follow-up PR.
func TestCapabilitiesNtfyURL(t *testing.T) {
	capFeatures := func(t *testing.T, srv *httptest.Server, tok string) map[string]any {
		t.Helper()
		req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/capabilities?token="+url.QueryEscape(tok), nil)
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("GET capabilities: %v", err)
		}
		defer resp.Body.Close()
		var body struct {
			Features map[string]any `json:"features"`
		}
		if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
			t.Fatalf("decode: %v", err)
		}
		return body.Features
	}

	t.Run("absent when not configured", func(t *testing.T) {
		srv, tok := newTestServer(t)
		features := capFeatures(t, srv, tok)
		if v, present := features["ntfy_url"]; present && v != "" {
			t.Errorf("ntfy_url should be absent when not configured, got %q", v)
		}
	})

	t.Run("populated from WithNtfyURL", func(t *testing.T) {
		a := auth.NewStore()
		tok := a.Mint()
		reg := newTestRegistry(t)
		m := session.NewManager(reg)
		wsSrv := New(a, m).WithNtfyURL("http://127.0.0.1:2586")
		srv := httptest.NewServer(wsSrv.Handler())
		t.Cleanup(func() { srv.Close(); m.Close() })

		features := capFeatures(t, srv, tok)
		got, _ := features["ntfy_url"].(string)
		if got != "http://127.0.0.1:2586" {
			t.Errorf("ntfy_url = %q, want http://127.0.0.1:2586", got)
		}
	})
}

// --- Register ---

func TestPushRegisterHappyPath(t *testing.T) {
	srv, tok, reg, _ := newTestServerWithPush(t)

	body := `{"platform":"apns","token":"mydevicetoken"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	var out struct {
		Registered bool   `json:"registered"`
		Platform   string `json:"platform"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !out.Registered || out.Platform != "apns" {
		t.Fatalf("unexpected response: %+v", out)
	}
	tokens := reg.TokensFor(pushIdentity)
	if len(tokens) != 1 || tokens[0].Token != "mydevicetoken" {
		t.Fatalf("token not in registry: %+v", tokens)
	}
}

func TestPushRegisterUnifiedPush(t *testing.T) {
	srv, tok, reg, _ := newTestServerWithPush(t)

	endpoint := "https://ntfy.example.com/push/abc"
	body := `{"platform":"unifiedpush","token":"` + endpoint + `"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp.StatusCode)
	}
	tokens := reg.TokensFor(pushIdentity)
	if len(tokens) != 1 || tokens[0].Token != endpoint || tokens[0].Platform != push.PlatformUnifiedPush {
		t.Fatalf("token not in registry: %+v", tokens)
	}
}

func TestPushRegisterInvalidPlatform(t *testing.T) {
	srv, tok, _, _ := newTestServerWithPush(t)

	body := `{"platform":"web","token":"t"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

func TestPushRegisterRequiresAuth(t *testing.T) {
	srv, _, _, _ := newTestServerWithPush(t)
	resp, err := http.Post(srv.URL+"/api/push/register", "application/json", strings.NewReader(`{"platform":"apns","token":"t"}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// --- Unregister ---

func TestPushUnregisterRemovesToken(t *testing.T) {
	srv, tok, reg, _ := newTestServerWithPush(t)

	// Register first.
	regBody := `{"platform":"apns","token":"tok1"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	_ = resp.Body.Close()

	if n := len(reg.TokensFor(pushIdentity)); n != 1 {
		t.Fatalf("expected 1 token after register, got %d", n)
	}

	// Unregister.
	unregBody := `{"platform":"apns","token":"tok1"}`
	req2, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/unregister?token="+url.QueryEscape(tok), strings.NewReader(unregBody))
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("POST unregister: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp2.StatusCode)
	}
	if n := len(reg.TokensFor(pushIdentity)); n != 0 {
		t.Fatalf("token should be removed, still have %d", n)
	}
}

// --- Test-push ---

func TestPushTestSendsToRelayAndReturns(t *testing.T) {
	srv, tok, reg, relay := newTestServerWithPush(t)

	// Register an APNs token first.
	regBody := `{"platform":"apns","token":"device123"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	_ = resp.Body.Close()

	if n := len(reg.TokensFor(pushIdentity)); n != 1 {
		t.Fatalf("expected 1 registered token, got %d", n)
	}

	// Hit test-push.
	testBody := `{"title":"Test","body":"This is a test"}`
	req2, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/test?token="+url.QueryEscape(tok), strings.NewReader(testBody))
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("POST test-push: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", resp2.StatusCode)
	}

	var out struct {
		Sent       bool `json:"sent"`
		TokenCount int  `json:"token_count"`
	}
	if err := json.NewDecoder(resp2.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !out.Sent || out.TokenCount != 1 {
		t.Fatalf("unexpected response: %+v", out)
	}

	// Relay must have received the send.
	if relay.calls != 1 {
		t.Fatalf("relay got %d calls, want 1", relay.calls)
	}
	body := relay.bodies[0]
	if body["token"] != "device123" {
		t.Errorf("relay token=%v, want device123", body["token"])
	}
	payload, _ := body["payload"].(map[string]any)
	if payload == nil || payload["title"] != "Test" {
		t.Errorf("relay payload=%v", payload)
	}
}

func TestPushTestRelay410PrunesToken(t *testing.T) {
	srv, tok, reg, relay := newTestServerWithPush(t)
	relay.status = http.StatusGone // relay will report token as gone

	// Register an APNs token.
	regBody := `{"platform":"apns","token":"deadtoken"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(regBody))
	req.Header.Set("Content-Type", "application/json")
	resp, _ := http.DefaultClient.Do(req)
	_ = resp.Body.Close()

	// Hit test-push — the 410 from the relay should prune the token.
	testBody := `{}`
	req2, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/test?token="+url.QueryEscape(tok), strings.NewReader(testBody))
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("POST test-push: %v", err)
	}
	defer resp2.Body.Close()

	// After a 410, the dispatcher prunes and returns no error → 200.
	if resp2.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, expected 200 (token gone is handled by pruning)", resp2.StatusCode)
	}

	// Token must be pruned from registry.
	if n := len(reg.TokensFor(pushIdentity)); n != 0 {
		t.Fatalf("gone token not pruned, registry still has %d tokens", n)
	}
}

func TestPushTestRequiresAuth(t *testing.T) {
	srv, _, _, _ := newTestServerWithPush(t)
	resp, err := http.Post(srv.URL+"/api/push/test", "application/json", strings.NewReader(`{}`))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// ---- Live Activity registration tests ----

// TestLARegisterHappyPath verifies that platform="apns-liveactivity" + session_id
// stores the token in the LARegistry and does NOT touch the alert registry.
func TestLARegisterHappyPath(t *testing.T) {
	srv, tok, alertReg, laReg, _ := newTestServerWithPushAndLA(t)

	body := `{"platform":"apns-liveactivity","token":"la-tok-123","session_id":"sess-abc"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register LA: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}

	var out struct {
		Registered bool   `json:"registered"`
		Platform   string `json:"platform"`
		SessionID  string `json:"session_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !out.Registered || out.Platform != "apns-liveactivity" || out.SessionID != "sess-abc" {
		t.Fatalf("unexpected response: %+v", out)
	}

	// LA token must be in the LA registry under the session.
	if got := laReg.GetLA(pushIdentity, "sess-abc"); got != "la-tok-123" {
		t.Errorf("LA token = %q, want la-tok-123", got)
	}

	// Alert registry must be unaffected.
	if n := len(alertReg.TokensFor(pushIdentity)); n != 0 {
		t.Errorf("alert registry should be empty, got %d tokens", n)
	}
}

// TestLARegisterReplacesOnReregister verifies that re-registering the same session
// replaces the previous LA token (replace-on-update semantics).
func TestLARegisterReplacesOnReregister(t *testing.T) {
	srv, tok, _, laReg, _ := newTestServerWithPushAndLA(t)

	doReg := func(token string) {
		body := `{"platform":"apns-liveactivity","token":"` + token + `","session_id":"sess-repl"}`
		req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			t.Fatalf("POST register: %v", err)
		}
		resp.Body.Close()
	}

	doReg("tok-v1")
	if got := laReg.GetLA(pushIdentity, "sess-repl"); got != "tok-v1" {
		t.Fatalf("after first register: %q, want tok-v1", got)
	}
	doReg("tok-v2")
	if got := laReg.GetLA(pushIdentity, "sess-repl"); got != "tok-v2" {
		t.Fatalf("after second register: %q, want tok-v2", got)
	}
}

// TestLARegisterMissingSessionID returns 400 when session_id is absent.
func TestLARegisterMissingSessionID(t *testing.T) {
	srv, tok, _, _, _ := newTestServerWithPushAndLA(t)

	body := `{"platform":"apns-liveactivity","token":"la-tok"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// TestLARegisterAlertPathUnchanged verifies that existing alert registrations
// (platform="apns") continue working when the LA registry is also wired.
func TestLARegisterAlertPathUnchanged(t *testing.T) {
	srv, tok, alertReg, laReg, _ := newTestServerWithPushAndLA(t)

	body := `{"platform":"apns","token":"alert-tok-xyz"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/push/register?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST register: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status=%d, want 200", resp.StatusCode)
	}

	// Alert token in the alert registry.
	toks := alertReg.TokensFor(pushIdentity)
	if len(toks) != 1 || toks[0].Token != "alert-tok-xyz" {
		t.Fatalf("alert token not in registry: %+v", toks)
	}
	// LA registry untouched.
	if got := laReg.GetLA(pushIdentity, ""); got != "" {
		t.Errorf("LA registry should be empty, got %q", got)
	}
}
