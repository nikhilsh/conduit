package ws

import (
	"encoding/json"
	"net/http"
	"net/url"
	"strings"
	"testing"
)

// TestApprovalResolveRequiresAuth verifies that the endpoint returns 401
// without a valid bearer token.
func TestApprovalResolveRequiresAuth(t *testing.T) {
	srv, _ := newTestServer(t)
	body := `{"session_id":"any","decision":"approve"}`
	resp, err := http.Post(srv.URL+"/api/session/approval", "application/json", strings.NewReader(body))
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("expected 401, got %d", resp.StatusCode)
	}
}

// TestApprovalResolveBadBody verifies that malformed JSON returns 400.
func TestApprovalResolveBadBody(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), strings.NewReader(`{not json}`))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// TestApprovalResolveMissingSessionID verifies that a missing session_id
// returns 400.
func TestApprovalResolveMissingSessionID(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"decision":"approve"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
}

// TestApprovalResolveInvalidDecision verifies that a decision value other than
// "approve" or "deny" returns 400.
func TestApprovalResolveInvalidDecision(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"session_id":"abc","decision":"yes"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("expected 400, got %d", resp.StatusCode)
	}
	var out struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if out.Error.Code != "invalid_decision" {
		t.Errorf("error code = %q, want invalid_decision", out.Error.Code)
	}
}

// TestApprovalResolveUnknownSession verifies that a session that doesn't exist
// returns 404 with code "no_pending_approval".
func TestApprovalResolveUnknownSession(t *testing.T) {
	srv, tok := newTestServer(t)
	body := `{"session_id":"no-such-session","decision":"approve"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST: %v", err)
	}
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
	if out.Error.Code != "no_pending_approval" {
		t.Errorf("error code = %q, want no_pending_approval", out.Error.Code)
	}
}

// TestApprovalResolveNothingPending verifies that a live session with no pending
// approval returns 404 (idempotence: a second resolve after the first should be
// a 404, not a double-submit).
func TestApprovalResolveNothingPending(t *testing.T) {
	srv, tok := newTestServer(t)

	// Create a real session.
	startBody := `{"assistant":"claude"}`
	req, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/start?token="+url.QueryEscape(tok), strings.NewReader(startBody))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("session start: %v", err)
	}
	var start struct {
		SessionID string `json:"session_id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&start); err != nil {
		t.Fatalf("decode start: %v", err)
	}
	_ = resp.Body.Close()
	if start.SessionID == "" {
		t.Fatal("no session id")
	}

	// Try to resolve an approval — nothing is pending, so expect 404.
	approvalBody := `{"session_id":"` + start.SessionID + `","decision":"approve"}`
	req2, _ := http.NewRequest(http.MethodPost, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), strings.NewReader(approvalBody))
	req2.Header.Set("Content-Type", "application/json")
	resp2, err := http.DefaultClient.Do(req2)
	if err != nil {
		t.Fatalf("POST approval: %v", err)
	}
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusNotFound {
		t.Fatalf("expected 404 (nothing pending), got %d", resp2.StatusCode)
	}
}

// TestApprovalResolveMethodNotAllowed verifies that GET on the approval endpoint
// returns 405.
func TestApprovalResolveMethodNotAllowed(t *testing.T) {
	srv, tok := newTestServer(t)
	req, _ := http.NewRequest(http.MethodGet, srv.URL+"/api/session/approval?token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("expected 405, got %d", resp.StatusCode)
	}
}
