package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// This file holds the PURE wire helpers for the codex app-server backend
// (codexappserver.go): the JSON-RPC frame encoders, the request-param builders,
// and the notification → chat-event mapper. Keeping them pure (no process, no
// I/O) makes them table-testable without spawning a real `codex app-server`.

// errCodexTurnInFlight is returned by Send when a turn is already running:
// codex app-server handles one turn at a time per thread, so a concurrent send
// is rejected (the composer should be disabled client-side while the agent
// works, so this is a backstop).
var errCodexTurnInFlight = errors.New("codex app-server: turn already in flight")

// codexRPCEnvelope is the minimal decode of a JSON-RPC line used by the reader
// to demux responses (have `id`, no `method`) from notifications (have
// `method`, no `id`). `ID` is json.RawMessage so a response with id 0 is still
// distinguishable from an absent id (notifications).
type codexRPCEnvelope struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

// codexAppEvent is a single mapped chat event (assistant prose, a tool card,
// or a system line) ready for emit().
type codexAppEvent struct {
	role    string // "assistant" | "tool" | "system"
	content string
}

// encodeCodexRequest builds one JSON-RPC request line (newline-terminated).
// The `jsonrpc` field is omitted on the wire — codex tolerates its absence
// (confirmed by the captured trace). Requests carry an integer id.
func encodeCodexRequest(id int, method string, params any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// encodeCodexNotification builds one JSON-RPC notification line (no id).
func encodeCodexNotification(method string, params any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"method": method,
		"params": params,
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// writeRequest encodes + writes one request to stdin (locks for the write).
func (c *codexAppServerProcess) writeRequest(id int, method string, params any) error {
	line, err := encodeCodexRequest(id, method, params)
	if err != nil {
		return err
	}
	return c.writeLine(line)
}

// writeNotification encodes + writes one notification to stdin.
func (c *codexAppServerProcess) writeNotification(method string, params any) error {
	line, err := encodeCodexNotification(method, params)
	if err != nil {
		return err
	}
	return c.writeLine(line)
}

func (c *codexAppServerProcess) writeLine(line []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errChatProcessClosed
	}
	if c.stdin == nil {
		return errChatProcessClosed
	}
	_, err := c.stdin.Write(line)
	return err
}

// codexInitializeParams is the initialize request's params.
func codexInitializeParams() map[string]any {
	return map[string]any{
		"clientInfo": map[string]any{
			"name":    "conduit-broker",
			"version": codexAppServerClientVersion,
		},
	}
}

// codexThreadStartParams builds thread/start params, applying the override's
// model / effort / permission mode as JSON-RPC params (the app-server twin of
// the exec path's CLI flags). Unknown / empty values are dropped, never
// breaking the spawn.
//
//	model:           override.Model (free-form string; codex validates)
//	effort:          ReasoningEffort, validated against codexEfforts → the
//	                 codex ReasoningEffort enum (low/medium/high)
//	sandbox:         permission mode "plan" → "read-only" (SandboxMode enum);
//	                 default → "danger-full-access" (the adapter's bypass posture)
//	approvalPolicy:  "plan" → "on-request" (read-only review); default →
//	                 "never" (no approval prompts, matching the bypass flag)
func codexThreadStartParams(dir string, o SpawnOverride) map[string]any {
	p := map[string]any{"cwd": dir}
	if m := strings.TrimSpace(o.Model); m != "" {
		p["model"] = m
	}
	if e := codexEffortParam(o.ReasoningEffort); e != "" {
		p["effort"] = e
	}
	sandbox, approval := codexSandboxFor(o.PermissionMode)
	p["sandbox"] = sandbox
	p["approvalPolicy"] = approval
	return p
}

// codexThreadResumeParams builds thread/resume params for the recovery path.
// Resume reuses the thread's recorded posture, but we still re-send cwd +
// model/effort so a fork-on-resume keeps its override. Sandbox/approval are
// re-applied for parity with start.
func codexThreadResumeParams(threadID, dir string, o SpawnOverride) map[string]any {
	p := map[string]any{"threadId": threadID, "cwd": dir}
	if m := strings.TrimSpace(o.Model); m != "" {
		p["model"] = m
	}
	sandbox, approval := codexSandboxFor(o.PermissionMode)
	p["sandbox"] = sandbox
	p["approvalPolicy"] = approval
	return p
}

// codexTurnStartParams builds turn/start params for a user message. Model /
// effort overrides ride along (turn-level overrides are honored per the
// schema's TurnStartParams.model / .effort).
func codexTurnStartParams(threadID, text string, o SpawnOverride) map[string]any {
	p := map[string]any{
		"threadId": threadID,
		"input": []map[string]any{
			{"type": "text", "text": text},
		},
	}
	if m := strings.TrimSpace(o.Model); m != "" {
		p["model"] = m
	}
	if e := codexEffortParam(o.ReasoningEffort); e != "" {
		p["effort"] = e
	}
	return p
}

// codexEffortParam validates a reasoning-effort label against the labels codex
// accepts (low/medium/high — matching codexEfforts, a subset of the schema's
// ReasoningEffort enum none/minimal/low/medium/high/xhigh). An empty or unknown
// value returns "" (dropped).
func codexEffortParam(effort string) string {
	effort = strings.TrimSpace(effort)
	if effort != "" && codexEfforts[effort] {
		return effort
	}
	return ""
}

// codexSandboxFor maps a permission mode to (sandbox, approvalPolicy) for
// thread/start|resume. The schema's ThreadStartParams.sandbox is a SandboxMode
// string enum (read-only / workspace-write / danger-full-access) and
// approvalPolicy is an AskForApproval enum (untrusted / on-failure / on-request
// / never).
//
//	"plan"  → read-only sandbox + on-request approvals (planning posture, the
//	          app-server twin of the exec path's `--sandbox read-only`)
//	default → danger-full-access + never (the adapter's
//	          `--dangerously-bypass-approvals-and-sandbox` bypass posture)
func codexSandboxFor(mode string) (sandbox, approval string) {
	if strings.TrimSpace(mode) == "plan" {
		return "read-only", "on-request"
	}
	return "danger-full-access", "never"
}

// codexThreadIDFromStartResult lifts the thread id from a thread/start
// response's result ({"thread":{"id":"…"}}). "" when absent/malformed.
func codexThreadIDFromStartResult(result json.RawMessage) string {
	var r struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if json.Unmarshal(result, &r) != nil {
		return ""
	}
	return r.Thread.ID
}

// codexStartedThreadID lifts the thread id from a thread/started notification's
// params ({"thread":{"id":"…"}}). "" when absent/malformed.
func codexStartedThreadID(params json.RawMessage) string {
	var p struct {
		Thread struct {
			ID string `json:"id"`
		} `json:"thread"`
	}
	if json.Unmarshal(params, &p) != nil {
		return ""
	}
	return p.Thread.ID
}

// codexStartedTurnID lifts the turn id from a turn/started notification's
// params ({"threadId":"…","turn":{"id":"…"}}). "" when absent/malformed. Used
// to target turn/interrupt (the Stop button).
func codexStartedTurnID(params json.RawMessage) string {
	var p struct {
		Turn struct {
			ID string `json:"id"`
		} `json:"turn"`
	}
	if json.Unmarshal(params, &p) != nil {
		return ""
	}
	return p.Turn.ID
}

// waitCodexResult extracts the result from the next response on the channel,
// returning an error for a JSON-RPC error response. The reader goroutine only
// forwards correlated responses, so reading one is correct here (the handshake
// is strictly sequential: one request, one awaited response).
func waitCodexResult(resp <-chan json.RawMessage) (json.RawMessage, error) {
	raw, ok := <-resp
	if !ok {
		return nil, errors.New("app-server closed before response")
	}
	var env codexRPCEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, err
	}
	if len(env.Error) > 0 && string(env.Error) != "null" {
		return nil, fmt.Errorf("rpc error: %s", string(env.Error))
	}
	return env.Result, nil
}

// codexUsageFromNotification folds a thread/tokenUsage/updated notification's
// running totals into a usageDelta. The `total` block is the thread's
// cumulative usage; accumulateUsage tracks context as point-in-time and sums
// the rest, so we map total.* through and use inputTokens as the live context
// occupancy and modelContextWindow as the window (which the exec path lacked).
//
// NOTE: because `total` is cumulative (not a per-turn delta) and accumulateUsage
// ADDS input/output/cached, the lifetime token totals will over-count across
// turns. This matches the exec path's behavior closely enough for the gauge
// (which reads context*, the point-in-time fields) and the integration test
// will confirm; flagged for the caller.
// codexUsageFromNotification maps a thread/tokenUsage/updated notification to a
// usageDelta. The notification carries BOTH `last` (the most recent turn's
// usage) and `total` (the thread's cumulative usage), plus modelContextWindow.
//
// accumulateUsage ADDS input/output/cached into lifetime running totals, so we
// must feed it the per-turn `last` breakdown — feeding cumulative `total` would
// over-count (each turn re-adds the whole running sum). The context gauge is
// point-in-time, and `last.inputTokens` is the size of the most recent prompt =
// the current conversation's footprint in the window, which correctly DROPS
// after a /compact. Using cumulative `total.inputTokens` here was the old
// "fake gauge" failure mode (it grows unbounded and pins the gauge at 100%).
func codexUsageFromNotification(params json.RawMessage) (usageDelta, bool) {
	type breakdown struct {
		TotalTokens           uint64 `json:"totalTokens"`
		InputTokens           uint64 `json:"inputTokens"`
		CachedInputTokens     uint64 `json:"cachedInputTokens"`
		OutputTokens          uint64 `json:"outputTokens"`
		ReasoningOutputTokens uint64 `json:"reasoningOutputTokens"`
	}
	var p struct {
		TokenUsage struct {
			Last               breakdown `json:"last"`
			Total              breakdown `json:"total"`
			ModelContextWindow uint64    `json:"modelContextWindow"`
		} `json:"tokenUsage"`
	}
	if json.Unmarshal(params, &p) != nil {
		return usageDelta{}, false
	}
	last := p.TokenUsage.Last
	if last.TotalTokens == 0 && last.InputTokens == 0 && last.OutputTokens == 0 {
		return usageDelta{}, false
	}
	return usageDelta{
		input:  last.InputTokens,
		output: last.OutputTokens + last.ReasoningOutputTokens,
		cached: last.CachedInputTokens,
		// Point-in-time occupancy: the latest prompt size, not the lifetime
		// sum. Drops after compaction so the gauge reflects "now".
		contextUsed:   last.InputTokens,
		contextWindow: p.TokenUsage.ModelContextWindow,
	}, true
}

// codexNotificationToEvent maps an item-bearing notification to an optional
// chat event. It handles:
//
//   - item/agentMessage/delta → IGNORED (the streaming token chunks). Emitting
//     one view_event per delta would fragment the assistant reply into one chat
//     bubble per token. Both proven backends — claude stream-json
//     (parseClaudeStreamLine drops content_block_delta) and codex exec — emit a
//     single assistant event per complete message, so we match that here.
//   - item/completed item.type=="agentMessage" → one role:"assistant" event with
//     the full final item.text (the whole reply as a single bubble)
//   - item/completed item.type=="commandExecution" → a role:"tool" command card
//     (same shape the exec path used via toolCardContent / command_execution)
//   - item/completed item.type=="contextCompaction" → a role:"system" line
//     "✓ Context compacted."
//   - item/completed item.type=="userMessage" → IGNORED (echo of our input)
//
// ok=false for anything else (item/started, reasoning, fileChange, deltas, …).
func codexNotificationToEvent(method string, params json.RawMessage) (codexAppEvent, bool) {
	switch method {
	case "item/completed":
		var p struct {
			Item struct {
				Type     string `json:"type"`
				Text     string `json:"text"`
				Command  string `json:"command"`
				ExitCode *int   `json:"exitCode"`
				Status   string `json:"status"`
			} `json:"item"`
		}
		if json.Unmarshal(params, &p) != nil {
			return codexAppEvent{}, false
		}
		switch p.Item.Type {
		case "agentMessage":
			if strings.TrimSpace(p.Item.Text) == "" {
				return codexAppEvent{}, false
			}
			return codexAppEvent{role: "assistant", content: p.Item.Text}, true
		case "commandExecution":
			if strings.TrimSpace(p.Item.Command) == "" {
				return codexAppEvent{}, false
			}
			input, err := json.Marshal(map[string]any{
				"command":   p.Item.Command,
				"exit_code": p.Item.ExitCode,
			})
			if err != nil {
				return codexAppEvent{}, false
			}
			return codexAppEvent{role: "tool", content: toolCardContent("command_execution", input)}, true
		case "contextCompaction":
			return codexAppEvent{role: "system", content: "✓ Context compacted."}, true
		}
	}
	return codexAppEvent{}, false
}

// isCodexCompactCommand reports whether the user's composer text is exactly the
// `/compact` slash command (trimmed). Routed to thread/compact/start instead of
// a turn.
func isCodexCompactCommand(text string) bool {
	return strings.TrimSpace(text) == "/compact"
}

// codexMessageCap bounds a surfaced error message so a verbose codex error
// doesn't blow up the chat bubble (mirrors firstMeaningfulLine's 200-char cap).
const codexMessageCap = 200

func codexTrimMessage(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > codexMessageCap {
		return s[:codexMessageCap] + "…"
	}
	return s
}

// codexErrorNotificationMessage decodes an `error` notification's params
// (ErrorNotification: {error:{message,additionalDetails,…}, threadId, turnId,
// willRetry}) into a human message and the willRetry flag. willRetry=true means
// codex retries internally (the turn is NOT over); false means the turn failed
// terminally — codex v0.132 has no `turn/failed` notification, so this `error`
// notification is the terminus for most turn failures (rate limit, network,
// server error). ok=false when params don't decode as an error notification, so
// the caller leaves an unparseable payload alone rather than ending the turn.
func codexErrorNotificationMessage(params json.RawMessage) (msg string, willRetry, ok bool) {
	var p struct {
		Error struct {
			Message           string `json:"message"`
			AdditionalDetails string `json:"additionalDetails"`
		} `json:"error"`
		WillRetry bool `json:"willRetry"`
	}
	if json.Unmarshal(params, &p) != nil {
		return "", false, false
	}
	msg = p.Error.Message
	if strings.TrimSpace(msg) == "" {
		msg = p.Error.AdditionalDetails
	}
	return codexTrimMessage(msg), p.WillRetry, true
}

// codexTurnCompletion lifts params.turn.{status,error.message} from a
// turn/completed notification. status is the TurnStatus enum
// (completed/interrupted/failed/inProgress); errMsg is populated only when the
// turn failed. Both empty when params don't decode.
func codexTurnCompletion(params json.RawMessage) (status, errMsg string) {
	var p struct {
		Turn struct {
			Status string `json:"status"`
			Error  *struct {
				Message string `json:"message"`
			} `json:"error"`
		} `json:"turn"`
	}
	if json.Unmarshal(params, &p) != nil {
		return "", ""
	}
	if p.Turn.Error != nil {
		errMsg = codexTrimMessage(p.Turn.Error.Message)
	}
	return p.Turn.Status, errMsg
}

// codexThreadStatusType lifts params.status.type from a thread/status/changed
// notification (idle / active / systemError / notLoaded). "" when absent. `idle`
// while a turn is in flight is a deterministic turn-end signal; `systemError`
// is a terminal failure.
func codexThreadStatusType(params json.RawMessage) string {
	var p struct {
		Status struct {
			Type string `json:"type"`
		} `json:"status"`
	}
	if json.Unmarshal(params, &p) != nil {
		return ""
	}
	return p.Status.Type
}

// codexRPCErrorMessage lifts a human message from a JSON-RPC error object
// ({code,message,data}). Falls back to the raw JSON when there's no message.
func codexRPCErrorMessage(errRaw json.RawMessage) string {
	var e struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(errRaw, &e) == nil && strings.TrimSpace(e.Message) != "" {
		return codexTrimMessage(e.Message)
	}
	return codexTrimMessage(string(errRaw))
}
