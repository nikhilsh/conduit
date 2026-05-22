// Package oauth implements the broker side of the v2 agent-login flow
// described in docs/PLAN-AGENT-OAUTH.md "Approach v2 — litter-faithful
// server-side login".
//
// The package owns the lifecycle of an active CLI login subprocess —
// `codex login` or `claude auth login` — running on the broker host.
// It captures the authorize URL printed on the CLI's stdout, extracts
// the loopback port the CLI bound (it is the broker, not the phone,
// that opens this port — the provider's `redirect_uri` whitelist
// points at it), and exposes a Forward method that ferries the phone's
// captured `?code=...&state=...` query string to the CLI's own
// localhost listener.
//
// What this package does NOT do:
//   - perform any token exchange — the CLI's own /login server does
//     that and writes ~/.codex/auth.json (or
//     ~/.claude/.credentials.json) directly on the broker filesystem.
//     The credentials package (see broker/internal/credentials) picks
//     up the on-disk file for per-session materialization (PR #106).
//   - present any UI — that's the phone's job. The broker emits a
//     `view_event` carrying { url, loopback_port, session_token }
//     and waits for the phone to call back.
//   - bind any network port itself — the CLI does its own binding;
//     the broker only Dials its own localhost to ferry the callback.
//
// Stage 0 scope (this file): codex CLI happy path + table-tested
// stdout parser + port detection. The `claude auth login` branch
// (which may not use a loopback at all, see PLAN §K) is a Stage 2
// follow-up; the Provider abstraction below is the seam.
package oauth

import (
	"bufio"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// Provider names — mirror credentials.ValidProvider. Kept as plain
// strings (not an enum-style type) so the WS layer can pass them
// through without a translation layer.
const (
	ProviderOpenAI    = "openai"
	ProviderAnthropic = "anthropic"
)

// loginTimeout is how long the broker keeps the CLI subprocess alive
// waiting for a `agent_login_callback`. 10 min mirrors litter's own
// callback timeout and the codex CLI's empirical patience window.
const loginTimeout = 10 * time.Minute

// Session is one active login attempt. Created by Start, advanced by
// Forward (when the phone sends the callback query string), torn down
// by Cancel or by the CLI exiting on its own.
//
// Concurrency contract: Start returns after the CLI has printed the
// authorize URL (or after a parse timeout). Forward must not be called
// after Cancel. Both methods are safe to invoke once each per session.
type Session struct {
	// Provider is the OAuth provider this login is for. Today: "openai"
	// or "anthropic". Validated by Start; consumers can read it for
	// emitting the `agent_login_url` view_event.
	Provider string

	// SessionToken is a 32-byte random hex string the broker mints to
	// tie an outbound `agent_login_url` view_event to its eventual
	// inbound `agent_login_callback`. The phone echoes this back; the
	// broker rejects callbacks whose token doesn't match an active
	// session. Confused-deputy defense on shared brokers.
	SessionToken string

	// AuthorizeURL is the URL the phone must open in the user's
	// browser. Parsed verbatim out of the CLI's stdout.
	AuthorizeURL string

	// LoopbackPort is the port the CLI bound on 127.0.0.1 — extracted
	// from AuthorizeURL's `redirect_uri` query param. The broker
	// forwards the callback by Dialing this port itself; the phone
	// uses this number to know what port to bind on the device side
	// in case it wants to host its own listener (Stage 1 phone path).
	// Zero when the provider's flow doesn't use a loopback (Anthropic
	// code-paste path — see PLAN §K).
	LoopbackPort int

	cmd        *exec.Cmd
	cancelFn   context.CancelFunc
	doneCh     chan struct{}
	httpClient *http.Client

	mu       sync.Mutex
	closed   bool
	exitErr  error
}

// Provider describes how to launch a CLI's login subcommand and how
// to read its stdout. The two production providers — codex and
// claude — share the same launch shape (an exec.Cmd + a stdout-line
// scanner), so the Provider interface only abstracts the parts that
// actually differ: the executable + args, and the URL-extraction
// predicate.
type Provider interface {
	// Name returns the canonical provider identifier. Must match
	// ProviderOpenAI or ProviderAnthropic; the WS layer also compares
	// against credentials.ValidProvider before reaching here.
	Name() string

	// Command returns the executable + args to spawn. The broker
	// inherits its own $PATH so the operator's `codex` / `claude`
	// install on the broker host is what runs.
	Command() (string, []string)

	// ExtractURL scans a line of CLI stdout and returns (url, true)
	// when the line carries the authorize URL we should ship to the
	// phone. Both codex and claude print the URL on its own line; the
	// codex line starts with `https://auth.openai.com/...`.
	//
	// Returning ("", false) means "not the line we want" and the
	// scanner advances. The first matching line wins.
	ExtractURL(line string) (string, bool)
}

// codexProvider implements Provider for `codex login`. Spawns the CLI
// with no extra args — codex auto-detects the loopback port (1455
// default, 1457 fallback per codex-rs/login/src/server.rs's
// FALLBACK_PORT).
type codexProvider struct{}

func (codexProvider) Name() string { return ProviderOpenAI }

func (codexProvider) Command() (string, []string) {
	return "codex", []string{"login"}
}

func (codexProvider) ExtractURL(line string) (string, bool) {
	// codex stdout (verbatim, see PLAN §K):
	//   Starting local login server on http://localhost:1455.
	//   If your browser did not open, navigate to this URL to authenticate:
	//
	//   https://auth.openai.com/oauth/authorize?...
	//
	// The match is "first line that starts with https:// after we've
	// already seen the 'Starting local login server' line", but tying
	// the matcher to that ordering would be fragile if codex ever
	// changes its banner copy. Instead we treat any line whose
	// trimmed form is a full https:// URL pointing at the OpenAI
	// authorize endpoint as the authoritative one. This is robust to
	// banner copy changes as long as the URL itself stays canonical.
	trimmed := strings.TrimSpace(line)
	if !strings.HasPrefix(trimmed, "https://") {
		return "", false
	}
	if !strings.Contains(trimmed, "auth.openai.com/oauth/authorize") {
		return "", false
	}
	return trimmed, true
}

// claudeProvider implements Provider for `claude auth login`.
//
// Stage 0 only ships a stub — the URL-extraction predicate hasn't been
// validated end-to-end on the harness host yet (the codex one was, see
// PLAN §K), and Anthropic's flow may not use a loopback at all. The
// predicate below matches lines that look like a claude.ai authorize
// URL; the broker will surface the URL to the phone but the loopback
// port will be 0, signalling the code-paste fallback. Stage 2 will
// either replace this with a real loopback extractor or pivot to the
// `agent_login_code` paste path documented in PLAN §K.
type claudeProvider struct{}

func (claudeProvider) Name() string { return ProviderAnthropic }

func (claudeProvider) Command() (string, []string) {
	return "claude", []string{"auth", "login", "--claudeai"}
}

func (claudeProvider) ExtractURL(line string) (string, bool) {
	trimmed := strings.TrimSpace(line)
	if !strings.HasPrefix(trimmed, "https://") {
		return "", false
	}
	// Accept either claude.ai or platform.claude.com authorize URLs —
	// the CLI's exact host hasn't been pinned yet (see PLAN §K), so
	// we cast a wide net. The phone never gets to forge this URL: the
	// CLI generates it from its embedded client_id + PKCE pair.
	if !(strings.Contains(trimmed, "claude.ai/oauth") ||
		strings.Contains(trimmed, "platform.claude.com")) {
		return "", false
	}
	return trimmed, true
}

// ProviderFor returns the registered Provider for `name`, or nil if
// the broker doesn't know how to drive that provider's CLI. Callers
// (the WS layer) map the WS-message `provider` field through this and
// emit an `agent_login_failed` view_event when nil — same shape as
// the credentials.ValidProvider gate.
func ProviderFor(name string) Provider {
	switch name {
	case ProviderOpenAI:
		return codexProvider{}
	case ProviderAnthropic:
		return claudeProvider{}
	default:
		return nil
	}
}

// Start launches the CLI login subprocess and blocks until either the
// authorize URL is captured on stdout or the URL-parse timeout fires.
//
// On success the returned *Session is "live" — the CLI is still running
// in the background waiting for the loopback callback. Callers must
// eventually Forward (to deliver the phone's captured callback) or
// Cancel (on phone-side abort / disconnect). Both calls release the
// subprocess.
//
// `provider` is one of ProviderOpenAI / ProviderAnthropic. Anything
// else returns a non-nil error; the caller surfaces it as an
// `agent_login_failed` view_event.
func Start(ctx context.Context, provider string) (*Session, error) {
	p := ProviderFor(provider)
	if p == nil {
		return nil, fmt.Errorf("oauth: unknown provider %q", provider)
	}
	token, err := newSessionToken()
	if err != nil {
		return nil, fmt.Errorf("oauth: session token: %w", err)
	}

	// Use a long-lived context so the subprocess outlives Start's
	// return — the CLI keeps running until Forward or Cancel. We
	// derive a cancellation func from a fresh background context so
	// the caller's ctx scoping (the WS read deadline, for instance)
	// doesn't accidentally kill the CLI mid-flow.
	subCtx, cancelFn := context.WithTimeout(context.Background(), loginTimeout)
	exe, args := p.Command()
	cmd := exec.CommandContext(subCtx, exe, args...)

	// Sanitize the environment — strip any OPENAI_API_KEY /
	// CODEX_ACCESS_TOKEN that might be on the broker process; those
	// short-circuit `codex login`'s OAuth flow and we explicitly want
	// the OAuth path so the phone-user's tokens (not the operator's)
	// land on disk. CODEX_HOME / CLAUDE_CONFIG_DIR are passed through
	// so the operator can redirect where the credentials land.
	cmd.Env = sanitizedEnv(os.Environ())

	stdout, err := cmd.StdoutPipe()
	if err != nil {
		cancelFn()
		return nil, fmt.Errorf("oauth: stdout pipe: %w", err)
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		cancelFn()
		return nil, fmt.Errorf("oauth: stderr pipe: %w", err)
	}

	if err := cmd.Start(); err != nil {
		cancelFn()
		return nil, fmt.Errorf("oauth: start %s: %w", exe, err)
	}

	sess := &Session{
		Provider:     provider,
		SessionToken: token,
		cmd:          cmd,
		cancelFn:     cancelFn,
		doneCh:       make(chan struct{}),
		httpClient: &http.Client{
			Timeout: 30 * time.Second,
		},
	}

	// Best-effort drain on stderr — we don't parse it but we need to
	// keep the pipe drained so the child doesn't block on a full
	// stderr buffer. Discard into io.Discard; logging would be noisy.
	go func() {
		_, _ = io.Copy(io.Discard, stderr)
	}()

	// Wait the subprocess in the background so the broker learns when
	// the CLI exits (success: the token exchange completed and the CLI
	// returned; failure: the user closed the browser or the loopback
	// errored). We don't act on the exit code here — the WS layer
	// emits `agent_login_complete` { ok: true } only after Forward
	// returns success; an early exit before Forward is treated by
	// Cancel/Wait callers as an error.
	go func() {
		err := cmd.Wait()
		sess.mu.Lock()
		sess.exitErr = err
		close(sess.doneCh)
		sess.mu.Unlock()
	}()

	// Block until we either parse the authorize URL or the URL-parse
	// timeout fires. 15 seconds is generous — codex prints the URL
	// within ~100ms on a warm CLI; claude similar. We don't hold the
	// caller's ctx hostage here because the broker's WS handler
	// already had to issue the start_agent_login control message; the
	// caller blocking on Start for up to 15s mirrors a chat send.
	parseCtx, parseCancel := context.WithTimeout(ctx, 15*time.Second)
	defer parseCancel()

	urlStr, err := scanAuthorizeURL(parseCtx, p, stdout)
	if err != nil {
		// Parse failed — kill the subprocess so we don't leak a
		// listening loopback. Whatever the CLI wrote on stderr was
		// already drained to discard; surface the parse error itself.
		sess.terminate()
		return nil, fmt.Errorf("oauth: scan authorize url: %w", err)
	}
	sess.AuthorizeURL = urlStr
	sess.LoopbackPort = extractLoopbackPort(urlStr)

	return sess, nil
}

// Forward ferries the phone's captured `?code=...&state=...` query
// string to the CLI's own loopback listener. The CLI receives the
// callback exactly as if a browser on the same machine had redirected
// to it, completes the token exchange, and writes the on-disk file.
//
// The CLI's listener path is the second segment of the parsed
// AuthorizeURL's `redirect_uri` — codex uses `/auth/callback` (per
// `codex-rs/login/src/server.rs`), and the broker preserves whatever
// path the CLI advertised so future CLI changes don't break the
// forwarder.
//
// On success Forward blocks until the CLI subprocess exits (typically
// 1-2 seconds — token exchange + disk write). Returns the CLI's exit
// error, if any. On failure (CLI not listening, network error, CLI
// exited before we delivered), returns a wrapped error and leaves the
// subprocess dead (Forward implies "we're done with the session").
func (s *Session) Forward(queryString string) error {
	if s.LoopbackPort == 0 {
		// Anthropic code-paste branch — the broker doesn't have a
		// loopback to forward to. Stage 2 will replace this with the
		// `agent_login_code` ferrying path. For now we reject so the
		// WS layer doesn't silently no-op.
		return errors.New("oauth: provider has no loopback (code-paste flow not yet implemented)")
	}

	cbPath := extractCallbackPath(s.AuthorizeURL)
	if cbPath == "" {
		cbPath = "/auth/callback"
	}
	target := fmt.Sprintf("http://127.0.0.1:%d%s?%s", s.LoopbackPort, cbPath, strings.TrimPrefix(queryString, "?"))

	req, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		s.terminate()
		return fmt.Errorf("oauth: build callback request: %w", err)
	}
	resp, err := s.httpClient.Do(req)
	if err != nil {
		// The CLI's loopback should be listening — if Dial fails we
		// either raced the CLI's startup or the CLI is wedged. Either
		// way the session is dead; clean up.
		s.terminate()
		return fmt.Errorf("oauth: forward to CLI loopback: %w", err)
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	_ = resp.Body.Close()

	// Wait for the CLI to exit (token exchange + on-disk write +
	// graceful shutdown). Bounded — if the CLI hangs, we don't want
	// the WS reply to hang forever.
	waitCtx, waitCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer waitCancel()
	select {
	case <-s.doneCh:
		s.mu.Lock()
		exitErr := s.exitErr
		s.mu.Unlock()
		if exitErr != nil {
			return fmt.Errorf("oauth: CLI exited with error: %w", exitErr)
		}
		return nil
	case <-waitCtx.Done():
		s.terminate()
		return errors.New("oauth: CLI did not exit within 30s after callback")
	}
}

// Cancel kills the login subprocess. Safe to call multiple times.
// Used on phone-side abort, WS disconnect, or session-token mismatch.
func (s *Session) Cancel() {
	s.terminate()
}

// terminate is the unconditional teardown path. Idempotent.
func (s *Session) terminate() {
	s.mu.Lock()
	if s.closed {
		s.mu.Unlock()
		return
	}
	s.closed = true
	cancel := s.cancelFn
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	// Best-effort wait so we don't leak a zombie. The kill arrives
	// via the context cancellation above (exec.CommandContext sends
	// SIGKILL). A bounded wait avoids hanging the WS handler if the
	// CLI is wedged in uninterruptible state.
	select {
	case <-s.doneCh:
	case <-time.After(2 * time.Second):
	}
}

// scanAuthorizeURL reads stdout line-by-line, returning the first line
// the Provider claims as the authorize URL. Returns ctx.Err() if the
// caller's parse deadline fires before a match.
//
// Hoisted for table tests — `provider.ExtractURL` is the unit under
// test; the scanner just feeds it lines.
func scanAuthorizeURL(ctx context.Context, p Provider, stdout io.Reader) (string, error) {
	// Run the scan on a goroutine so the parse timeout can interrupt
	// it. The scanner itself doesn't accept a ctx.
	type result struct {
		url string
		err error
	}
	ch := make(chan result, 1)
	go func() {
		s := bufio.NewScanner(stdout)
		// Bump the buffer ceiling — codex's authorize URL exceeds the
		// default 64KB on some scope configurations.
		s.Buffer(make([]byte, 0, 64*1024), 1024*1024)
		for s.Scan() {
			line := s.Text()
			if url, ok := p.ExtractURL(line); ok {
				ch <- result{url: url}
				return
			}
		}
		if err := s.Err(); err != nil {
			ch <- result{err: fmt.Errorf("oauth: stdout scan: %w", err)}
			return
		}
		ch <- result{err: errors.New("oauth: stdout closed before authorize URL appeared")}
	}()
	select {
	case r := <-ch:
		return r.url, r.err
	case <-ctx.Done():
		return "", ctx.Err()
	}
}

// extractLoopbackPort pulls the port out of the authorize URL's
// `redirect_uri` query parameter. Returns 0 when the URL has no
// `redirect_uri` (Anthropic code-paste flow) or when the embedded
// host isn't a localhost loopback (defensive — we never want to
// trigger forward Dials at a remote host).
//
// Hoisted for table tests.
func extractLoopbackPort(authorizeURL string) int {
	u, err := url.Parse(authorizeURL)
	if err != nil {
		return 0
	}
	redirect := u.Query().Get("redirect_uri")
	if redirect == "" {
		return 0
	}
	r, err := url.Parse(redirect)
	if err != nil {
		return 0
	}
	host := r.Hostname()
	if host != "127.0.0.1" && host != "localhost" && host != "::1" {
		return 0
	}
	if r.Port() == "" {
		return 0
	}
	var port int
	if _, err := fmt.Sscanf(r.Port(), "%d", &port); err != nil {
		return 0
	}
	if port <= 0 || port > 65535 {
		return 0
	}
	return port
}

// extractCallbackPath returns the path component of the authorize
// URL's `redirect_uri` (e.g. "/auth/callback"). Empty when absent —
// callers should default to "/auth/callback".
func extractCallbackPath(authorizeURL string) string {
	u, err := url.Parse(authorizeURL)
	if err != nil {
		return ""
	}
	redirect := u.Query().Get("redirect_uri")
	if redirect == "" {
		return ""
	}
	r, err := url.Parse(redirect)
	if err != nil {
		return ""
	}
	return r.Path
}

// newSessionToken returns a 32-byte random hex string. Used as the
// SessionToken handshake value between broker and phone — anti-confused-
// deputy on a shared broker where multiple WS peers could otherwise
// race callback delivery.
func newSessionToken() (string, error) {
	b := make([]byte, 32)
	if _, err := io.ReadFull(rand.Reader, b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// sanitizedEnv strips environment variables that would short-circuit
// the CLI's OAuth flow (OPENAI_API_KEY, CODEX_ACCESS_TOKEN), so we
// always exercise the OAuth path regardless of what the operator's
// shell has set. CODEX_HOME and CLAUDE_CONFIG_DIR are kept — they're
// the operator's choice of where credentials land.
func sanitizedEnv(in []string) []string {
	stripped := map[string]struct{}{
		"OPENAI_API_KEY":       {},
		"CODEX_ACCESS_TOKEN":   {},
		"ANTHROPIC_API_KEY":    {},
		"ANTHROPIC_AUTH_TOKEN": {},
	}
	out := make([]string, 0, len(in))
	for _, kv := range in {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			out = append(out, kv)
			continue
		}
		if _, drop := stripped[kv[:eq]]; drop {
			continue
		}
		out = append(out, kv)
	}
	return out
}

// Manager owns active login sessions, keyed by the broker-issued
// session_token. The WS layer drives it: Start on a `start_agent_login`,
// Forward on `agent_login_callback`, Cancel on `cancel_agent_login` or
// on socket close. Concurrency-safe: a single broker instance may have
// multiple paired identities each running their own login attempt.
type Manager struct {
	mu       sync.Mutex
	sessions map[string]*Session
}

// NewManager returns an empty Manager. Pass the same instance through
// the WS layer (see broker/internal/ws/server.go).
func NewManager() *Manager {
	return &Manager{sessions: make(map[string]*Session)}
}

// StartSession is the Manager-mediated wrapper around Start. Stores
// the resulting *Session under its SessionToken so subsequent
// ForwardCallback / CancelSession calls can find it.
func (m *Manager) StartSession(ctx context.Context, provider string) (*Session, error) {
	sess, err := Start(ctx, provider)
	if err != nil {
		return nil, err
	}
	m.mu.Lock()
	m.sessions[sess.SessionToken] = sess
	m.mu.Unlock()
	return sess, nil
}

// ForwardCallback delivers `queryString` to the CLI for the session
// identified by `sessionToken`. Returns os.ErrNotExist when no
// matching session is active (stale token, broker restart, etc.).
func (m *Manager) ForwardCallback(sessionToken, queryString string) error {
	m.mu.Lock()
	sess, ok := m.sessions[sessionToken]
	if ok {
		delete(m.sessions, sessionToken)
	}
	m.mu.Unlock()
	if !ok {
		return os.ErrNotExist
	}
	return sess.Forward(queryString)
}

// CancelSession kills the subprocess for `sessionToken` without
// forwarding a callback. Used on phone-side abort. No-op when the
// token is unknown (already completed, already cancelled).
func (m *Manager) CancelSession(sessionToken string) {
	m.mu.Lock()
	sess, ok := m.sessions[sessionToken]
	if ok {
		delete(m.sessions, sessionToken)
	}
	m.mu.Unlock()
	if ok {
		sess.Cancel()
	}
}

// Close cancels every active login session. Called on broker
// shutdown so no orphan CLI process is left listening.
func (m *Manager) Close() {
	m.mu.Lock()
	all := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		all = append(all, s)
	}
	m.sessions = make(map[string]*Session)
	m.mu.Unlock()
	for _, s := range all {
		s.Cancel()
	}
}
