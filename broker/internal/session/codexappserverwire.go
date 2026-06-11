package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
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

// encodeCodexResponse builds one JSON-RPC RESULT response line for a
// server→client request (the approval path). The id is echoed back verbatim as
// a RawMessage because codex's RequestId is `string | integer` — the approval
// request carries a server-side counter id (starts at 0, independent of our
// client request-id space), and the response MUST echo it exactly. Newline-
// terminated.
func encodeCodexResponse(rawID json.RawMessage, result any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"id":     rawID,
		"result": result,
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

// codexTurnSteerParams builds turn/steer params for mid-turn user injection.
// The steer frame injects input into the running turn at the next
// reasoning/step boundary. No model/effort/sandbox overrides are allowed on
// a steer — input only.
//
// Confirmed working against codex-cli 0.132.0 (frames_multistep.jsonl):
//
//	C->S {"id":99,"method":"turn/steer","params":{
//	       "threadId":"019eb47f-…","input":[{"type":"text","text":"…"}],
//	       "expectedTurnId":"019eb47f-ee92-…"}}
//	S->C {"id":99,"result":{"turnId":"019eb47f-ee92-…"}}
//
// Success: same active turn id echoed back — no new turn/started fires.
// Failure: error -32600 "no active turn to steer" when the turn already
// ended before the steer arrived; caller falls back to turn/start.
func codexTurnSteerParams(threadID, expectedTurnID, text string) map[string]any {
	return map[string]any{
		"threadId": threadID,
		"input": []map[string]any{
			{"type": "text", "text": text},
		},
		"expectedTurnId": expectedTurnID,
	}
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
// accepts: the static codexEfforts fallback plus whatever the discovered model
// catalog advertises (so a newly shipped level like "xhigh" passes through
// without a broker release). An empty or unknown value returns "" (dropped).
func codexEffortParam(effort string) string {
	effort = strings.TrimSpace(effort)
	if effort != "" && effortSupported("codex", effort) {
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

// codexApprovalMethods is the set of server→client REQUEST methods that ask the
// user to approve (or deny) an action codex wants to take during a turn. These
// fire only under approvalPolicy on-request/untrusted/on-failure (plan mode uses
// on-request). They are the codex twin of claude's AskUserQuestion: an id-bearing
// request that BLOCKS the turn until the client responds with a decision.
//
// Verified live (codex-cli 0.132.0, docs/CODEX-APPSERVER-PROTOCOL.md):
//   - item/commandExecution/requestApproval — a shell command needs approval.
//   - item/fileChange/requestApproval — a file edit/patch needs approval.
func codexIsApprovalMethod(method string) bool {
	switch method {
	case codexMethodCommandApproval, codexMethodFileChangeApproval:
		return true
	}
	return false
}

// codexServerRequestKind classifies a server→client request into how the broker
// surfaces it to the user. Each kind maps to a pending-input card and a
// distinct JSON-RPC response shape (built by codexBuildResponse).
type codexServerRequestKind int

const (
	// codexReqUnknown — not a request we render a card for (auto-ack empty result).
	codexReqUnknown codexServerRequestKind = iota
	// codexReqApproval — command/file-change approval → {"decision": …}.
	codexReqApproval
	// codexReqUserInput — item/tool/requestUserInput → {"answers": {id:{answers:[…]}}}.
	codexReqUserInput
	// codexReqElicitation — mcpServer/elicitation/request → {"action": …, "content"?}.
	codexReqElicitation
)

// The server→client request method strings (see ServerRequest.json,
// codex-cli 0.132.0). Centralized so the routing switch and the doc agree.
const (
	codexMethodCommandApproval    = "item/commandExecution/requestApproval"
	codexMethodFileChangeApproval = "item/fileChange/requestApproval"
	codexMethodRequestUserInput   = "item/tool/requestUserInput"
	codexMethodMcpElicitation     = "mcpServer/elicitation/request"
)

// codexServerRequestKindFor maps a method to its handling kind.
func codexServerRequestKindFor(method string) codexServerRequestKind {
	switch method {
	case codexMethodCommandApproval, codexMethodFileChangeApproval:
		return codexReqApproval
	case codexMethodRequestUserInput:
		return codexReqUserInput
	case codexMethodMcpElicitation:
		return codexReqElicitation
	}
	return codexReqUnknown
}

// codexApprovalRequest is a parsed approval request: the human-facing summary
// (command line or file-change description) for the card, plus the working
// directory for context. Both `command` and `cwd` are nullable on the wire, so
// they degrade to "".
type codexApprovalRequest struct {
	summary string // the command line, or a file-change summary
	cwd     string
	// declineAvailable is true when this request's availableDecisions includes
	// the string `decline`. `decline` blocks just this command and lets the turn
	// CONTINUE (the agent acknowledges and can retry/give up); `cancel` interrupts
	// the whole turn. `decline` is offered only for SOME requests, so deny prefers
	// it when present and falls back to `cancel` (always available) otherwise.
	declineAvailable bool
}

// codexFileChange is the path + diff of one pending file edit, lifted from a
// `fileChange` item notification (item/started|completed). The fileChange
// APPROVAL request (item/fileChange/requestApproval) carries only the itemId —
// the actual changes live in the preceding fileChange item — so the broker joins
// the two by itemId to render a card with the real path/diff. Verified live
// (codex-cli 0.132.0): the approval params are {itemId,startedAtMs,threadId,
// turnId,reason?,grantRoot?} with NO command/cwd/changes.
type codexFileChange struct {
	path string
	diff string
}

// codexFileChangeItem holds the changes of the most recently seen fileChange
// item, keyed by its id, so a later fileChange approval request can join to it.
type codexFileChangeItem struct {
	id      string
	changes []codexFileChange
}

// parseCodexFileChangeItem lifts an item/started|completed notification's
// fileChange item (id + changes[].{path,diff}). ok=false unless it is a
// fileChange item with an id (so the caller only stashes real file edits).
func parseCodexFileChangeItem(params json.RawMessage) (codexFileChangeItem, bool) {
	var p struct {
		Item struct {
			Type    string `json:"type"`
			ID      string `json:"id"`
			Changes []struct {
				Path string `json:"path"`
				Diff string `json:"diff"`
			} `json:"changes"`
		} `json:"item"`
	}
	if json.Unmarshal(params, &p) != nil {
		return codexFileChangeItem{}, false
	}
	if p.Item.Type != "fileChange" || strings.TrimSpace(p.Item.ID) == "" {
		return codexFileChangeItem{}, false
	}
	item := codexFileChangeItem{id: p.Item.ID}
	for _, c := range p.Item.Changes {
		item.changes = append(item.changes, codexFileChange{
			path: strings.TrimSpace(c.Path),
			diff: c.Diff,
		})
	}
	return item, true
}

// parseCodexApprovalRequest decodes an approval request's params into the bits
// the card needs. `joined` is the fileChange item the broker matched by itemId
// (nil for command approvals or when no match was found) — it supplies the
// path/diff a fileChange approval request omits. ok=false when params don't
// decode at all (the caller then denies with cancel so the turn doesn't wedge).
func parseCodexApprovalRequest(method string, params json.RawMessage, joined *codexFileChangeItem) (codexApprovalRequest, bool) {
	var p struct {
		Command string `json:"command"`
		Cwd     string `json:"cwd"`
		// Legacy/embedded file-change shape (some versions inline changes); the
		// 0.132 fileChange approval omits these and we fall back to `joined`.
		Changes []struct {
			Path string `json:"path"`
		} `json:"changes"`
		// availableDecisions is a heterogeneous array: plain strings ("accept",
		// "cancel", "decline") AND objects ({"acceptWithExecpolicyAmendment":…}).
		// json.RawMessage per element so an object entry doesn't fail the decode;
		// only the string entries are inspected for `decline`.
		AvailableDecisions []json.RawMessage `json:"availableDecisions"`
	}
	if json.Unmarshal(params, &p) != nil {
		return codexApprovalRequest{}, false
	}
	summary := strings.TrimSpace(p.Command)
	if summary == "" && method == codexMethodFileChangeApproval {
		summary = codexFileChangeSummary(p.Changes, joined)
	}
	declineAvailable := false
	for _, d := range p.AvailableDecisions {
		var s string
		if json.Unmarshal(d, &s) == nil && s == codexDecisionDecline {
			declineAvailable = true
			break
		}
	}
	// fileChange responses ALWAYS accept `decline` per the schema
	// (FileChangeApprovalDecision), even though the request omits
	// availableDecisions — so a denied file edit lets the turn continue rather
	// than interrupting it (verified live: decline → turn completes).
	if method == codexMethodFileChangeApproval {
		declineAvailable = true
	}
	return codexApprovalRequest{
		summary:          summary,
		cwd:              strings.TrimSpace(p.Cwd),
		declineAvailable: declineAvailable,
	}, true
}

// codexFileChangeSummary renders a human file-change summary from whichever
// source carries the paths: the inline `changes` (legacy) or the joined
// fileChange item (0.132). Falls back to a generic line so the card is never
// blank.
func codexFileChangeSummary(inline []struct {
	Path string `json:"path"`
}, joined *codexFileChangeItem) string {
	type pathOnly struct{ path string }
	var paths []pathOnly
	for _, c := range inline {
		if p := strings.TrimSpace(c.Path); p != "" {
			paths = append(paths, pathOnly{p})
		}
	}
	if len(paths) == 0 && joined != nil {
		for _, c := range joined.changes {
			if c.path != "" {
				paths = append(paths, pathOnly{c.path})
			}
		}
	}
	switch {
	case len(paths) == 1:
		return "edit " + paths[0].path
	case len(paths) > 1:
		return fmt.Sprintf("apply changes to %d files", len(paths))
	default:
		return "apply file changes"
	}
}

// codexApprovalApproveLabel / codexApprovalDenyLabel are the tappable option
// labels rendered in the approval card. The user's tap sends the label back as
// the next chat message; codexApprovalDecisionFor maps it to a JSON-RPC decision.
const (
	codexApprovalApproveLabel = "Approve"
	codexApprovalDenyLabel    = "Deny"
)

// codexApprovalCardContent renders an approval request as the SAME
// pending-input-shaped chat line claude's AskUserQuestion uses
// (askUserQuestionContent): the deterministic sentinel, a question, and a
// numbered Approve/Deny menu. That is exactly the shape core's classifier
// (core/src/conversation.rs) turns into a tappable approval card — so the iOS /
// Android approval UI renders it with ZERO app changes. ok=false on an empty
// summary (caller falls back to auto-deny rather than a blank card).
//
// NOTE: the raw diff is deliberately NOT embedded in the body — core's
// extract_pending_options scans every line and treats a "- foo" diff line as a
// bullet option, which would inject garbage choices into the card. The summary
// (the file path[s]) is enough; the diff already surfaced as the preceding
// fileChange tool card.
func codexApprovalCardContent(method string, req codexApprovalRequest) (string, bool) {
	summary := strings.TrimSpace(req.summary)
	if summary == "" {
		return "", false
	}
	var b strings.Builder
	b.WriteString(pendingInputSentinel)
	if method == codexMethodFileChangeApproval {
		b.WriteString("\nAllow codex to make this file change?\n\n")
	} else {
		b.WriteString("\nAllow codex to run this command?\n\n")
	}
	b.WriteString(summary)
	if req.cwd != "" {
		b.WriteString("\nin ")
		b.WriteString(req.cwd)
	}
	b.WriteString("\n\n1. ")
	b.WriteString(codexApprovalApproveLabel)
	b.WriteString("\n2. ")
	b.WriteString(codexApprovalDenyLabel)
	return b.String(), true
}

// codexApprovalDecision* are the JSON-RPC decision strings the broker sends in
// response to an approval request (CommandExecutionApprovalDecision /
// FileChangeApprovalDecision).
const (
	codexDecisionAccept  = "accept"
	codexDecisionDecline = "decline"
	codexDecisionCancel  = "cancel"
)

// codexApprovalDecisionFor maps the user's tapped label (or typed reply) to a
// CommandExecutionApprovalDecision / FileChangeApprovalDecision string.
//
// Approve → "accept" (run it). Anything else is a deny: prefer "decline" when
// this request offered it (declineAvailable) — it blocks only this command and
// lets the turn CONTINUE so the agent acknowledges the denial and can adapt
// (device feedback: a deny→cancel left the agent silent because cancel
// interrupts the whole turn). Fall back to "cancel" when decline isn't offered
// (cancel is ALWAYS in availableDecisions); a deny must never leave the turn
// spinning, mirroring claude's AskUserQuestion-deny posture.
func codexApprovalDecisionFor(answer string, declineAvailable bool) string {
	if strings.EqualFold(strings.TrimSpace(answer), codexApprovalApproveLabel) {
		return codexDecisionAccept
	}
	if declineAvailable {
		return codexDecisionDecline
	}
	return codexDecisionCancel
}

// ---------------------------------------------------------------------------
// item/tool/requestUserInput (EXPERIMENTAL) — the codex twin of claude's
// AskUserQuestion. Captured schema-only (codex-cli 0.132.0,
// ToolRequestUserInputParams): a labeled set of questions, each with optional
// {label,description} options or free-text. The response maps each question id
// to {answers:[…]}. We render the FIRST question as a pending-input card (the
// card UI is single-question; multi-question prompts are rare for this tool) and
// answer that one; remaining questions get an empty answer so the response is
// well-formed and the turn doesn't wedge.
// ---------------------------------------------------------------------------

// codexUserInputQuestion is one parsed requestUserInput question.
type codexUserInputQuestion struct {
	id      string
	header  string
	prompt  string
	options []string // option labels; empty → free-text answer
}

// codexUserInputRequest is the parsed requestUserInput payload: the ordered
// questions (first is the one we surface as a card).
type codexUserInputRequest struct {
	questions []codexUserInputQuestion
}

// parseCodexUserInputRequest decodes a ToolRequestUserInputParams. ok=false when
// it has no answerable question (caller then auto-declines the safety-net way).
func parseCodexUserInputRequest(params json.RawMessage) (codexUserInputRequest, bool) {
	var p struct {
		Questions []struct {
			ID       string `json:"id"`
			Header   string `json:"header"`
			Question string `json:"question"`
			Options  []struct {
				Label       string `json:"label"`
				Description string `json:"description"`
			} `json:"options"`
		} `json:"questions"`
	}
	if json.Unmarshal(params, &p) != nil {
		return codexUserInputRequest{}, false
	}
	var req codexUserInputRequest
	for _, q := range p.Questions {
		if strings.TrimSpace(q.ID) == "" || strings.TrimSpace(q.Question) == "" {
			continue
		}
		cq := codexUserInputQuestion{
			id:     q.ID,
			header: strings.TrimSpace(q.Header),
			prompt: strings.TrimSpace(q.Question),
		}
		for _, o := range q.Options {
			if l := strings.TrimSpace(o.Label); l != "" {
				cq.options = append(cq.options, l)
			}
		}
		req.questions = append(req.questions, cq)
	}
	if len(req.questions) == 0 {
		return codexUserInputRequest{}, false
	}
	return req, true
}

// codexUserInputCardContent renders the FIRST question of a requestUserInput as
// a pending-input card: the sentinel, the header/question, and a numbered menu
// of options (free-text when there are none — the apps show a text field for a
// sentinel card with no options). ok=false when there's nothing to ask.
func codexUserInputCardContent(req codexUserInputRequest) (string, bool) {
	if len(req.questions) == 0 {
		return "", false
	}
	q := req.questions[0]
	var b strings.Builder
	b.WriteString(pendingInputSentinel)
	b.WriteString("\n")
	if q.header != "" && !strings.EqualFold(q.header, q.prompt) {
		b.WriteString(q.header)
		b.WriteString("\n\n")
	}
	b.WriteString(q.prompt)
	for i, opt := range q.options {
		b.WriteString("\n")
		b.WriteString(strconv.Itoa(i + 1))
		b.WriteString(". ")
		b.WriteString(opt)
	}
	return b.String(), true
}

// codexBuildUserInputResult builds the ToolRequestUserInputResponse for the
// user's answer to the first question; remaining questions get an empty answer
// array so the response stays well-formed. The answer is sent verbatim (the
// app sends the tapped option label or typed free text).
func codexBuildUserInputResult(req codexUserInputRequest, answer string) map[string]any {
	answers := map[string]any{}
	for i, q := range req.questions {
		if i == 0 {
			answers[q.id] = map[string]any{"answers": []string{strings.TrimSpace(answer)}}
		} else {
			answers[q.id] = map[string]any{"answers": []string{}}
		}
	}
	return map[string]any{"answers": answers}
}

// codexBuildEmptyUserInputResult builds a well-formed ToolRequestUserInputResponse
// with an empty answer array for every question — the safety-net deny when an
// outstanding requestUserInput card is abandoned (timeout / EOF / close).
func codexBuildEmptyUserInputResult(req codexUserInputRequest) map[string]any {
	answers := map[string]any{}
	for _, q := range req.questions {
		answers[q.id] = map[string]any{"answers": []string{}}
	}
	return map[string]any{"answers": answers}
}

// ---------------------------------------------------------------------------
// mcpServer/elicitation/request — an MCP server asks the user for structured
// input. Captured schema-only (codex-cli 0.132.0, McpServerElicitationRequest
// Params): a `form` mode with a typed `requestedSchema`, or a `url` mode. The
// response is {action: accept|decline|cancel, content?}. Full form rendering is
// complex (typed fields); the broker surfaces the message as a card with an
// Approve/Decline choice and responds accept (empty content) / decline — the
// safety-net principle: never hang the turn silently.
// ---------------------------------------------------------------------------

// codexElicitationRequest is the parsed elicitation payload the broker acts on.
type codexElicitationRequest struct {
	serverName string
	message    string
	mode       string // "form" | "url" | ""
	url        string // set for url mode
}

// parseCodexElicitationRequest decodes an McpServerElicitationRequestParams.
// ok=false when it doesn't decode (caller declines as a safety net).
func parseCodexElicitationRequest(params json.RawMessage) (codexElicitationRequest, bool) {
	var p struct {
		ServerName string `json:"serverName"`
		Message    string `json:"message"`
		Mode       string `json:"mode"`
		URL        string `json:"url"`
	}
	if json.Unmarshal(params, &p) != nil {
		return codexElicitationRequest{}, false
	}
	return codexElicitationRequest{
		serverName: strings.TrimSpace(p.ServerName),
		message:    strings.TrimSpace(p.Message),
		mode:       strings.TrimSpace(p.Mode),
		url:        strings.TrimSpace(p.URL),
	}, true
}

// codexElicitationApproveLabel / codexElicitationDeclineLabel are the elicitation
// card's choices. Approve → action "accept"; anything else → "decline".
const (
	codexElicitationApproveLabel = "Approve"
	codexElicitationDeclineLabel = "Decline"
)

// codexElicitationActionDecline / Accept are McpServerElicitationAction values.
const (
	codexElicitationAccept  = "accept"
	codexElicitationDecline = "decline"
)

// codexElicitationCardContent renders an elicitation as a pending-input card:
// the server's message + an Approve/Decline menu. A url-mode elicitation
// includes the URL in the body so the user can open it. ok=false when there's
// no message to show (caller declines as a safety net).
func codexElicitationCardContent(req codexElicitationRequest) (string, bool) {
	msg := req.message
	if msg == "" && req.serverName != "" {
		msg = req.serverName + " is requesting input."
	}
	if msg == "" {
		return "", false
	}
	var b strings.Builder
	b.WriteString(pendingInputSentinel)
	b.WriteString("\n")
	if req.serverName != "" {
		b.WriteString(req.serverName)
		b.WriteString(": ")
	}
	b.WriteString(msg)
	if req.mode == "url" && req.url != "" {
		b.WriteString("\n")
		b.WriteString(req.url)
	}
	b.WriteString("\n\n1. ")
	b.WriteString(codexElicitationApproveLabel)
	b.WriteString("\n2. ")
	b.WriteString(codexElicitationDeclineLabel)
	return b.String(), true
}

// codexElicitationActionFor maps the user's answer to an McpServerElicitation
// action. Approve → accept; anything else → decline (the safe default).
func codexElicitationActionFor(answer string) string {
	if strings.EqualFold(strings.TrimSpace(answer), codexElicitationApproveLabel) {
		return codexElicitationAccept
	}
	return codexElicitationDecline
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

// codexRPCErrorCode lifts the integer error code from a JSON-RPC error object
// ({code,message,data}). Returns 0 when absent or not parseable.
//
// -32600 is the "no active turn to steer" error code returned by codex when
// turn/steer is called after the turn has already completed.
func codexRPCErrorCode(errRaw json.RawMessage) int {
	var e struct {
		Code int `json:"code"`
	}
	if json.Unmarshal(errRaw, &e) == nil {
		return e.Code
	}
	return 0
}

// codexSteerNoActiveTurnCode is the JSON-RPC error code codex returns when
// turn/steer is sent after the active turn has already completed.
// Confirmed live (codex-cli 0.132.0): {"code":-32600,"message":"no active turn to steer"}.
const codexSteerNoActiveTurnCode = -32600

// ---- codex multi-agent / sub-agent wire helpers ----

// codexNotificationThreadID lifts the top-level params.threadId field present
// on all turn/item/thread-status notifications (but NOT thread/started, which
// puts the id inside params.thread.id). Returns "" when absent.
func codexNotificationThreadID(params json.RawMessage) string {
	var p struct {
		ThreadID string `json:"threadId"`
	}
	if json.Unmarshal(params, &p) != nil {
		return ""
	}
	return p.ThreadID
}

// codexCollabSpawnEvent is extracted from an item/started or item/completed
// notification whose item.type == "collabAgentToolCall". It captures the
// fields the sub-agent roster needs.
type codexCollabSpawnEvent struct {
	// CallID is item.id — used to correlate item/started → item/completed for
	// the same spawn call (the receiverThreadIds is only populated on completed).
	CallID string
	// Tool is item.tool (spawnAgent / sendInput / resumeAgent / wait / closeAgent).
	Tool string
	// Prompt is item.prompt — used as the sub-agent description.
	Prompt string
	// ReceiverThreadIDs is item.receiverThreadIds — the spawned sub-agent's
	// threadId (populated on spawnAgent/completed, empty on started).
	ReceiverThreadIDs []string
	// Status is item.status (inProgress / completed / failed).
	Status string
	// AgentsStates is item.agentsStates — optional per-thread status map.
	AgentsStates map[string]codexCollabAgentState
}

// codexCollabAgentState is the per-thread entry in item.agentsStates.
type codexCollabAgentState struct {
	Status  string  `json:"status"`
	Message *string `json:"message"`
}

// codexParseCollabItem attempts to parse an item/started or item/completed
// notification as a collabAgentToolCall frame. Returns (event, true) only when
// item.type == "collabAgentToolCall"; all other item types return (_, false).
func codexParseCollabItem(params json.RawMessage) (codexCollabSpawnEvent, bool) {
	var p struct {
		Item struct {
			Type              string                           `json:"type"`
			ID                string                           `json:"id"`
			Tool              string                           `json:"tool"`
			Status            string                           `json:"status"`
			Prompt            *string                          `json:"prompt"`
			ReceiverThreadIDs []string                         `json:"receiverThreadIds"`
			AgentsStates      map[string]codexCollabAgentState `json:"agentsStates"`
		} `json:"item"`
	}
	if json.Unmarshal(params, &p) != nil {
		return codexCollabSpawnEvent{}, false
	}
	if p.Item.Type != "collabAgentToolCall" {
		return codexCollabSpawnEvent{}, false
	}
	var prompt string
	if p.Item.Prompt != nil {
		prompt = *p.Item.Prompt
	}
	return codexCollabSpawnEvent{
		CallID:            p.Item.ID,
		Tool:              p.Item.Tool,
		Prompt:            prompt,
		ReceiverThreadIDs: p.Item.ReceiverThreadIDs,
		Status:            p.Item.Status,
		AgentsStates:      p.Item.AgentsStates,
	}, true
}

// codexSubagentTurnDurationMS extracts the turn.durationMs field from a
// turn/completed notification, used to update the sub-agent roster node's
// duration_ms. Returns 0 when absent or the turn is not completed.
func codexSubagentTurnDurationMS(params json.RawMessage) uint64 {
	var p struct {
		Turn struct {
			DurationMs *uint64 `json:"durationMs"`
			Status     string  `json:"status"`
		} `json:"turn"`
	}
	if json.Unmarshal(params, &p) != nil {
		return 0
	}
	if p.Turn.DurationMs == nil {
		return 0
	}
	return *p.Turn.DurationMs
}

// codexSubagentTurnStatus extracts the turn.status from a turn/completed
// notification: "completed" | "interrupted" | "failed" | "inProgress".
func codexSubagentTurnStatus(params json.RawMessage) string {
	var p struct {
		Turn struct {
			Status string `json:"status"`
		} `json:"turn"`
	}
	if json.Unmarshal(params, &p) != nil {
		return ""
	}
	return p.Turn.Status
}

// codexSubagentLastTokens extracts the thread/tokenUsage/updated `last`
// breakdown's totalTokens for sub-agent roster token tracking. Using `last`
// (not cumulative `total`) matches the existing per-turn token-gauge fix in
// codexUsageFromNotification.
func codexSubagentLastTokens(params json.RawMessage) uint64 {
	var p struct {
		TokenUsage struct {
			Last struct {
				TotalTokens uint64 `json:"totalTokens"`
			} `json:"last"`
		} `json:"tokenUsage"`
	}
	if json.Unmarshal(params, &p) != nil {
		return 0
	}
	return p.TokenUsage.Last.TotalTokens
}

// codexSubagentNameFromPrompt derives a short display label from the prompt
// text the parent sent to spawnAgent. It returns the first non-empty line of
// the prompt capped at 40 characters, falling back to "agent "+last6(threadID)
// when the prompt is empty or whitespace-only.
func codexSubagentNameFromPrompt(prompt, threadID string) string {
	for _, line := range strings.Split(prompt, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if len(line) > 40 {
			return line[:40]
		}
		return line
	}
	// Fallback: "agent " + last 6 chars of threadId.
	if len(threadID) >= 6 {
		return "agent " + threadID[len(threadID)-6:]
	}
	return "agent"
}

// codexCollabStatusToRoster maps a CollabAgentStatus string (from
// agentsStates or thread/status/changed) to the roster node status
// ("working" | "done" | "failed").
func codexCollabStatusToRoster(collabStatus string) string {
	switch collabStatus {
	case "completed", "shutdown":
		return "done"
	case "errored", "interrupted", "notFound":
		return "failed"
	default:
		// pendingInit, running → "working"
		return "working"
	}
}

// codexTurnStatusToRoster maps a TurnStatus string from a turn/completed
// notification to a roster status.
func codexTurnStatusToRoster(turnStatus string) string {
	switch turnStatus {
	case "completed":
		return "done"
	case "failed":
		return "failed"
	default:
		return "done"
	}
}
