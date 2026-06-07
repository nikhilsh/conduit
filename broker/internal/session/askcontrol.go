package session

import (
	"encoding/json"
	"time"
)

// AskUserQuestion control bridge (--permission-prompt-tool stdio).
//
// Headless `claude -p` AUTO-DENIES AskUserQuestion ("Permission prompts
// are not available in this context"), so the agent never waited for the
// phone's tap: it improvised past the error mid-turn ("the question was
// dismissed — I'll take that as proceed") and the user's selection later
// arrived as an unrelated user turn. Device feedback, round 4.
//
// With `--permission-prompt-tool stdio` the CLI instead emits a
// stream-json `control_request` (subtype can_use_tool) and BLOCKS THE
// TURN until a `control_response` arrives on stdin (verified live
// against claude-code 2.1.168). The bridge:
//   - AskUserQuestion requests are stashed on the session; the user's
//     next chat message answers them via `updatedInput.answers` (single
//     question) or `updatedInput.response` (multi-question free text),
//     so the agent resumes with the real answer in the SAME turn.
//   - every other can_use_tool is auto-allowed with unchanged input,
//     preserving --dangerously-skip-permissions semantics.
//   - an unanswered question times out after `askAnswerTimeout`: allow
//     with unchanged input → the model sees "The user did not answer
//     the questions." and decides for itself.

// askAnswerTimeout is how long an AskUserQuestion waits for the phone
// before the broker lets the agent continue unanswered. Generous on
// purpose — a lock-screen approval can sit for a while; var for tests.
var askAnswerTimeout = 30 * time.Minute

// multiSelectMarker is appended to a multi-select question's prompt line
// in the rendered pending-input card text. The apps detect it (exact
// match, end of the question line) and switch that question to
// checkbox + Send. Text-carried so no broker→core→app schema changes.
const multiSelectMarker = " (select all that apply)"

// controlRequest is a parsed stream-json `control_request` line.
type controlRequest struct {
	RequestID string
	ToolName  string
	Input     json.RawMessage
}

// parseControlRequest decodes a `control_request` line; ok=false for any
// other line shape.
func parseControlRequest(line []byte) (controlRequest, bool) {
	var ev struct {
		Type      string `json:"type"`
		RequestID string `json:"request_id"`
		Request   struct {
			Subtype  string          `json:"subtype"`
			ToolName string          `json:"tool_name"`
			Input    json.RawMessage `json:"input"`
		} `json:"request"`
	}
	if json.Unmarshal(line, &ev) != nil || ev.Type != "control_request" {
		return controlRequest{}, false
	}
	if ev.Request.Subtype != "can_use_tool" || ev.RequestID == "" {
		return controlRequest{}, false
	}
	return controlRequest{
		RequestID: ev.RequestID,
		ToolName:  ev.Request.ToolName,
		Input:     ev.Request.Input,
	}, true
}

// encodeControlAllow builds the control_response that allows the tool
// with the given updatedInput (pass the original input unchanged for the
// plain auto-allow and the timed-out-unanswered paths). Trailing newline
// terminates the stream-json line.
func encodeControlAllow(requestID string, updatedInput json.RawMessage) []byte {
	if len(updatedInput) == 0 {
		updatedInput = json.RawMessage(`{}`)
	}
	b, err := json.Marshal(map[string]any{
		"type": "control_response",
		"response": map[string]any{
			"subtype":    "success",
			"request_id": requestID,
			"response": map[string]any{
				"behavior":     "allow",
				"updatedInput": updatedInput,
			},
		},
	})
	if err != nil {
		return nil
	}
	return append(b, '\n')
}

// encodeAskAnswer builds the control_response that answers an
// AskUserQuestion with the user's message:
//   - exactly one question → `updatedInput.answers = {question: msg}`
//     (the CLI folds it into "Your questions have been answered: …";
//     multi-select taps arrive comma-joined and pass through verbatim);
//   - multiple questions → `updatedInput.response = msg` (free-text
//     variant: "The user responded: …" — we can't split one message
//     across questions reliably).
func encodeAskAnswer(requestID string, originalInput json.RawMessage, msg string) ([]byte, error) {
	var updated map[string]any
	if len(originalInput) == 0 || json.Unmarshal(originalInput, &updated) != nil {
		updated = map[string]any{}
	}
	var questions struct {
		Questions []struct {
			Question string `json:"question"`
		} `json:"questions"`
	}
	_ = json.Unmarshal(originalInput, &questions)
	if len(questions.Questions) == 1 {
		updated["answers"] = map[string]string{questions.Questions[0].Question: msg}
	} else {
		updated["response"] = msg
	}
	raw, err := json.Marshal(updated)
	if err != nil {
		return nil, err
	}
	return encodeControlAllow(requestID, raw), nil
}

// pendingAsk is an AskUserQuestion control request waiting for the
// user's answer. Guarded by Session.mu.
type pendingAsk struct {
	requestID string
	input     json.RawMessage
	cp        *chatProcess
	timer     *time.Timer
}

// handleAskControl stashes a blocked AskUserQuestion so the user's next
// chat message can answer it (SendChat), and arms the give-up timer. A
// prior un-answered stash is superseded silently (its timer stopped) —
// the CLI can only have one blocked request per turn, so a leftover
// means the agent was respawned underneath it.
func (s *Session) handleAskControl(req controlRequest, cp *chatProcess) {
	timer := time.AfterFunc(askAnswerTimeout, func() { s.expirePendingAsk(req.RequestID) })
	s.mu.Lock()
	if prev := s.pendingAsk; prev != nil && prev.timer != nil {
		prev.timer.Stop()
	}
	s.pendingAsk = &pendingAsk{requestID: req.RequestID, input: req.Input, cp: cp, timer: timer}
	s.mu.Unlock()
}

// takePendingAsk atomically consumes the stashed request, if any.
func (s *Session) takePendingAsk() *pendingAsk {
	s.mu.Lock()
	ask := s.pendingAsk
	s.pendingAsk = nil
	s.mu.Unlock()
	if ask != nil && ask.timer != nil {
		ask.timer.Stop()
	}
	return ask
}

// expirePendingAsk releases an AskUserQuestion the user never answered:
// allow with unchanged input, which the CLI reports to the model as
// "The user did not answer the questions."
func (s *Session) expirePendingAsk(requestID string) {
	s.mu.Lock()
	ask := s.pendingAsk
	if ask == nil || ask.requestID != requestID {
		s.mu.Unlock()
		return
	}
	s.pendingAsk = nil
	s.mu.Unlock()
	_ = ask.cp.SendRaw(encodeControlAllow(ask.requestID, ask.input))
}

// latchChatSessionID records the claude CLI's announced conversation id
// (stream-json init line) and persists it so respawns/recovery can
// `--resume` the agent's memory. Lives here with the other chat-control
// session plumbing.
func (s *Session) latchChatSessionID(id string) {
	s.mu.Lock()
	changed := s.chatSessionID != id
	s.chatSessionID = id
	s.mu.Unlock()
	if changed && s.metaPath != "" {
		_ = s.persistMetadata()
	}
}
