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
	Type string `json:"type"` // "text" | "tool_use"
	Text string `json:"text"`
	Name string `json:"name"` // tool_use: the tool name
}

// ClaudeChatEvent is a chat item lifted from one stream-json line, ready to
// be marshaled into a view_event{view:"chat"}. Exactly one of Text /
// ToolName is set per event.
type ClaudeChatEvent struct {
	Role     string // always "assistant" for now
	Text     string // assistant prose (set for a text block)
	ToolName string // set for a tool_use block (Text empty)
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
				out = append(out, ClaudeChatEvent{Role: "assistant", ToolName: c.Name})
			}
		}
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}
