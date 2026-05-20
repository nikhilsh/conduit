// Package auth provides bearer-token validation for the harness HTTP/WS
// surface. The token table is in-memory; a single token is minted at
// startup and printed to stdout (later: rendered as a QR by main).
package auth

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"net/http"
	"strings"
	"sync"
)

type Store struct {
	mu     sync.RWMutex
	tokens map[string]struct{}
}

func NewStore() *Store {
	return &Store{tokens: make(map[string]struct{})}
}

// Mint generates a 32-byte URL-safe token, stores it, and returns it.
func (s *Store) Mint() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	tok := base64.RawURLEncoding.EncodeToString(b)
	s.Adopt(tok)
	return tok
}

// Adopt stores a caller-supplied token. Used when an upstream
// orchestrator (e.g. the mobile app's SSH-bootstrap path) wants to
// pre-allocate the bearer so it doesn't have to scrape it back out
// of the harness's stdout. Empty / overly-short tokens are rejected.
func (s *Store) Adopt(token string) bool {
	if len(token) < 16 {
		return false
	}
	s.mu.Lock()
	s.tokens[token] = struct{}{}
	s.mu.Unlock()
	return true
}

// Check returns true iff the Authorization header carries a valid bearer
// token. Uses constant-time comparison against every stored token.
func (s *Store) Check(r *http.Request) bool {
	authz := r.Header.Get("Authorization")
	if authz == "" {
		// Browsers can't always set headers on the WS handshake; accept ?token=
		authz = "Bearer " + r.URL.Query().Get("token")
	}
	const prefix = "Bearer "
	if !strings.HasPrefix(authz, prefix) {
		return false
	}
	got := []byte(strings.TrimPrefix(authz, prefix))
	s.mu.RLock()
	defer s.mu.RUnlock()
	for tok := range s.tokens {
		if subtle.ConstantTimeCompare(got, []byte(tok)) == 1 {
			return true
		}
	}
	return false
}
