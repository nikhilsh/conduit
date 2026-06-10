package session

import (
	"bufio"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestCodexApprovalCardContent: an approval request renders as the SAME
// pending-input-shaped chat line claude's AskUserQuestion uses — the sentinel,
// a question, and a numbered Approve/Deny menu — so the apps render the tappable
// approval card with zero changes.
func TestCodexApprovalCardContent(t *testing.T) {
	req, ok := parseCodexApprovalRequest(
		"item/commandExecution/requestApproval",
		json.RawMessage(`{"command":"/bin/bash -lc 'echo hi > hello.txt'","cwd":"/work","itemId":"call_1","threadId":"thr-1","turnId":"turn-1"}`),
	)
	if !ok {
		t.Fatal("parse failed")
	}
	if req.summary != "/bin/bash -lc 'echo hi > hello.txt'" {
		t.Fatalf("summary = %q", req.summary)
	}
	if req.cwd != "/work" {
		t.Fatalf("cwd = %q", req.cwd)
	}
	content, ok := codexApprovalCardContent(req)
	if !ok {
		t.Fatal("card content failed")
	}
	// Must lead with the deterministic sentinel the core classifier keys on.
	if !strings.HasPrefix(content, pendingInputSentinel+"\n") {
		t.Fatalf("card must start with sentinel:\n%s", content)
	}
	// Numbered Approve/Deny menu (the shape extract_pending_options parses).
	if !strings.Contains(content, "\n1. "+codexApprovalApproveLabel) ||
		!strings.Contains(content, "\n2. "+codexApprovalDenyLabel) {
		t.Fatalf("card missing numbered Approve/Deny menu:\n%s", content)
	}
	if !strings.Contains(content, "/bin/bash -lc 'echo hi > hello.txt'") {
		t.Fatalf("card missing command summary:\n%s", content)
	}
	if !strings.Contains(content, "/work") {
		t.Fatalf("card missing cwd:\n%s", content)
	}
}

// TestCodexApprovalCardFileChange: a file-change approval (no `command`) gets a
// synthesized human summary so the card is never blank.
func TestCodexApprovalCardFileChange(t *testing.T) {
	cases := []struct {
		name   string
		params string
		want   string
	}{
		{"single", `{"changes":[{"path":"a.txt"}],"cwd":"/w"}`, "edit a.txt"},
		{"multi", `{"changes":[{"path":"a.txt"},{"path":"b.txt"}],"cwd":"/w"}`, "apply changes to 2 files"},
		{"none", `{"changes":[],"cwd":"/w"}`, "apply file changes"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req, ok := parseCodexApprovalRequest("item/fileChange/requestApproval", json.RawMessage(tc.params))
			if !ok {
				t.Fatal("parse failed")
			}
			if req.summary != tc.want {
				t.Fatalf("summary = %q, want %q", req.summary, tc.want)
			}
			if _, ok := codexApprovalCardContent(req); !ok {
				t.Fatal("card content failed")
			}
		})
	}
}

// TestCodexApprovalDecisionFor: Approve → accept; everything else → cancel
// (cancel is always available and ends the turn cleanly; decline is not always
// offered).
func TestCodexApprovalDecisionFor(t *testing.T) {
	cases := map[string]string{
		"Approve":     "accept",
		"approve":     "accept",
		"  Approve  ": "accept",
		"Deny":        "cancel",
		"no":          "cancel",
		"":            "cancel",
		"garbage":     "cancel",
	}
	for answer, want := range cases {
		if got := codexApprovalDecisionFor(answer); got != want {
			t.Fatalf("decision(%q) = %q, want %q", answer, got, want)
		}
	}
}

// TestEncodeCodexResponse: the response echoes the request id VERBATIM (codex's
// RequestId is string|integer; the approval id is a server-side counter that may
// be 0) and carries no `jsonrpc` field, newline-terminated.
func TestEncodeCodexResponse(t *testing.T) {
	for _, rawID := range []string{`0`, `42`, `"req-abc"`} {
		t.Run(rawID, func(t *testing.T) {
			line, err := encodeCodexResponse(json.RawMessage(rawID), map[string]any{"decision": "accept"})
			if err != nil {
				t.Fatal(err)
			}
			if !strings.HasSuffix(string(line), "\n") {
				t.Fatalf("not newline-terminated: %q", line)
			}
			// The id must serialize back to the exact same JSON token.
			var m map[string]json.RawMessage
			if err := json.Unmarshal(line, &m); err != nil {
				t.Fatalf("not json: %v", err)
			}
			if _, ok := m["jsonrpc"]; ok {
				t.Fatal("jsonrpc must be omitted")
			}
			if string(m["id"]) != rawID {
				t.Fatalf("id = %s, want %s", m["id"], rawID)
			}
			if string(m["result"]) != `{"decision":"accept"}` {
				t.Fatalf("result = %s", m["result"])
			}
		})
	}
}

func TestCodexIsApprovalMethod(t *testing.T) {
	yes := []string{"item/commandExecution/requestApproval", "item/fileChange/requestApproval"}
	no := []string{"item/tool/requestUserInput", "mcpServer/elicitation/request", "turn/completed", ""}
	for _, m := range yes {
		if !codexIsApprovalMethod(m) {
			t.Fatalf("%q should be an approval method", m)
		}
	}
	for _, m := range no {
		if codexIsApprovalMethod(m) {
			t.Fatalf("%q should NOT be an approval method", m)
		}
	}
}

// codexApprovalStub writes a fake `codex` binary that handshakes, then on
// turn/start emits a command-execution approval REQUEST (id:0, the server-side
// counter from the live capture) and waits. Every line it reads is appended to
// recvPath so the test can assert the approval RESPONSE it receives. After it
// sees a response for id 0 it streams a completing turn.
func codexApprovalStub(t *testing.T, dir, recvPath string) string {
	t.Helper()
	fake := filepath.Join(dir, "codex")
	script := `#!/usr/bin/env bash
RECV="` + recvPath + `"
while IFS= read -r line; do
  printf '%s\n' "$line" >> "$RECV"
  case "$line" in
    *'"initialize"'*)
      printf '%s\n' '{"id":1,"result":{"userAgent":"fake"}}'
      ;;
    *'"thread/start"'*)
      printf '%s\n' '{"id":2,"result":{"thread":{"id":"thr-1"}}}'
      ;;
    *'"turn/start"'*)
      printf '%s\n' '{"method":"turn/started","params":{"threadId":"thr-1","turn":{"id":"turn-1"}}}'
      printf '%s\n' '{"method":"item/commandExecution/requestApproval","id":0,"params":{"threadId":"thr-1","turnId":"turn-1","itemId":"call_1","command":"/bin/bash -lc '"'"'echo hi > hello.txt'"'"'","cwd":"'"$PWD"'","availableDecisions":["accept","cancel"]}}'
      ;;
    *'"id":0'*'"decision"'*)
      # The broker answered the approval. Acknowledge + complete the turn.
      printf '%s\n' '{"method":"serverRequest/resolved","params":{"threadId":"thr-1","requestId":0}}'
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-1","item":{"type":"agentMessage","id":"m1","text":"done"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"status":"completed"}}}'
      ;;
  esac
done
`
	if err := os.WriteFile(fake, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	return fake
}

// waitForApprovalResponse polls recvPath for a JSON-RPC response line carrying
// the approval decision and returns the decision string.
func waitForApprovalResponse(t *testing.T, recvPath string) string {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			b, _ := os.ReadFile(recvPath)
			t.Fatalf("timeout waiting for approval response; recv so far:\n%s", b)
		default:
		}
		f, err := os.Open(recvPath)
		if err == nil {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				line := sc.Bytes()
				var m struct {
					ID     json.RawMessage `json:"id"`
					Method string          `json:"method"`
					Result struct {
						Decision string `json:"decision"`
					} `json:"result"`
				}
				if json.Unmarshal(line, &m) == nil && m.Method == "" && string(m.ID) == "0" && m.Result.Decision != "" {
					f.Close()
					return m.Result.Decision
				}
			}
			f.Close()
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// TestCodexApprovalAcceptIntegration drives the real backend against a stub
// codex that requests approval: the card surfaces as a chat event, AnswerApproval
// sends accept, and the stub receives a well-formed {"id":0,"result":{"decision":"accept"}}.
func TestCodexApprovalAcceptIntegration(t *testing.T) {
	dir := t.TempDir()
	recv := filepath.Join(dir, "recv.jsonl")
	fake := codexApprovalStub(t, dir, recv)

	events := make(chan []byte, 32)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(string) {},
	)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	defer proc.Close()

	if err := proc.Send("do the thing"); err != nil {
		t.Fatalf("Send: %v", err)
	}

	// The approval card must arrive as a pending-input chat event.
	card := waitForChatEvent(t, events, func(role, content string) bool {
		return role == "assistant" && strings.HasPrefix(content, pendingInputSentinel)
	})
	if !strings.Contains(card, codexApprovalApproveLabel) {
		t.Fatalf("approval card missing Approve option:\n%s", card)
	}

	// The backend must report a pending approval (so a reattaching client can
	// re-surface it) before the user answers.
	if _, ok := proc.PendingApprovalCard(); !ok {
		t.Fatal("expected a pending approval card")
	}

	// User taps "Approve" → routed as the JSON-RPC decision.
	if !proc.AnswerApproval(codexApprovalApproveLabel) {
		t.Fatal("AnswerApproval should report handled")
	}
	if got := waitForApprovalResponse(t, recv); got != "accept" {
		t.Fatalf("decision = %q, want accept", got)
	}

	// Pending approval cleared after answering.
	if _, ok := proc.PendingApprovalCard(); ok {
		t.Fatal("pending approval should be cleared after answering")
	}
	// A second answer with nothing pending is a no-op (false).
	if proc.AnswerApproval("anything") {
		t.Fatal("AnswerApproval with nothing pending should return false")
	}
}

// TestCodexApprovalDenyIntegration: tapping Deny sends cancel.
func TestCodexApprovalDenyIntegration(t *testing.T) {
	dir := t.TempDir()
	recv := filepath.Join(dir, "recv.jsonl")
	fake := codexApprovalStub(t, dir, recv)

	events := make(chan []byte, 32)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(string) {},
	)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	defer proc.Close()

	if err := proc.Send("do the thing"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	waitForChatEvent(t, events, func(role, content string) bool {
		return role == "assistant" && strings.HasPrefix(content, pendingInputSentinel)
	})
	if !proc.AnswerApproval(codexApprovalDenyLabel) {
		t.Fatal("AnswerApproval should report handled")
	}
	if got := waitForApprovalResponse(t, recv); got != "cancel" {
		t.Fatalf("decision = %q, want cancel", got)
	}
}

// TestCodexApprovalTimeoutDenies: an unanswered approval auto-denies (cancel)
// after the give-up timer fires.
func TestCodexApprovalTimeoutDenies(t *testing.T) {
	prev := askAnswerTimeout
	askAnswerTimeout = 50 * time.Millisecond
	defer func() { askAnswerTimeout = prev }()

	dir := t.TempDir()
	recv := filepath.Join(dir, "recv.jsonl")
	fake := codexApprovalStub(t, dir, recv)

	events := make(chan []byte, 32)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(string) {},
	)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	defer proc.Close()

	if err := proc.Send("do the thing"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	waitForChatEvent(t, events, func(role, content string) bool {
		return role == "assistant" && strings.HasPrefix(content, pendingInputSentinel)
	})
	// Don't answer — the give-up timer must auto-deny with cancel.
	if got := waitForApprovalResponse(t, recv); got != "cancel" {
		t.Fatalf("timeout decision = %q, want cancel", got)
	}
}

// waitForChatEvent reads chat view_events until one matches, returning its
// content. Fails on timeout.
func waitForChatEvent(t *testing.T, events <-chan []byte, match func(role, content string) bool) string {
	t.Helper()
	deadline := time.After(5 * time.Second)
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
			if json.Unmarshal(p, &ev) != nil || ev.View != "chat" {
				continue
			}
			if match(ev.Event.Role, ev.Event.Content) {
				return ev.Event.Content
			}
		case <-deadline:
			t.Fatal("timeout waiting for matching chat event")
		}
	}
}
