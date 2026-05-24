package session

import (
	"bufio"
	"encoding/json"
	"io"
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
// Only assistant *text* is published here; tool_use blocks are parsed
// (slice 1) but their card rendering is a later slice. system/result/
// stream_event envelopes are skipped — no TUI chrome can leak in, which is
// the whole point of the structured channel (device bug #6).
func processClaudeStreamOutput(r io.Reader, publish func([]byte)) error {
	sc := bufio.NewScanner(r)
	// Assistant turns can be large; raise the line cap well past bufio's
	// 64KB default.
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		evs, ok := parseClaudeStreamLine(sc.Bytes())
		if !ok {
			continue
		}
		for _, e := range evs {
			if e.Text == "" {
				continue // tool_use-only block; card rendering is a later slice
			}
			payload, err := json.Marshal(map[string]any{
				"type": "view_event",
				"view": "chat",
				"event": map[string]any{
					"role":    e.Role,
					"content": e.Text,
					"ts":      claudeChatNow().UTC().Format(time.RFC3339Nano),
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
