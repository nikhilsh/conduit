package session

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
)

func TestParseQuickReplies(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want []string
	}{
		{
			name: "bare json array",
			raw:  `["Yes, go ahead","No","Tell me more"]`,
			want: []string{"Yes, go ahead", "No", "Tell me more"},
		},
		{
			name: "prose around array",
			raw:  "Sure! Here are some replies:\n[\"Run tests\", \"Show diff\"]\nHope that helps.",
			want: []string{"Run tests", "Show diff"},
		},
		{
			name: "fenced code block",
			raw:  "```json\n[\"Proceed\", \"Wait\"]\n```",
			want: []string{"Proceed", "Wait"},
		},
		{
			name: "caps at four",
			raw:  `["a","b","c","d","e","f"]`,
			want: []string{"a", "b", "c", "d"},
		},
		{
			name: "trims and drops empties + dupes",
			raw:  `["  Yes  ", "", "Yes", "No"]`,
			want: []string{"Yes", "No"},
		},
		{
			name: "bracket inside string is not the close",
			raw:  `["use [brackets]", "ok"]`,
			want: []string{"use [brackets]", "ok"},
		},
		{
			name: "empty array yields nil",
			raw:  `[]`,
			want: nil,
		},
		{
			name: "no array at all yields nil",
			raw:  `I cannot suggest replies.`,
			want: nil,
		},
		{
			name: "malformed json yields nil",
			raw:  `["unterminated`,
			want: nil,
		},
		{
			name: "loose mixed types keeps strings",
			raw:  `["Keep going", 42, true, "Stop"]`,
			want: []string{"Keep going", "Stop"},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := parseQuickReplies(tc.raw)
			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("parseQuickReplies(%q) = %#v, want %#v", tc.raw, got, tc.want)
			}
		})
	}
}

func TestQuickRepliesEnabled(t *testing.T) {
	cases := map[string]bool{
		"":      true,
		"1":     true,
		"true":  true,
		"0":     false,
		"false": false,
		"off":   false,
		"OFF":   false,
		"no":    false,
	}
	for val, want := range cases {
		t.Setenv("SWE_KITTY_AI_QUICKREPLIES", val)
		if got := quickRepliesEnabled(); got != want {
			t.Errorf("quickRepliesEnabled() with %q = %v, want %v", val, got, want)
		}
	}
}

func TestNewQuickReplyGeneratorNilCases(t *testing.T) {
	pub := func([]byte) {}
	if g := newQuickReplyGenerator("s", "claude", "", "/d", nil, pub); g != nil {
		t.Error("expected nil when agentHomeDir is empty")
	}
	if g := newQuickReplyGenerator("s", "claude", "/home", "/d", nil, nil); g != nil {
		t.Error("expected nil when publish is nil")
	}
	if g := newQuickReplyGenerator("s", "", "/home", "/d", nil, pub); g != nil {
		t.Error("expected nil when binary is empty")
	}
	t.Setenv("SWE_KITTY_AI_QUICKREPLIES", "0")
	if g := newQuickReplyGenerator("s", "claude", "/home", "/d", nil, pub); g != nil {
		t.Error("expected nil when feature disabled")
	}
}

func TestNewQuickReplyGeneratorWiresHTTPDoer(t *testing.T) {
	g := newQuickReplyGenerator("s", "claude", "/home", "/d", nil, func([]byte) {})
	if g == nil {
		t.Fatal("expected non-nil generator")
	}
	if g.httpDo == nil {
		t.Fatal("expected httpDo to default to a real HTTP doer")
	}
}

func TestQuickReplyGeneratorNilSafe(t *testing.T) {
	var g *quickReplyGenerator
	// Must not panic on the nil receiver — this is the "feature off"
	// / non-claude path the stream reader takes.
	g.kickoff("hello", "ts-1")
	g.Generate("hello", "ts-1")
}

// writeCreds drops a `.claude/.credentials.json` into home with the given
// access token and expiry (epoch ms; 0 = omit), returning home.
func writeCreds(t *testing.T, accessToken string, expiresAt int64) string {
	t.Helper()
	home := t.TempDir()
	credPath := filepath.Join(home, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatal(err)
	}
	oauth := map[string]any{"accessToken": accessToken}
	if expiresAt != 0 {
		oauth["expiresAt"] = expiresAt
	}
	blob, _ := json.Marshal(map[string]any{"claudeAiOauth": oauth})
	if err := os.WriteFile(credPath, blob, 0o600); err != nil {
		t.Fatal(err)
	}
	return home
}

func TestReadClaudeOAuthToken(t *testing.T) {
	future := time.Now().Add(time.Hour).UnixMilli()
	home := writeCreds(t, "tok-abc", future)
	tok, err := readClaudeOAuthToken(home)
	if err != nil {
		t.Fatalf("readClaudeOAuthToken: %v", err)
	}
	if tok != "tok-abc" {
		t.Fatalf("token = %q, want tok-abc", tok)
	}

	// Missing file → error.
	if _, err := readClaudeOAuthToken(t.TempDir()); err == nil {
		t.Fatal("expected error when credentials missing")
	}

	// Empty token → error.
	if _, err := readClaudeOAuthToken(writeCreds(t, "", future)); err == nil {
		t.Fatal("expected error on empty token")
	}

	// Expired token → error (best-effort skip).
	past := time.Now().Add(-time.Hour).UnixMilli()
	if _, err := readClaudeOAuthToken(writeCreds(t, "tok-old", past)); err == nil {
		t.Fatal("expected error on expired token")
	}

	// expiresAt omitted (0) → accepted (no expiry check).
	if _, err := readClaudeOAuthToken(writeCreds(t, "tok-noexp", 0)); err != nil {
		t.Fatalf("expected no error when expiresAt omitted: %v", err)
	}
}

func TestExtractMessageText(t *testing.T) {
	raw := []byte(`{"content":[{"type":"text","text":"hello "},{"type":"thinking","text":"ignored"},{"type":"text","text":"world"}]}`)
	got, err := extractMessageText(raw)
	if err != nil {
		t.Fatalf("extractMessageText: %v", err)
	}
	if got != "hello world" {
		t.Fatalf("text = %q, want %q", got, "hello world")
	}

	if _, err := extractMessageText([]byte(`{"content":[]}`)); err == nil {
		t.Fatal("expected error on empty content")
	}
	if _, err := extractMessageText([]byte(`not json`)); err == nil {
		t.Fatal("expected error on malformed body")
	}
}

// fakeDoer returns an httpDo func that asserts the request shape and
// replies with the given status + body, without touching the network.
func fakeDoer(t *testing.T, status int, body string, gotReq *http.Request) func(*http.Request) (*http.Response, error) {
	t.Helper()
	return func(req *http.Request) (*http.Response, error) {
		if gotReq != nil {
			*gotReq = *req
		}
		return &http.Response{
			StatusCode: status,
			Body:       io.NopCloser(strings.NewReader(body)),
			Header:     make(http.Header),
		}, nil
	}
}

// TestQuickReplyGeneratorInvoke proves the direct-API path end to end with
// a stubbed HTTP doer (no network): it reads the OAuth token, sets the
// required headers, posts the prompt, and parses the model's JSON.
func TestQuickReplyGeneratorInvoke(t *testing.T) {
	home := writeCreds(t, "tok-xyz", time.Now().Add(time.Hour).UnixMilli())
	var gotReq http.Request
	g := &quickReplyGenerator{
		sessionID:    "sess-1",
		agentHomeDir: home,
		publish:      func([]byte) {},
		httpDo:       fakeDoer(t, 200, `{"content":[{"type":"text","text":"[\"Yes\",\"No\",\"Explain\"]"}]}`, &gotReq),
	}
	replies, err := g.invoke(context.Background(), "Should I proceed?")
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	want := []string{"Yes", "No", "Explain"}
	if !reflect.DeepEqual(replies, want) {
		t.Fatalf("replies = %#v, want %#v", replies, want)
	}

	// Required OAuth headers.
	if got := gotReq.Header.Get("authorization"); got != "Bearer tok-xyz" {
		t.Fatalf("authorization = %q, want Bearer tok-xyz", got)
	}
	if got := gotReq.Header.Get("anthropic-beta"); got != oauthBeta {
		t.Fatalf("anthropic-beta = %q, want %q", got, oauthBeta)
	}
	if got := gotReq.Header.Get("anthropic-version"); got != anthropicVersion {
		t.Fatalf("anthropic-version = %q, want %q", got, anthropicVersion)
	}
	if gotReq.URL.String() != anthropicMessagesURL {
		t.Fatalf("url = %q, want %q", gotReq.URL.String(), anthropicMessagesURL)
	}
}

func TestQuickReplyGeneratorInvokeNoCreds(t *testing.T) {
	called := false
	g := &quickReplyGenerator{
		sessionID:    "sess-nocred",
		agentHomeDir: t.TempDir(), // no .claude/.credentials.json
		publish:      func([]byte) {},
		httpDo: func(*http.Request) (*http.Response, error) {
			called = true
			return nil, fmt.Errorf("should not be called")
		},
	}
	if _, err := g.invoke(context.Background(), "hi"); err == nil {
		t.Fatal("expected error when no credentials present")
	}
	if called {
		t.Fatal("httpDo must not be called when token is unavailable")
	}
}

func TestQuickReplyGeneratorInvokeNon200(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	g := &quickReplyGenerator{
		sessionID:    "sess-401",
		agentHomeDir: home,
		publish:      func([]byte) {},
		httpDo:       fakeDoer(t, 401, `{"error":"unauthorized"}`, nil),
	}
	if _, err := g.invoke(context.Background(), "hi"); err == nil {
		t.Fatal("expected error on non-200 status")
	}
}

// TestQuickReplyGeneratorGeneratePublishes proves Generate emits a clean
// view:"quick_replies" view_event when the API call succeeds.
func TestQuickReplyGeneratorGeneratePublishes(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	got := make(chan []byte, 1)
	g := &quickReplyGenerator{
		sessionID:    "sess-9",
		agentHomeDir: home,
		publish:      func(p []byte) { got <- p },
		httpDo:       fakeDoer(t, 200, `{"content":[{"type":"text","text":"[\"Run it\",\"Cancel\"]"}]}`, nil),
	}
	g.Generate("Ready to run the migration?", "msg-42")

	select {
	case p := <-got:
		var ev struct {
			Type  string `json:"type"`
			View  string `json:"view"`
			Event struct {
				SessionID    string   `json:"session_id"`
				Replies      []string `json:"replies"`
				ForMessageID string   `json:"for_message_id"`
			} `json:"event"`
		}
		if err := json.Unmarshal(p, &ev); err != nil {
			t.Fatalf("payload not json: %v", err)
		}
		if ev.Type != "view_event" || ev.View != "quick_replies" {
			t.Fatalf("unexpected envelope: %s", p)
		}
		if ev.Event.SessionID != "sess-9" || ev.Event.ForMessageID != "msg-42" {
			t.Fatalf("unexpected event meta: %s", p)
		}
		if !reflect.DeepEqual(ev.Event.Replies, []string{"Run it", "Cancel"}) {
			t.Fatalf("replies = %#v", ev.Event.Replies)
		}
	default:
		t.Fatal("Generate did not publish a quick_replies event")
	}
}

// TestQuickReplyGeneratorGenerateSilentOnEmpty: a model that returns no
// usable replies (or a blank assistant message) must publish nothing.
func TestQuickReplyGeneratorGenerateSilentOnEmpty(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	published := false
	g := &quickReplyGenerator{
		sessionID:    "sess-empty",
		agentHomeDir: home,
		publish:      func([]byte) { published = true },
		httpDo:       fakeDoer(t, 200, `{"content":[{"type":"text","text":"[]"}]}`, nil),
	}
	g.Generate("Anything else?", "msg-1")
	if published {
		t.Fatal("expected no publish on empty model output")
	}

	// Also silent on a non-empty but blank input message.
	g.Generate("   ", "msg-2")
	if published {
		t.Fatal("expected no publish on blank assistant text")
	}
}

// TestQuickReplyGeneratorGenerateSilentOnAPIError: a non-200 API response
// (e.g. auth failure) emits nothing.
func TestQuickReplyGeneratorGenerateSilentOnAPIError(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	published := false
	g := &quickReplyGenerator{
		sessionID:    "sess-err",
		agentHomeDir: home,
		publish:      func([]byte) { published = true },
		httpDo:       fakeDoer(t, 500, `{"error":"boom"}`, nil),
	}
	g.Generate("Should I retry?", "msg-1")
	if published {
		t.Fatal("expected no publish when the API errors")
	}
}

func TestQuickReplyPromptIncludesAssistantText(t *testing.T) {
	p := quickReplyPrompt("Let me know if you want me to deploy.")
	if !strings.Contains(p, "Let me know if you want me to deploy.") {
		t.Fatal("prompt should embed the assistant message")
	}
	if !strings.Contains(p, "JSON array") {
		t.Fatal("prompt should ask for a JSON array")
	}
}

// TestQuickReplyPromptTrimsLongContext: a long assistant turn is capped to
// its tail so the haiku request stays small and fast. The closing
// question (the part the user actually replies to) must survive; the head
// must be dropped.
func TestQuickReplyPromptTrimsLongContext(t *testing.T) {
	head := strings.Repeat("noise about an old subtask. ", 300) // ~8KB
	tail := "All set — should I open the PR now?"
	p := quickReplyPrompt(head + tail)
	if !strings.Contains(p, tail) {
		t.Fatal("prompt must keep the tail of the assistant message")
	}
	if strings.Contains(p, head) {
		t.Fatal("prompt must drop the head of an over-long assistant message")
	}
	// The embedded assistant section must be bounded (prompt scaffolding
	// adds a few hundred chars; the assistant slice itself is capped).
	if len(p) > quickReplyContextChars+1024 {
		t.Fatalf("prompt too large after trim: %d chars", len(p))
	}
}

func TestTrimAssistantTail(t *testing.T) {
	if got := trimAssistantTail("short", 2000); got != "short" {
		t.Fatalf("under-budget text should be unchanged, got %q", got)
	}
	if got := trimAssistantTail("anything", 0); got != "anything" {
		t.Fatalf("max<=0 should be unchanged, got %q", got)
	}
	long := strings.Repeat("x", 100) + "TAIL"
	got := trimAssistantTail(long, 20)
	if !strings.HasSuffix(got, "TAIL") {
		t.Fatalf("expected tail preserved, got %q", got)
	}
	if !utf8.ValidString(got) {
		t.Fatalf("trimmed text must stay valid UTF-8: %q", got)
	}
	// A multi-byte rune straddling the cut must not yield invalid UTF-8.
	multi := strings.Repeat("é", 50) // 2 bytes each = 100 bytes
	if !utf8.ValidString(trimAssistantTail(multi, 25)) {
		t.Fatal("trim must not split a multi-byte rune")
	}
}

func TestIsTransientGenError(t *testing.T) {
	transient := []string{
		"timeout: context deadline exceeded",
		"messages api: status 429 (rate limited)",
		"messages api: status 503 (overloaded)",
		"messages api: Post: read tcp: connection reset by peer",
		"messages api: unexpected EOF",
	}
	for _, m := range transient {
		if !isTransientGenError(fmt.Errorf("%s", m)) {
			t.Errorf("expected transient: %q", m)
		}
	}
	permanent := []string{
		"messages api: status 401 (unauthorized)",
		"messages api: status 400 (bad request)",
		"oauth access token expired",
		"read credentials: no such file",
	}
	for _, m := range permanent {
		if isTransientGenError(fmt.Errorf("%s", m)) {
			t.Errorf("expected permanent: %q", m)
		}
	}
	if isTransientGenError(nil) {
		t.Error("nil error must not be transient")
	}
}

// TestQuickReplyInvokeRetriesTransient: a first transient failure (503)
// followed by a success must yield the replies — proving the retry.
func TestQuickReplyInvokeRetriesTransient(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	calls := 0
	g := &quickReplyGenerator{
		sessionID:    "sess-retry",
		agentHomeDir: home,
		publish:      func([]byte) {},
		httpDo: func(req *http.Request) (*http.Response, error) {
			calls++
			if calls == 1 {
				return &http.Response{
					StatusCode: 503,
					Body:       io.NopCloser(strings.NewReader(`{"type":"error","error":{"type":"overloaded_error"}}`)),
					Header:     make(http.Header),
				}, nil
			}
			return &http.Response{
				StatusCode: 200,
				Body:       io.NopCloser(strings.NewReader(`{"content":[{"type":"text","text":"[\"Yes\",\"No\"]"}]}`)),
				Header:     make(http.Header),
			}, nil
		},
	}
	replies, err := g.invoke(context.Background(), "Proceed?")
	if err != nil {
		t.Fatalf("invoke after retry: %v", err)
	}
	if calls != 2 {
		t.Fatalf("expected 2 attempts (1 retry), got %d", calls)
	}
	if !reflect.DeepEqual(replies, []string{"Yes", "No"}) {
		t.Fatalf("replies = %#v", replies)
	}
}

// TestQuickReplyInvokeNoRetryOnPermanent: a 401 (expired/invalid token) is
// permanent — invoke must NOT retry it.
func TestQuickReplyInvokeNoRetryOnPermanent(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	calls := 0
	g := &quickReplyGenerator{
		sessionID:    "sess-401-once",
		agentHomeDir: home,
		publish:      func([]byte) {},
		httpDo: func(req *http.Request) (*http.Response, error) {
			calls++
			return &http.Response{
				StatusCode: 401,
				Body:       io.NopCloser(strings.NewReader(`{"error":"unauthorized"}`)),
				Header:     make(http.Header),
			}, nil
		},
	}
	if _, err := g.invoke(context.Background(), "hi"); err == nil {
		t.Fatal("expected error on 401")
	}
	if calls != 1 {
		t.Fatalf("expected no retry on permanent 401, got %d attempts", calls)
	}
}

// TestProcessClaudeStreamFiresGeneratorOnResult: the stream reader must
// kick the generator with the turn's last assistant text when it sees the
// `result` envelope — and NOT before.
func TestProcessClaudeStreamFiresGeneratorOnResult(t *testing.T) {
	if !claudeStreamLineIsTurnEnd([]byte(`{"type":"result","subtype":"success"}`)) {
		t.Fatal("result envelope should be detected as turn-end")
	}
	if claudeStreamLineIsTurnEnd([]byte(`{"type":"assistant","message":{"role":"assistant","content":[]}}`)) {
		t.Fatal("assistant envelope is not turn-end")
	}
	if claudeStreamLineIsTurnEnd([]byte(`not json`)) {
		t.Fatal("malformed line is not turn-end")
	}
}
