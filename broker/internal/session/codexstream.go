package session

import (
	"bytes"
	"encoding/json"
	"strings"
)

// codexStreamEvent decodes one JSONL line from `codex exec --json`. Codex's
// schema (verified against codex-cli 0.132 on the box): a turn emits
// thread.started{thread_id} → turn.started → item.completed{item:{type,text}}
// → turn.completed. Unlike claude's persistent stream-json stdin, `codex
// exec` is one-shot; multi-turn chat resumes via `codex exec resume
// <thread_id>`. See docs/PLAN-CHAT-CHANNEL.md (task #24, codex slice).
type codexStreamEvent struct {
	Type     string `json:"type"`
	ThreadID string `json:"thread_id"`
	Item     struct {
		Type string `json:"type"` // "agent_message" | "command_execution" | …
		Text string `json:"text"`
		// command_execution fields (codex-cli 0.132, captured 2026-05-29):
		// item.completed{item:{type:"command_execution",command,exit_code,status,aggregated_output}}.
		Command  string `json:"command"`
		ExitCode *int   `json:"exit_code"` // null while in_progress
		Status   string `json:"status"`    // "in_progress" | "completed"
	} `json:"item"`
}

// parseCodexStreamLine lifts chat items + the thread id out of one codex
// JSONL line. threadID is non-empty only on thread.started (the caller
// stashes it to `codex exec resume` the next turn). ok is true when events
// carries a renderable chat event. Non-message items (turn.*, tool items
// not yet mapped) and malformed lines return ok=false.
func parseCodexStreamLine(line []byte) (events []ClaudeChatEvent, threadID string, ok bool) {
	line = bytes.TrimSpace(line)
	if len(line) == 0 {
		return nil, "", false
	}
	var ev codexStreamEvent
	if err := json.Unmarshal(line, &ev); err != nil {
		return nil, "", false
	}
	switch ev.Type {
	case "thread.started":
		return nil, ev.ThreadID, false
	case "item.completed":
		if ev.Item.Type == "agent_message" && strings.TrimSpace(ev.Item.Text) != "" {
			return []ClaudeChatEvent{{Role: "assistant", Text: ev.Item.Text}}, "", true
		}
		// Surface a finished shell command as a tool card (the same
		// role:"tool" rendering claude's tool_use blocks use). Only on
		// completion (in_progress items carry no exit_code yet).
		if ev.Item.Type == "command_execution" && strings.TrimSpace(ev.Item.Command) != "" {
			input, err := json.Marshal(map[string]any{
				"command":   ev.Item.Command,
				"exit_code": ev.Item.ExitCode,
			})
			if err == nil {
				return []ClaudeChatEvent{{Role: "tool", ToolName: "command_execution", ToolInput: input}}, "", true
			}
		}
	}
	return nil, "", false
}
