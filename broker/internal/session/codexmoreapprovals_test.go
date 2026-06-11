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

// writeExec writes an executable stub script.
func writeExec(t *testing.T, path, script string) error {
	t.Helper()
	return os.WriteFile(path, []byte(script), 0o755)
}

// waitForResponseLine polls recvPath for a JSON-RPC response line (id 0, no
// method) whose decoded object satisfies match, returning the raw line.
func waitForResponseLine(t *testing.T, recvPath string, match func(map[string]json.RawMessage) bool) string {
	t.Helper()
	deadline := time.After(5 * time.Second)
	for {
		select {
		case <-deadline:
			b, _ := os.ReadFile(recvPath)
			t.Fatalf("timeout waiting for response line; recv so far:\n%s", b)
		default:
		}
		if f, err := os.Open(recvPath); err == nil {
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 0, 64*1024), 1024*1024)
			for sc.Scan() {
				line := sc.Bytes()
				var probe struct {
					ID     json.RawMessage `json:"id"`
					Method string          `json:"method"`
				}
				if json.Unmarshal(line, &probe) != nil || probe.Method != "" || string(probe.ID) != "0" {
					continue
				}
				var m map[string]json.RawMessage
				if json.Unmarshal(line, &m) == nil {
					if _, ok := m["result"]; ok {
						var res map[string]json.RawMessage
						if json.Unmarshal(m["result"], &res) == nil && match(res) {
							f.Close()
							return string(line)
						}
					}
				}
			}
			f.Close()
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// These tests cover the THREE additional server→client request types the codex
// app-server can send beyond command-execution approval (which were previously
// silently empty-acked): file-change approval (now with a joined diff/path),
// item/tool/requestUserInput, and mcpServer/elicitation/request. The captured
// frames are verbatim from codex-cli 0.132.0 (fileChange live-captured; the
// other two schema-captured — see docs/CODEX-APPSERVER-PROTOCOL.md).

// ---- file-change item join (the diff/path source) ----------------------------

// TestParseCodexFileChangeItem: a fileChange item/started notification yields
// the id + per-change path/diff so a later approval request can join to it. The
// frame is verbatim from the live 0.132 capture.
func TestParseCodexFileChangeItem(t *testing.T) {
	// item/started for a fileChange (live 0.132 capture, paths/ids trimmed).
	params := json.RawMessage(`{"item":{"type":"fileChange","id":"call_X","changes":[{"path":"/tmp/w/notes.txt","kind":{"type":"update","move_path":null},"diff":"@@ -2 +2,2 @@\n this is a seed file\n+GOODBYE\n"}],"status":"inProgress"},"threadId":"t","turnId":"u","startedAtMs":1}`)
	fc, ok := parseCodexFileChangeItem(params)
	if !ok {
		t.Fatal("expected a fileChange item")
	}
	if fc.id != "call_X" {
		t.Fatalf("id = %q", fc.id)
	}
	if len(fc.changes) != 1 || fc.changes[0].path != "/tmp/w/notes.txt" {
		t.Fatalf("changes = %+v", fc.changes)
	}
	if !strings.Contains(fc.changes[0].diff, "+GOODBYE") {
		t.Fatalf("diff = %q", fc.changes[0].diff)
	}

	// A non-fileChange item is ignored.
	if _, ok := parseCodexFileChangeItem(json.RawMessage(`{"item":{"type":"commandExecution","id":"c"}}`)); ok {
		t.Fatal("commandExecution item should not parse as a fileChange")
	}
	// A fileChange without an id is ignored (nothing to join on).
	if _, ok := parseCodexFileChangeItem(json.RawMessage(`{"item":{"type":"fileChange","changes":[]}}`)); ok {
		t.Fatal("fileChange with no id should not parse")
	}
}

// TestCodexFileChangeApprovalParse: the REAL 0.132 file-change approval request
// (verbatim live capture) carries ONLY itemId/threadId/turnId/startedAtMs — no
// command/cwd/changes — so the summary must come from the joined item, and
// decline must always be available.
func TestCodexFileChangeApprovalParse(t *testing.T) {
	// Verbatim from the live capture.
	params := json.RawMessage(`{"threadId":"019eb43d-5099-73b3-ae05-43068af51349","turnId":"019eb43d-511c-7052-8d0c-0a246e794e46","itemId":"call_XpdYgBBNHRXxKymuVa1GTgaA","startedAtMs":1781140384431,"reason":null,"grantRoot":null}`)
	joined := &codexFileChangeItem{
		id:      "call_XpdYgBBNHRXxKymuVa1GTgaA",
		changes: []codexFileChange{{path: "notes.txt", diff: "@@\n+GOODBYE\n"}},
	}
	req, ok := parseCodexApprovalRequest(codexMethodFileChangeApproval, params, joined)
	if !ok {
		t.Fatal("parse failed")
	}
	if req.summary != "edit notes.txt" {
		t.Fatalf("summary = %q, want 'edit notes.txt'", req.summary)
	}
	if !req.declineAvailable {
		t.Fatal("fileChange must always offer decline")
	}
	content, ok := codexApprovalCardContent(codexMethodFileChangeApproval, req)
	if !ok {
		t.Fatal("card content failed")
	}
	if !strings.HasPrefix(content, pendingInputSentinel+"\n") {
		t.Fatalf("card missing sentinel:\n%s", content)
	}
	if !strings.Contains(content, "file change") {
		t.Fatalf("file-change card should mention a file change:\n%s", content)
	}
	if !strings.Contains(content, "edit notes.txt") {
		t.Fatalf("card missing path summary:\n%s", content)
	}
	// The raw diff must NOT leak into the card (would pollute option parsing).
	if strings.Contains(content, "+GOODBYE") {
		t.Fatalf("raw diff must not appear in the card body:\n%s", content)
	}
}

// ---- item/tool/requestUserInput ---------------------------------------------

// TestCodexUserInputCardWithOptions: a requestUserInput with options renders as
// a numbered pending-input card and the answer maps to {answers:{id:{answers:[…]}}}.
func TestCodexUserInputCardWithOptions(t *testing.T) {
	// Schema-shaped frame (ToolRequestUserInputParams, codex-cli 0.132.0).
	params := json.RawMessage(`{"itemId":"i","threadId":"t","turnId":"u","questions":[{"id":"q1","header":"Pick a fruit","question":"Which fruit?","options":[{"label":"Apple","description":"a pome"},{"label":"Banana","description":"a berry"}]}]}`)
	req, ok := parseCodexUserInputRequest(params)
	if !ok {
		t.Fatal("parse failed")
	}
	content, ok := codexUserInputCardContent(req)
	if !ok {
		t.Fatal("card content failed")
	}
	if !strings.HasPrefix(content, pendingInputSentinel+"\n") {
		t.Fatalf("card missing sentinel:\n%s", content)
	}
	for _, want := range []string{"Pick a fruit", "Which fruit?", "1. Apple", "2. Banana"} {
		if !strings.Contains(content, want) {
			t.Fatalf("card missing %q:\n%s", want, content)
		}
	}
	// The user taps "Apple" → {"answers":{"q1":{"answers":["Apple"]}}}.
	res := codexBuildUserInputResult(req, "Apple")
	b, _ := json.Marshal(res)
	if string(b) != `{"answers":{"q1":{"answers":["Apple"]}}}` {
		t.Fatalf("result = %s", b)
	}
}

// TestCodexUserInputFreeText: a question with no options renders as a free-text
// card (sentinel + prompt, no numbered menu) and the typed reply is sent verbatim.
func TestCodexUserInputFreeText(t *testing.T) {
	params := json.RawMessage(`{"itemId":"i","threadId":"t","turnId":"u","questions":[{"id":"name","header":"Name","question":"What is your name?"}]}`)
	req, ok := parseCodexUserInputRequest(params)
	if !ok {
		t.Fatal("parse failed")
	}
	content, _ := codexUserInputCardContent(req)
	if strings.Contains(content, "\n1. ") {
		t.Fatalf("free-text card should have no numbered menu:\n%s", content)
	}
	res := codexBuildUserInputResult(req, "  Ada  ")
	b, _ := json.Marshal(res)
	if string(b) != `{"answers":{"name":{"answers":["Ada"]}}}` {
		t.Fatalf("result = %s", b)
	}
}

// TestCodexUserInputMultiQuestion: only the first question is surfaced; the rest
// get an empty answer so the response is well-formed (the schema requires an
// entry per question id).
func TestCodexUserInputMultiQuestion(t *testing.T) {
	params := json.RawMessage(`{"itemId":"i","threadId":"t","turnId":"u","questions":[{"id":"a","header":"H","question":"Q1?"},{"id":"b","header":"H","question":"Q2?"}]}`)
	req, ok := parseCodexUserInputRequest(params)
	if !ok {
		t.Fatal("parse failed")
	}
	res := codexBuildUserInputResult(req, "answer-1")
	b, _ := json.Marshal(res)
	var got struct {
		Answers map[string]struct {
			Answers []string `json:"answers"`
		} `json:"answers"`
	}
	if err := json.Unmarshal(b, &got); err != nil {
		t.Fatal(err)
	}
	if len(got.Answers) != 2 {
		t.Fatalf("expected 2 answer entries, got %d (%s)", len(got.Answers), b)
	}
	if len(got.Answers["a"].Answers) != 1 || got.Answers["a"].Answers[0] != "answer-1" {
		t.Fatalf("first answer wrong: %s", b)
	}
	if len(got.Answers["b"].Answers) != 0 {
		t.Fatalf("second question should be empty: %s", b)
	}
}

// TestCodexUserInputEmpty: a payload with no answerable question is rejected so
// the caller takes the auto-answer safety net.
func TestCodexUserInputEmpty(t *testing.T) {
	for _, p := range []string{`{"questions":[]}`, `{"questions":[{"id":"","question":""}]}`, `{`} {
		if _, ok := parseCodexUserInputRequest(json.RawMessage(p)); ok {
			t.Fatalf("expected parse failure for %q", p)
		}
	}
}

// ---- mcpServer/elicitation/request ------------------------------------------

// TestCodexElicitationFormCard: a form-mode elicitation renders as an
// Approve/Decline card; the answer maps to {"action":…}.
func TestCodexElicitationFormCard(t *testing.T) {
	// Schema-shaped form-mode frame (McpServerElicitationRequestParams).
	params := json.RawMessage(`{"serverName":"github","threadId":"t","mode":"form","message":"Authorize access to your repos?","requestedSchema":{"type":"object","properties":{}}}`)
	req, ok := parseCodexElicitationRequest(params)
	if !ok {
		t.Fatal("parse failed")
	}
	content, ok := codexElicitationCardContent(req)
	if !ok {
		t.Fatal("card content failed")
	}
	if !strings.HasPrefix(content, pendingInputSentinel+"\n") {
		t.Fatalf("card missing sentinel:\n%s", content)
	}
	for _, want := range []string{"github", "Authorize access to your repos?", "1. Approve", "2. Decline"} {
		if !strings.Contains(content, want) {
			t.Fatalf("card missing %q:\n%s", want, content)
		}
	}
	if codexElicitationActionFor("Approve") != "accept" {
		t.Fatal("Approve → accept")
	}
	if codexElicitationActionFor("Decline") != "decline" {
		t.Fatal("Decline → decline")
	}
	if codexElicitationActionFor("anything else") != "decline" {
		t.Fatal("non-approve → decline (safe default)")
	}
}

// TestCodexElicitationUrlCard: a url-mode elicitation includes the URL in the body.
func TestCodexElicitationUrlCard(t *testing.T) {
	params := json.RawMessage(`{"serverName":"auth","threadId":"t","mode":"url","message":"Open this link to sign in","url":"https://example.com/login","elicitationId":"e1"}`)
	req, ok := parseCodexElicitationRequest(params)
	if !ok {
		t.Fatal("parse failed")
	}
	content, _ := codexElicitationCardContent(req)
	if !strings.Contains(content, "https://example.com/login") {
		t.Fatalf("url-mode card missing the link:\n%s", content)
	}
}

// TestCodexSafetyNetResult: the abandoned-request (timeout/EOF/close) deny shape
// matches each kind so the turn never hangs silently.
func TestCodexSafetyNetResult(t *testing.T) {
	if got := codexSafetyNetResult(codexReqApproval, codexUserInputRequest{}); got["decision"] != codexDecisionCancel {
		t.Fatalf("approval safety net = %+v, want decision=cancel", got)
	}
	if got := codexSafetyNetResult(codexReqElicitation, codexUserInputRequest{}); got["action"] != codexElicitationDecline {
		t.Fatalf("elicitation safety net = %+v, want action=decline", got)
	}
	ui := codexUserInputRequest{questions: []codexUserInputQuestion{{id: "q"}}}
	got := codexSafetyNetResult(codexReqUserInput, ui)
	b, _ := json.Marshal(got)
	if string(b) != `{"answers":{"q":{"answers":[]}}}` {
		t.Fatalf("userInput safety net = %s, want empty answers", b)
	}
}

// TestCodexServerRequestKindFor: each method routes to the right kind.
func TestCodexServerRequestKindFor(t *testing.T) {
	cases := map[string]codexServerRequestKind{
		codexMethodCommandApproval:    codexReqApproval,
		codexMethodFileChangeApproval: codexReqApproval,
		codexMethodRequestUserInput:   codexReqUserInput,
		codexMethodMcpElicitation:     codexReqElicitation,
		"attestation/generate":        codexReqUnknown,
		"item/tool/call":              codexReqUnknown,
		"":                            codexReqUnknown,
	}
	for method, want := range cases {
		if got := codexServerRequestKindFor(method); got != want {
			t.Fatalf("kind(%q) = %d, want %d", method, got, want)
		}
	}
}

// ---- integration: each new request type drives the real backend -------------

// codexUserInputStub emits an item/tool/requestUserInput request on turn/start,
// records every line it reads to recvPath, then completes the turn once it sees
// the response.
func codexUserInputStub(t *testing.T, dir, recvPath string) string {
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
      printf '%s\n' '{"method":"item/tool/requestUserInput","id":0,"params":{"itemId":"i","threadId":"thr-1","turnId":"turn-1","questions":[{"id":"q1","header":"Choose","question":"Pick one","options":[{"label":"Apple","description":"d"},{"label":"Banana","description":"d"}]}]}}'
      ;;
    *'"id":0'*'"answers"'*)
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-1","item":{"type":"agentMessage","id":"m1","text":"done"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"status":"completed"}}}'
      ;;
  esac
done
`
	if err := writeExec(t, fake, script); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	return fake
}

// TestCodexUserInputIntegration drives the backend against a stub that requests
// user input: the question card surfaces, AnswerApproval routes the tap to the
// ToolRequestUserInputResponse shape.
func TestCodexUserInputIntegration(t *testing.T) {
	dir := t.TempDir()
	recv := filepath.Join(dir, "recv.jsonl")
	fake := codexUserInputStub(t, dir, recv)

	events := make(chan []byte, 32)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(string) {},
		nil, // no subagent roster in unit tests
	)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	defer proc.Close()

	if err := proc.Send("do the thing"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	card := waitForChatEvent(t, events, func(role, content string) bool {
		return role == "assistant" && strings.HasPrefix(content, pendingInputSentinel)
	})
	if !strings.Contains(card, "1. Apple") {
		t.Fatalf("user-input card missing options:\n%s", card)
	}
	if !proc.AnswerApproval("Apple") {
		t.Fatal("AnswerApproval should report handled")
	}
	// The stub records the response line; assert it is the answers shape.
	got := waitForResponseLine(t, recv, func(m map[string]json.RawMessage) bool {
		_, ok := m["answers"]
		return ok
	})
	if !strings.Contains(got, `"Apple"`) {
		t.Fatalf("response missing the answer: %s", got)
	}
}

// codexElicitationStub emits an mcpServer/elicitation/request on turn/start.
func codexElicitationStub(t *testing.T, dir, recvPath string) string {
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
      printf '%s\n' '{"method":"mcpServer/elicitation/request","id":0,"params":{"serverName":"github","threadId":"thr-1","mode":"form","message":"Authorize?","requestedSchema":{"type":"object","properties":{}}}}'
      ;;
    *'"id":0'*'"action"'*)
      printf '%s\n' '{"method":"item/completed","params":{"threadId":"thr-1","item":{"type":"agentMessage","id":"m1","text":"done"}}}'
      printf '%s\n' '{"method":"turn/completed","params":{"threadId":"thr-1","turn":{"status":"completed"}}}'
      ;;
  esac
done
`
	if err := writeExec(t, fake, script); err != nil {
		t.Fatalf("write fake: %v", err)
	}
	return fake
}

// TestCodexElicitationIntegration: an elicitation surfaces as an Approve/Decline
// card and a deny sends {"action":"decline"}.
func TestCodexElicitationIntegration(t *testing.T) {
	dir := t.TempDir()
	recv := filepath.Join(dir, "recv.jsonl")
	fake := codexElicitationStub(t, dir, recv)

	events := make(chan []byte, 32)
	proc, err := newCodexAppServerProcess(
		fake, dir, nil, SpawnOverride{},
		func(p []byte) { events <- p },
		nil, "", func(string) {},
		nil, // no subagent roster in unit tests
	)
	if err != nil {
		t.Fatalf("construct: %v", err)
	}
	defer proc.Close()

	if err := proc.Send("do the thing"); err != nil {
		t.Fatalf("Send: %v", err)
	}
	card := waitForChatEvent(t, events, func(role, content string) bool {
		return role == "assistant" && strings.HasPrefix(content, pendingInputSentinel)
	})
	if !strings.Contains(card, "Authorize?") || !strings.Contains(card, "Decline") {
		t.Fatalf("elicitation card wrong:\n%s", card)
	}
	if !proc.AnswerApproval("Decline") {
		t.Fatal("AnswerApproval should report handled")
	}
	got := waitForResponseLine(t, recv, func(m map[string]json.RawMessage) bool {
		_, ok := m["action"]
		return ok
	})
	if !strings.Contains(got, `"decline"`) {
		t.Fatalf("response action wrong: %s", got)
	}
}
