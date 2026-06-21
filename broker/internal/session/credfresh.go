package session

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Credential freshness plumbing for the per-session ephemeral HOME.
//
// Anthropic rotates the OAuth refresh token on every refresh, so each
// copied `.credentials.json` is a forked lineage: whichever holder
// refreshes first consumes the shared refresh token and every other
// copy dies with "401 Invalid authentication credentials" at its next
// refresh. On a box where the operator also runs claude directly, the
// host login wins that race constantly — so both the app-pushed
// credStore blob and every session's private copy rot within hours
// while `~/.claude/.credentials.json` stays perpetually fresh.
//
// Two defenses, both keyed on the expiry timestamp embedded in the
// credential blob:
//
//  1. Spawn time (manager.go): an app-pushed blob that is already
//     expired loses to a fresher host login instead of being
//     materialized verbatim (useHostOverAppBlob).
//  2. Watchdog tick (watchdog.go): a live session whose private copy
//     has expired gets the host file re-mirrored — but only when the
//     host copy is strictly fresher, so a copy the session's own agent
//     refreshed successfully is never clobbered
//     (refreshStaleAgentCredentials).
//
// A still-valid app blob is always honored even when the host login is
// fresher: the phone may be signed into a different account than the
// box on purpose.

// credentialExpirySlack is how close to (or past) expiry a credential
// must be before we consider replacing it. Mirrors the 30s guard in
// readClaudeOAuthToken but wider, since the replacement path is cheap
// and the failure mode (an agent stuck on 401) is expensive.
const credentialExpirySlack = 2 * time.Minute

// credentialExpiryMillis extracts a comparable expiry (epoch ms) from a
// provider-native credential blob:
//
//   - anthropic → `claudeAiOauth.expiresAt` (already epoch ms)
//   - openai    → the `exp` claim of `tokens.access_token` (JWT,
//     unverified decode — ordering metadata only, never an auth
//     decision), falling back to `last_refresh` when the token has no
//     parseable exp. Both orderings agree on "newer is fresher".
//
// ok=false means the blob carries no usable expiry (malformed JSON,
// missing fields); callers treat that as "assume stale".
func credentialExpiryMillis(provider string, data []byte) (int64, bool) {
	switch provider {
	case "anthropic":
		var blob struct {
			ClaudeAiOauth struct {
				ExpiresAt int64 `json:"expiresAt"`
			} `json:"claudeAiOauth"`
		}
		if json.Unmarshal(data, &blob) != nil || blob.ClaudeAiOauth.ExpiresAt <= 0 {
			return 0, false
		}
		return blob.ClaudeAiOauth.ExpiresAt, true
	case "openai":
		var blob struct {
			Tokens struct {
				AccessToken string `json:"access_token"`
			} `json:"tokens"`
			LastRefresh string `json:"last_refresh"`
		}
		if json.Unmarshal(data, &blob) != nil {
			return 0, false
		}
		if exp, ok := jwtExpiryMillis(blob.Tokens.AccessToken); ok {
			return exp, true
		}
		if t, err := time.Parse(time.RFC3339Nano, blob.LastRefresh); err == nil {
			return t.UnixMilli(), true
		}
		return 0, false
	default:
		return 0, false
	}
}

// jwtExpiryMillis reads the `exp` claim (epoch seconds) out of a JWT
// payload without verifying the signature — display/ordering metadata
// only, same trust posture as the apps' plan-badge decode.
func jwtExpiryMillis(token string) (int64, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return 0, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return 0, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Exp <= 0 {
		return 0, false
	}
	return claims.Exp * 1000, true
}

// hostCredentialFile is the host-login counterpart of the file
// credentials.Materialize writes into the ephemeral HOME. "" when the
// provider is unknown or the host home can't be resolved.
func hostCredentialFile(provider string) string {
	host := hostHomeDir()
	if host == "" {
		return ""
	}
	switch provider {
	case "anthropic":
		return filepath.Join(host, ".claude", ".credentials.json")
	case "openai":
		return filepath.Join(host, ".codex", "auth.json")
	default:
		return ""
	}
}

// sessionCredentialFile is where the session's private credential copy
// lives inside the ephemeral HOME (same path Materialize and
// mirrorHostCredentials write).
func sessionCredentialFile(provider, ephemeralHome string) string {
	switch provider {
	case "anthropic":
		return filepath.Join(ephemeralHome, ".claude", ".credentials.json")
	case "openai":
		return filepath.Join(ephemeralHome, ".codex", "auth.json")
	default:
		return ""
	}
}

// useHostOverAppBlob decides at spawn whether the app-pushed OAuth blob
// should be skipped in favour of mirroring the host login: only when
// the blob is expired (or carries no parseable expiry) AND the host
// file is strictly fresher. A valid blob always wins — it may be a
// deliberately different account than the box login.
func useHostOverAppBlob(provider string, blob []byte) (skip bool, blobExp, hostExp int64) {
	blobExp, blobOK := credentialExpiryMillis(provider, blob)
	if blobOK && blobExp > time.Now().Add(credentialExpirySlack).UnixMilli() {
		return false, blobExp, 0
	}
	hostData, err := os.ReadFile(hostCredentialFile(provider))
	if err != nil {
		return false, blobExp, 0
	}
	hostExp, hostOK := credentialExpiryMillis(provider, hostData)
	if !hostOK || hostExp <= blobExp {
		return false, blobExp, hostExp
	}
	return true, blobExp, hostExp
}

// refreshStaleAgentCredentials re-mirrors the host credential file over
// the session's private copy once the copy has expired. Also handles
// the "app blob arrived after spawn" case: if the session's credential
// file is absent and the store now has a blob, materialize it. Called
// from the watchdog tick, so the account-usage / quick-reply / title
// fetchers (which re-read the file per call) heal within one tick; the
// long-lived chat/PTY agent picks the fresh copy up at its next spawn.
// No-op unless the host copy is strictly fresher — a copy the agent
// refreshed itself is the newest lineage and must not be clobbered.
func (s *Session) refreshStaleAgentCredentials() {
	home, provider := s.agentHomeDir, s.agentCredProvider
	if home == "" || provider == "" {
		return
	}
	path := sessionCredentialFile(provider, home)
	copyData, err := os.ReadFile(path)
	if err != nil {
		// No credential file in the session's ephemeral HOME. Two cases:
		//   a) Spawn had no credential at all (agent will prompt /login) —
		//      nothing to do, spawn already made that call.
		//   b) App pushed a credential blob AFTER this session spawned —
		//      the watchdog is our only chance to materialize it in time.
		// Distinguish by checking the store: if a blob now exists, write
		// it in so the next turn (and any live fetchers) picks it up.
		if s.agentCredStore != nil && s.agentCredStore.Has(provider) {
			if err := s.agentCredStore.Materialize(provider, home); err != nil {
				fmt.Fprintf(os.Stderr, "session %s: watchdog re-materialize %s credentials: %v\n", s.ID, provider, err)
				return
			}
			log.Printf("session %s: watchdog materialized app %s credential into session that spawned without one", s.ID, provider)
		}
		return
	}
	copyExp, copyOK := credentialExpiryMillis(provider, copyData)
	if copyOK && copyExp > time.Now().Add(credentialExpirySlack).UnixMilli() {
		return // copy still valid
	}
	hostData, err := os.ReadFile(hostCredentialFile(provider))
	if err != nil {
		return
	}
	hostExp, hostOK := credentialExpiryMillis(provider, hostData)
	if !hostOK || hostExp <= copyExp {
		return
	}
	if err := atomicWriteFileMode(path, hostData, 0o600); err != nil {
		fmt.Fprintf(os.Stderr, "session %s: re-mirror %s credentials: %v\n", s.ID, provider, err)
		return
	}
	log.Printf("session %s: re-mirrored fresher host %s credentials (copy expiry %d → host expiry %d)", s.ID, provider, copyExp, hostExp)
}
