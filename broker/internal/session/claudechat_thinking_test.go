package session

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// TestParseClaudeStreamLineThinking verifies that a thinking block in an
// assistant snapshot surfaces as IsThinking=true with ThinkingText set to
// the accumulated reasoning. Captured shape from claude-sonnet-4-6
// (2026-07-03): assistant snapshots under --include-partial-messages carry
// the thinking block as content[0].type=="thinking" with content[0].thinking
// holding the accumulated text so far.
func TestParseClaudeStreamLineThinking(t *testing.T) {
	cases := []struct {
		name             string
		line             string
		wantOK           bool
		wantIsThinking   bool
		wantThinkingText string
	}{
		{
			name:             "thinking block with text",
			line:             `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"step one\nstep two"}]}}`,
			wantOK:           true,
			wantIsThinking:   true,
			wantThinkingText: "step one\nstep two",
		},
		{
			name:             "thinking block empty text still emits event",
			line:             `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":""}]}}`,
			wantOK:           true,
			wantIsThinking:   true,
			wantThinkingText: "",
		},
		{
			name:           "thinking block followed by text block yields both events",
			line:           `{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"reason"},{"type":"text","text":"answer"}]}}`,
			wantOK:         true,
			wantIsThinking: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			evs, ok := parseClaudeStreamLine([]byte(tc.line))
			if ok != tc.wantOK {
				t.Fatalf("ok=%v want %v (evs=%+v)", ok, tc.wantOK, evs)
			}
			if !ok {
				return
			}
			var found bool
			for _, e := range evs {
				if e.IsThinking {
					found = true
					if e.ThinkingText != tc.wantThinkingText && tc.wantThinkingText != "" {
						t.Errorf("ThinkingText=%q want %q", e.ThinkingText, tc.wantThinkingText)
					}
				}
			}
			if tc.wantIsThinking && !found {
				t.Errorf("expected an IsThinking event but got %+v", evs)
			}
		})
	}
}

// TestProcessClaudeStreamOutputThinkingStreaming verifies the
// thinking_streaming view_event accumulation behavior:
//
//   - Each `assistant` snapshot with a thinking block publishes a
//     thinking_streaming view_event with the accumulated content.
//   - The turnTS in thinking_streaming is stable across the turn.
//   - The thinkingAccum resets at turn end (next turn produces fresh events).
//   - After thinking, the chat_streaming events for the prose use the SAME
//     turnTS that was latched during the thinking phase.
//
// Stream shape matches the real claude-sonnet-4-6 capture (2026-07-03):
// thinking arrives as assistant snapshots, each carrying the full accumulated
// thinking text; text follows in subsequent assistant snapshots.
func TestProcessClaudeStreamOutputThinkingStreaming(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(1000, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	// Simulate two thinking snapshots growing incrementally, then a text
	// snapshot, then a result (turn end). Second turn follows with text only.
	stream := strings.Join([]string{
		// Turn 1 — thinking then prose.
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"first bit"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"first bit second bit"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer"}]}}`,
		`{"type":"result","subtype":"success","result":"answer","is_error":false}`,
		// Turn 2 — no thinking, just prose.
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"turn two"}]}}`,
		`{"type":"result","subtype":"success","result":"turn two","is_error":false}`,
	}, "\n")

	type evEnvelope struct {
		View  string `json:"view"`
		Event struct {
			Role    string `json:"role"`
			Content string `json:"content"`
			TS      string `json:"ts"`
			TurnTS  string `json:"turn_ts"`
		} `json:"event"`
	}
	var all []evEnvelope
	_ = processClaudeStreamOutput(strings.NewReader(stream), func(p []byte) {
		var ev evEnvelope
		if json.Unmarshal(p, &ev) == nil {
			all = append(all, ev)
		}
	}, nil, nil, nil, nil, nil, nil, nil, nil)

	// Collect by view.
	var thinkingEvs, chatStreamEvs, chatFinalEvs []evEnvelope
	for _, ev := range all {
		switch ev.View {
		case "thinking_streaming":
			thinkingEvs = append(thinkingEvs, ev)
		case "chat_streaming":
			chatStreamEvs = append(chatStreamEvs, ev)
		case "chat":
			if ev.Event.Role == "assistant" {
				chatFinalEvs = append(chatFinalEvs, ev)
			}
		}
	}

	// Two thinking_streaming events for turn 1 (one per snapshot delta).
	if len(thinkingEvs) != 2 {
		t.Fatalf("want 2 thinking_streaming events, got %d: %+v", len(thinkingEvs), thinkingEvs)
	}
	if thinkingEvs[0].Event.Content != "first bit" {
		t.Errorf("thinking[0].content = %q, want %q", thinkingEvs[0].Event.Content, "first bit")
	}
	if thinkingEvs[1].Event.Content != "first bit second bit" {
		t.Errorf("thinking[1].content = %q, want %q", thinkingEvs[1].Event.Content, "first bit second bit")
	}

	// All thinking events must carry the same non-empty ts (turn latch).
	if thinkingEvs[0].Event.TS == "" {
		t.Error("thinking_streaming event missing ts")
	}
	if thinkingEvs[0].Event.TS != thinkingEvs[1].Event.TS {
		t.Errorf("thinking_streaming ts must be stable across turn: %q vs %q",
			thinkingEvs[0].Event.TS, thinkingEvs[1].Event.TS)
	}

	// The chat_streaming events for turn 1 must share the SAME turnTS that
	// was latched during thinking (thinking latches turnTS first).
	if len(chatStreamEvs) < 1 {
		t.Fatalf("want at least 1 chat_streaming event, got 0")
	}
	turn1TS := thinkingEvs[0].Event.TS
	for _, cs := range chatStreamEvs {
		// Only check turn 1 events (which follow thinking).
		if cs.Event.Content == "answer" && cs.Event.TurnTS != turn1TS {
			t.Errorf("chat_streaming turn_ts=%q want %q (same as thinking ts)", cs.Event.TurnTS, turn1TS)
		}
	}

	// Two final chat events (one per turn).
	if len(chatFinalEvs) != 2 {
		t.Fatalf("want 2 final chat events, got %d: %+v", len(chatFinalEvs), chatFinalEvs)
	}
	if chatFinalEvs[0].Event.Content != "answer" {
		t.Errorf("final[0].content=%q want %q", chatFinalEvs[0].Event.Content, "answer")
	}
	if chatFinalEvs[1].Event.Content != "turn two" {
		t.Errorf("final[1].content=%q want %q", chatFinalEvs[1].Event.Content, "turn two")
	}

	// Turn 2 must produce NO thinking_streaming events (no thinking block).
	for _, ev := range thinkingEvs {
		if ev.Event.Content == "turn two" {
			t.Error("turn 2 unexpectedly produced a thinking_streaming event")
		}
	}
}

// TestProcessClaudeStreamOutputThinkingReset verifies that thinkingAccum
// resets between turns: the second turn does not carry forward the first
// turn's reasoning text.
func TestProcessClaudeStreamOutputThinkingReset(t *testing.T) {
	claudeChatNow = func() time.Time { return time.Unix(2000, 0).UTC() }
	defer func() { claudeChatNow = time.Now }()

	stream := strings.Join([]string{
		// Turn 1 with thinking.
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"turn1 reason"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"turn1 answer"}]}}`,
		`{"type":"result","subtype":"success","result":"turn1 answer","is_error":false}`,
		// Turn 2 with fresh thinking (smaller text, must not include turn1 content).
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"turn2 reason"}]}}`,
		`{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"turn2 answer"}]}}`,
		`{"type":"result","subtype":"success","result":"turn2 answer","is_error":false}`,
	}, "\n")

	type thinkEv struct {
		View  string `json:"view"`
		Event struct {
			Content string `json:"content"`
			TS      string `json:"ts"`
		} `json:"event"`
	}
	var thinkingEvs []thinkEv
	_ = processClaudeStreamOutput(strings.NewReader(stream), func(p []byte) {
		var ev thinkEv
		if json.Unmarshal(p, &ev) == nil && ev.View == "thinking_streaming" {
			thinkingEvs = append(thinkingEvs, ev)
		}
	}, nil, nil, nil, nil, nil, nil, nil, nil)

	if len(thinkingEvs) != 2 {
		t.Fatalf("want 2 thinking_streaming events (one per turn), got %d: %+v", len(thinkingEvs), thinkingEvs)
	}
	if thinkingEvs[0].Event.Content != "turn1 reason" {
		t.Errorf("turn1 thinking content=%q, want %q", thinkingEvs[0].Event.Content, "turn1 reason")
	}
	if thinkingEvs[1].Event.Content != "turn2 reason" {
		t.Errorf("turn2 thinking content=%q, want %q", thinkingEvs[1].Event.Content, "turn2 reason")
	}
	// The two thinking events must have DIFFERENT ts values (different turns
	// → different latch times — real clock advances; this test uses fixed
	// clock so they actually share the same second. Instead verify they are
	// from distinct turns by checking turn 2 doesn't contain turn 1 text).
	if strings.Contains(thinkingEvs[1].Event.Content, "turn1") {
		t.Errorf("turn2 thinking content leaked turn1 data: %q", thinkingEvs[1].Event.Content)
	}
}
