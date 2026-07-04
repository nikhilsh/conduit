package ws

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

func postPeerMessage(t *testing.T, srv string, tok string, body string) *http.Response {
	t.Helper()
	u := srv + "/api/session/message"
	if tok != "" {
		u += "?token=" + url.QueryEscape(tok)
	}
	req, _ := http.NewRequest(http.MethodPost, u, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	return resp
}

// TestPeerMessageRequiresAuth: 401 without a valid bearer token.
func TestPeerMessageRequiresAuth(t *testing.T) {
	srv, _ := newTestServer(t)
	resp := postPeerMessage(t, srv.URL, "", `{"session_id":"any","message":"hi"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// TestPeerMessageBadBody: malformed JSON returns 400.
func TestPeerMessageBadBody(t *testing.T) {
	srv, tok := newTestServer(t)
	resp := postPeerMessage(t, srv.URL, tok, `{not json}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// TestPeerMessageMissingFields: session_id and message are both required.
func TestPeerMessageMissingFields(t *testing.T) {
	srv, tok := newTestServer(t)
	for _, body := range []string{
		`{"message":"hi"}`,
		`{"session_id":"abc"}`,
		`{"session_id":"abc","message":"   "}`,
	} {
		resp := postPeerMessage(t, srv.URL, tok, body)
		if resp.StatusCode != http.StatusBadRequest {
			t.Errorf("body %s: expected 400, got %d", body, resp.StatusCode)
		}
		resp.Body.Close()
	}
}

// TestPeerMessageSelfSend: a session cannot message itself.
func TestPeerMessageSelfSend(t *testing.T) {
	srv, tok := newTestServer(t)
	resp := postPeerMessage(t, srv.URL, tok, `{"session_id":"abc","message":"hi","from_session_id":"abc"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// TestPeerMessageUnknownSession: only LIVE sessions are addressable — an
// unknown (or recoverable) recipient is a 404, never a wake.
func TestPeerMessageUnknownSession(t *testing.T) {
	srv, tok := newTestServer(t)
	resp := postPeerMessage(t, srv.URL, tok, `{"session_id":"nope","message":"hi"}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", resp.StatusCode)
	}
	var out struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Error.Code != "session_not_found" {
		t.Fatalf("expected session_not_found, got %q", out.Error.Code)
	}
}
