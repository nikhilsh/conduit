package oauth

import (
	"context"
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

// TestClaudeExtractURL pins the (provisional) claude CLI matcher. The
// Stage 0 implementation accepts both claude.ai and platform.claude.com
// authorize URLs — until Stage 2 nails down which one actually appears.
func TestClaudeExtractURL(t *testing.T) {
	p := claudeProvider{}
	cases := []struct {
		name string
		line string
		want string
		ok   bool
	}{
		{
			name: "claude_ai_oauth_url",
			line: "https://claude.ai/oauth/authorize?response_type=code&scope=user:inference",
			want: "https://claude.ai/oauth/authorize?response_type=code&scope=user:inference",
			ok:   true,
		},
		{
			name: "platform_claude_com_url",
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
			name: "banner_rejected",
			line: "Open this URL in your browser:",
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
		"CODEX_HOME=/var/lib/swekitty/codex",
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
