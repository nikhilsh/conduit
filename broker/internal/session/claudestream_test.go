package session

import (
	"bufio"
	"os"
	"testing"
)

// TestParseClaudeStreamLineFixture runs the parser over a real
// `claude -p --output-format stream-json` capture (testdata/...). The
// session emitted system/init, stream_event partials, one assistant text
// block ("hi"), and a result — only the assistant text should surface as a
// chat event.
func TestParseClaudeStreamLineFixture(t *testing.T) {
	f, err := os.Open("testdata/claude-streamjson-sample.jsonl")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	var texts []string
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 0, 1<<20), 1<<20)
	for sc.Scan() {
		evs, ok := parseClaudeStreamLine(sc.Bytes())
		if !ok {
			continue
		}
		for _, e := range evs {
			if e.Text != "" {
				texts = append(texts, e.Text)
			}
		}
	}
	if err := sc.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(texts) != 1 || texts[0] != "hi" {
		t.Fatalf("expected exactly one assistant text \"hi\", got %v", texts)
	}
}

func TestParseClaudeStreamLineCases(t *testing.T) {
	cases := []struct {
		name     string
		line     string
		wantOK   bool
		wantText string
		wantTool string
	}{
		{
			name:     "assistant text",
			line:     `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"hello there"}]}}`,
			wantOK:   true,
			wantText: "hello there",
		},
		{
			name:     "assistant tool_use",
			line:     `{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}`,
			wantOK:   true,
			wantTool: "Bash",
		},
		{name: "result ignored", line: `{"type":"result","subtype":"success","result":"hi","is_error":false}`, wantOK: false},
		{name: "system init ignored", line: `{"type":"system","subtype":"init","session_id":"x"}`, wantOK: false},
		{name: "stream_event ignored", line: `{"type":"stream_event","event":{"type":"content_block_delta"}}`, wantOK: false},
		{name: "empty line ignored", line: ``, wantOK: false},
		{name: "malformed json ignored", line: `{not json`, wantOK: false},
		{name: "empty text block dropped", line: `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"  "}]}}`, wantOK: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evs, ok := parseClaudeStreamLine([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v (events=%+v)", ok, tc.wantOK, evs)
			}
			if !ok {
				return
			}
			if tc.wantText != "" && (len(evs) != 1 || evs[0].Text != tc.wantText) {
				t.Fatalf("want text %q, got %+v", tc.wantText, evs)
			}
			if tc.wantTool != "" && (len(evs) != 1 || evs[0].ToolName != tc.wantTool) {
				t.Fatalf("want tool %q, got %+v", tc.wantTool, evs)
			}
		})
	}
}

// Mixed text + tool_use in one assistant event yields both, in order.
func TestParseClaudeStreamLineMixedBlocks(t *testing.T) {
	line := `{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"running it"},{"type":"tool_use","name":"Edit"}]}}`
	evs, ok := parseClaudeStreamLine([]byte(line))
	if !ok || len(evs) != 2 {
		t.Fatalf("expected 2 events, got ok=%v evs=%+v", ok, evs)
	}
	if evs[0].Text != "running it" || evs[1].ToolName != "Edit" {
		t.Fatalf("unexpected events: %+v", evs)
	}
}
