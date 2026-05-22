package ws

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/broker/internal/auth"
	"github.com/nikhilsh/swe-kitty/broker/internal/credentials"
	"github.com/nikhilsh/swe-kitty/broker/internal/session"
)

// newTestServerWithCredentials mints a Server with a per-test
// credentials store wired in. The store is rooted under t.TempDir() so
// the on-disk shape stays isolated from other tests in the package.
// Returns the credentials store directly too so tests can assert on
// what the broker wrote.
func newTestServerWithCredentials(t *testing.T) (*httptest.Server, string, *credentials.Store) {
	t.Helper()
	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	cs := credentials.NewStore(t.TempDir(), []byte(tok))
	wsSrv := New(a, m).WithCredentials(cs)
	srv := httptest.NewServer(wsSrv.Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok, cs
}

// readCredentialsViewEvent drains text frames until it sees a
// `view_event` frame related to set_agent_credentials (either the
// success-side `agent_credentials_refreshed` mirror or the chat-tool
// rejection emitted with tool_name=set_agent_credentials). Other
// view_event frames — the connect-time viewer status mirror, for
// instance — are skipped so callers can assert on the one they care
// about without ordering brittleness.
func readCredentialsViewEvent(t *testing.T, c *websocket.Conn) map[string]any {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		mt, payload, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if mt != websocket.TextMessage {
			continue
		}
		var env map[string]any
		if err := json.Unmarshal(payload, &env); err != nil {
			continue
		}
		if env["type"] != "view_event" {
			continue
		}
		event, _ := env["event"].(map[string]any)
		if event == nil {
			continue
		}
		if _, ok := event["agent_credentials_refreshed"]; ok {
			return env
		}
		if tn, _ := event["tool_name"].(string); tn == "set_agent_credentials" {
			return env
		}
	}
	t.Fatal("did not observe a credentials view_event frame before deadline")
	return nil
}

// TestSetAgentCredentialsHappyPath: a well-formed control message
// stores the encrypted blob on disk AND broadcasts the typed
// `view: "status"` view_event whose event carries
// `agent_credentials_refreshed.provider`. Per docs/PLAN-AGENT-OAUTH.md
// §D.1 this is the wire-level success signal the phone watches for.
func TestSetAgentCredentialsHappyPath(t *testing.T) {
	srv, tok, cs := newTestServerWithCredentials(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c1", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage() // initial status

	blob := json.RawMessage(`{"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def","expiresAt":1700000000000}}`)
	env := map[string]any{
		"type":       "set_agent_credentials",
		"provider":   "anthropic",
		"kind":       "oauth",
		"credential": blob,
	}
	payload, err := json.Marshal(env)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	got := readCredentialsViewEvent(t, c)
	if got["view"] != "status" {
		t.Fatalf("view: want status, got %v", got["view"])
	}
	event, _ := got["event"].(map[string]any)
	refresh, _ := event["agent_credentials_refreshed"].(map[string]any)
	if refresh["provider"] != "anthropic" {
		t.Fatalf("provider: want anthropic, got %v", refresh["provider"])
	}

	// And the credential store actually has the blob, round-trippable.
	stored, err := cs.Get("anthropic")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if string(stored) != string(blob) {
		t.Fatalf("stored blob: want %s, got %s", string(blob), string(stored))
	}
}

// TestSetAgentCredentialsRejectsUnknownProvider: a control message
// with provider=foo (anything not in the {anthropic, openai} allowlist)
// gets a chat-tool error event AND the credential store stays empty.
// Importantly: the socket stays open and a follow-up ping still pongs.
func TestSetAgentCredentialsRejectsUnknownProvider(t *testing.T) {
	srv, tok, cs := newTestServerWithCredentials(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c2", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage() // initial status

	env := map[string]any{
		"type":       "set_agent_credentials",
		"provider":   "gemini",
		"kind":       "oauth",
		"credential": json.RawMessage(`{"x":1}`),
	}
	payload, _ := json.Marshal(env)
	if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	got := readCredentialsViewEvent(t, c)
	if got["view"] != "chat" {
		t.Fatalf("view: want chat, got %v", got["view"])
	}
	event, _ := got["event"].(map[string]any)
	if event["role"] != "tool" {
		t.Fatalf("role: want tool, got %v", event["role"])
	}
	content, _ := event["content"].(string)
	if !strings.Contains(content, "unknown provider") {
		t.Fatalf("content: want 'unknown provider' substring, got %q", content)
	}

	if cs.Has("gemini") {
		t.Fatalf("store should not have a 'gemini' entry after a rejection")
	}
	if cs.Has("anthropic") || cs.Has("openai") {
		t.Fatalf("store leaked the rejected payload into a known provider")
	}

	// Socket survival: ping/pong must still round-trip.
	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatalf("write ping: %v", err)
	}
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		mt, b, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("read after invalid: %v", err)
		}
		if mt != websocket.TextMessage {
			continue
		}
		var got map[string]any
		if err := json.Unmarshal(b, &got); err != nil {
			continue
		}
		if got["type"] == "pong" {
			return
		}
	}
	t.Fatal("did not observe pong after invalid credential message")
}

// TestSetAgentCredentialsRejectsUnsupportedKind: Stage 1 only
// understands `kind: "oauth"`. Anything else (e.g. "api_key") is
// rejected with a chat-tool error so future protocol revs can extend
// without surprising the broker.
func TestSetAgentCredentialsRejectsUnsupportedKind(t *testing.T) {
	srv, tok, cs := newTestServerWithCredentials(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c3", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	env := map[string]any{
		"type":       "set_agent_credentials",
		"provider":   "anthropic",
		"kind":       "api_key",
		"credential": json.RawMessage(`{"x":1}`),
	}
	payload, _ := json.Marshal(env)
	if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	got := readCredentialsViewEvent(t, c)
	event, _ := got["event"].(map[string]any)
	content, _ := event["content"].(string)
	if !strings.Contains(content, "unsupported kind") {
		t.Fatalf("content: want 'unsupported kind' substring, got %q", content)
	}
	if cs.Has("anthropic") {
		t.Fatalf("store should not have anthropic credential after kind rejection")
	}
}

// TestSetAgentCredentialsRequiresAuth: the WS upgrade itself is
// bearer-gated, so an unauthenticated dial never reaches the
// set_agent_credentials handler. Re-asserts the property for the
// per-user OAuth path so a future refactor that loosens auth on the
// upgrade also has to delete this test.
func TestSetAgentCredentialsRequiresAuth(t *testing.T) {
	srv, _, _ := newTestServerWithCredentials(t)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws/00000000-0000-0000-0000-0000000000c4?assistant=claude"
	_, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Fatal("expected dial to fail without token")
	}
	if resp == nil || resp.StatusCode != 401 {
		t.Fatalf("expected 401, got %v", resp)
	}
}

// TestSetAgentCredentialsNoStoreConfigured: a broker started without a
// credentials store (the default until --credentials-dir lands in
// production) must surface a chat-tool error rather than panic when a
// client sends set_agent_credentials.
func TestSetAgentCredentialsNoStoreConfigured(t *testing.T) {
	// newTestServer (from conformance_test.go) doesn't wire a credentials
	// store, so this is the "broker started without --credentials-dir"
	// shape on the wire.
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c5", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	env := map[string]any{
		"type":       "set_agent_credentials",
		"provider":   "anthropic",
		"kind":       "oauth",
		"credential": json.RawMessage(`{"x":1}`),
	}
	payload, _ := json.Marshal(env)
	if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
		t.Fatalf("write: %v", err)
	}

	got := readCredentialsViewEvent(t, c)
	event, _ := got["event"].(map[string]any)
	content, _ := event["content"].(string)
	if !strings.Contains(content, "no credentials store") {
		t.Fatalf("content: want 'no credentials store' substring, got %q", content)
	}
}
