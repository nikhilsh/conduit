package session

import (
	"bufio"
	"os"
	"strings"
	"testing"
)

// TestParseCodexStreamLineFixture runs the parser over a real
// `codex exec --json` capture: thread.started → turn.started →
// item.completed(agent_message "pong") → turn.completed. Only the
// agent_message should surface; thread.started yields the resume id.
func TestParseCodexStreamLineFixture(t *testing.T) {
	f, err := os.Open("testdata/codex-exec-sample.jsonl")
	if err != nil {
		t.Fatalf("open fixture: %v", err)
	}
	defer f.Close()

	var texts []string
	var threadID string
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		evs, tid, ok := parseCodexStreamLine(sc.Bytes())
		if tid != "" {
			threadID = tid
		}
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
	if threadID == "" {
		t.Fatalf("expected a thread id from thread.started, got none")
	}
	if len(texts) != 1 || texts[0] != "pong" {
		t.Fatalf("expected one assistant text \"pong\", got %v", texts)
	}
}

func TestParseCodexStreamLineCases(t *testing.T) {
	cases := []struct {
		name, line, wantText, wantThread string
		wantOK                           bool
	}{
		{
			name:     "agent_message",
			line:     `{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"hello"}}`,
			wantText: "hello", wantOK: true,
		},
		{
			name:       "thread.started yields id, no event",
			line:       `{"type":"thread.started","thread_id":"abc-123"}`,
			wantThread: "abc-123", wantOK: false,
		},
		{name: "turn.started ignored", line: `{"type":"turn.started"}`, wantOK: false},
		{name: "turn.completed ignored", line: `{"type":"turn.completed"}`, wantOK: false},
		{name: "non-message item ignored", line: `{"type":"item.completed","item":{"type":"command_execution","text":""}}`, wantOK: false},
		{name: "empty agent_message dropped", line: `{"type":"item.completed","item":{"type":"agent_message","text":"  "}}`, wantOK: false},
		{name: "malformed ignored", line: `{nope`, wantOK: false},
		{name: "blank ignored", line: ``, wantOK: false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evs, tid, ok := parseCodexStreamLine([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok=%v want %v (evs=%+v tid=%q)", ok, tc.wantOK, evs, tid)
			}
			if tid != tc.wantThread {
				t.Fatalf("threadID=%q want %q", tid, tc.wantThread)
			}
			if tc.wantText != "" && (len(evs) != 1 || evs[0].Text != tc.wantText) {
				t.Fatalf("want text %q, got %+v", tc.wantText, evs)
			}
		})
	}
}

// A completed command_execution item (codex-cli 0.132, captured 2026-05-29)
// surfaces as a role:"tool" event carrying the command in ToolInput. An
// in-progress item (no command/exit_code yet) is dropped.
func TestParseCodexCommandExecution(t *testing.T) {
	line := `{"type":"item.completed","item":{"id":"item_0","type":"command_execution","command":"/bin/bash -lc 'ls -la'","aggregated_output":"total 0\n","exit_code":0,"status":"completed"}}`
	evs, _, ok := parseCodexStreamLine([]byte(line))
	if !ok || len(evs) != 1 {
		t.Fatalf("want one event, ok=%v evs=%+v", ok, evs)
	}
	if evs[0].Role != "tool" || evs[0].ToolName != "command_execution" {
		t.Fatalf("want tool/command_execution, got role=%q tool=%q", evs[0].Role, evs[0].ToolName)
	}
	if got := toolCardContent(evs[0].ToolName, evs[0].ToolInput); !strings.Contains(got, "/bin/bash -lc 'ls -la'") {
		t.Fatalf("tool card content = %q, want it to include the command", got)
	}

	// in_progress (no command yet) is not rendered.
	prog := `{"type":"item.started","item":{"type":"command_execution","command":"","status":"in_progress"}}`
	if _, _, ok := parseCodexStreamLine([]byte(prog)); ok {
		t.Fatalf("in-progress command_execution should be dropped")
	}
}
