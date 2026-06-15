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
	// Mirrors the CONDUIT_TOKEN code path in cmd/conduit-broker/main.go:
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
	// All of these are under the 24-char floor (the last is 23 chars).
	for _, tok := range []string{"", "x", "short", "0123456789012345", "01234567890123456789012"} {
		if s.Adopt(tok) {
			t.Fatalf("Adopt accepted too-short token: %q (len=%d)", tok, len(tok))
		}
	}
	// Boundary: 24 chars exactly should be accepted.
	twentyFour := "012345678901234567890123"
	if len(twentyFour) != 24 {
		t.Fatalf("test fixture not 24 chars: len=%d", len(twentyFour))
	}
	if !s.Adopt(twentyFour) {
		t.Fatal("Adopt rejected a 24-char token; min is 24")
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
