package session

import (
	"bytes"
	"encoding/json"
	"strings"
)

// subagentTaskEvent captures the fields present in all three
// system/task_* frames emitted by claude when a subagent is spawned.
// Unknown fields are silently discarded — only what the roster needs.
type subagentTaskEvent struct {
	// Common to all three subtypes.
	Subtype string `json:"subtype"` // "task_started" | "task_progress" | "task_notification"
	TaskID  string `json:"task_id"`

	// task_started / task_progress
	SubagentType string `json:"subagent_type"` // display name, e.g. "researcher", "general-purpose"
	Description  string `json:"description"`

	// task_progress
	LastToolName string        `json:"last_tool_name"`
	Usage        subagentUsage `json:"usage"`

	// task_notification
	Status string `json:"status"` // "completed" | "failed"
}

type subagentUsage struct {
	TotalTokens uint64 `json:"total_tokens"`
	ToolUses    uint64 `json:"tool_uses"`
	DurationMS  uint64 `json:"duration_ms"`
}

// parseSubagentTaskEvent decodes one stream-json line as a
// system/task_started|task_progress|task_notification frame. Returns
// (event, true) only for those three subtypes; all other lines return
// (_, false) without allocating.
func parseSubagentTaskEvent(line []byte) (subagentTaskEvent, bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return subagentTaskEvent{}, false
	}
	// Fast reject: must contain a task_ subtype marker.
	if !bytes.Contains(line, []byte(`"task_`)) {
		return subagentTaskEvent{}, false
	}
	// Decode with a flat struct that covers all three frame shapes.
	var ev struct {
		Type         string        `json:"type"`
		Subtype      string        `json:"subtype"`
		TaskID       string        `json:"task_id"`
		SubagentType string        `json:"subagent_type"`
		Description  string        `json:"description"`
		LastToolName string        `json:"last_tool_name"`
		Usage        subagentUsage `json:"usage"`
		Status       string        `json:"status"`
	}
	if err := json.Unmarshal(line, &ev); err != nil {
		return subagentTaskEvent{}, false
	}
	if ev.Type != "system" {
		return subagentTaskEvent{}, false
	}
	switch ev.Subtype {
	case "task_started", "task_progress", "task_notification":
	default:
		return subagentTaskEvent{}, false
	}
	if ev.TaskID == "" {
		return subagentTaskEvent{}, false
	}
	return subagentTaskEvent{
		Subtype:      ev.Subtype,
		TaskID:       ev.TaskID,
		SubagentType: ev.SubagentType,
		Description:  ev.Description,
		LastToolName: ev.LastToolName,
		Usage:        ev.Usage,
		Status:       ev.Status,
	}, true
}

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
	Model   string               `json:"model"`
	Content []claudeContentBlock `json:"content"`
}

type claudeContentBlock struct {
	Type     string          `json:"type"` // "text" | "tool_use" | "thinking"
	Text     string          `json:"text"`
	Name     string          `json:"name"`     // tool_use: the tool name
	Input    json.RawMessage `json:"input"`    // tool_use: the tool args
	Thinking string          `json:"thinking"` // thinking: the reasoning content
}

// ClaudeChatEvent is a chat item lifted from one stream-json line, ready to
// be marshaled into a view_event{view:"chat"}. Either Text (assistant
// prose) or ToolName (+ optional ToolInput) is set per event.
// IsThinking is set for a thinking block (no chat content emitted).
// ThinkingText carries the accumulated reasoning text from the snapshot
// (non-empty only when IsThinking is true and the CLI has emitted content).
type ClaudeChatEvent struct {
	Role         string          // "assistant" prose; the processor maps tool blocks to role:"tool"
	Text         string          // assistant prose (set for a text block)
	ToolName     string          // set for a tool_use block (Text empty)
	ToolInput    json.RawMessage // tool_use args, for the card summary
	IsThinking   bool            // set for a thinking/reasoning block
	ThinkingText string          // accumulated reasoning text for this turn (set when IsThinking)
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
	// Suppress the synthetic assistant event the CLI emits for a /clear
	// turn. Its model field is literally "<synthetic>" (never a real model
	// name) and its content is "(no content)" — not useful chat content.
	// The turn-end onTurnEnd handler publishes the "✓ Context cleared"
	// system line instead, gated by chatProcess.expectingClear.
	if ev.Message.Model == "<synthetic>" {
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
		case "thinking":
			// Always emit an IsThinking event so emitPhase("thinking") fires
			// even before any text has accumulated. ThinkingText carries the
			// accumulated reasoning so far (empty on the very first snapshot
			// before any delta has arrived).
			out = append(out, ClaudeChatEvent{IsThinking: true, ThinkingText: c.Thinking})
		}
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}
