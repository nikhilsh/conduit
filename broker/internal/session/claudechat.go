package session

import (
	"bufio"
	"encoding/json"
	"io"
	"strconv"
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
// `resumeSessionID`, when non-empty, appends `--resume <id>` so a
// RESPAWNED agent (broker restart, self-heal after a crash) picks the
// conversation back up instead of starting amnesiac (device feedback:
// "it went down and lost where it was"). The CLI's conversation files
// live in the per-session agent-home, which persists on disk, so resume
// works across broker restarts. An unknown id fails fast with a clean
// error result (verified live), which lands in the normal agent-exit
// notice path rather than hanging.
// `continueLatest` (used only when no id is known — sessions recovered
// from a pre-latch broker) appends `--continue`, which resolves the most
// recent conversation in the cwd; with the per-session agent-home that
// is unambiguously THIS session's own conversation (verified live).
func claudeStreamCommand(command, args []string, resumeSessionID string, continueLatest bool) []string {
	argv := make([]string, 0, len(command)+len(args)+8)
	argv = append(argv, command...)
	argv = append(argv, args...)
	if resumeSessionID != "" {
		argv = append(argv, "--resume", resumeSessionID)
	} else if continueLatest {
		argv = append(argv, "--continue")
	}
	argv = append(argv,
		"-p",
		"--input-format", "stream-json",
		"--output-format", "stream-json",
		"--include-partial-messages",
		"--verbose",
		// Route interactive-tool permission asks (AskUserQuestion) to
		// stdin/stdout control_request/control_response instead of the
		// headless auto-DENY, so the agent genuinely WAITS for the
		// phone's answer (see askcontrol.go). Ordinary tools still
		// auto-allow under --dangerously-skip-permissions — verified
		// live against claude-code 2.1.168.
		"--permission-prompt-tool", "stdio",
		// Nudge the agent to ASK via the AskUserQuestion tool instead of
		// writing a numbered question in prose. Only the tool blocks the
		// turn and renders the tappable, waiting card; a prose question
		// just ends the turn. This makes "the agent asked me to choose"
		// reliably interactive (device feedback, round 4).
		"--append-system-prompt", askUserQuestionNudge,
	)
	return argv
}

// askUserQuestionNudge steers the agent toward the interactive path.
const askUserQuestionNudge = "When you need the user to choose between options or " +
	"answer a question before you continue, ALWAYS use the AskUserQuestion tool " +
	"rather than writing the question and options as plain text. The mobile app " +
	"renders AskUserQuestion as tappable choices and waits for the answer; a " +
	"plain-text question does not pause your turn and the user may miss it."

// claudeStreamInitSessionID extracts the CLI's own conversation id from
// a `system/init` stream-json line. Captured + persisted so respawns can
// `--resume` it; ok=false for any other line.
func claudeStreamInitSessionID(line []byte) (string, bool) {
	var ev struct {
		Type      string `json:"type"`
		Subtype   string `json:"subtype"`
		SessionID string `json:"session_id"`
	}
	if json.Unmarshal(line, &ev) != nil || ev.Type != "system" ||
		ev.Subtype != "init" || ev.SessionID == "" {
		return "", false
	}
	return ev.SessionID, true
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
// (task #233) with the turn's last assistant text, and the AI title
// generator (task: ai-session-titles) which mints/refines the session
// name from the conversation. gen / titleGen may be nil (feature disabled
// / non-claude), in which case turn-end is a no-op for that one.
func processClaudeStreamOutput(r io.Reader, publish func([]byte), gen *quickReplyGenerator, titleGen *titleGenerator, onUsage func(usageDelta), onControl func(controlRequest), onInit func(string), onTurnEnd func()) error {
	sc := bufio.NewScanner(r)
	// Assistant turns can be large; raise the line cap well past bufio's
	// 64KB default.
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	// Track the most recent assistant prose + its event ts across the
	// turn so the turn-end `result` can hand the generator the message it
	// should base chips on (and an id the apps tie the chips to).
	var lastAssistantText, lastAssistantTS string
	// Current context-window occupancy, latched from each assistant
	// message's per-call usage. The turn-end `result` usage is a SUM across
	// every API call in the turn, so it overcounts context badly on
	// tool-heavy turns; the last call's prompt size is the real occupancy.
	var lastContextTokens uint64
	for sc.Scan() {
		line := sc.Bytes()
		// The CLI announces its conversation id on init; latch it so
		// respawns can --resume this exact conversation.
		if id, ok := claudeStreamInitSessionID(line); ok {
			if onInit != nil {
				onInit(id)
			}
			continue
		}
		// Control protocol (--permission-prompt-tool stdio): a blocked
		// can_use_tool request. Routed to the session's bridge — never
		// rendered as chat content.
		if req, ok := parseControlRequest(line); ok {
			if onControl != nil {
				onControl(req)
			}
			continue
		}
		if claudeStreamLineIsTurnEnd(line) {
			// Turn complete: clear the turn-in-flight latch FIRST (before the
			// usage fold) so the status broadcast that rides accumulateUsage
			// carries turn_active=false and a watching/reconnecting client's
			// "working" indicator clears. Then fold the turn's token/cost
			// usage from the `result` envelope, kick off best-effort AI quick
			// replies for the turn's final assistant message, give the title
			// generator the turn's prose so it can mint/refine the session
			// name, then reset for the next turn.
			if onTurnEnd != nil {
				onTurnEnd()
			}
			if onUsage != nil {
				if u, ok := parseClaudeUsage(line); ok {
					// Prefer the latched last-call prompt size for context
					// occupancy; the result envelope's own contextUsed is a
					// sum across the turn's API calls (kept only as a
					// fallback for turns where no per-message usage arrived).
					if lastContextTokens > 0 {
						u.contextUsed = lastContextTokens
					}
					onUsage(u)
				}
			}
			gen.kickoff(lastAssistantText, lastAssistantTS)
			titleGen.onTurnEnd(lastAssistantText)
			lastAssistantText, lastAssistantTS = "", ""
			lastContextTokens = 0
			continue
		}
		// Latch this assistant message's per-call prompt size as the live
		// context occupancy (see parseClaudeContextTokens). Falls through to
		// normal event processing below.
		if c, ok := parseClaudeContextTokens(line); ok {
			lastContextTokens = c
		}
		// Surface /compact progress + result as a system chat line — the
		// stream-json engine reports it via system/status events that
		// parseClaudeStreamLine ignores, so without this a /compact is
		// silent in the Chat tab.
		if msg, ok := claudeCompactNotice(line); ok {
			publishChatSystem(publish, msg)
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
			case e.ToolName == "AskUserQuestion":
				// Interactive question tool: render the question + a
				// numbered option menu so the client classifier
				// (core/src/conversation.rs looks_like_pending_input /
				// extract_pending_options) shows the tappable
				// approval/options card. The generic tool-card summary
				// matched none of AskUserQuestion's args, so the user saw
				// a bare "AskUserQuestion:" row and no way to answer
				// (device bug: "can't see approval").
				q, ok := askUserQuestionContent(e.ToolInput)
				if !ok {
					role, content = "tool", toolCardContent(e.ToolName, e.ToolInput)
					break
				}
				role, content = "assistant", q
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

// claudeCompactNotice decodes a `/compact` progress/result line and returns
// the user-facing message to surface (and true). claude-code 2.1.156 emits
// (captured 2026-05-29):
//
//	{"type":"system","subtype":"status","status":"compacting", …}
//	{"type":"system","subtype":"status","status":null,
//	 "compact_result":"success"|"failed","compact_error":"…", …}
//
// Returns ok=false for any other line.
func claudeCompactNotice(line []byte) (string, bool) {
	var ev struct {
		Type          string `json:"type"`
		Subtype       string `json:"subtype"`
		Status        string `json:"status"`
		CompactResult string `json:"compact_result"`
		CompactError  string `json:"compact_error"`
	}
	if err := json.Unmarshal(line, &ev); err != nil {
		return "", false
	}
	if ev.Type != "system" || ev.Subtype != "status" {
		return "", false
	}
	switch {
	case ev.CompactResult == "success":
		return "✓ Context compacted.", true
	case ev.CompactResult == "failed":
		if strings.TrimSpace(ev.CompactError) != "" {
			return "Couldn’t compact: " + ev.CompactError, true
		}
		return "Couldn’t compact the conversation.", true
	case ev.Status == "compacting":
		return "Compacting context…", true
	}
	return "", false
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

// askUserQuestionContent renders an AskUserQuestion tool_use as a
// pending-input-shaped chat line: each question's text followed by its
// options as a numbered menu ("1. Label"). That is exactly the shape the
// client classifier recognizes (numbered menu → kind "pending_input" with
// tappable pending_options), so the question surfaces as the interactive
// approval/options card on both apps. Returns ok=false on malformed input
// (the caller falls back to the generic tool card).
func askUserQuestionContent(input json.RawMessage) (string, bool) {
	var payload struct {
		Questions []struct {
			Question    string `json:"question"`
			MultiSelect bool   `json:"multiSelect"`
			Options     []struct {
				Label string `json:"label"`
			} `json:"options"`
		} `json:"questions"`
	}
	if len(input) == 0 || json.Unmarshal(input, &payload) != nil {
		return "", false
	}
	var b strings.Builder
	for _, q := range payload.Questions {
		question := strings.TrimSpace(q.Question)
		if question == "" {
			continue
		}
		if b.Len() > 0 {
			b.WriteString("\n\n")
		}
		b.WriteString(question)
		// Multi-select travels INSIDE the text (no schema change across
		// broker → core → apps): the apps' pending-input parser detects
		// this exact marker and renders checkboxes + Send instead of
		// tap-to-send. Doubles as honest prose for clients that don't.
		if q.MultiSelect {
			b.WriteString(multiSelectMarker)
		}
		n := 0
		for _, o := range q.Options {
			label := strings.TrimSpace(o.Label)
			if label == "" {
				continue
			}
			n++
			b.WriteString("\n")
			b.WriteString(strconv.Itoa(n))
			b.WriteString(". ")
			b.WriteString(label)
		}
	}
	if b.Len() == 0 {
		return "", false
	}
	// Prepend the deterministic sentinel so the core classifier renders
	// the interactive card from a REAL AskUserQuestion only — never from
	// a text-shape guess on prose. The apps strip this leading line.
	return pendingInputSentinel + "\n" + b.String(), true
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
