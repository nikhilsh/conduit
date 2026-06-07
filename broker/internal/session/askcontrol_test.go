package session

import (
	"encoding/json"
	"strings"
	"testing"
)

// Shapes captured live against claude-code 2.1.168 with
// `--permission-prompt-tool stdio` (post-v0.0.118 AskUserQuestion probe).

const askControlLine = `{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which colors?","multiSelect":true,"options":[{"label":"Red"},{"label":"Green"}]}]},"tool_use_id":"toolu_1"}}`

func TestParseControlRequest(t *testing.T) {
	req, ok := parseControlRequest([]byte(askControlLine))
	if !ok {
		t.Fatal("expected control_request to parse")
	}
	if req.RequestID != "req-1" || req.ToolName != "AskUserQuestion" {
		t.Fatalf("parsed %+v", req)
	}
	if !strings.Contains(string(req.Input), "Which colors?") {
		t.Fatalf("input not carried: %s", req.Input)
	}

	for _, bad := range []string{
		`{"type":"assistant","message":{}}`,
		`{"type":"control_request","request":{"subtype":"other"}}`,
		`not json`,
	} {
		if _, ok := parseControlRequest([]byte(bad)); ok {
			t.Fatalf("should not parse: %s", bad)
		}
	}
}

func TestEncodeControlAllowUnchanged(t *testing.T) {
	line := encodeControlAllow("req-9", json.RawMessage(`{"a":1}`))
	var env struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string `json:"subtype"`
			RequestID string `json:"request_id"`
			Response  struct {
				Behavior     string          `json:"behavior"`
				UpdatedInput json.RawMessage `json:"updatedInput"`
			} `json:"response"`
		} `json:"response"`
	}
	if err := json.Unmarshal(line, &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Type != "control_response" || env.Response.RequestID != "req-9" ||
		env.Response.Response.Behavior != "allow" {
		t.Fatalf("envelope: %s", line)
	}
	if string(env.Response.Response.UpdatedInput) != `{"a":1}` {
		t.Fatalf("updatedInput: %s", env.Response.Response.UpdatedInput)
	}
	if line[len(line)-1] != '\n' {
		t.Fatal("control line must be newline-terminated")
	}
}

func TestEncodeAskAnswerSingleQuestionUsesAnswers(t *testing.T) {
	req, _ := parseControlRequest([]byte(askControlLine))
	line, err := encodeAskAnswer(req.RequestID, req.Input, "Red, Green")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	s := string(line)
	if !strings.Contains(s, `"answers":{"Which colors?":"Red, Green"}`) {
		t.Fatalf("expected answers map, got: %s", s)
	}
	// Original questions must ride along unchanged.
	if !strings.Contains(s, `"questions":[`) {
		t.Fatalf("expected original questions preserved: %s", s)
	}
}

func TestEncodeAskAnswerMultiQuestionUsesFreeText(t *testing.T) {
	input := json.RawMessage(`{"questions":[{"question":"A?"},{"question":"B?"}]}`)
	line, err := encodeAskAnswer("req-2", input, "A: yes. B: no.")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if !strings.Contains(string(line), `"response":"A: yes. B: no."`) {
		t.Fatalf("expected free-text response, got: %s", line)
	}
}

// A pending ask consumes the next SendChat message as the control answer
// (no plain user turn), and a second message goes through normally.
func TestSendChatAnswersPendingAsk(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.kittyRoot = dir
	s.ID = "ask-test"
	s.applyPaths()
	fake := &fakeChatBackend{}
	s.chat = fake

	req, _ := parseControlRequest([]byte(askControlLine))
	// Stash without a real chatProcess: drive takePendingAsk directly.
	s.mu.Lock()
	s.pendingAsk = &pendingAsk{requestID: req.RequestID, input: req.Input}
	s.mu.Unlock()

	ask := s.takePendingAsk()
	if ask == nil || ask.requestID != "req-1" {
		t.Fatalf("takePendingAsk: %+v", ask)
	}
	if again := s.takePendingAsk(); again != nil {
		t.Fatalf("pending ask must be consumed once, got %+v", again)
	}
	line, err := encodeAskAnswer(ask.requestID, ask.input, "Green")
	if err != nil || !strings.Contains(string(line), `"Green"`) {
		t.Fatalf("answer encode: %v %s", err, line)
	}
}

type fakeChatBackend struct{ sent []string }

func (f *fakeChatBackend) Send(text string) error { f.sent = append(f.sent, text); return nil }
func (f *fakeChatBackend) Close() error           { return nil }

// The multi-select marker rides inside the rendered card text.
func TestAskUserQuestionContentMultiSelectMarker(t *testing.T) {
	input := json.RawMessage(`{"questions":[
		{"question":"Pick colors","multiSelect":true,"options":[{"label":"Red"},{"label":"Green"}]},
		{"question":"Pick one","options":[{"label":"A"},{"label":"B"}]}
	]}`)
	content, ok := askUserQuestionContent(input)
	if !ok {
		t.Fatal("expected content")
	}
	if !strings.Contains(content, "Pick colors"+multiSelectMarker+"\n1. Red") {
		t.Fatalf("multi-select question missing marker: %q", content)
	}
	if strings.Contains(content, "Pick one"+multiSelectMarker) {
		t.Fatalf("single-select question must not carry the marker: %q", content)
	}
}
