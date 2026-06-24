package session

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync/atomic"
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

// pendingResolvedMarker is the leading token of the SECOND line of a
// PERSISTED, already-answered pending-input card. The broker writes a
// resolution entry into the conversation log when an AskUserQuestion is
// answered (or times out) so the answered/selected state survives an app
// close+reopen and rides across devices — until now that state lived only
// in the client's ephemeral SwiftUI @State and was lost on reload.
//
// Wire contract (text-carried, like multiSelectMarker, so NO broker→core→
// app schema change): the resolution card content is
//
//	[[conduit:needs-input]]
//	[[conduit:resolved]]{"answered":true,"answer":"Merge now"}
//	<question>
//	1. Merge now
//	2. Hold off
//
// i.e. the normal pending-input card body with this marker line inserted
// right after the sentinel. The JSON tail carries the resolution:
//   - answered:true + answer:"<chosen text>" for a real answer (a tap or
//     typed free text; multi-select taps arrive comma-joined verbatim);
//   - answered:false (answer omitted) when the ask TIMED OUT or was
//     resolved without a user answer, so the card stops showing "needs
//     input" but renders no selected option.
//
// Backward-compat: a transcript with no [[conduit:resolved]] line parses
// exactly as today (an unanswered card, or — for the unpersisted live
// card — nothing). Core keeps classifying the entry as pending_input (the
// sentinel is still present) and strips ONLY the sentinel line, so the
// marker line survives in `content` for the app to parse. The JSON tail
// leaves room to add fields without breaking older parsers.
const pendingResolvedMarker = "[[conduit:resolved]]"

// pendingResolution is the JSON payload carried after pendingResolvedMarker.
type pendingResolution struct {
	Answered bool   `json:"answered"`
	Answer   string `json:"answer,omitempty"`
}

// resolvedPendingInputContent renders the persisted resolution card for an
// answered/expired AskUserQuestion: the normal pending-input body with the
// resolution marker inserted on the line after the sentinel. ok=false when
// the ask has no renderable question body (nothing to persist). answer is
// ignored when answered is false (timeout / no-answer resolution).
func resolvedPendingInputContent(input json.RawMessage, answer string, answered bool) (string, bool) {
	body, ok := askUserQuestionContent(input)
	if !ok {
		return "", false
	}
	res := pendingResolution{Answered: answered}
	if answered {
		res.Answer = answer
	}
	meta, err := json.Marshal(res)
	if err != nil {
		return "", false
	}
	markerLine := pendingResolvedMarker + string(meta)
	// askUserQuestionContent guarantees a leading sentinel line; insert the
	// marker right after it so core's strip_pending_sentinel (which removes
	// only the exact sentinel line) leaves the marker intact in `content`.
	if rest, found := strings.CutPrefix(body, pendingInputSentinel+"\n"); found {
		return pendingInputSentinel + "\n" + markerLine + "\n" + rest, true
	}
	// Defensive: sentinel not at the head (shouldn't happen) — prepend both.
	return pendingInputSentinel + "\n" + markerLine + "\n" + body, true
}

// parsePendingResolution extracts the resolution carried in a persisted
// pending-input card's content, scanning for the pendingResolvedMarker line.
// ok=false when the content has no resolution marker (an unanswered card, or
// a legacy/backward-compat transcript). Mirrors the parse the apps perform.
func parsePendingResolution(content string) (pendingResolution, bool) {
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if rest, found := strings.CutPrefix(trimmed, pendingResolvedMarker); found {
			var res pendingResolution
			if json.Unmarshal([]byte(rest), &res) != nil {
				return pendingResolution{}, false
			}
			return res, true
		}
	}
	return pendingResolution{}, false
}

// pendingInputSentinel is a leading marker the broker prepends to the
// rendered content of a GENUINE interactive question (the AskUserQuestion
// tool — the agent is actually blocked waiting). It is the ONE
// deterministic signal that a "NEEDS YOUR INPUT" card should render and
// that the agent is waiting. The core classifier keys on it instead of
// guessing from text shape — the prior heuristic (any prose mentioning
// "select"+"option/choice", or any two short numbered lines) both
// false-fired on ordinary prose discussing options AND failed to wait,
// because prose questions don't block the agent (device feedback: a
// message describing the multi-select bug rendered as a needs-input
// card). The apps strip this line before display. First-line, newline-
// terminated, distinctive enough never to occur in real prose.
const pendingInputSentinel = "[[conduit:needs-input]]"

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

// interruptReqSeq numbers interrupt control_requests so each carries a unique
// request_id (the CLI echoes it back in the control_response). Atomic: Interrupt
// may be called from any goroutine.
var interruptReqSeq atomic.Uint64

// encodeControlInterrupt builds the stream-json control_request that aborts the
// agent's CURRENT turn — the Claude Agent SDK's `interrupt()` mechanism, the
// same one Claude's own mobile app uses. Verified live against claude-code
// 2.1.168: the CLI replies `control_response {subtype:"success"}`, emits a
// `[Request interrupted by user]` user event, ends the turn with
// `result/error_during_execution`, and stays alive for the next turn. Trailing
// newline terminates the stream-json line.
func encodeControlInterrupt() []byte {
	id := fmt.Sprintf("interrupt-%d", interruptReqSeq.Add(1))
	b, err := json.Marshal(map[string]any{
		"type":       "control_request",
		"request_id": id,
		"request":    map[string]any{"subtype": "interrupt"},
	})
	if err != nil {
		return nil
	}
	return append(b, '\n')
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
	ts        string // original chat-event ts; preserved for reconnect replay
}

// handleAskControl stashes a blocked AskUserQuestion so the user's next
// chat message can answer it (SendChat), and arms the give-up timer. A
// prior un-answered stash is superseded silently (its timer stopped) —
// the CLI can only have one blocked request per turn, so a leftover
// means the agent was respawned underneath it.
func (s *Session) handleAskControl(req controlRequest, cp *chatProcess, ts string) {
	timer := time.AfterFunc(askAnswerTimeout, func() { s.expirePendingAsk(req.RequestID) })
	s.mu.Lock()
	if prev := s.pendingAsk; prev != nil && prev.timer != nil {
		prev.timer.Stop()
	}
	s.pendingAsk = &pendingAsk{requestID: req.RequestID, input: req.Input, cp: cp, timer: timer, ts: ts}
	s.mu.Unlock()
	// Notify the device that the agent is waiting for input. Only fires
	// when no client is currently attached (maybeNotifyPendingInput guards
	// this). Runs after the stash is set so a racing client reattach sees
	// the pending ask and the push is coalesced / skipped.
	s.maybeNotifyPendingInput()
}

// PendingAskChatContent renders the session's currently-outstanding
// AskUserQuestion as the pending-input chat line (sentinel + numbered
// options), or ok=false when nothing is blocked.
//
// Used to re-surface the interactive approval/options card to a client that
// REATTACHES after a WS drop (e.g. the app was backgrounded long enough for
// the socket to die). The card originally arrived as a live chat view_event;
// the broker doesn't replay chat history on reattach and the Rust-core live
// copy died with the socket, so without this the card vanishes while the
// agent is still blocked on the question. Keys off the live `pendingAsk`, so
// an already-answered question (consumed → nil) correctly stays gone.
func (s *Session) PendingAskChatContent() (string, bool) {
	s.mu.Lock()
	ask := s.pendingAsk
	chat := s.chat
	s.mu.Unlock()
	if ask != nil {
		return askUserQuestionContent(ask.input)
	}
	// Codex twin: a codex app-server backend blocked on an approval has its
	// card live in the backend, not in pendingAsk. Re-surface it the same way
	// so a reattaching client doesn't lose the approval prompt.
	if rs, ok := chat.(approvalCardResurfacer); ok {
		return rs.PendingApprovalCard()
	}
	return "", false
}

// PendingAskChatTs returns the original chat-event timestamp that was assigned
// when the AskUserQuestion was first published as a view_event. Empty when no
// ask is pending or the ts wasn't captured (codex path). Used by the reconnect
// resend path so apply_chat's (role,content,ts) dedup treats the replay as the
// same event rather than storing a second copy.
func (s *Session) PendingAskChatTs() string {
	s.mu.Lock()
	ask := s.pendingAsk
	s.mu.Unlock()
	if ask != nil {
		return ask.ts
	}
	return ""
}

// approvalCardResurfacer is the OPTIONAL backend capability that lets a
// reattaching client re-see an outstanding approval card (codex app-server).
// Mirrors PendingAskChatContent's role for claude's pendingAsk.
type approvalCardResurfacer interface {
	PendingApprovalCard() (string, bool)
}

// approvalSummarizer is the OPTIONAL backend capability that exposes the
// human-readable summary of an outstanding approval request (codex app-server
// only — command line or file-change description). Used by the push-notify
// path to populate the "approval" category notification body.
type approvalSummarizer interface {
	PendingApprovalSummary() (string, bool)
}

// PendingApprovalSummaryForPush returns the human-readable summary and
// isApproval=true when the session is blocked on a codex approval-type
// server request (command/file-change), so the push notification can carry
// an informative body and the "approval" category. Returns ("", false) when
// nothing is pending, or when the pending kind is AskUserQuestion-style (not
// a codex approval), so callers fall back to the generic "input" category.
func (s *Session) PendingApprovalSummaryForPush() (summary string, isApproval bool) {
	s.mu.Lock()
	chat := s.chat
	s.mu.Unlock()
	if as, ok := chat.(approvalSummarizer); ok {
		return as.PendingApprovalSummary()
	}
	return "", false
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

// recordPendingResolution persists the resolved pending-input card to the
// conversation log so the answered state survives close+reopen (transcript
// replay on any device). answer is the chosen option text (ignored when
// answered is false, e.g. a timeout). No-op when the ask has no renderable
// body. Best-effort: never blocks the answer.
//
// NOTE: we intentionally do NOT re-broadcast the resolved content over the
// live WS. The resolved content differs from the original (it prepends
// [[conduit:resolved]]...) so Rust apply_chat stores it as a SECOND item
// alongside the original pending_input, producing a duplicate raw-text
// bubble in the chat. The client already flips the card to a chip
// optimistically on tap; the transcript update here covers the
// close+reopen path.
func (s *Session) recordPendingResolution(ask *pendingAsk, answer string, answered bool) {
	if ask == nil {
		return
	}
	content, ok := resolvedPendingInputContent(ask.input, answer, answered)
	if !ok {
		return
	}
	s.convLog.appendResolvedPendingInput(content, ask.ts)
}

// expirePendingAsk releases an AskUserQuestion the user never answered:
// allow with unchanged input, which the CLI reports to the model as
// "The user did not answer the questions." It also records a no-answer
// resolution so the card stops showing "needs input" on reopen.
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
	s.recordPendingResolution(ask, "", false)
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

// latchCodexThreadID records codex's thread id (thread.started) and
// persists it so recovery can `exec resume` it — the codex twin of
// latchChatSessionID.
func (s *Session) latchCodexThreadID(id string) {
	s.mu.Lock()
	changed := s.codexThreadID != id
	s.codexThreadID = id
	s.mu.Unlock()
	if changed && s.metaPath != "" {
		_ = s.persistMetadata()
	}
}
