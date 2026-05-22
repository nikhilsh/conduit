package replay

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// helper to build a server with a temp base dir and a sample recording.
func newTestServer(t *testing.T) (*Server, string) {
	t.Helper()
	dir := t.TempDir()
	rec, err := NewRecorder("abc123", dir)
	if err != nil {
		t.Fatalf("NewRecorder: %v", err)
	}
	rec.RecordBytes([]byte("hello"), time.Unix(0, 0))
	rec.RecordEvent("chat", map[string]any{"role": "assistant", "content": "hi"}, time.Unix(1, 0))
	if err := rec.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	return NewServer(dir, []byte("test-secret-1234567890")), dir
}

func TestServerRejectsMissingToken(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/replay/abc123", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401 (body=%q)", rec.Code, rec.Body.String())
	}
}

func TestServerRejectsBadToken(t *testing.T) {
	srv, _ := newTestServer(t)
	req := httptest.NewRequest(http.MethodGet, "/replay/abc123?t=deadbeefdeadbeefdeadbeefdeadbeef", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("status=%d want 401", rec.Code)
	}
}

func TestServerServesHTMLWithToken(t *testing.T) {
	srv, _ := newTestServer(t)
	tok := srv.Token("abc123")
	req := httptest.NewRequest(http.MethodGet, "/replay/abc123?t="+tok, nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d want 200 (body=%q)", rec.Code, rec.Body.String())
	}
	body := rec.Body.String()
	if !strings.Contains(body, "swe-kitty replay") {
		t.Fatalf("body missing title (got %q)", body[:min(120, len(body))])
	}
	// Embedded JSON config must contain session id + timeline URL
	// with the token already baked in.
	if !strings.Contains(body, `"session_id":"abc123"`) {
		t.Fatalf("body missing embedded session id JSON")
	}
	if !strings.Contains(body, "/replay/abc123/timeline.json?t="+tok) {
		t.Fatalf("body missing timeline URL")
	}
	// xterm.js loaded from a CDN — see audit "binary-size delta" note.
	if !strings.Contains(body, "xterm@5.3.0") {
		t.Fatalf("body missing xterm.js CDN reference")
	}
}

func TestServerServesTimelineWithToken(t *testing.T) {
	srv, _ := newTestServer(t)
	tok := srv.Token("abc123")
	req := httptest.NewRequest(http.MethodGet, "/replay/abc123/timeline.json?t="+tok, nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusOK {
		t.Fatalf("status=%d want 200", rec.Code)
	}
	ct := rec.Header().Get("Content-Type")
	if !strings.Contains(ct, "application/x-ndjson") {
		t.Fatalf("content-type=%q want application/x-ndjson", ct)
	}
	body := rec.Body.String()
	if !strings.Contains(body, `"kind":"pty"`) || !strings.Contains(body, `"kind":"view_event"`) {
		t.Fatalf("timeline body missing expected lines: %q", body)
	}
}

func TestServerMissingRecording(t *testing.T) {
	srv, _ := newTestServer(t)
	tok := srv.Token("not-there")
	req := httptest.NewRequest(http.MethodGet, "/replay/not-there/timeline.json?t="+tok, nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code != http.StatusNotFound {
		t.Fatalf("status=%d want 404", rec.Code)
	}
}

func TestServerRejectsPathTraversal(t *testing.T) {
	dir := t.TempDir()
	// Drop a file outside the per-session subdir to make sure the
	// safety check doesn't allow `..` to reach it.
	if err := os.WriteFile(filepath.Join(dir, "secret.txt"), []byte("nope"), 0o600); err != nil {
		t.Fatalf("seed: %v", err)
	}
	srv := NewServer(dir, []byte("test-secret-1234567890"))
	// `..` has a slash → split takes the first segment which contains
	// `..` and fails the safe-id check. Either way we never want a
	// 200 here.
	req := httptest.NewRequest(http.MethodGet, "/replay/..%2Fsecret.txt?t=x", nil)
	rec := httptest.NewRecorder()
	srv.Handler().ServeHTTP(rec, req)
	if rec.Code == http.StatusOK {
		t.Fatalf("path traversal slipped through: body=%q", rec.Body.String())
	}
}

func TestServerTokenDeterministic(t *testing.T) {
	srv := NewServer("", []byte("s"))
	// Bind both calls to vars so staticcheck SA4000 doesn't flag the
	// idempotency check as "identical expressions". We genuinely
	// want to confirm two calls return the same token.
	a1 := srv.Token("a")
	a2 := srv.Token("a")
	if a1 != a2 {
		t.Fatal("token not deterministic")
	}
	if srv.Token("a") == srv.Token("b") {
		t.Fatal("token collides across session ids")
	}
}
