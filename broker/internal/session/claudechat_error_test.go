package session

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// Verbatim frames captured live 2026-07-24 against claude-code 2.1.218 on an
// auth failure (bogus API key). See the "silent chat hang" bug: the broker
// used to swallow both lines, leaving the turn stuck on "thinking" forever.
const (
	claudeSyntheticErrorLine = `{"type":"assistant","message":{"id":"925e181d","container":null,"model":"<synthetic>","role":"assistant","stop_details":null,"stop_reason":"stop_sequence","stop_sequence":"","type":"message","usage":{"input_tokens":0,"output_tokens":0},"content":[{"type":"text","text":"Invalid API key · Fix external API key"}],"context_management":null},"parent_tool_use_id":null,"session_id":"15cf0cfa","uuid":"f615e409","timestamp":"2026-07-24T04:14:27.871Z","error":"authentication_failed","request_id":"req_011CdLEUPfXrzaDMTezeP8pk"}`
	claudeErrorResultLine    = `{"is_error":true,"duration_api_ms":0,"num_turns":1,"stop_reason":"stop_sequence","session_id":"15cf0cfa","total_cost_usd":0,"usage":{"input_tokens":0,"output_tokens":0},"modelUsage":{},"permission_denials":[],"terminal_reason":"api_error","fast_mode_state":"off","subtype":"success","api_error_status":401,"result":"Invalid API key · Fix external API key","type":"result","duration_ms":339,"uuid":"84afade4"}`
	// The benign /clear synthetic — model "<synthetic>" but NO top-level
	// "error" field. Must NOT be treated as an error.
	claudeClearSyntheticLine = `{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"(no content)"}],"usage":{"input_tokens":0,"output_tokens":0}}}`
)

func TestParseClaudeSyntheticError(t *testing.T) {
	cases := []struct {
		name     string
		line     string
		wantOK   bool
		wantText string
	}{
		{
			name:     "line A verbatim",
			line:     claudeSyntheticErrorLine,
			wantOK:   true,
			wantText: "Invalid API key · Fix external API key",
		},
		{
			name:   "clear synthetic has no error field, rejected",
			line:   claudeClearSyntheticLine,
			wantOK: false,
		},
		{
			name:   "normal assistant line rejected",
			line:   `{"type":"assistant","message":{"model":"claude-opus-4-5","role":"assistant","content":[{"type":"text","text":"hi"}]}}`,
			wantOK: false,
		},
		{
			name:     "falls back to error code when content empty",
			line:     `{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[]},"error":"authentication_failed"}`,
			wantOK:   true,
			wantText: "authentication_failed",
		},
		{
			name:   "malformed json rejected",
			line:   `{"type":"assistant","message":{"model":"<synthetic>"`,
			wantOK: false,
		},
		{
			name:   "empty line rejected",
			line:   ``,
			wantOK: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseClaudeSyntheticError([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v (text=%q)", ok, tc.wantOK, got)
			}
			if tc.wantOK && got != tc.wantText {
				t.Fatalf("text = %q, want %q", got, tc.wantText)
			}
		})
	}
}

func TestParseClaudeErrorResult(t *testing.T) {
	cases := []struct {
		name     string
		line     string
		wantOK   bool
		wantText string
	}{
		{
			name:     "line B verbatim",
			line:     claudeErrorResultLine,
			wantOK:   true,
			wantText: "Invalid API key · Fix external API key",
		},
		{
			name:   "normal success result rejected (is_error absent)",
			line:   `{"type":"result","subtype":"success","result":"all done"}`,
			wantOK: false,
		},
		{
			name:   "normal success result rejected (is_error false)",
			line:   `{"type":"result","subtype":"success","is_error":false,"result":"all done"}`,
			wantOK: false,
		},
		{
			name:     "fallback text when result empty",
			line:     `{"type":"result","subtype":"success","is_error":true,"result":""}`,
			wantOK:   true,
			wantText: "The agent reported an error.",
		},
		{
			name:   "non-result line rejected",
			line:   `{"type":"assistant","message":{"role":"assistant"}}`,
			wantOK: false,
		},
		{
			name:   "malformed json rejected",
			line:   `{not json`,
			wantOK: false,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, ok := parseClaudeErrorResult([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok = %v, want %v (text=%q)", ok, tc.wantOK, got)
			}
			if tc.wantOK && got != tc.wantText {
				t.Fatalf("text = %q, want %q", got, tc.wantText)
			}
		})
	}
}

// chatEvErr is the minimal shape used by the end-to-end pump tests below.
type chatEvErr struct {
	Type  string `json:"type"`
	View  string `json:"view"`
	Event struct {
		Role      string `json:"role"`
		Content   string `json:"content"`
		TurnPhase string `json:"turn_phase"`
	} `json:"event"`
}

// TestProcessClaudeStreamOutputSyntheticErrorThenResult pins case (a): init
// + line A + line B. Exactly one system chat message carrying the error
// text is published, onTurnEnd fires exactly once, a turn_phase "" event is
// emitted, and usage from line B is still folded.
func TestProcessClaudeStreamOutputSyntheticErrorThenResult(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// A thinking block precedes the error so the turn_phase transitions away
	// from "" first (emitPhase is a no-op when the phase hasn't changed) —
	// this lets the assertion below observe the reset-to-"" transition the
	// synthetic-error handler performs.
	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"15cf0cfa"}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"considering…"}]}}`,
		claudeSyntheticErrorLine,
		claudeErrorResultLine,
	}, "\n")

	var turnEnds int
	onTurnEnd := func() { turnEnds++ }
	var usageCalls int
	onUsage := func(u usageDelta) {
		usageCalls++
		if u.input != 0 || u.output != 0 {
			t.Fatalf("unexpected usage delta: %+v", u)
		}
	}

	var events []chatEvErr
	err := processClaudeStreamOutput(strings.NewReader(stream+"\n"), func(p []byte) {
		var ev chatEvErr
		if json.Unmarshal(p, &ev) == nil {
			events = append(events, ev)
		}
	}, nil, nil, onUsage, nil, nil, onTurnEnd, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}

	var systemMsgs []chatEvErr
	var emptyPhases int
	for _, ev := range events {
		if ev.View == "chat" && ev.Event.Role == "system" {
			systemMsgs = append(systemMsgs, ev)
		}
		if ev.View == "turn_phase" && ev.Event.TurnPhase == "" {
			emptyPhases++
		}
	}
	if len(systemMsgs) != 1 {
		t.Fatalf("expected exactly 1 system chat message, got %d: %+v", len(systemMsgs), systemMsgs)
	}
	if !strings.Contains(systemMsgs[0].Event.Content, "Invalid API key") {
		t.Fatalf("system message missing error text: %+v", systemMsgs[0])
	}
	if turnEnds != 1 {
		t.Fatalf("onTurnEnd fired %d times, want 1", turnEnds)
	}
	if emptyPhases == 0 {
		t.Fatalf("expected a turn_phase \"\" event, got none: %+v", events)
	}
	if usageCalls != 1 {
		t.Fatalf("onUsage fired %d times, want 1 (usage from line B must still be folded)", usageCalls)
	}
}

// TestProcessClaudeStreamOutputSyntheticErrorNoResult pins case (b): init +
// line A only (no result ever arrives). The system message is published and
// onTurnEnd fires once anyway — the turn must not hang.
func TestProcessClaudeStreamOutputSyntheticErrorNoResult(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"15cf0cfa"}`,
		claudeSyntheticErrorLine,
	}, "\n")

	var turnEnds int
	onTurnEnd := func() { turnEnds++ }

	var events []chatEvErr
	err := processClaudeStreamOutput(strings.NewReader(stream+"\n"), func(p []byte) {
		var ev chatEvErr
		if json.Unmarshal(p, &ev) == nil {
			events = append(events, ev)
		}
	}, nil, nil, nil, nil, nil, onTurnEnd, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}

	found := false
	for _, ev := range events {
		if ev.View == "chat" && ev.Event.Role == "system" && strings.Contains(ev.Event.Content, "Invalid API key") {
			found = true
		}
	}
	if !found {
		t.Fatalf("system error message not published: %+v", events)
	}
	if turnEnds != 1 {
		t.Fatalf("onTurnEnd fired %d times, want 1", turnEnds)
	}
}

// TestProcessClaudeStreamOutputErrorResultOnly pins case (c): an error
// result arrives with no preceding synthetic error line. The system message
// is published from the result string and the normal turn-end path runs
// exactly once.
func TestProcessClaudeStreamOutputErrorResultOnly(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"15cf0cfa"}`,
		claudeErrorResultLine,
	}, "\n")

	var turnEnds int
	onTurnEnd := func() { turnEnds++ }

	var events []chatEvErr
	err := processClaudeStreamOutput(strings.NewReader(stream+"\n"), func(p []byte) {
		var ev chatEvErr
		if json.Unmarshal(p, &ev) == nil {
			events = append(events, ev)
		}
	}, nil, nil, nil, nil, nil, onTurnEnd, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}

	found := false
	for _, ev := range events {
		if ev.View == "chat" && ev.Event.Role == "system" && strings.Contains(ev.Event.Content, "Invalid API key") {
			found = true
		}
	}
	if !found {
		t.Fatalf("system error message not published: %+v", events)
	}
	if turnEnds != 1 {
		t.Fatalf("onTurnEnd fired %d times, want 1", turnEnds)
	}
}

// TestProcessClaudeStreamOutputClearStillWorks pins case (d): the /clear
// synthetic (model "<synthetic>", no top-level error) must NOT be treated
// as an error — no system error message is published for it. Complements
// the pre-existing TestClaudeClearCommand in claudechat_clear_test.go.
func TestProcessClaudeStreamOutputClearStillWorks(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(0, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	stream := strings.Join([]string{
		`{"type":"system","subtype":"init","session_id":"new-uuid"}`,
		claudeClearSyntheticLine,
		`{"type":"result","subtype":"success","is_error":false,"result":"","num_turns":0,"session_id":"new-uuid","total_cost_usd":0}`,
	}, "\n")

	var events []chatEvErr
	err := processClaudeStreamOutput(strings.NewReader(stream+"\n"), func(p []byte) {
		var ev chatEvErr
		if json.Unmarshal(p, &ev) == nil {
			events = append(events, ev)
		}
	}, nil, nil, nil, nil, nil, nil, nil, nil, nil)
	if err != nil {
		t.Fatalf("process: %v", err)
	}
	for _, ev := range events {
		if ev.View == "chat" && ev.Event.Role == "system" {
			t.Fatalf("unexpected system message published for /clear flow: %+v", ev)
		}
		if strings.Contains(ev.Event.Content, "(no content)") {
			t.Fatalf("synthetic '(no content)' assistant line was published: %+v", ev)
		}
	}
}
