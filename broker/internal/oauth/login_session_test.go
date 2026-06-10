package oauth

import (
	"context"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
	"time"
)

// TestCodexExtractURL pins the codex CLI stdout matcher against the
// verbatim line shape captured from `codex login` on the harness host
// (see PLAN-AGENT-OAUTH.md §K). When the codex CLI changes its banner
// copy this is the test that goes red first.
func TestCodexExtractURL(t *testing.T) {
	p := codexProvider{}
	cases := []struct {
		name string
		line string
		want string
		ok   bool
	}{
		{
			name: "verbatim_codex_stdout_line",
			line: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid&state=abc",
			want: "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid&state=abc",
			ok:   true,
		},
		{
			name: "leading_whitespace_trimmed",
			line: "   https://auth.openai.com/oauth/authorize?x=1",
			want: "https://auth.openai.com/oauth/authorize?x=1",
			ok:   true,
		},
		{
			name: "banner_line_rejected",
			line: "Starting local login server on http://localhost:1455.",
			want: "",
			ok:   false,
		},
		{
			name: "blank_line_rejected",
			line: "",
			want: "",
			ok:   false,
		},
		{
			name: "claude_url_rejected_by_codex_provider",
			line: "https://claude.ai/oauth/authorize?x=1",
			want: "",
			ok:   false,
		},
		{
			name: "non_openai_https_rejected",
			line: "https://example.com/oauth/authorize?x=1",
			want: "",
			ok:   false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := p.ExtractURL(tc.line)
			if ok != tc.ok {
				t.Fatalf("ok = %v, want %v (line=%q)", ok, tc.ok, tc.line)
			}
			if got != tc.want {
				t.Fatalf("url = %q, want %q", got, tc.want)
			}
		})
	}
}

// claudeVisitLine is the verbatim stdout line `claude auth login
// --claudeai` (CLI 2.1.170) prints with the authorize URL inline after
// a "visit:" prefix. Captured on the harness host 2026-06-10 (see
// PLAN-AGENT-OAUTH.md "Stage 2 validation 2026-06-10"). The
// code_challenge/state values are redacted/synthetic — the parser only
// cares about the URL shape, not the secret values.
const claudeVisitLine = "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference&code_challenge=TESTCHALLENGE&code_challenge_method=S256&state=TESTSTATE"

const claudeAuthURL = "https://claude.com/cai/oauth/authorize?code=true&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e&response_type=code&redirect_uri=https%3A%2F%2Fplatform.claude.com%2Foauth%2Fcode%2Fcallback&scope=org%3Acreate_api_key+user%3Aprofile+user%3Ainference&code_challenge=TESTCHALLENGE&code_challenge_method=S256&state=TESTSTATE"

// TestClaudeExtractURL pins the claude CLI matcher against the verbatim
// captured line. The CLI prints the URL INLINE after a prose prefix
// (unlike codex's whole-line URL), so the matcher must scan for an
// embedded URL and strip the prefix. This is the test that goes red
// first if the CLI changes its authorize host or banner copy.
func TestClaudeExtractURL(t *testing.T) {
	p := claudeProvider{}
	cases := []struct {
		name string
		line string
		want string
		ok   bool
	}{
		{
			name: "verbatim_2_1_170_inline_visit_line",
			line: claudeVisitLine,
			want: claudeAuthURL,
			ok:   true,
		},
		{
			name: "trailing_whitespace_trimmed",
			line: "If the browser didn't open, visit: https://claude.com/cai/oauth/authorize?code=true&state=x more prose",
			want: "https://claude.com/cai/oauth/authorize?code=true&state=x",
			ok:   true,
		},
		{
			name: "legacy_claude_ai_oauth_url",
			line: "https://claude.ai/oauth/authorize?response_type=code&scope=user:inference",
			want: "https://claude.ai/oauth/authorize?response_type=code&scope=user:inference",
			ok:   true,
		},
		{
			name: "legacy_platform_claude_com_url",
			line: "https://platform.claude.com/v1/oauth/authorize?response_type=code",
			want: "https://platform.claude.com/v1/oauth/authorize?response_type=code",
			ok:   true,
		},
		{
			name: "codex_url_rejected_by_claude_provider",
			line: "https://auth.openai.com/oauth/authorize?x=1",
			want: "",
			ok:   false,
		},
		{
			name: "opening_browser_banner_rejected",
			line: "Opening browser to sign in…",
			want: "",
			ok:   false,
		},
		{
			name: "paste_prompt_rejected",
			line: "Paste code here if prompted > ",
			want: "",
			ok:   false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := p.ExtractURL(tc.line)
			if ok != tc.ok {
				t.Fatalf("ok = %v, want %v", ok, tc.ok)
			}
			if got != tc.want {
				t.Fatalf("url = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestClaudeRedirectIsRemoteNotLoopback documents the load-bearing fact
// that the claude flow is code-paste: the redirect_uri points at the
// remote platform.claude.com page (no loopback), so extractLoopbackPort
// returns 0 — which is what routes Forward to the stdin-paste path.
func TestClaudeRedirectIsRemoteNotLoopback(t *testing.T) {
	if port := extractLoopbackPort(claudeAuthURL); port != 0 {
		t.Fatalf("expected no loopback port for claude authorize URL, got %d", port)
	}
}

// TestClaudeDelivery asserts the providers declare the delivery mode
// Forward dispatches on: codex loopback, claude stdin-paste.
func TestClaudeDelivery(t *testing.T) {
	if got := (codexProvider{}).Delivery(); got != DeliveryLoopback {
		t.Fatalf("codex delivery = %v, want DeliveryLoopback", got)
	}
	if got := (claudeProvider{}).Delivery(); got != DeliveryStdinPaste {
		t.Fatalf("claude delivery = %v, want DeliveryStdinPaste", got)
	}
}

// TestClaudeFormatPaste covers the normalization of the phone's captured
// callback into the `code#state` line the CLI's stdin prompt expects.
// The CLI splits on `#` and rejects empty halves, so both must be
// present.
func TestClaudeFormatPaste(t *testing.T) {
	p := claudeProvider{}
	cases := []struct {
		name    string
		in      string
		want    string
		wantErr bool
	}{
		{
			name: "query_string_with_leading_question_mark",
			in:   "?code=AUTHCODE123&state=STATE456",
			want: "AUTHCODE123#STATE456",
		},
		{
			name: "query_string_without_question_mark",
			in:   "code=AUTHCODE123&state=STATE456",
			want: "AUTHCODE123#STATE456",
		},
		{
			name: "query_string_reordered_params",
			in:   "state=STATE456&code=AUTHCODE123&other=ignored",
			want: "AUTHCODE123#STATE456",
		},
		{
			name: "bare_code_hash_state_paste",
			in:   "AUTHCODE123#STATE456",
			want: "AUTHCODE123#STATE456",
		},
		{
			name: "bare_paste_with_surrounding_whitespace",
			in:   "  AUTHCODE123#STATE456\n",
			want: "AUTHCODE123#STATE456",
		},
		{
			name:    "empty_input",
			in:      "",
			wantErr: true,
		},
		{
			name:    "query_missing_state",
			in:      "code=AUTHCODE123",
			wantErr: true,
		},
		{
			name:    "query_missing_code",
			in:      "state=STATE456",
			wantErr: true,
		},
		{
			name:    "bare_paste_missing_state_half",
			in:      "AUTHCODE123#",
			wantErr: true,
		},
		{
			name:    "bare_paste_missing_code_half",
			in:      "#STATE456",
			wantErr: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := p.FormatPaste(tc.in)
			if tc.wantErr {
				if err == nil {
					t.Fatalf("expected error, got %q", got)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if got != tc.want {
				t.Fatalf("FormatPaste(%q) = %q, want %q", tc.in, got, tc.want)
			}
		})
	}
}

// TestExtractLoopbackPort exercises the parser that lifts the loopback
// port out of the authorize URL's `redirect_uri` query param. This is
// the broker's source of truth for which port to Dial when forwarding
// the callback — hard-coding 1455 would break when codex falls back to
// FALLBACK_PORT=1457 (see PLAN §C.2).
func TestExtractLoopbackPort(t *testing.T) {
	cases := []struct {
		name string
		url  string
		want int
	}{
		{
			name: "codex_default_port_1455",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&state=abc",
			want: 1455,
		},
		{
			name: "codex_fallback_port_1457",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1457%2Fauth%2Fcallback",
			want: 1457,
		},
		{
			name: "explicit_127_0_0_1_loopback",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2F127.0.0.1%3A9999%2Fauth%2Fcallback",
			want: 9999,
		},
		{
			name: "non_loopback_host_rejected",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Fexample.com%3A1455%2Fauth%2Fcallback",
			want: 0,
		},
		{
			name: "anthropic_codepaste_no_redirect_uri",
			url:  "https://claude.ai/oauth/authorize?response_type=code",
			want: 0,
		},
		{
			name: "malformed_authorize_url",
			url:  "not a url",
			want: 0,
		},
		{
			name: "redirect_uri_missing_port",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%2Fauth%2Fcallback",
			want: 0,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := extractLoopbackPort(tc.url)
			if got != tc.want {
				t.Fatalf("port = %d, want %d", got, tc.want)
			}
		})
	}
}

// TestExtractCallbackPath confirms the forwarder uses whatever path
// the CLI advertised, not a hard-coded "/auth/callback". Lets us
// survive future CLI revs that move the callback endpoint.
func TestExtractCallbackPath(t *testing.T) {
	cases := []struct {
		name string
		url  string
		want string
	}{
		{
			name: "default_auth_callback",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback",
			want: "/auth/callback",
		},
		{
			name: "custom_path",
			url:  "https://auth.openai.com/oauth/authorize?redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fcallback%2Fv2",
			want: "/callback/v2",
		},
		{
			name: "missing_redirect_uri",
			url:  "https://claude.ai/oauth/authorize?response_type=code",
			want: "",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := extractCallbackPath(tc.url)
			if got != tc.want {
				t.Fatalf("path = %q, want %q", got, tc.want)
			}
		})
	}
}

// TestScanAuthorizeURL_HappyPath feeds the codex-shaped stdout stream
// through scanAuthorizeURL and asserts it returns the captured URL.
// The verbatim block matches the harness host capture in PLAN §K.
func TestScanAuthorizeURL_HappyPath(t *testing.T) {
	stdout := strings.NewReader(`WARNING: proceeding, even though we could not update PATH
Starting local login server on http://localhost:1455.
If your browser did not open, navigate to this URL to authenticate:

https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid&state=xyz

On a remote or headless machine? Use ` + "`" + `codex login --device-auth` + "`" + ` instead.
`)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	url, err := scanAuthorizeURL(ctx, codexProvider{}, stdout)
	if err != nil {
		t.Fatalf("scan err: %v", err)
	}
	want := "https://auth.openai.com/oauth/authorize?response_type=code&client_id=app_EMoamEEZ73f0CkXaXp7hrann&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&scope=openid&state=xyz"
	if url != want {
		t.Fatalf("url = %q, want %q", url, want)
	}
}

// TestScanAuthorizeURL_StdoutClosedBeforeMatch asserts we return a
// useful error when the CLI exits without printing the URL (e.g. the
// CLI crashed at startup). Without this branch the broker would hang
// the WS handler for the full parse timeout.
func TestScanAuthorizeURL_StdoutClosedBeforeMatch(t *testing.T) {
	stdout := strings.NewReader("Starting local login server on http://localhost:1455.\nsome other line\n")
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, err := scanAuthorizeURL(ctx, codexProvider{}, stdout)
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
	if !strings.Contains(err.Error(), "stdout closed") {
		t.Fatalf("expected stdout-closed error, got %v", err)
	}
}

// TestSanitizedEnv guards against the operator's shell short-circuiting
// the OAuth flow with a stale OPENAI_API_KEY / ANTHROPIC_API_KEY. The
// CLI honours either env var ahead of the OAuth path, which would land
// the operator's tokens (not the phone-user's) on disk — exactly the
// bug v2 is meant to fix.
func TestSanitizedEnv(t *testing.T) {
	in := []string{
		"PATH=/usr/bin",
		"OPENAI_API_KEY=sk-test",
		"ANTHROPIC_API_KEY=sk-ant-test",
		"CODEX_ACCESS_TOKEN=oat-test",
		"ANTHROPIC_AUTH_TOKEN=oat-ant-test",
		"CODEX_HOME=/var/lib/conduit/codex",
		"USER=app",
	}
	out := sanitizedEnv(in)
	join := strings.Join(out, "\n")
	for _, banned := range []string{"OPENAI_API_KEY", "ANTHROPIC_API_KEY", "CODEX_ACCESS_TOKEN", "ANTHROPIC_AUTH_TOKEN"} {
		if strings.Contains(join, banned+"=") {
			t.Errorf("expected %s stripped, still present in %v", banned, out)
		}
	}
	for _, kept := range []string{"PATH", "CODEX_HOME", "USER"} {
		if !strings.Contains(join, kept+"=") {
			t.Errorf("expected %s kept, missing from %v", kept, out)
		}
	}
}

// TestProviderFor confirms the WS-layer dispatch table maps the wire
// strings the protocol documents to non-nil Provider implementations,
// and rejects anything else with nil.
func TestProviderFor(t *testing.T) {
	cases := []struct {
		in    string
		isNil bool
	}{
		{"openai", false},
		{"anthropic", false},
		{"", true},
		{"unknown", true},
		{"OpenAI", true}, // case-sensitive on purpose
	}
	for _, tc := range cases {
		t.Run(tc.in, func(t *testing.T) {
			got := ProviderFor(tc.in)
			if (got == nil) != tc.isNil {
				t.Fatalf("ProviderFor(%q): got nil=%v, want nil=%v", tc.in, got == nil, tc.isNil)
			}
		})
	}
}

// TestNewSessionToken asserts the token is 64 hex chars (32 bytes) and
// not constant across calls — confused-deputy defense relies on the
// token being unguessable to a WS peer that races the callback.
func TestNewSessionToken(t *testing.T) {
	a, err := newSessionToken()
	if err != nil {
		t.Fatalf("newSessionToken: %v", err)
	}
	b, err := newSessionToken()
	if err != nil {
		t.Fatalf("newSessionToken: %v", err)
	}
	if len(a) != 64 {
		t.Errorf("token len = %d, want 64", len(a))
	}
	if a == b {
		t.Errorf("two tokens collided: %s", a)
	}
}

// TestManagerCancelUnknown asserts that cancelling an unknown token is
// a silent no-op — the WS layer relies on this so stale `cancel_agent_login`
// messages from a phone don't error the socket.
func TestManagerCancelUnknown(t *testing.T) {
	m := NewManager()
	m.CancelSession("does-not-exist")
	// success: no panic
}

// TestManagerForwardUnknown asserts ForwardCallback on an unknown token
// returns os.ErrNotExist so the WS layer can emit a useful
// agent_login_failed view_event.
func TestManagerForwardUnknown(t *testing.T) {
	m := NewManager()
	err := m.ForwardCallback("does-not-exist", "code=abc")
	if err == nil {
		t.Fatalf("expected error, got nil")
	}
}

// stubClaudeProvider points Command() at a stub script while reusing the
// real claudeProvider's ExtractURL / Delivery / FormatPaste — so the
// login-session integration test exercises the production parsing and
// stdin-paste wiring against a fake CLI binary (no real network / creds).
type stubClaudeProvider struct {
	claudeProvider
	script string
}

func (s stubClaudeProvider) Command() (string, []string) {
	return s.script, nil
}

// writeStubClaudeScript writes an executable shell script that mimics the
// real `claude auth login --claudeai` stdout (the inline "visit:" URL +
// "Paste code here" prompt), reads one line from stdin, and records it to
// codeSink so the test can assert what the broker forwarded. Skips on
// non-unix (no /bin/sh).
func writeStubClaudeScript(t *testing.T, dir, codeSink string) string {
	t.Helper()
	if runtime.GOOS == "windows" {
		t.Skip("stub script test requires a POSIX shell")
	}
	script := filepath.Join(dir, "claude-stub.sh")
	body := "#!/bin/sh\n" +
		"echo 'Opening browser to sign in…'\n" +
		"printf 'If the browser did not open, visit: %s\\n' \"" + claudeAuthURL + "\"\n" +
		"printf 'Paste code here if prompted > '\n" +
		"IFS= read -r line\n" +
		"printf '%s' \"$line\" > '" + codeSink + "'\n" +
		"exit 0\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub script: %v", err)
	}
	return script
}

// TestClaudeLoginSession_StdinPaste is the end-to-end fake-binary test:
// spawn the stub "claude" via the real Start machinery, assert Start
// captured the inline authorize URL with LoopbackPort 0 (code-paste), then
// Forward a captured `?code=…&state=…` callback and assert the stub saw
// the `code#state` line on its stdin.
func TestClaudeLoginSession_StdinPaste(t *testing.T) {
	dir := t.TempDir()
	codeSink := filepath.Join(dir, "received-code.txt")
	script := writeStubClaudeScript(t, dir, codeSink)

	p := stubClaudeProvider{script: script}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	sess, err := startProvider(ctx, p)
	if err != nil {
		t.Fatalf("startProvider: %v", err)
	}
	if sess.AuthorizeURL != claudeAuthURL {
		t.Fatalf("AuthorizeURL = %q, want %q", sess.AuthorizeURL, claudeAuthURL)
	}
	if sess.LoopbackPort != 0 {
		t.Fatalf("LoopbackPort = %d, want 0 (code-paste flow)", sess.LoopbackPort)
	}

	// Forward the phone's captured callback query string. The broker must
	// normalize it to `code#state` and write it to the stub's stdin.
	if err := sess.Forward("?code=AUTHCODE123&state=STATE456"); err != nil {
		t.Fatalf("Forward: %v", err)
	}

	got, err := os.ReadFile(codeSink)
	if err != nil {
		t.Fatalf("read code sink: %v", err)
	}
	if string(got) != "AUTHCODE123#STATE456" {
		t.Fatalf("stub received %q on stdin, want %q", got, "AUTHCODE123#STATE456")
	}
}

// TestCodexLoginSession_LoopbackRejectsNoPort confirms a loopback
// provider whose authorize URL advertised no 127.0.0.1 redirect_uri
// fails Forward loudly instead of routing to the stdin path. Uses a stub
// codex that prints a URL with a remote redirect_uri.
func TestCodexLoginSession_LoopbackRejectsNoPort(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("stub script test requires a POSIX shell")
	}
	dir := t.TempDir()
	script := filepath.Join(dir, "codex-stub.sh")
	body := "#!/bin/sh\n" +
		"echo 'https://auth.openai.com/oauth/authorize?redirect_uri=https%3A%2F%2Fexample.com%2Fcb&state=x'\n" +
		"sleep 5\n"
	if err := os.WriteFile(script, []byte(body), 0o755); err != nil {
		t.Fatalf("write stub: %v", err)
	}
	p := stubCodexProvider{script: script}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	sess, err := startProvider(ctx, p)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer sess.Cancel()
	if sess.LoopbackPort != 0 {
		t.Fatalf("LoopbackPort = %d, want 0 (remote redirect_uri)", sess.LoopbackPort)
	}
	if err := sess.Forward("?code=x&state=x"); err == nil {
		t.Fatalf("expected Forward to reject loopback provider with no port")
	}
}

type stubCodexProvider struct {
	codexProvider
	script string
}

func (s stubCodexProvider) Command() (string, []string) {
	return s.script, nil
}
