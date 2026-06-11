package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCodexRequestFrames asserts the JSON-RPC frame encoders emit the exact
// wire shape the captured trace shows: a newline-terminated object with id +
// method + params (no `jsonrpc` field), and notifications without an id.
func TestCodexRequestFrames(t *testing.T) {
	t.Run("initialize", func(t *testing.T) {
		line, err := encodeCodexRequest(1, "initialize", codexInitializeParams())
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasSuffix(string(line), "\n") {
			t.Fatalf("frame not newline-terminated: %q", line)
		}
		var m map[string]any
		if err := json.Unmarshal(line, &m); err != nil {
			t.Fatalf("not json: %v", err)
		}
		if _, ok := m["jsonrpc"]; ok {
			t.Fatal("jsonrpc field must be omitted on the wire")
		}
		if m["id"].(float64) != 1 || m["method"] != "initialize" {
			t.Fatalf("bad id/method: %v", m)
		}
		ci := m["params"].(map[string]any)["clientInfo"].(map[string]any)
		if ci["name"] != "conduit-broker" {
			t.Fatalf("bad clientInfo.name: %v", ci)
		}
	})

	t.Run("turn-start", func(t *testing.T) {
		params := codexTurnStartParams("t-1", "hello", SpawnOverride{})
		line, err := encodeCodexRequest(3, "turn/start", params)
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(line, &m)
		if m["method"] != "turn/start" {
			t.Fatalf("bad method: %v", m["method"])
		}
		p := m["params"].(map[string]any)
		if p["threadId"] != "t-1" {
			t.Fatalf("bad threadId: %v", p["threadId"])
		}
		input := p["input"].([]any)
		first := input[0].(map[string]any)
		if first["type"] != "text" || first["text"] != "hello" {
			t.Fatalf("bad input: %v", input)
		}
	})

	t.Run("compact-start", func(t *testing.T) {
		line, err := encodeCodexRequest(4, "thread/compact/start", map[string]any{"threadId": "t-1"})
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(line, &m)
		if m["method"] != "thread/compact/start" {
			t.Fatalf("bad method: %v", m["method"])
		}
		if m["params"].(map[string]any)["threadId"] != "t-1" {
			t.Fatalf("bad threadId")
		}
	})

	t.Run("initialized-notification-has-no-id", func(t *testing.T) {
		line, err := encodeCodexNotification("initialized", map[string]any{})
		if err != nil {
			t.Fatal(err)
		}
		var m map[string]any
		_ = json.Unmarshal(line, &m)
		if _, ok := m["id"]; ok {
			t.Fatal("notification must not carry an id")
		}
		if m["method"] != "initialized" {
			t.Fatalf("bad method: %v", m["method"])
		}
	})
}

// TestCodexThreadStartParams covers the permission-mode / effort / model
// param mapping against the schema-confirmed enum values.
func TestCodexThreadStartParams(t *testing.T) {
	tests := []struct {
		name         string
		override     SpawnOverride
		wantSandbox  string
		wantApproval string
		wantModel    any // nil when absent
		wantEffort   any // nil when absent
	}{
		{
			name:         "default-auto-is-full-access",
			override:     SpawnOverride{},
			wantSandbox:  "danger-full-access",
			wantApproval: "never",
		},
		{
			name:         "plan-is-read-only",
			override:     SpawnOverride{PermissionMode: "plan"},
			wantSandbox:  "read-only",
			wantApproval: "on-request",
		},
		{
			name:         "model-and-effort-pass-through",
			override:     SpawnOverride{Model: "gpt-5-codex", ReasoningEffort: "high"},
			wantSandbox:  "danger-full-access",
			wantApproval: "never",
			wantModel:    "gpt-5-codex",
			wantEffort:   "high",
		},
		{
			name:         "unknown-effort-dropped",
			override:     SpawnOverride{ReasoningEffort: "ludicrous"},
			wantSandbox:  "danger-full-access",
			wantApproval: "never",
			wantEffort:   nil,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			p := codexThreadStartParams("/work", tc.override)
			if p["cwd"] != "/work" {
				t.Fatalf("bad cwd: %v", p["cwd"])
			}
			if p["sandbox"] != tc.wantSandbox {
				t.Fatalf("sandbox = %v, want %v", p["sandbox"], tc.wantSandbox)
			}
			if p["approvalPolicy"] != tc.wantApproval {
				t.Fatalf("approvalPolicy = %v, want %v", p["approvalPolicy"], tc.wantApproval)
			}
			if got := p["model"]; got != tc.wantModel {
				t.Fatalf("model = %v, want %v", got, tc.wantModel)
			}
			if got := p["effort"]; got != tc.wantEffort {
				t.Fatalf("effort = %v, want %v", got, tc.wantEffort)
			}
		})
	}
}

// TestCodexNotificationToEvent covers the notification → view_event mapping for
// each item type we render (and the ones we ignore).
func TestCodexNotificationToEvent(t *testing.T) {
	tests := []struct {
		name        string
		method      string
		params      string
		wantOK      bool
		wantRole    string
		wantContent string
	}{
		{
			name:   "agentMessage delta ignored (avoid one bubble per token)",
			method: "item/agentMessage/delta",
			params: `{"threadId":"t","turnId":"u","itemId":"i","delta":"hello"}`,
			wantOK: false,
		},
		{
			name:        "completed agentMessage → one assistant bubble (full text)",
			method:      "item/completed",
			params:      `{"item":{"type":"agentMessage","text":"hello world"}}`,
			wantOK:      true,
			wantRole:    "assistant",
			wantContent: "hello world",
		},
		{
			name:   "completed agentMessage empty text ignored",
			method: "item/completed",
			params: `{"item":{"type":"agentMessage","text":""}}`,
			wantOK: false,
		},
		{
			name:        "completed commandExecution → tool card",
			method:      "item/completed",
			params:      `{"item":{"type":"commandExecution","command":"ls -la","exitCode":0,"status":"completed"}}`,
			wantOK:      true,
			wantRole:    "tool",
			wantContent: "command_execution: ls -la",
		},
		{
			name:        "completed contextCompaction → system line",
			method:      "item/completed",
			params:      `{"item":{"type":"contextCompaction","id":"c1"}}`,
			wantOK:      true,
			wantRole:    "system",
			wantContent: "✓ Context compacted.",
		},
		{
			name:   "completed userMessage echo ignored",
			method: "item/completed",
			params: `{"item":{"type":"userMessage","content":[]}}`,
			wantOK: false,
		},
		{
			name:   "reasoning item ignored",
			method: "item/completed",
			params: `{"item":{"type":"reasoning"}}`,
			wantOK: false,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ev, ok := codexNotificationToEvent(tc.method, json.RawMessage(tc.params))
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v (ev=%+v)", ok, tc.wantOK, ev)
			}
			if !ok {
				return
			}
			if ev.role != tc.wantRole || ev.content != tc.wantContent {
				t.Fatalf("got {%q,%q}, want {%q,%q}", ev.role, ev.content, tc.wantRole, tc.wantContent)
			}
		})
	}
}

// TestCodexUsageFromNotification folds the thread/tokenUsage/updated `last`
// (per-turn) breakdown into a usageDelta — NOT the cumulative `total`, which
// would over-count the additive lifetime tokens and pin the context gauge.
// The fixture deliberately gives `last` different values from `total` so a
// regression that reads `total` fails here.
func TestCodexUsageFromNotification(t *testing.T) {
	params := `{"threadId":"t","turnId":"u","tokenUsage":{` +
		`"last":{"totalTokens":9000,"inputTokens":8200,"cachedInputTokens":1000,"outputTokens":5,"reasoningOutputTokens":3},` +
		`"total":{"totalTokens":17494,"inputTokens":17488,"cachedInputTokens":2432,"outputTokens":6,"reasoningOutputTokens":0},` +
		`"modelContextWindow":258400}}`
	u, ok := codexUsageFromNotification(json.RawMessage(params))
	if !ok {
		t.Fatal("expected ok")
	}
	// From `last`: output folds reasoning (5+3=8).
	if u.input != 8200 || u.output != 8 || u.cached != 1000 {
		t.Fatalf("bad tokens (should read `last`, not `total`): %+v", u)
	}
	// Context occupancy = last.inputTokens (point-in-time), window from model.
	if u.contextUsed != 8200 || u.contextWindow != 258400 {
		t.Fatalf("bad context: %+v", u)
	}
	if _, ok := codexUsageFromNotification(json.RawMessage(`{"tokenUsage":{"last":{}}}`)); ok {
		t.Fatal("zero usage should be ok=false")
	}
}

func TestIsCodexCompactCommand(t *testing.T) {
	cases := map[string]bool{
		"/compact":       true,
		"  /compact  ":   true,
		"/compact now":   false,
		"please compact": false,
		"":               false,
		"hello":          false,
	}
	for in, want := range cases {
		if got := isCodexCompactCommand(in); got != want {
			t.Fatalf("isCodexCompactCommand(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestCodexThreadIDFromStartResult(t *testing.T) {
	if got := codexThreadIDFromStartResult(json.RawMessage(`{"thread":{"id":"019ea-uuid"}}`)); got != "019ea-uuid" {
		t.Fatalf("got %q", got)
	}
	if got := codexThreadIDFromStartResult(json.RawMessage(`{}`)); got != "" {
		t.Fatalf("expected empty, got %q", got)
	}
}

// TestCodexAppServerRoundTrip drives a FAKE codex app-server (a bash script
// that replays a canned JSON-RPC session) through the real spawn → handshake →
// turn pipeline, proving: the thread id latches from thread/start, a streamed
// agentMessage delta surfaces as an assistant chat event, and the usage folds.
// No real codex is spawned.
func TestCodexAppServerRoundTrip(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	// The script reads request lines from stdin and replies on stdout. It is
	// deliberately simple: respond to each id in order, then stream a turn.
	script := `#!/usr/bin/env bash
# id:1 initialize, id:2 thread/start handshake — replied as soon as we see them.
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"userAgent":"fake"}}'
      ;;
    *'"thread/start"'*)
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr-1"}}}'
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-1"}}}'
      ;;
    *'"turn/start"'*)
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-1"}}'
      printf '%s\n' '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m1","text":""},"threadId":"thr-1"}}'
      printf '%s\n' '{"method":"item/agentMessage/delta","params":{"threadId":"thr-1","itemId":"m1","delta":"hi back"}}'
      printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"hi back"},"threadId":"thr-1"}}'
      printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thr-1","tokenUsage":{"last":{"inputTokens":100,"outputTokens":2,"cachedInputTokens":0},"total":{"inputTokens":100,"outputTokens":2,"cachedInputTokens":0},"modelContextWindow":1000}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"status":"completed"}}}'
      ;;
  esac
done
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}

	events := make(chan []byte, 16)
	usages := make(chan usageDelta, 4)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		func(u usageDelta) { usages <- u },
		"", // no seed → thread/start
		func(id string) { threads <- id },
		nil, // no subagent roster in unit tests
	)
	if err != nil {
		t.Fatalf("newCodexAppServerProcess: %v", err)
	}
	defer proc.Close()

	// Thread id latched during the handshake.
	select {
	case id := <-threads:
		if id != "thr-1" {
			t.Fatalf("latched thread id = %q", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for thread latch")
	}

	if err := proc.Send("hi"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	select {
	case p := <-events:
		var ev struct {
			View  string `json:"view"`
			Event struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"event"`
		}
		if err := json.Unmarshal(p, &ev); err != nil {
			t.Fatalf("payload not json: %v", err)
		}
		if ev.View != "chat" || ev.Event.Role != "assistant" || ev.Event.Content != "hi back" {
			t.Fatalf("unexpected chat event: %s", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for assistant chat event")
	}

	select {
	case u := <-usages:
		if u.input != 100 || u.output != 2 || u.contextWindow != 1000 {
			t.Fatalf("bad usage: %+v", u)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for usage")
	}
}

// TestCodexAppServerSendAfterClose: Send after Close is rejected.
func TestCodexAppServerSendAfterClose(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	// Minimal handshake responder so the constructor succeeds.
	script := `#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"thread/start"'*) printf '%s\n' '{"id":2,"result":{"thread":{"id":"t"}}}' ;;
  esac
done
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	proc, err := newCodexAppServerProcess(fake, dir, nil, SpawnOverride{}, func([]byte) {}, nil, "", func(string) {}, nil)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	if err := proc.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := proc.Send("x"); err != errChatProcessClosed {
		t.Fatalf("Send after Close = %v, want errChatProcessClosed", err)
	}
}
