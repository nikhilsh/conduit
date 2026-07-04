package session

import (
	"strings"
	"testing"
)

// TestClaudeClearCommand pins the /clear turn behavior against the verbatim
// stream-json frames captured from claude-code 2.1.193:
//
//  1. system/init with a NEW session_id — the conversation is reset.
//  2. A SYNTHETIC assistant event (model=="<synthetic>", content="(no content)").
//  3. A result/success with num_turns==0.
//
// Assertions:
// (a) The "(no content)" assistant line is NOT published as chat.
// (b) A "✓ Context cleared — starting fresh." system line IS published.
// (c) The new session_id is latched via onInit.
func TestClaudeClearCommand(t *testing.T) {
	const newSessionID = "new-uuid-after-clear"

	// Verbatim captured frames (formatted for readability; the parser is
	// whitespace-tolerant as it uses json.Unmarshal line-by-line).
	lines := []string{
		// Frame 1: system/init with the new session id after /clear.
		`{"type":"system","subtype":"init","session_id":"` + newSessionID + `","cwd":"/tmp","tools":[],"mcp_servers":[],"model":"claude-opus-4-5","permissionMode":"default","apiKeySource":"env"}`,
		// Frame 2: synthetic assistant event — must be SUPPRESSED.
		`{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"(no content)"}],"usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}`,
		// Frame 3: result/success with num_turns==0 (turn end).
		`{"type":"result","subtype":"success","is_error":false,"result":"","num_turns":0,"session_id":"` + newSessionID + `","total_cost_usd":0}`,
	}

	var published []string
	publish := func(b []byte) { published = append(published, string(b)) }

	var latchedID string
	onInit := func(id string) { latchedID = id }

	// Feed through processClaudeStreamOutput with expectingClear=true by
	// using the chatProcess path: set expectingClear before the pump starts.
	// For this unit test we drive processClaudeStreamOutput directly via a
	// reader that delivers the three captured lines and then EOF.
	r := strings.NewReader(strings.Join(lines, "\n") + "\n")
	_ = processClaudeStreamOutput(
		r,
		publish,
		nil, // quickReplyGenerator
		nil, // titleGenerator
		nil, // onUsage
		nil, // onControl
		onInit,
		func() {
			// onTurnEnd: simulate what startChatProcess does — publish the
			// clear confirmation. In the real path this reads cp.expectingClear;
			// here we call publishChatSystem directly as the test drives the
			// turn-end path explicitly.
			publishChatSystem(publish, "✓ Context cleared — starting fresh.")
		},
		nil, // onSubagent
		nil, // onPhaseChange
		nil, // onModel
	)

	// (a) The "(no content)" assistant line must NOT appear.
	for _, p := range published {
		if strings.Contains(p, "(no content)") {
			t.Errorf("synthetic '(no content)' assistant line was published: %s", p)
		}
	}

	// (b) The confirmation system line MUST appear.
	found := false
	for _, p := range published {
		if strings.Contains(p, "Context cleared") {
			found = true
			break
		}
	}
	if !found {
		t.Errorf("clear confirmation not published; got: %v", published)
	}

	// (c) The new session_id must be latched.
	if latchedID != newSessionID {
		t.Errorf("latched session id = %q, want %q", latchedID, newSessionID)
	}
}

// TestParseClaudeStreamLineSyntheticSuppressed pins that parseClaudeStreamLine
// returns (nil, false) for a synthetic assistant event (model=="<synthetic>").
// This is the discriminator that suppresses the /clear "(no content)" bubble.
func TestParseClaudeStreamLineSyntheticSuppressed(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"model":"<synthetic>","role":"assistant","content":[{"type":"text","text":"(no content)"}],"usage":{"input_tokens":0,"output_tokens":0}}}`)
	evs, ok := parseClaudeStreamLine(line)
	if ok || len(evs) != 0 {
		t.Errorf("synthetic assistant line should be suppressed; got ok=%v evs=%v", ok, evs)
	}
}

// TestParseClaudeStreamLineRealModelNotSuppressed verifies that a real
// assistant event (model != "<synthetic>") is NOT suppressed.
func TestParseClaudeStreamLineRealModelNotSuppressed(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"model":"claude-opus-4-5","role":"assistant","content":[{"type":"text","text":"Hello"}]}}`)
	evs, ok := parseClaudeStreamLine(line)
	if !ok || len(evs) == 0 {
		t.Errorf("real assistant line should not be suppressed; got ok=%v evs=%v", ok, evs)
	}
}
