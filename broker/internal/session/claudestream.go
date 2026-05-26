package session

import (
	"bytes"
	"encoding/json"
	"strings"
)

// claudeStreamEvent decodes one NDJSON line emitted by
//
//	claude -p --output-format stream-json --include-partial-messages
//
// Only the fields the chat channel consumes are modeled; everything else
// is ignored. The captured schema (and a sample) live in
// docs/PLAN-CHAT-CHANNEL.md and testdata/claude-streamjson-sample.jsonl.
//
// This is slice 1 of the structured chat channel (task #24): a pure,
// agent-output → chat-event mapping. Wiring it into the session lifecycle
// (spawning claude in stream-json mode, piping the composer to stdin) is a
// follow-up slice.
type claudeStreamEvent struct {
	Type    string              `json:"type"`    // "assistant" | "result" | "system" | "stream_event" | ...
	Subtype string              `json:"subtype"` // e.g. "init", "success"
	Message claudeStreamMessage `json:"message"`
}

type claudeStreamMessage struct {
	Role    string               `json:"role"`
	Content []claudeContentBlock `json:"content"`
}

type claudeContentBlock struct {
	Type  string          `json:"type"` // "text" | "tool_use"
	Text  string          `json:"text"`
	Name  string          `json:"name"`  // tool_use: the tool name
	Input json.RawMessage `json:"input"` // tool_use: the tool args
}

// ClaudeChatEvent is a chat item lifted from one stream-json line, ready to
// be marshaled into a view_event{view:"chat"}. Either Text (assistant
// prose) or ToolName (+ optional ToolInput) is set per event.
type ClaudeChatEvent struct {
	Role      string          // "assistant" prose; the processor maps tool blocks to role:"tool"
	Text      string          // assistant prose (set for a text block)
	ToolName  string          // set for a tool_use block (Text empty)
	ToolInput json.RawMessage // tool_use args, for the card summary
}

// claudeStreamLineIsTurnEnd reports whether a stream-json line is the
// turn-terminating `result` envelope claude emits once the assistant has
// finished its reply (and all tool calls in it). It's the hook the
// AI quick-reply generator fires on. Tolerates malformed lines (returns
// false). Kept separate from parseClaudeStreamLine so the chat-event
// mapping stays a pure text/tool extractor.
func claudeStreamLineIsTurnEnd(line []byte) bool {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return false
	}
	var ev claudeStreamEvent
	if err := json.Unmarshal(line, &ev); err != nil {
		return false
	}
	return ev.Type == "result"
}

// parseClaudeStreamLine lifts renderable chat items out of a single
// stream-json line. It returns (events, true) for an "assistant" event
// that carries text or tool_use blocks, and (nil, false) for everything
// the chat tab ignores: system/result/stream_event envelopes, blank lines,
// and malformed JSON. A single assistant event may carry several blocks
// (e.g. prose followed by a tool call), so the result is a slice.
func parseClaudeStreamLine(line []byte) ([]ClaudeChatEvent, bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, false
	}
	var ev claudeStreamEvent
	if err := json.Unmarshal(line, &ev); err != nil {
		// Non-JSON or partial line — not our concern; the reader skips it.
		return nil, false
	}
	if ev.Type != "assistant" || ev.Message.Role != "assistant" {
		return nil, false
	}
	var out []ClaudeChatEvent
	for _, c := range ev.Message.Content {
		switch c.Type {
		case "text":
			if strings.TrimSpace(c.Text) != "" {
				out = append(out, ClaudeChatEvent{Role: "assistant", Text: c.Text})
			}
		case "tool_use":
			if strings.TrimSpace(c.Name) != "" {
				out = append(out, ClaudeChatEvent{Role: "assistant", ToolName: c.Name, ToolInput: c.Input})
			}
		}
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}
