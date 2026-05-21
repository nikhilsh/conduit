package auth

import (
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestMintProducesValidToken(t *testing.T) {
	s := NewStore()
	tok := s.Mint()
	if len(tok) < 16 {
		t.Fatalf("minted token too short: %q (len=%d)", tok, len(tok))
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	if !s.Check(req) {
		t.Fatal("freshly minted token did not Check")
	}
}

func TestAdoptHonoursCallerSuppliedToken(t *testing.T) {
	// Mirrors the SWE_KITTY_TOKEN code path in cmd/swe-kitty-broker/main.go:
	// an upstream orchestrator (the mobile SSH-bootstrap) picks the bearer
	// so it doesn't have to scrape it back out of `docker logs`.
	s := NewStore()
	chosen := "this-is-a-pre-allocated-token-1234"
	if !s.Adopt(chosen) {
		t.Fatal("Adopt rejected a 33-char token; should have accepted")
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+chosen)
	if !s.Check(req) {
		t.Fatal("adopted token did not Check")
	}
}

func TestAdoptRejectsShortTokens(t *testing.T) {
	s := NewStore()
	for _, tok := range []string{"", "x", "short", "012345678901234"} { // last is 15 chars
		if s.Adopt(tok) {
			t.Fatalf("Adopt accepted too-short token: %q (len=%d)", tok, len(tok))
		}
	}
	// Boundary: 16 chars exactly should be accepted.
	if !s.Adopt("0123456789012345") {
		t.Fatal("Adopt rejected a 16-char token; min was 16")
	}
}

func TestAdoptIsIdempotent(t *testing.T) {
	s := NewStore()
	tok := "stable-token-abcdef-1234567890"
	if !s.Adopt(tok) {
		t.Fatal("Adopt rejected fresh token")
	}
	if !s.Adopt(tok) {
		t.Fatal("Adopt should be idempotent on the same input")
	}
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	if !s.Check(req) {
		t.Fatal("token still Check after double Adopt")
	}
}

func TestCheckHonoursTokenQueryParam(t *testing.T) {
	// Browsers can't always set headers on the WS handshake — the harness
	// accepts ?token= as a fallback. Make sure Adopt-ed tokens flow there.
	s := NewStore()
	tok := "query-flow-token-1234567890"
	s.Adopt(tok)
	req := httptest.NewRequest(http.MethodGet, "/ws/abc?token="+tok, nil)
	if !s.Check(req) {
		t.Fatal("query-param auth failed for adopted token")
	}
}
