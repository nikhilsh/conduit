package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// --- Pure wire-helper tests -------------------------------------------------

func TestCodexErrorNotificationMessage(t *testing.T) {
	tests := []struct {
		name          string
		params        string
		wantMsg       string
		wantWillRetry bool
		wantOK        bool
	}{
		{
			name:    "terminal error with message",
			params:  `{"threadId":"t","turnId":"u","willRetry":false,"error":{"message":"usage limit reached"}}`,
			wantMsg: "usage limit reached",
			wantOK:  true,
		},
		{
			name:          "retryable error keeps willRetry",
			params:        `{"threadId":"t","turnId":"u","willRetry":true,"error":{"message":"server overloaded"}}`,
			wantMsg:       "server overloaded",
			wantWillRetry: true,
			wantOK:        true,
		},
		{
			name:    "falls back to additionalDetails when message empty",
			params:  `{"threadId":"t","turnId":"u","willRetry":false,"error":{"message":"","additionalDetails":"stream disconnected"}}`,
			wantMsg: "stream disconnected",
			wantOK:  true,
		},
		{
			name:    "parses but empty message → ok with empty msg",
			params:  `{"threadId":"t","turnId":"u","willRetry":false,"error":{}}`,
			wantMsg: "",
			wantOK:  true,
		},
		{
			name:   "garbage → not ok",
			params: `not json`,
			wantOK: false,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			msg, willRetry, ok := codexErrorNotificationMessage(json.RawMessage(tc.params))
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v", ok, tc.wantOK)
			}
			if !ok {
				return
			}
			if msg != tc.wantMsg || willRetry != tc.wantWillRetry {
				t.Fatalf("got (%q, retry=%v), want (%q, retry=%v)", msg, willRetry, tc.wantMsg, tc.wantWillRetry)
			}
		})
	}
}

func TestCodexTurnCompletion(t *testing.T) {
	tests := []struct {
		name       string
		params     string
		wantStatus string
		wantErr    string
	}{
		{
			name:       "completed",
			params:     `{"threadId":"t","turn":{"status":"completed"}}`,
			wantStatus: "completed",
		},
		{
			name:       "failed carries error message",
			params:     `{"threadId":"t","turn":{"status":"failed","error":{"message":"context window exceeded"}}}`,
			wantStatus: "failed",
			wantErr:    "context window exceeded",
		},
		{
			name:       "interrupted, no error",
			params:     `{"threadId":"t","turn":{"status":"interrupted"}}`,
			wantStatus: "interrupted",
		},
		{
			name:   "garbage → empty",
			params: `nope`,
		},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			status, errMsg := codexTurnCompletion(json.RawMessage(tc.params))
			if status != tc.wantStatus || errMsg != tc.wantErr {
				t.Fatalf("got (%q, %q), want (%q, %q)", status, errMsg, tc.wantStatus, tc.wantErr)
			}
		})
	}
}

func TestCodexThreadStatusType(t *testing.T) {
	cases := map[string]string{
		`{"threadId":"t","status":{"type":"idle"}}`:                    "idle",
		`{"threadId":"t","status":{"type":"systemError"}}`:             "systemError",
		`{"threadId":"t","status":{"type":"active","activeFlags":[]}}`: "active",
		`{"threadId":"t","status":{"type":"notLoaded"}}`:               "notLoaded",
		`garbage`: "",
	}
	for params, want := range cases {
		if got := codexThreadStatusType(json.RawMessage(params)); got != want {
			t.Fatalf("codexThreadStatusType(%s) = %q, want %q", params, got, want)
		}
	}
}

func TestCodexRPCErrorMessage(t *testing.T) {
	if got := codexRPCErrorMessage(json.RawMessage(`{"code":-32000,"message":"active turn not steerable"}`)); got != "active turn not steerable" {
		t.Fatalf("got %q", got)
	}
	// No message field → raw fallback (still bounded/trimmed).
	if got := codexRPCErrorMessage(json.RawMessage(`{"code":-32000}`)); got != `{"code":-32000}` {
		t.Fatalf("raw fallback got %q", got)
	}
}

func TestCodexTrimMessage(t *testing.T) {
	long := strings.Repeat("x", codexMessageCap+50)
	got := codexTrimMessage(long)
	if len([]rune(got)) != codexMessageCap+1 || !strings.HasSuffix(got, "…") {
		t.Fatalf("expected cap+ellipsis, got len %d", len([]rune(got)))
	}
	if got := codexTrimMessage("  hi  "); got != "hi" {
		t.Fatalf("trim got %q", got)
	}
}

// --- End-to-end recovery tests (fake app-server) ----------------------------
//
// These drive the FULL spawn → handshake → turn pipeline against a fake codex
// app-server and assert the user-reported bug is fixed: when a turn ends in any
// way OTHER than a clean turn/completed, the backend clears turnActive so the
// NEXT message is accepted (no permanent "turn already in flight").

// codexFakeScript builds a fake app-server that answers the handshake and runs
// turnStartBody (a bash snippet) for every turn/start.
func codexFakeScript(turnStartBody string) string {
	return `#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'"thread/start"'*)
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr-1"}}}'
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-1"}}}'
      ;;
    *'"turn/start"'*)
` + turnStartBody + `
      ;;
  esac
done
`
}

func newCodexFake(t *testing.T, turnStartBody string) (*codexAppServerProcess, chan []byte) {
	t.Helper()
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	if err := os.WriteFile(fake, []byte(codexFakeScript(turnStartBody)), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	events := make(chan []byte, 64)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(id string) { threads <- id },
	)
	if err != nil {
		t.Fatalf("newCodexAppServerProcess: %v", err)
	}
	t.Cleanup(func() { _ = proc.Close() })
	select {
	case <-threads:
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for thread latch")
	}
	return proc, events
}

func waitForSystemEvent(t *testing.T, events <-chan []byte, substr string) string {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case p := <-events:
			role, content := chatEventRoleContent(p)
			if role == "system" && strings.Contains(content, substr) {
				return content
			}
		case <-deadline:
			t.Fatalf("timeout waiting for system event containing %q", substr)
			return ""
		}
	}
}

func waitTurnInactive(t *testing.T, proc *codexAppServerProcess) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		proc.mu.Lock()
		active := proc.turnActive
		proc.mu.Unlock()
		if !active {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatal("turn still active after timeout — turnActive wedged")
}

// assertRecovered proves a second message is accepted (the turn flag cleared).
func assertRecovered(t *testing.T, proc *codexAppServerProcess) {
	t.Helper()
	waitTurnInactive(t, proc)
	if err := proc.Send("second message"); err != nil {
		t.Fatalf("second Send rejected after turn ended: %v (want nil — the bug is turnActive wedged true)", err)
	}
}

// An `error` notification with willRetry=false ends the turn (codex 0.132 has
// no turn/failed notification and may not send turn/completed) — the exact path
// that wedged the reported session.
func TestCodexAppServerRecoversAfterErrorNotification(t *testing.T) {
	body := `      printf '%s\n' '{"method":"error","params":{"threadId":"thr-1","turnId":"u1","willRetry":false,"error":{"message":"usage limit reached"}}}'`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	got := waitForSystemEvent(t, events, "usage limit reached")
	if !strings.HasPrefix(got, "⚠️ codex:") {
		t.Fatalf("error not surfaced as codex notice: %q", got)
	}
	assertRecovered(t, proc)
}

// A retryable `error` notification must NOT end the turn — codex retries.
func TestCodexAppServerRetryableErrorKeepsTurn(t *testing.T) {
	body := `      printf '%s\n' '{"method":"error","params":{"threadId":"thr-1","turnId":"u1","willRetry":true,"error":{"message":"server overloaded"}}}'`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	got := waitForSystemEvent(t, events, "server overloaded")
	if !strings.Contains(got, "retrying") {
		t.Fatalf("retryable error should say retrying: %q", got)
	}
	// Turn must still be in flight — a concurrent Send is still rejected.
	if err := proc.Send("again"); err != errCodexTurnInFlight {
		t.Fatalf("Send during retryable turn = %v, want errCodexTurnInFlight", err)
	}
}

// A JSON-RPC error RESPONSE to turn/start (e.g. activeTurnNotSteerable) carries
// the request id and never yields a turn/completed — it must end the turn.
func TestCodexAppServerRecoversAfterTurnStartError(t *testing.T) {
	body := `      id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9][0-9]*\).*/\1/p')
      printf '%s\n' "{\"id\":$id,\"error\":{\"code\":-32000,\"message\":\"active turn not steerable\"}}"`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	waitForSystemEvent(t, events, "active turn not steerable")
	assertRecovered(t, proc)
}

// turn/completed with status:"failed" surfaces the real error and ends the turn.
func TestCodexAppServerSurfacesFailedTurnStatus(t *testing.T) {
	body := `      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"status":"failed","error":{"message":"context window exceeded"}}}}'`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	waitForSystemEvent(t, events, "context window exceeded")
	assertRecovered(t, proc)
}

// A turn that streams output then goes thread idle WITHOUT a turn/completed must
// still end (the deterministic idle backstop) so the next message is accepted.
func TestCodexAppServerIdleStatusEndsTurn(t *testing.T) {
	body := `      printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","text":"partial reply"},"threadId":"thr-1"}}'
      printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"thr-1","status":{"type":"idle"}}}'`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	// The assistant message arrives; then idle clears the turn (no notice).
	select {
	case p := <-events:
		if role, content := chatEventRoleContent(p); role != "assistant" || content != "partial reply" {
			t.Fatalf("unexpected first event: role=%q content=%q", role, content)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for assistant event")
	}
	assertRecovered(t, proc) // only the idle handler can have cleared the turn
}

// A thread systemError ends the turn with a notice.
func TestCodexAppServerSystemErrorEndsTurn(t *testing.T) {
	body := `      printf '%s\n' '{"method":"thread/status/changed","params":{"threadId":"thr-1","status":{"type":"systemError"}}}'`
	proc, events := newCodexFake(t, body)
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	waitForSystemEvent(t, events, "system error")
	assertRecovered(t, proc)
}

// The silence watchdog force-ends a turn that produces nothing at all (a hung
// codex), so the session self-heals instead of wedging forever.
func TestCodexAppServerWatchdogEndsSilentTurn(t *testing.T) {
	body := `      : # swallow turn/start, emit nothing (simulate a hung turn)`
	proc, events := newCodexFake(t, body)
	// Shorten the watchdog window for the test (under lock — the reader reads it).
	proc.mu.Lock()
	proc.silenceTimeout = 80 * time.Millisecond
	proc.mu.Unlock()
	if err := proc.Send("hi"); err != nil {
		t.Fatalf("first Send: %v", err)
	}
	waitForSystemEvent(t, events, "no response from the agent")
	assertRecovered(t, proc)
}
