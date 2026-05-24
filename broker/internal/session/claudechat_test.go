package session

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestEncodeClaudeUserMessage(t *testing.T) {
	line, err := encodeClaudeUserMessage("hello world")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if len(line) == 0 || line[len(line)-1] != '\n' {
		t.Fatalf("expected trailing newline, got %q", line)
	}
	var got struct {
		Type    string `json:"type"`
		Message struct {
			Role    string `json:"role"`
			Content []struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
		} `json:"message"`
	}
	if err := json.Unmarshal(line, &got); err != nil {
		t.Fatalf("result is not valid json: %v", err)
	}
	if got.Type != "user" || got.Message.Role != "user" ||
		len(got.Message.Content) != 1 ||
		got.Message.Content[0].Type != "text" ||
		got.Message.Content[0].Text != "hello world" {
		t.Fatalf("unexpected envelope: %s", line)
	}
}

func TestProcessClaudeStreamOutput(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// A realistic mixed stream: init, a partial, a tool-only assistant
	// turn (no chat event), an assistant text turn (one chat event), and
	// a result (ignored).
	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"s"}`,
		`{"type":"stream_event","event":{"type":"content_block_delta"}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"all done"}]}}`,
		`{"type":"result","subtype":"success","result":"all done","is_error":false}`,
	}, "\n")

	var published [][]byte
	err := processClaudeStreamOutput(strings.NewReader(stream), func(p []byte) {
		published = append(published, p)
	})
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if len(published) != 1 {
		t.Fatalf("expected exactly 1 chat event (the assistant text), got %d", len(published))
	}
	var ev struct {
		Type  string `json:"type"`
		View  string `json:"view"`
		Event struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"event"`
	}
	if err := json.Unmarshal(published[0], &ev); err != nil {
		t.Fatalf("published payload not json: %v", err)
	}
	if ev.Type != "view_event" || ev.View != "chat" ||
		ev.Event.Role != "assistant" || ev.Event.Content != "all done" {
		t.Fatalf("unexpected chat event: %s", published[0])
	}
}
