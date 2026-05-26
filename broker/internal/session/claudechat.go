package session

import (
	"bufio"
	"encoding/json"
	"io"
	"strings"
	"time"
)

// This is slice 2a of the structured chat channel (task #24, decision B +
// B-i): the pure stream mappers that sit between a `claude -p
// --input-format stream-json --output-format stream-json` subprocess and
// the WS chat view_events. The subprocess lifecycle (spawn, stdin/stdout
// pipes, restart) is slice 2b; keeping the mapping pure here makes it
// deterministically testable without a real claude.

// claudeChatNow is the clock used for chat-event timestamps; overridable in
// tests.
var claudeChatNow = time.Now

// claudeStreamCommand builds the argv that runs the agent headless in
// stream-json mode for the structured chat channel: the adapter's own
// command + args, then the stream-json flags. `-p` + stream-json output
// requires `--verbose` (verified against Claude Code 2.1.x); without it the
// CLI refuses.
func claudeStreamCommand(command, args []string) []string {
	argv := make([]string, 0, len(command)+len(args)+6)
	argv = append(argv, command...)
	argv = append(argv, args...)
	argv = append(argv,
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--verbose",
	)
	return argv
}

// encodeClaudeUserMessage builds one stream-json input line for the user's
// composer message: the `{"type":"user", …}` envelope claude reads on stdin
// in `--input-format stream-json`. A trailing newline terminates the line.
func encodeClaudeUserMessage(text string) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"type": "user",
		"message": map[string]any{
			"role": "user",
			"content": []map[string]any{
				{"type": "text", "text": text},
			},
		},
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// processClaudeStreamOutput reads claude's stream-json stdout line by line,
// maps each assistant text block to a chat `view_event`, and hands the
// marshaled JSON to publish. It returns when the reader hits EOF (the
// subprocess exited) or errors.
//
// Assistant text becomes a role:"assistant" chat event; tool_use blocks
// become a role:"tool" event whose content ("Name: <summary>") the client's
// conversation classifier renders as a tool card. system/stream_event
// envelopes are skipped — no TUI chrome can leak in, which is the whole
// point of the structured channel (device bug #6).
//
// The `result` envelope (turn end) fires the AI quick-reply generator
// (task #233) with the turn's last assistant text. gen may be nil
// (feature disabled / non-claude), in which case turn-end is a no-op.
func processClaudeStreamOutput(r io.Reader, publish func([]byte), gen *quickReplyGenerator) error {
	sc := bufio.NewScanner(r)
	// Assistant turns can be large; raise the line cap well past bufio's
	// 64KB default.
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	// Track the most recent assistant prose + its event ts across the
	// turn so the turn-end `result` can hand the generator the message it
	// should base chips on (and an id the apps tie the chips to).
	var lastAssistantText, lastAssistantTS string
	for sc.Scan() {
		line := sc.Bytes()
		if claudeStreamLineIsTurnEnd(line) {
			// Turn complete: kick off best-effort AI quick replies for the
			// turn's final assistant message, then reset for the next turn.
			gen.kickoff(lastAssistantText, lastAssistantTS)
			lastAssistantText, lastAssistantTS = "", ""
			continue
		}
		evs, ok := parseClaudeStreamLine(line)
		if !ok {
			continue
		}
		for _, e := range evs {
			var role, content string
			switch {
			case e.Text != "":
				role, content = "assistant", e.Text
			case e.ToolName != "":
				role, content = "tool", toolCardContent(e.ToolName, e.ToolInput)
			default:
				continue
			}
			ts := claudeChatNow().UTC().Format(time.RFC3339Nano)
			if role == "assistant" {
				lastAssistantText, lastAssistantTS = content, ts
			}
			payload, err := json.Marshal(map[string]any{
				"type": "view_event",
				"view": "chat",
				"event": map[string]any{
					"role":    role,
					"content": content,
					"ts":      ts,
					"files":   []any{},
				},
			})
			if err != nil {
				continue
			}
			publish(payload)
		}
	}
	return sc.Err()
}

// publishChatSystem emits a role:"system" chat view_event (e.g. an
// agent-exit notice) through the same path as assistant events, so
// out-of-band conditions surface in the Chat tab instead of as silence.
func publishChatSystem(publish func([]byte), content string) {
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    "system",
			"content": content,
			"ts":      claudeChatNow().UTC().Format(time.RFC3339Nano),
			"files":   []any{},
		},
	})
	if err != nil {
		return
	}
	publish(payload)
}

// toolCardContent formats a tool_use block as "Name: <summary>" — the shape
// the client's conversation classifier (core/src/conversation.rs
// extract_tool_name) turns into a tool card. The summary surfaces the most
// salient arg; it falls back to a bare "Name:" so the card still classifies.
func toolCardContent(name string, input json.RawMessage) string {
	summary := ""
	if len(input) > 0 {
		var m map[string]any
		if json.Unmarshal(input, &m) == nil {
			for _, k := range []string{"command", "file_path", "path", "pattern", "query", "url", "description"} {
				if v, ok := m[k].(string); ok && strings.TrimSpace(v) != "" {
					summary = v
					break
				}
			}
		}
	}
	if summary == "" {
		return name + ":"
	}
	return name + ": " + summary
}
