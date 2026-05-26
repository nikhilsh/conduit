package session

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestCleanTitle(t *testing.T) {
	cases := []struct {
		name string
		raw  string
		want string
	}{
		{"plain", "Debug Broker Session Limit", "Debug Broker Session Limit"},
		{"wrapping double quotes", `"Summarize Repo Structure"`, "Summarize Repo Structure"},
		{"single quotes", `'Fix Login Crash'`, "Fix Login Crash"},
		{"backticks", "`Add Dark Mode`", "Add Dark Mode"},
		{"trailing period", "Refactor Auth Flow.", "Refactor Auth Flow"},
		{"preamble Title:", "Title: Optimize Query Plan", "Optimize Query Plan"},
		{"preamble Here's a title", "Here's a title: Migrate To V2", "Migrate To V2"},
		{"collapse whitespace", "Fix   the    flaky test", "Fix the flaky test"},
		{"first line only", "Tune Cache TTL\nMore prose here", "Tune Cache TTL"},
		{"word cap at six", "One Two Three Four Five Six Seven Eight", "One Two Three Four Five Six"},
		{"empty", "", ""},
		{"whitespace only", "   \n  ", ""},
		{"quotes and trailing punct", `"Investigate Slow Startup!"`, "Investigate Slow Startup"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := cleanTitle(tc.raw); got != tc.want {
				t.Fatalf("cleanTitle(%q) = %q, want %q", tc.raw, got, tc.want)
			}
		})
	}
}

func TestCleanTitleCharCap(t *testing.T) {
	// A single long run gets capped at maxTitleLen on a word boundary.
	raw := "Supercalifragilistic Antidisestablishmentarianism"
	got := cleanTitle(raw)
	if len(got) > maxTitleLen {
		t.Fatalf("cleanTitle len = %d (%q), want <= %d", len(got), got, maxTitleLen)
	}
	if got == "" {
		t.Fatal("expected a non-empty capped title")
	}
}

func TestTitlesEnabled(t *testing.T) {
	cases := map[string]bool{
		"": true, "1": true, "true": true,
		"0": false, "false": false, "off": false, "OFF": false, "no": false,
	}
	for val, want := range cases {
		t.Setenv("SWE_KITTY_AI_TITLES", val)
		if got := titlesEnabled(); got != want {
			t.Errorf("titlesEnabled() with %q = %v, want %v", val, got, want)
		}
	}
}

func TestNewTitleGeneratorNilCases(t *testing.T) {
	fp := func() string { return "hi" }
	st := func(string) {}
	if g := newTitleGenerator("s", "claude", "", fp, st); g != nil {
		t.Error("expected nil when agentHomeDir empty")
	}
	if g := newTitleGenerator("s", "", "/home", fp, st); g != nil {
		t.Error("expected nil when binary empty")
	}
	if g := newTitleGenerator("s", "claude", "/home", nil, st); g != nil {
		t.Error("expected nil when firstPrompt nil")
	}
	if g := newTitleGenerator("s", "claude", "/home", fp, nil); g != nil {
		t.Error("expected nil when setTitle nil")
	}
	t.Setenv("SWE_KITTY_AI_TITLES", "0")
	if g := newTitleGenerator("s", "claude", "/home", fp, st); g != nil {
		t.Error("expected nil when feature disabled")
	}
}

func TestTitleGeneratorNilSafe(t *testing.T) {
	var g *titleGenerator
	// Must not panic on the nil receiver — the disabled / non-claude path.
	g.onTurnEnd("some assistant prose")
}

func TestNewTitleGeneratorWiresHTTPDoer(t *testing.T) {
	g := newTitleGenerator("s", "claude", "/home", func() string { return "x" }, func(string) {})
	if g == nil {
		t.Fatal("expected non-nil generator")
	}
	if g.httpDo == nil {
		t.Fatal("expected httpDo to default to a real HTTP doer")
	}
}

// TestTitleGeneratorInvoke proves the direct-API path end to end with a
// stubbed HTTP doer: reads the token, posts the prompt, cleans the title.
func TestTitleGeneratorInvoke(t *testing.T) {
	home := writeCreds(t, "tok-t", time.Now().Add(time.Hour).UnixMilli())
	var gotReq http.Request
	g := &titleGenerator{
		sessionID:    "s1",
		agentHomeDir: home,
		firstPrompt:  func() string { return "help me debug the broker" },
		setTitle:     func(string) {},
		httpDo:       fakeDoer(t, 200, `{"content":[{"type":"text","text":"Debug Broker Session Limit"}]}`, &gotReq),
	}
	title, err := g.invoke(context.Background(), "help me debug the broker", "Sure, let's look at the limits.")
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	if title != "Debug Broker Session Limit" {
		t.Fatalf("title = %q", title)
	}
	if got := gotReq.Header.Get("authorization"); got != "Bearer tok-t" {
		t.Fatalf("authorization = %q", got)
	}
	if got := gotReq.Header.Get("anthropic-beta"); got != oauthBeta {
		t.Fatalf("anthropic-beta = %q", got)
	}
	if gotReq.URL.String() != anthropicMessagesURL {
		t.Fatalf("url = %q", gotReq.URL.String())
	}
}

func TestTitleGeneratorInvokeNoCreds(t *testing.T) {
	called := false
	g := &titleGenerator{
		sessionID:    "s-nocred",
		agentHomeDir: t.TempDir(),
		firstPrompt:  func() string { return "hi" },
		setTitle:     func(string) {},
		httpDo: func(*http.Request) (*http.Response, error) {
			called = true
			return nil, nil
		},
	}
	if _, err := g.invoke(context.Background(), "hi", "yo"); err == nil {
		t.Fatal("expected error when credentials missing")
	}
	if called {
		t.Fatal("httpDo must not be called when token unavailable")
	}
}

// TestTitleGeneratorFirstExchangeSetsTitle: the first turn-end mints a
// title via setTitle.
func TestTitleGeneratorFirstExchangeSetsTitle(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	got := make(chan string, 4)
	g := &titleGenerator{
		sessionID:    "s9",
		agentHomeDir: home,
		firstPrompt:  func() string { return "summarize the repo structure" },
		setTitle:     func(s string) { got <- s },
		httpDo:       fakeDoer(t, 200, `{"content":[{"type":"text","text":"Summarize Repo Structure"}]}`, nil),
	}
	g.onTurnEnd("Here's the structure...")
	select {
	case title := <-got:
		if title != "Summarize Repo Structure" {
			t.Fatalf("title = %q", title)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("expected a title within timeout")
	}
}

// TestTitleGeneratorSilentWithoutPrompt: no first user prompt → no
// generation (and the HTTP doer is never called).
func TestTitleGeneratorSilentWithoutPrompt(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	called := false
	var mu sync.Mutex
	g := &titleGenerator{
		sessionID:    "s-noprompt",
		agentHomeDir: home,
		firstPrompt:  func() string { return "  " }, // blank
		setTitle:     func(string) {},
		httpDo: func(*http.Request) (*http.Response, error) {
			mu.Lock()
			called = true
			mu.Unlock()
			return nil, nil
		},
	}
	g.onTurnEnd("assistant reply")
	time.Sleep(100 * time.Millisecond)
	mu.Lock()
	defer mu.Unlock()
	if called {
		t.Fatal("must not call the API without a user prompt")
	}
}

// TestTitleGeneratorCadence: at most maxTitleGenerations generations per
// session, and a refine only fires after substantial growth.
func TestTitleGeneratorCadence(t *testing.T) {
	home := writeCreds(t, "tok", time.Now().Add(time.Hour).UnixMilli())
	var mu sync.Mutex
	count := 0
	done := make(chan struct{}, 8)
	g := &titleGenerator{
		sessionID:    "s-cadence",
		agentHomeDir: home,
		firstPrompt:  func() string { return "do the thing" },
		setTitle:     func(string) { done <- struct{}{} },
		httpDo: func(*http.Request) (*http.Response, error) {
			mu.Lock()
			count++
			mu.Unlock()
			return fakeDoer(t, 200, `{"content":[{"type":"text","text":"Do The Thing"}]}`, nil)(nil)
		},
	}

	waitGen := func() {
		select {
		case <-done:
		case <-time.After(2 * time.Second):
			t.Fatal("expected a generation")
		}
	}

	// First turn → gen #1.
	g.onTurnEnd("short reply")
	waitGen()

	// A small follow-up turn must NOT regenerate (growth below threshold).
	g.onTurnEnd("tiny")
	time.Sleep(150 * time.Millisecond)

	// A big turn (past titleRefineAfterChars) → the one allowed refine.
	g.onTurnEnd(strings.Repeat("x", titleRefineAfterChars+10))
	waitGen()

	// Another big turn must NOT regenerate — we've hit maxTitleGenerations.
	g.onTurnEnd(strings.Repeat("y", titleRefineAfterChars+10))
	time.Sleep(150 * time.Millisecond)

	mu.Lock()
	defer mu.Unlock()
	if count != maxTitleGenerations {
		t.Fatalf("generated %d times, want %d", count, maxTitleGenerations)
	}
}

func TestTitlePromptIncludesContext(t *testing.T) {
	p := titlePrompt("fix the login bug", "I'll trace the auth flow.")
	if !strings.Contains(p, "fix the login bug") {
		t.Fatal("prompt should embed the user message")
	}
	if !strings.Contains(p, "I'll trace the auth flow.") {
		t.Fatal("prompt should embed the assistant reply")
	}
	if !strings.Contains(p, "title") {
		t.Fatal("prompt should ask for a title")
	}
}
