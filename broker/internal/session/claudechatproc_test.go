package session

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestChatProcessRoundTrip uses a fake "agent" (a bash one-liner emitting
// canned stream-json) to prove the subprocess → processClaudeStreamOutput
// → publish path delivers a clean chat event. No real claude.
func TestChatProcessRoundTrip(t *testing.T) {
	script := `printf '%s\n' ` +
		`'{"type":"system","subtype":"init"}' ` +
		`'{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pong"}]}}' ` +
		`'{"type":"result","subtype":"success","result":"pong"}'`
	command := []string{"bash", "-c", script}

	events := make(chan []byte, 8)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	cp, err := startChatProcess(ctx, command, nil, "", func(p []byte) { events <- p }, nil, nil, nil)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer cp.Close()

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
			t.Fatalf("publish payload not json: %v", err)
		}
		if ev.View != "chat" || ev.Event.Role != "assistant" || ev.Event.Content != "pong" {
			t.Fatalf("unexpected chat event: %s", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for chat event from fake agent")
	}
}

// TestChatProcessSendAndClose covers the stdin write + idempotent shutdown:
// Send works while running, and errors with errChatProcessClosed afterward.
func TestChatProcessSendAndClose(t *testing.T) {
	// `cat` reads stdin forever so Send has a live pipe to write to.
	command := []string{"bash", "-c", "cat >/dev/null"}
	cp, err := startChatProcess(context.Background(), command, nil, "", func([]byte) {}, nil, nil, nil)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	if err := cp.Send("hello"); err != nil {
		t.Fatalf("Send while running: %v", err)
	}
	if err := cp.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if err := cp.Close(); err != nil {
		t.Fatalf("Close is not idempotent: %v", err)
	}
	if err := cp.Send("again"); err != errChatProcessClosed {
		t.Fatalf("Send after Close: got %v, want errChatProcessClosed", err)
	}
}

// TestChatProcessExitNotice: when the agent exits on its own (not via
// Close), the user should get a system chat event, not silence.
func TestChatProcessExitNotice(t *testing.T) {
	// Fake agent that emits nothing and exits non-zero immediately.
	command := []string{"bash", "-c", "exit 3"}
	events := make(chan []byte, 4)
	cp, err := startChatProcess(context.Background(), command, nil, "", func(p []byte) { events <- p }, nil, nil, nil)
	if err != nil {
		t.Fatalf("start: %v", err)
	}
	defer cp.Close()

	select {
	case p := <-events:
		var ev struct {
			Event struct {
				Role    string `json:"role"`
				Content string `json:"content"`
			} `json:"event"`
		}
		if err := json.Unmarshal(p, &ev); err != nil {
			t.Fatalf("notice not json: %v", err)
		}
		if ev.Event.Role != "system" || !strings.Contains(ev.Event.Content, "agent process") {
			t.Fatalf("expected a system agent-exit notice, got %s", p)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout: expected an agent-exit chat notice")
	}
}
