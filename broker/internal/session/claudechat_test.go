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
	argv := claudeStreamCommand([]string{"claude"}, []string{"--dangerously-skip-permissions"}, "")
	want := []string{
		"claude", "--dangerously-skip-permissions",
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--verbose",
		// AskUserQuestion waits for the phone's answer via the stdio
		// control protocol (askcontrol.go) instead of headless auto-deny.
		"--permission-prompt-tool", "stdio",
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
	}, nil, nil, nil, nil, nil)
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

func TestAskUserQuestionContent(t *testing.T) {
	cases := []struct {
		name, input, want string
		ok                bool
	}{
		{
			name:  "single question with options",
			input: `{"questions":[{"question":"Ship it?","header":"Deploy","multiSelect":false,"options":[{"label":"Yes","description":"go"},{"label":"No"}]}]}`,
			want:  "Ship it?\n1. Yes\n2. No",
			ok:    true,
		},
		{
			name:  "two questions renumber per question",
			input: `{"questions":[{"question":"Color?","options":[{"label":"Red"},{"label":"Blue"}]},{"question":"Size?","options":[{"label":"S"},{"label":"M"}]}]}`,
			want:  "Color?\n1. Red\n2. Blue\n\nSize?\n1. S\n2. M",
			ok:    true,
		},
		{
			name:  "question without options still surfaces",
			input: `{"questions":[{"question":"Anything else?","options":[]}]}`,
			want:  "Anything else?",
			ok:    true,
		},
		{name: "empty questions", input: `{"questions":[]}`, ok: false},
		{name: "malformed", input: `{"questions":`, ok: false},
		{name: "empty input", input: ``, ok: false},
	}
	for _, tc := range cases {
		var raw json.RawMessage
		if tc.input != "" {
			raw = json.RawMessage(tc.input)
		}
		got, ok := askUserQuestionContent(raw)
		if ok != tc.ok || (ok && got != tc.want) {
			t.Fatalf("%s: askUserQuestionContent(%q) = (%q, %v), want (%q, %v)",
				tc.name, tc.input, got, ok, tc.want, tc.ok)
		}
	}
}

func TestProcessClaudeStreamOutputAskUserQuestion(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// An AskUserQuestion tool_use must surface as a pending-input-shaped
	// chat line (question + numbered options) — NOT a bare tool card —
	// so the apps' classifier renders the interactive options card
	// (device bug: "can't see approval").
	stream := strings.Join([]string{
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"Proceed with the merge?","header":"Merge","options":[{"label":"Merge now"},{"label":"Hold off"}]}]}}]}}`,
	}, "\n")

	type chatEv struct {
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
	}, nil, nil, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 chat event, got %d: %+v", len(got), got)
	}
	want := "Proceed with the merge?\n1. Merge now\n2. Hold off"
	if got[0].Event.Role != "assistant" || got[0].Event.Content != want {
		t.Fatalf("unexpected event: %+v (want assistant %q)", got[0], want)
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
