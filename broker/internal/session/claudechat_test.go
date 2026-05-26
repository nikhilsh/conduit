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

func TestClaudeStreamCommand(t *testing.T) {
	argv := claudeStreamCommand([]string{"claude"}, []string{"--dangerously-skip-permissions"})
	want := []string{
		"claude", "--dangerously-skip-permissions",
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--verbose",
	}
	if len(argv) != len(want) {
		t.Fatalf("argv = %v, want %v", argv, want)
	}
	for i := range want {
		if argv[i] != want[i] {
			t.Fatalf("argv[%d] = %q, want %q (full: %v)", i, argv[i], want[i], argv)
		}
	}
}

func TestProcessClaudeStreamOutput(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// A realistic mixed stream: init, a partial, a tool_use turn (→ tool
	// card), an assistant text turn (→ assistant bubble), and a result
	// (ignored). system/stream_event/result carry no chat events.
	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"s"}`,
		`{"type":"stream_event","event":{"type":"content_block_delta"}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"all done"}]}}`,
		`{"type":"result","subtype":"success","result":"all done","is_error":false}`,
	}, "\n")

	type chatEv struct {
		View  string `json:"view"`
		Event struct {
			Role    string `json:"role"`
			Content string `json:"content"`
		} `json:"event"`
	}
	var got []chatEv
	err := processClaudeStreamOutput(strings.NewReader(stream), func(p []byte) {
		var ev chatEv
		if json.Unmarshal(p, &ev) == nil {
			got = append(got, ev)
		}
	}, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("expected 2 chat events (tool card + assistant text), got %d: %+v", len(got), got)
	}
	// [0] tool card from the tool_use block.
	if got[0].View != "chat" || got[0].Event.Role != "tool" || got[0].Event.Content != "Bash: ls -la" {
		t.Fatalf("unexpected tool event: %+v", got[0])
	}
	// [1] assistant prose.
	if got[1].View != "chat" || got[1].Event.Role != "assistant" || got[1].Event.Content != "all done" {
		t.Fatalf("unexpected assistant event: %+v", got[1])
	}
}

func TestToolCardContent(t *testing.T) {
	cases := []struct {
		name, input, want string
	}{
		{"Bash", `{"command":"ls -la"}`, "Bash: ls -la"},
		{"Edit", `{"file_path":"src/foo.go","old_string":"a"}`, "Edit: src/foo.go"},
		{"Read", `{"path":"/etc/hosts"}`, "Read: /etc/hosts"},
		{"Glob", `{}`, "Glob:"},
		{"Bare", ``, "Bare:"},
	}
	for _, tc := range cases {
		var raw json.RawMessage
		if tc.input != "" {
			raw = json.RawMessage(tc.input)
		}
		if got := toolCardContent(tc.name, raw); got != tc.want {
			t.Fatalf("toolCardContent(%q, %q) = %q, want %q", tc.name, tc.input, got, tc.want)
		}
	}
}
