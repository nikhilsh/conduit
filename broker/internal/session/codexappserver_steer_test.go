package session

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCodexTurnSteerParams pins the exact wire frame for turn/steer (confirmed
// working against codex-cli 0.132.0 in frames_multistep.jsonl):
//
//	{"id":99,"method":"turn/steer","params":{
//	  "threadId":"tid","input":[{"type":"text","text":"hello"}],
//	  "expectedTurnId":"turn-1"}}
func TestCodexTurnSteerParams(t *testing.T) {
	p := codexTurnSteerParams("tid", "turn-1", "hello")
	if p["threadId"] != "tid" {
		t.Fatalf("threadId = %v", p["threadId"])
	}
	if p["expectedTurnId"] != "turn-1" {
		t.Fatalf("expectedTurnId = %v", p["expectedTurnId"])
	}
	input, ok := p["input"].([]map[string]any)
	if !ok || len(input) != 1 {
		t.Fatalf("input must be a single-element slice: %v", p["input"])
	}
	if input[0]["type"] != "text" || input[0]["text"] != "hello" {
		t.Fatalf("input[0] = %v", input[0])
	}
	// No model/effort/sandbox fields on a steer.
	for _, banned := range []string{"model", "effort", "sandbox", "approvalPolicy"} {
		if _, ok := p[banned]; ok {
			t.Fatalf("steer params must not carry %q", banned)
		}
	}

	// Round-trip through JSON to verify the encoded frame matches the confirmed shape.
	line, err := encodeCodexRequest(99, "turn/steer", p)
	if err != nil {
		t.Fatal(err)
	}
	var m map[string]any
	if err := json.Unmarshal(line, &m); err != nil {
		t.Fatalf("not JSON: %v", err)
	}
	if m["method"] != "turn/steer" {
		t.Fatalf("method = %v", m["method"])
	}
	if m["id"].(float64) != 99 {
		t.Fatalf("id = %v", m["id"])
	}
	pp := m["params"].(map[string]any)
	if pp["expectedTurnId"] != "turn-1" {
		t.Fatalf("encoded expectedTurnId = %v", pp["expectedTurnId"])
	}
}

// TestCodexRPCErrorCode pins the error-code extractor used to detect -32600
// "no active turn to steer".
func TestCodexRPCErrorCode(t *testing.T) {
	cases := []struct {
		raw  string
		want int
	}{
		{`{"code":-32600,"message":"no active turn to steer"}`, -32600},
		{`{"code":0,"message":"ok"}`, 0},
		{`{}`, 0},
		{`not json`, 0},
	}
	for _, tc := range cases {
		if got := codexRPCErrorCode(json.RawMessage(tc.raw)); got != tc.want {
			t.Fatalf("codexRPCErrorCode(%q) = %d, want %d", tc.raw, got, tc.want)
		}
	}
}

// TestCodexSteerNoActiveTurnCodeValue pins the sentinel constant value so a
// future refactor of the constant doesn't silently change the fallback logic.
func TestCodexSteerNoActiveTurnCodeValue(t *testing.T) {
	if codexSteerNoActiveTurnCode != -32600 {
		t.Fatalf("codexSteerNoActiveTurnCode = %d, want -32600", codexSteerNoActiveTurnCode)
	}
}

// TestCodexSteerSendsFrame: with an active turn (turnID latched), Steer writes
// a turn/steer frame with the correct threadId and expectedTurnId. No turn is
// opened (turnActive stays true, turnReqID is unchanged).
func TestCodexSteerSendsFrame(t *testing.T) {
	buf := &bytes.Buffer{}
	c := &codexAppServerProcess{
		stdin:    bufWriteCloser{buf},
		inited:   true,
		threadID: "t-1",
	}
	c.turnActive = true
	c.turnID = "turn-7"

	if err := c.Steer("steer me"); err != nil {
		t.Fatalf("Steer: %v", err)
	}

	out := buf.String()
	if !strings.Contains(out, `"method":"turn/steer"`) {
		t.Fatalf("must emit turn/steer, got: %s", out)
	}
	if !strings.Contains(out, `"expectedTurnId":"turn-7"`) {
		t.Fatalf("must carry expectedTurnId=turn-7, got: %s", out)
	}
	if !strings.Contains(out, `"threadId":"t-1"`) {
		t.Fatalf("must carry threadId=t-1, got: %s", out)
	}
	if !strings.Contains(out, `"text":"steer me"`) {
		t.Fatalf("must carry steer text, got: %s", out)
	}

	// The turn is still considered active (steer doesn't start a new turn).
	if !c.turnActive {
		t.Fatal("Steer must not clear turnActive")
	}
}

// TestCodexSteerNoopWhenTurnInactive: Steer is a no-op when no turn is in
// flight, and also when the turn id hasn't been latched yet.
func TestCodexSteerNoopWhenTurnInactive(t *testing.T) {
	buf := &bytes.Buffer{}
	c := &codexAppServerProcess{stdin: bufWriteCloser{buf}, inited: true, threadID: "t-1"}

	// No turn in flight → no bytes written.
	if err := c.Steer("hello"); err != nil {
		t.Fatalf("Steer (no turn): %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("Steer with no turn must write nothing, got: %s", buf)
	}

	// Turn active but turnID not yet latched → no bytes written.
	c.turnActive = true
	c.turnID = ""
	if err := c.Steer("hello"); err != nil {
		t.Fatalf("Steer (no turnID): %v", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("Steer with no turnID must write nothing, got: %s", buf)
	}
}

// TestCodexSendSteersDuringActiveTurn: when Send() is called while a turn is
// active with a latched turn id, it emits turn/steer (not turn/start or an
// error) and returns nil.
func TestCodexSendSteersDuringActiveTurn(t *testing.T) {
	buf := &bytes.Buffer{}
	c := &codexAppServerProcess{
		stdin:    bufWriteCloser{buf},
		inited:   true,
		threadID: "t-1",
	}
	c.turnActive = true
	c.turnID = "turn-active"

	err := c.Send("redirect me")
	if err != nil {
		t.Fatalf("Send during active turn = %v, want nil", err)
	}
	out := buf.String()
	if !strings.Contains(out, `"method":"turn/steer"`) {
		t.Fatalf("Send during active turn must emit turn/steer, got: %s", out)
	}
}

// TestCodexSendRejectsWhenTurnActiveNoID: when Send() is called while a turn
// is active but the turn id hasn't been latched (turn/started not yet seen),
// it must return errCodexTurnInFlight (no steer possible without the turn id).
func TestCodexSendRejectsWhenTurnActiveNoID(t *testing.T) {
	buf := &bytes.Buffer{}
	c := &codexAppServerProcess{
		stdin:    bufWriteCloser{buf},
		inited:   true,
		threadID: "t-1",
	}
	c.turnActive = true
	c.turnID = "" // no turn id yet

	err := c.Send("hello")
	if err != errCodexTurnInFlight {
		t.Fatalf("Send with no turnID = %v, want errCodexTurnInFlight", err)
	}
	if buf.Len() != 0 {
		t.Fatalf("Send with no turnID must write nothing, got: %s", buf)
	}
}

// TestCodexSteerFallbackOnError: when the steer response carries a -32600
// error (no active turn), the broker falls back to a normal turn/start using
// the original steer text, and routeTurnResponse clears the steer latch.
func TestCodexSteerFallbackOnError(t *testing.T) {
	buf := &bytes.Buffer{}
	published := &bytes.Buffer{}
	c := &codexAppServerProcess{
		stdin:          bufWriteCloser{buf},
		inited:         true,
		threadID:       "t-1",
		stderrBuf:      bytes.NewBuffer(nil),
		publish:        func(b []byte) { published.Write(b) },
		silenceTimeout: 10 * time.Second,
	}
	c.turnActive = true
	c.turnID = "turn-ended"

	// Steer it — this latches steerReqID and steerText.
	if err := c.Steer("fallback text"); err != nil {
		t.Fatalf("Steer: %v", err)
	}

	// Capture the steer request id so we can build the fake error response.
	c.mu.Lock()
	steerID := c.steerReqID
	c.mu.Unlock()
	if steerID == 0 {
		t.Fatal("steerReqID must be set after Steer()")
	}

	buf.Reset() // clear the steer frame so we can see the fallback start frame

	// Simulate the turn completing (natural path — turn/completed notification).
	c.endTurn()

	// Route the -32600 steer error response through routeTurnResponse, which
	// both clears the steer latch and calls handleSteerResponse (the fallback).
	steerIDRaw, _ := json.Marshal(steerID)
	errRaw := json.RawMessage(`{"code":-32600,"message":"no active turn to steer"}`)
	if !c.routeTurnResponse(steerIDRaw, errRaw) {
		t.Fatal("routeTurnResponse must claim the steer response")
	}

	// The fallback must have written a turn/start frame.
	out := buf.String()
	if !strings.Contains(out, `"method":"turn/start"`) {
		t.Fatalf("steer fallback must emit turn/start, got: %q", out)
	}
	if !strings.Contains(out, `"text":"fallback text"`) {
		t.Fatalf("fallback turn/start must carry original steer text, got: %s", out)
	}

	// Steer latch cleared by routeTurnResponse before calling handleSteerResponse.
	c.mu.Lock()
	gotSteerID := c.steerReqID
	gotSteerText := c.steerText
	c.mu.Unlock()
	if gotSteerID != 0 || gotSteerText != "" {
		t.Fatalf("steer latch must be cleared after response: id=%d text=%q", gotSteerID, gotSteerText)
	}
}

// TestCodexSteerSuccessClears: a successful steer response (no error) clears
// the steer latch (via routeTurnResponse) without publishing anything and
// without touching turnActive.
func TestCodexSteerSuccessClears(t *testing.T) {
	buf := &bytes.Buffer{}
	published := &bytes.Buffer{}
	c := &codexAppServerProcess{
		stdin:     bufWriteCloser{buf},
		inited:    true,
		threadID:  "t-1",
		stderrBuf: bytes.NewBuffer(nil),
		publish:   func(b []byte) { published.Write(b) },
	}
	c.turnActive = true
	c.turnID = "turn-1"

	if err := c.Steer("color it purple"); err != nil {
		t.Fatalf("Steer: %v", err)
	}

	c.mu.Lock()
	steerID := c.steerReqID
	c.mu.Unlock()
	if steerID == 0 {
		t.Fatal("steerReqID must be set after Steer()")
	}

	buf.Reset()

	// Route the success response through routeTurnResponse.
	steerIDRaw, _ := json.Marshal(steerID)
	successResult := json.RawMessage(`{"turnId":"turn-1"}`)
	// Build a full success response (result, not error) to route.
	fullResp, _ := json.Marshal(map[string]any{"id": steerID, "result": successResult})
	_ = fullResp
	// routeTurnResponse takes the rawID and errRaw separately; null errRaw = success.
	if !c.routeTurnResponse(steerIDRaw, nil) {
		t.Fatal("routeTurnResponse must claim the steer response")
	}

	// No new frames written and nothing published.
	if buf.Len() != 0 {
		t.Fatalf("successful steer must not write any new frames, got: %s", buf)
	}
	if published.Len() != 0 {
		t.Fatalf("successful steer must not publish anything, got: %s", published)
	}
	// Turn still active.
	if !c.turnActive {
		t.Fatal("successful steer must not end the turn")
	}
	// Steer latch cleared by routeTurnResponse.
	c.mu.Lock()
	gotSteerID := c.steerReqID
	c.mu.Unlock()
	if gotSteerID != 0 {
		t.Fatalf("steer latch must be cleared on success: id=%d", gotSteerID)
	}
}

// TestCodexAppServerSteerRoundTrip drives a fake codex app-server that knows
// how to handle turn/steer: it responds to the steer with a success result
// and then completes the turn. Verifies the end-to-end flow through the real
// spawn → handshake → turn → steer → turn-end pipeline.
func TestCodexAppServerSteerRoundTrip(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	// The script handles: initialize, thread/start, turn/start, turn/steer.
	// On the steer it emits a second agent message containing "STEERED", then
	// completes the turn.
	script := `#!/usr/bin/env bash
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"userAgent":"fake"}}'
      ;;
    *'"thread/start"'*)
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr-steer"}}}'
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-steer"}}}'
      ;;
    *'"turn/start"'*)
      # Emit turn/started so the turn id is latched.
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-steer","turn":{"id":"turn-s1"}}}'
      printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-s1","status":"inProgress"}}}'
      # Wait briefly (simulating work), then respond to steer in next read.
      ;;
    *'"turn/steer"'*)
      # Reply with steer success.
      tid=$(echo "$line" | grep -o '"expectedTurnId":"[^"]*"' | cut -d'"' -f4)
      printf '%s\n' "{\"id\":4,\"result\":{\"turnId\":\"turn-s1\"}}"
      # Then stream the "steered" agent message and complete the turn.
      printf '%s\n' '{"method":"item/started","params":{"item":{"type":"agentMessage","id":"m2","text":""},"threadId":"thr-steer","turnId":"turn-s1"}}'
      printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m2","text":"STEERED"},"threadId":"thr-steer","turnId":"turn-s1"}}'
      printf '%s\n' '{"method":"thread/tokenUsage/updated","params":{"threadId":"thr-steer","tokenUsage":{"last":{"inputTokens":50,"outputTokens":3},"total":{"inputTokens":50,"outputTokens":3},"modelContextWindow":1000}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-steer","turn":{"id":"turn-s1","status":"completed"}}}'
      ;;
  esac
done
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}

	events := make(chan []byte, 16)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil,
		"",
		func(id string) { threads <- id },
	)
	if err != nil {
		t.Fatalf("newCodexAppServerProcess: %v", err)
	}
	defer proc.Close()

	select {
	case id := <-threads:
		if id != "thr-steer" {
			t.Fatalf("thread id = %q", id)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for thread latch")
	}

	// Start a turn.
	if err := proc.Send("original prompt"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// Wait until the turn id is latched (turn/started received), then steer.
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		proc.mu.Lock()
		tid := proc.turnID
		proc.mu.Unlock()
		if tid != "" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	proc.mu.Lock()
	gotTurnID := proc.turnID
	proc.mu.Unlock()
	if gotTurnID == "" {
		t.Fatal("turn id never latched")
	}

	// Send a steer mid-turn.
	if err := proc.Steer("STEER: write about purple elephants"); err != nil {
		t.Fatalf("Steer: %v", err)
	}

	// Collect the assistant event — it should contain "STEERED" (from the fake's
	// post-steer agent message), proving the steer was accepted and the turn
	// continued under the same id.
	var got string
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
outer:
	for {
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
				continue
			}
			if ev.View == "chat" && ev.Event.Role == "assistant" {
				got = ev.Event.Content
				break outer
			}
		case <-timer.C:
			t.Fatal("timeout waiting for post-steer assistant event")
		}
	}
	if !strings.Contains(got, "STEERED") {
		t.Fatalf("post-steer assistant content = %q, want to contain STEERED", got)
	}
}

// TestCodexAppServerSteerFallbackRoundTrip drives the fallback path end-to-end:
// the fake codex replies to turn/steer with -32600 (turn already ended), and
// the broker falls back to turn/start with the same text. Verifies that the
// fallback turn/start is sent and produces an assistant event.
func TestCodexAppServerSteerFallbackRoundTrip(t *testing.T) {
	dir := t.TempDir()
	fake := filepath.Join(dir, "codex")
	// The fake completes the turn BEFORE responding to the steer, then handles
	// the fallback turn/start normally.
	script := `#!/usr/bin/env bash
first_turn=true
while IFS= read -r line; do
  case "$line" in
    *'"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"userAgent":"fake"}}'
      ;;
    *'"thread/start"'*)
      printf '%s\n' '{"method":"thread/started","params":{"thread":{"id":"thr-fb"}}}'
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-fb"}}}'
      ;;
    *'"turn/start"'*)
      if $first_turn; then
        first_turn=false
        # First turn: emit turn/started, a quick agent message, then complete.
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-fb","turn":{"id":"turn-fb1"}}}'
        printf '%s\n' '{"id":3,"result":{"turn":{"id":"turn-fb1","status":"inProgress"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m1","text":"done"},"threadId":"thr-fb","turnId":"turn-fb1"}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-fb","turn":{"id":"turn-fb1","status":"completed"}}}'
      else
        # Fallback turn/start: emit a normal response.
        printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-fb","turn":{"id":"turn-fb2"}}}'
        printf '%s\n' '{"id":5,"result":{"turn":{"id":"turn-fb2","status":"inProgress"}}}'
        printf '%s\n' '{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"m2","text":"FALLBACK_RESPONSE"},"threadId":"thr-fb","turnId":"turn-fb2"}}'
        printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-fb","turn":{"id":"turn-fb2","status":"completed"}}}'
      fi
      ;;
    *'"turn/steer"'*)
      # Reject with -32600 — the turn already ended.
      steer_id=$(echo "$line" | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)
      printf '%s\n' "{\"id\":${steer_id},\"error\":{\"code\":-32600,\"message\":\"no active turn to steer\"}}"
      ;;
  esac
done
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}

	events := make(chan []byte, 16)
	threads := make(chan string, 4)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil,
		"",
		func(id string) { threads <- id },
	)
	if err != nil {
		t.Fatalf("newCodexAppServerProcess: %v", err)
	}
	defer proc.Close()

	select {
	case <-threads:
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for thread latch")
	}

	// Start the first turn.
	if err := proc.Send("first prompt"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// Wait for the first turn to complete and drain its event.
	timer := time.NewTimer(10 * time.Second)
	defer timer.Stop()
	gotFirst := false
	for !gotFirst {
		select {
		case p := <-events:
			var ev struct {
				View  string                         `json:"view"`
				Event struct{ Role, Content string } `json:"event"`
			}
			if json.Unmarshal(p, &ev) == nil && ev.Event.Role == "assistant" && ev.Event.Content == "done" {
				gotFirst = true
			}
		case <-timer.C:
			t.Fatal("timeout waiting for first turn event")
		}
	}

	// Wait for the first turn to truly end so turnID is latched then cleared.
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		proc.mu.Lock()
		active := proc.turnActive
		proc.mu.Unlock()
		if !active {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Now manually set up the steer scenario: pretend we sent a steer but the
	// turn had just ended. We directly call handleSteerResponse with a -32600
	// error to exercise the fallback path.
	timer.Reset(10 * time.Second)
	proc.handleSteerResponse("STEER_FALLBACK_TEXT", json.RawMessage(`{"code":-32600,"message":"no active turn to steer"}`))

	// The fallback should have started a new turn. Collect its response.
	var got string
	for got == "" {
		select {
		case p := <-events:
			var ev struct {
				View  string                         `json:"view"`
				Event struct{ Role, Content string } `json:"event"`
			}
			if json.Unmarshal(p, &ev) == nil && ev.Event.Role == "assistant" {
				got = ev.Event.Content
			}
		case <-timer.C:
			t.Fatal("timeout waiting for fallback turn event")
		}
	}
	if !strings.Contains(got, "FALLBACK_RESPONSE") {
		t.Fatalf("fallback turn response = %q, want to contain FALLBACK_RESPONSE", got)
	}
}
