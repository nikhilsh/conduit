package session

import (
	"context"
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"testing"
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

func TestQuickReplyGeneratorNilSafe(t *testing.T) {
	var g *quickReplyGenerator
	// Must not panic on the nil receiver — this is the "feature off"
	// / non-claude path the stream reader takes.
	g.kickoff("hello", "ts-1")
	g.Generate("hello", "ts-1")
}

func TestWithHomeOverride(t *testing.T) {
	env := []string{"PATH=/bin", "HOME=/old/home", "FOO=bar"}
	out := withHomeOverride(env, "/new/home")
	var homeCount int
	var home string
	for _, kv := range out {
		if strings.HasPrefix(kv, "HOME=") {
			homeCount++
			home = strings.TrimPrefix(kv, "HOME=")
		}
	}
	if homeCount != 1 {
		t.Fatalf("expected exactly 1 HOME entry, got %d (%v)", homeCount, out)
	}
	if home != "/new/home" {
		t.Fatalf("HOME = %q, want /new/home", home)
	}
}

func TestCopyClaudeCreds(t *testing.T) {
	srcHome := t.TempDir()
	dstHome := t.TempDir()
	credPath := filepath.Join(srcHome, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credPath, []byte(`{"token":"abc"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := copyClaudeCreds(srcHome, dstHome); err != nil {
		t.Fatalf("copyClaudeCreds: %v", err)
	}
	got, err := os.ReadFile(filepath.Join(dstHome, ".claude", ".credentials.json"))
	if err != nil {
		t.Fatalf("copied creds missing: %v", err)
	}
	if string(got) != `{"token":"abc"}` {
		t.Fatalf("copied creds = %q", got)
	}

	// No creds at all → error (so the one-shot is skipped cleanly).
	if err := copyClaudeCreds(t.TempDir(), t.TempDir()); err == nil {
		t.Fatal("expected error when no creds to copy")
	}
}

// fakeClaudeBin writes an executable shell script that mimics `claude -p`
// for the one-shot: it ignores its args/stdin and prints the given stdout
// body. Returns the script path to use as the generator binary.
func fakeClaudeBin(t *testing.T, stdout string, exitCode int) string {
	t.Helper()
	dir := t.TempDir()
	bin := filepath.Join(dir, "claude")
	script := "#!/bin/sh\ncat >/dev/null\n" +
		"printf '%s' " + shellQuote(stdout) + "\n" +
		"exit " + strconv.Itoa(exitCode) + "\n"
	if err := os.WriteFile(bin, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return bin
}

func shellQuote(s string) string { return "'" + strings.ReplaceAll(s, "'", `'\''`) + "'" }

// TestQuickReplyGeneratorInvoke proves the end-to-end one-shot path with a
// FAKE claude binary (no real model): it copies creds into a throwaway
// home, runs the binary, and parses its JSON output.
func TestQuickReplyGeneratorInvoke(t *testing.T) {
	srcHome := t.TempDir()
	credPath := filepath.Join(srcHome, ".claude", ".credentials.json")
	if err := os.MkdirAll(filepath.Dir(credPath), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(credPath, []byte(`{"token":"abc"}`), 0o600); err != nil {
		t.Fatal(err)
	}

	bin := fakeClaudeBin(t, `["Yes","No","Explain"]`, 0)
	g := &quickReplyGenerator{
		sessionID:    "sess-1",
		binary:       bin,
		agentHomeDir: srcHome,
		env:          []string{"PATH=" + os.Getenv("PATH")},
		dir:          t.TempDir(),
		publish:      func([]byte) {},
	}
	replies, err := g.invoke(context.Background(), "Should I proceed?")
	if err != nil {
		t.Fatalf("invoke: %v", err)
	}
	want := []string{"Yes", "No", "Explain"}
	if !reflect.DeepEqual(replies, want) {
		t.Fatalf("replies = %#v, want %#v", replies, want)
	}
}

// TestQuickReplyGeneratorGeneratePublishes proves Generate emits a clean
// view:"quick_replies" view_event when the one-shot succeeds.
func TestQuickReplyGeneratorGeneratePublishes(t *testing.T) {
	srcHome := t.TempDir()
	credPath := filepath.Join(srcHome, ".claude", ".credentials.json")
	_ = os.MkdirAll(filepath.Dir(credPath), 0o700)
	_ = os.WriteFile(credPath, []byte(`{"token":"abc"}`), 0o600)

	bin := fakeClaudeBin(t, `["Run it","Cancel"]`, 0)
	got := make(chan []byte, 1)
	g := &quickReplyGenerator{
		sessionID:    "sess-9",
		binary:       bin,
		agentHomeDir: srcHome,
		env:          []string{"PATH=" + os.Getenv("PATH")},
		dir:          t.TempDir(),
		publish:      func(p []byte) { got <- p },
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
// usable replies (or fails) must publish nothing — best-effort no-op.
func TestQuickReplyGeneratorGenerateSilentOnEmpty(t *testing.T) {
	srcHome := t.TempDir()
	credPath := filepath.Join(srcHome, ".claude", ".credentials.json")
	_ = os.MkdirAll(filepath.Dir(credPath), 0o700)
	_ = os.WriteFile(credPath, []byte(`{"token":"abc"}`), 0o600)

	// Model returns an empty array → no chips.
	bin := fakeClaudeBin(t, `[]`, 0)
	published := false
	g := &quickReplyGenerator{
		sessionID:    "sess-empty",
		binary:       bin,
		agentHomeDir: srcHome,
		env:          []string{"PATH=" + os.Getenv("PATH")},
		dir:          t.TempDir(),
		publish:      func([]byte) { published = true },
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

// TestQuickReplyGeneratorGenerateSilentOnExitError: a non-zero claude exit
// (e.g. auth failure) emits nothing.
func TestQuickReplyGeneratorGenerateSilentOnExitError(t *testing.T) {
	srcHome := t.TempDir()
	credPath := filepath.Join(srcHome, ".claude", ".credentials.json")
	_ = os.MkdirAll(filepath.Dir(credPath), 0o700)
	_ = os.WriteFile(credPath, []byte(`{"token":"abc"}`), 0o600)

	bin := fakeClaudeBin(t, `error: not logged in`, 1)
	published := false
	g := &quickReplyGenerator{
		sessionID:    "sess-err",
		binary:       bin,
		agentHomeDir: srcHome,
		env:          []string{"PATH=" + os.Getenv("PATH")},
		dir:          t.TempDir(),
		publish:      func([]byte) { published = true },
	}
	g.Generate("Should I retry?", "msg-1")
	if published {
		t.Fatal("expected no publish when claude exits non-zero")
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
