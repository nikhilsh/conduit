package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
)

// This file holds the PURE wire helpers for the ACP (Agent Client Protocol)
// backend (backend_acp.go): the JSON-RPC frame encoders, the request-param
// builders, the session/update notification → chat-event mapper, and the
// session/request_permission option mapper. Keeping them pure (no process, no
// I/O) makes them table-testable without spawning a real `gemini --acp`.
//
// ACP is JSON-RPC 2.0, one object per line over the subprocess stdio (same
// JSONL model as codex app-server). gemini-cli DOES emit the `"jsonrpc":"2.0"`
// field; we emit it too (harmless for codex-style readers, required by strict
// ACP servers). The demux is identical to codex: a line with id+method is a
// server→client request; id-only is a response; method-only is a notification.
//
// All shapes verified live against gemini-cli 0.42.0 (`gemini --acp`); see
// docs/ACP-PROTOCOL.md for the captured frames.

// errACPTurnInFlight is returned by Send when a turn is already running: ACP
// handles one prompt at a time per session (a second session/prompt must wait
// for the outstanding one to resolve), so a concurrent send is rejected (the
// composer is disabled client-side while the agent works; this is a backstop).
var errACPTurnInFlight = errors.New("acp: turn already in flight")

// acpProtocolVersion is the integer protocolVersion the broker negotiates in
// initialize. ACP uses an integer (1), not a semver string.
const acpProtocolVersion = 1

// acpClientVersion is the clientInfo.version reported on initialize.
// Informational only.
const acpClientVersion = "0.0.1"

// acpRPCEnvelope is the minimal decode of a JSON-RPC line used by the reader to
// demux server→client requests (id+method), responses (id, no method) and
// notifications (method, no id). `ID` is json.RawMessage so a request with id 0
// is still distinguishable from an absent id (notifications).
type acpRPCEnvelope struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  json.RawMessage `json:"error"`
}

// acpEvent is a single mapped chat event (assistant prose, a tool card, or a
// system line) ready for emit().
type acpEvent struct {
	role    string // "assistant" | "tool" | "system"
	content string
}

// --- frame encoders ---

// encodeACPRequest builds one JSON-RPC request line (newline-terminated). The
// `jsonrpc:"2.0"` field is included — strict ACP servers (and gemini-cli)
// expect it.
func encodeACPRequest(id int, method string, params any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"method":  method,
		"params":  params,
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// encodeACPNotification builds one JSON-RPC notification line (no id).
func encodeACPNotification(method string, params any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"method":  method,
		"params":  params,
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// encodeACPResponse builds one JSON-RPC RESULT response line for a
// server→client request (the permission / fs path). The id is echoed back
// verbatim as a RawMessage — gemini's server-side request id is its own counter
// space starting at 0 (independent of our client request-id space), and the
// response MUST echo it exactly. Newline-terminated.
func encodeACPResponse(rawID json.RawMessage, result any) ([]byte, error) {
	b, err := json.Marshal(map[string]any{
		"jsonrpc": "2.0",
		"id":      rawID,
		"result":  result,
	})
	if err != nil {
		return nil, err
	}
	return append(b, '\n'), nil
}

// --- request param builders ---

// acpInitializeParams is the initialize request's params. fs + terminal are
// advertised FALSE: the agent's own child does its disk/command I/O directly in
// the session cwd (the conduit norm — claude/codex/opencode never proxy agent
// disk access), so the broker need not implement fs/* or terminal/* server
// methods. protocolVersion is an integer.
func acpInitializeParams() map[string]any {
	return map[string]any{
		"protocolVersion": acpProtocolVersion,
		"clientCapabilities": map[string]any{
			"fs": map[string]any{
				"readTextFile":  false,
				"writeTextFile": false,
			},
			"terminal": false,
		},
		"clientInfo": map[string]any{
			"name":    "conduit-broker",
			"version": acpClientVersion,
		},
	}
}

// acpSessionNewParams builds session/new params. The agent runs its own tools
// in cwd; no MCP servers are wired in v1.
func acpSessionNewParams(dir string) map[string]any {
	return map[string]any{
		"cwd":        dir,
		"mcpServers": []any{},
	}
}

// acpSessionLoadParams builds session/load params for the resume path (gated by
// the agent's loadSession capability). Same shape as session/new plus the prior
// sessionId.
func acpSessionLoadParams(sessionID, dir string) map[string]any {
	return map[string]any{
		"sessionId":  sessionID,
		"cwd":        dir,
		"mcpServers": []any{},
	}
}

// acpPromptParams builds session/prompt params for a user turn. The prompt is a
// ContentBlock array; conduit sends a single text block (mirroring its codex
// `input` shape).
func acpPromptParams(sessionID, text string) map[string]any {
	return map[string]any{
		"sessionId": sessionID,
		"prompt": []map[string]any{
			{"type": "text", "text": text},
		},
	}
}

// acpSetModeParams builds session/set_mode params (the protocol-level effort /
// permission-mode switch — ACP has no model/effort CLI flag).
func acpSetModeParams(sessionID, modeID string) map[string]any {
	return map[string]any{
		"sessionId": sessionID,
		"modeId":    modeID,
	}
}

// acpCancelParams builds the session/cancel notification params (interrupt).
func acpCancelParams(sessionID string) map[string]any {
	return map[string]any{"sessionId": sessionID}
}

// acpSetModelParams builds session/set_model params (gemini-cli's
// `unstable_setSessionModel` extension — verified live against gemini-cli
// 0.42.0, method `session/set_model`, params `{sessionId, modelId}`).
func acpSetModelParams(sessionID, modelID string) map[string]any {
	return map[string]any{
		"sessionId": sessionID,
		"modelId":   modelID,
	}
}

// --- handshake result parsers ---

// acpInitializeResult is the parsed initialize response: the agent's declared
// capabilities (loadSession gates resume).
type acpInitializeResult struct {
	loadSession bool
}

// parseACPInitializeResult lifts the bits the backend latches from the
// initialize result. A malformed result yields the zero value (loadSession
// false → resume falls back to a fresh session/new).
func parseACPInitializeResult(result json.RawMessage) acpInitializeResult {
	var r struct {
		AgentCapabilities struct {
			LoadSession bool `json:"loadSession"`
		} `json:"agentCapabilities"`
	}
	if json.Unmarshal(result, &r) != nil {
		return acpInitializeResult{}
	}
	return acpInitializeResult{loadSession: r.AgentCapabilities.LoadSession}
}

// acpSessionNewResult is the parsed session/new (or session/load) result: the
// session id plus the per-session mode + model catalog gemini embeds (a gemini
// extension to base ACP — base servers return these null).
type acpSessionNewResult struct {
	sessionID    string
	currentMode  string
	modes        []acpMode
	currentModel string
	models       []acpModel
}

// acpMode is one available permission mode (default / autoEdit / yolo / plan).
type acpMode struct {
	id          string
	name        string
	description string
}

// acpModel is one available model (id + display name + description).
type acpModel struct {
	id          string
	name        string
	description string
}

// parseACPSessionNewResult decodes a session/new result. The sessionId is
// required (ok=false without it). modes/models are optional (nil for base ACP
// servers that don't expose them). session/load returns the same shape.
func parseACPSessionNewResult(result json.RawMessage) (acpSessionNewResult, bool) {
	var r struct {
		SessionID string `json:"sessionId"`
		Modes     *struct {
			CurrentModeID  string `json:"currentModeId"`
			AvailableModes []struct {
				ID          string `json:"id"`
				Name        string `json:"name"`
				Description string `json:"description"`
			} `json:"availableModes"`
		} `json:"modes"`
		Models *struct {
			CurrentModelID  string `json:"currentModelId"`
			AvailableModels []struct {
				ModelID     string `json:"modelId"`
				Name        string `json:"name"`
				Description string `json:"description"`
			} `json:"availableModels"`
		} `json:"models"`
	}
	if json.Unmarshal(result, &r) != nil {
		return acpSessionNewResult{}, false
	}
	if strings.TrimSpace(r.SessionID) == "" {
		return acpSessionNewResult{}, false
	}
	out := acpSessionNewResult{sessionID: r.SessionID}
	if r.Modes != nil {
		out.currentMode = r.Modes.CurrentModeID
		for _, m := range r.Modes.AvailableModes {
			out.modes = append(out.modes, acpMode{
				id:          strings.TrimSpace(m.ID),
				name:        strings.TrimSpace(m.Name),
				description: strings.TrimSpace(m.Description),
			})
		}
	}
	if r.Models != nil {
		out.currentModel = r.Models.CurrentModelID
		for _, m := range r.Models.AvailableModels {
			out.models = append(out.models, acpModel{
				id:          strings.TrimSpace(m.ModelID),
				name:        strings.TrimSpace(m.Name),
				description: strings.TrimSpace(m.Description),
			})
		}
	}
	return out, true
}

// acpModelsToCatalog maps the session/new model block to the conduit ModelInfo
// catalog. ACP has no per-model reasoning-effort list (effort is the session
// mode axis, applied via session/set_mode), so Efforts is left empty.
func acpModelsToCatalog(r acpSessionNewResult) []ModelInfo {
	out := make([]ModelInfo, 0, len(r.models))
	for _, m := range r.models {
		if m.id == "" {
			continue
		}
		display := m.name
		if display == "" {
			display = m.id
		}
		out = append(out, ModelInfo{
			ID:          m.id,
			DisplayName: display,
			Description: m.description,
			IsDefault:   m.id == r.currentModel,
		})
	}
	return out
}

// --- session/prompt response parser (turn terminus) ---

// acpPromptResult is the parsed session/prompt response: the terminal
// stopReason plus the per-turn token usage gemini embeds in _meta.quota.
type acpPromptResult struct {
	stopReason   string
	inputTokens  uint64
	outputTokens uint64
}

// parseACPPromptResult decodes a session/prompt result. stopReason is the turn
// terminus enum (end_turn / max_tokens / max_turn_requests / refusal /
// cancelled). The usage is gemini's _meta.quota.token_count (absent on base
// ACP servers → zero).
func parseACPPromptResult(result json.RawMessage) acpPromptResult {
	var r struct {
		StopReason string `json:"stopReason"`
		Meta       struct {
			Quota struct {
				TokenCount struct {
					InputTokens  uint64 `json:"input_tokens"`
					OutputTokens uint64 `json:"output_tokens"`
				} `json:"token_count"`
			} `json:"quota"`
		} `json:"_meta"`
	}
	if json.Unmarshal(result, &r) != nil {
		return acpPromptResult{}
	}
	return acpPromptResult{
		stopReason:   strings.TrimSpace(r.StopReason),
		inputTokens:  r.Meta.Quota.TokenCount.InputTokens,
		outputTokens: r.Meta.Quota.TokenCount.OutputTokens,
	}
}

// acpUsageFromPromptResult folds a prompt result's token_count into a
// usageDelta. ok=false when the agent reported no usage (base ACP). The context
// gauge tracks input_tokens (the latest prompt footprint), point-in-time like
// codex's `last.inputTokens`.
func acpUsageFromPromptResult(r acpPromptResult) (usageDelta, bool) {
	if r.inputTokens == 0 && r.outputTokens == 0 {
		return usageDelta{}, false
	}
	return usageDelta{
		input:       r.inputTokens,
		output:      r.outputTokens,
		contextUsed: r.inputTokens,
	}, true
}

// acpStopReasonCancelled is the stopReason for a turn that was interrupted via
// session/cancel.
const acpStopReasonCancelled = "cancelled"

// --- session/update notification mapper ---

// The session/update `sessionUpdate` discriminator values (NOT `type` — the
// published schema renders this ambiguously, but the live wire and the
// prompt-turn doc confirm `sessionUpdate`).
const (
	acpUpdateAgentMessageChunk = "agent_message_chunk"
	acpUpdateAgentThoughtChunk = "agent_thought_chunk"
	acpUpdateToolCall          = "tool_call"
	acpUpdateToolCallUpdate    = "tool_call_update"
	acpUpdatePlan              = "plan"
	acpUpdateAvailableCommands = "available_commands_update"
	acpUpdateCurrentModeUpdate = "current_mode_update"
)

// acpUpdate is the parsed payload of a session/update notification, demuxed by
// its sessionUpdate discriminator. Only the fields relevant to the kind are
// populated.
type acpUpdate struct {
	sessionID string
	kind      string
	// text is the chunk content for agent_message_chunk / agent_thought_chunk.
	text string
	// toolCallID / toolStatus / toolTitle / toolKind describe a tool_call or
	// tool_call_update.
	toolCallID string
	toolStatus string
	toolTitle  string
	toolKind   string
}

// parseACPUpdate decodes a session/update notification's params into an
// acpUpdate. ok=false when the frame doesn't decode or carries no
// sessionUpdate discriminator (the reader then drops it).
func parseACPUpdate(params json.RawMessage) (acpUpdate, bool) {
	var p struct {
		SessionID string `json:"sessionId"`
		Update    struct {
			SessionUpdate string `json:"sessionUpdate"`
			Content       *struct {
				Type string `json:"type"`
				Text string `json:"text"`
			} `json:"content"`
			ToolCallID string `json:"toolCallId"`
			Status     string `json:"status"`
			Title      string `json:"title"`
			Kind       string `json:"kind"`
		} `json:"update"`
	}
	if json.Unmarshal(params, &p) != nil {
		return acpUpdate{}, false
	}
	kind := strings.TrimSpace(p.Update.SessionUpdate)
	if kind == "" {
		return acpUpdate{}, false
	}
	u := acpUpdate{
		sessionID:  p.SessionID,
		kind:       kind,
		toolCallID: p.Update.ToolCallID,
		toolStatus: strings.TrimSpace(p.Update.Status),
		toolTitle:  strings.TrimSpace(p.Update.Title),
		toolKind:   strings.TrimSpace(p.Update.Kind),
	}
	if p.Update.Content != nil {
		u.text = p.Update.Content.Text
	}
	return u, true
}

// acpToolCardContent renders a tool_call / tool_call_update into a role:"tool"
// chat card body, reusing the same toolCardContent shape codex uses so the apps
// render it with zero changes. ok=false when there's no title to show.
func acpToolCardContent(u acpUpdate) (string, bool) {
	title := u.toolTitle
	if title == "" {
		return "", false
	}
	// toolCardContent surfaces a known summary key (command/path/description/…).
	// ACP gives a human `title`, so map it to `description` for the card body.
	input, err := json.Marshal(map[string]any{
		"description": title,
	})
	if err != nil {
		return "", false
	}
	return toolCardContent("tool_call", input), true
}

// --- session/request_permission option mapping ---

// acpPermissionOption is one agent-supplied option from a
// session/request_permission request: its optionId (echoed back verbatim) and
// its kind (allow_once / allow_always / reject_once / reject_always), used to
// pick the right option for Approve / Deny.
type acpPermissionOption struct {
	optionID string
	name     string
	kind     string
}

// ACP PermissionOptionKind values (agentclientprotocol.com). The broker NEVER
// invents a decision string — it echoes the agent-supplied optionId for the
// matching kind (Approve → allow_once, Deny → reject_once).
const (
	acpPermAllowOnce    = "allow_once"
	acpPermAllowAlways  = "allow_always"
	acpPermRejectOnce   = "reject_once"
	acpPermRejectAlways = "reject_always"
)

// acpPermissionRequest is the parsed session/request_permission payload: the
// gated tool call's title (for the card) and the agent-supplied option list.
type acpPermissionRequest struct {
	sessionID string
	title     string
	options   []acpPermissionOption
}

// parseACPPermissionRequest decodes a session/request_permission request.
// ok=false when params don't decode or carry no options (the caller then
// responds {"outcome":"cancelled"} so the turn doesn't wedge).
func parseACPPermissionRequest(params json.RawMessage) (acpPermissionRequest, bool) {
	var p struct {
		SessionID string `json:"sessionId"`
		ToolCall  struct {
			Title string `json:"title"`
		} `json:"toolCall"`
		Options []struct {
			OptionID string `json:"optionId"`
			Name     string `json:"name"`
			Kind     string `json:"kind"`
		} `json:"options"`
	}
	if json.Unmarshal(params, &p) != nil {
		return acpPermissionRequest{}, false
	}
	req := acpPermissionRequest{
		sessionID: p.SessionID,
		title:     strings.TrimSpace(p.ToolCall.Title),
	}
	for _, o := range p.Options {
		id := strings.TrimSpace(o.OptionID)
		if id == "" {
			continue
		}
		req.options = append(req.options, acpPermissionOption{
			optionID: id,
			name:     strings.TrimSpace(o.Name),
			kind:     strings.TrimSpace(o.Kind),
		})
	}
	if len(req.options) == 0 {
		return acpPermissionRequest{}, false
	}
	return req, true
}

// acpApproveLabel / acpDenyLabel are the tappable option labels rendered in the
// permission card (the same Approve/Deny shape codex's approval card uses, so
// core's classifier turns it into a tappable approval card with zero app
// changes).
const (
	acpApproveLabel = "Approve"
	acpDenyLabel    = "Deny"
)

// acpPermissionCardContent renders a permission request as the SAME
// pending-input-shaped chat line claude's AskUserQuestion uses: the sentinel, a
// question, and a numbered Approve/Deny menu. core's extract_pending_options
// turns this into a tappable approval card. Always renders (a missing title
// degrades to a generic phrasing) so the turn never blocks on a blank card.
func acpPermissionCardContent(req acpPermissionRequest) string {
	title := strings.TrimSpace(req.title)
	if title == "" {
		title = "perform this action"
	}
	var b strings.Builder
	b.WriteString(pendingInputSentinel)
	b.WriteString("\nAllow gemini to ")
	b.WriteString(title)
	b.WriteString("?\n\n1. ")
	b.WriteString(acpApproveLabel)
	b.WriteString("\n2. ")
	b.WriteString(acpDenyLabel)
	return b.String()
}

// acpOptionIDForAnswer maps the user's tapped label (or typed reply) to the
// agent-supplied optionId to echo back. Approve → the allow_once option's id;
// anything else (Deny) → the reject_once option's id. A deny must never leave
// the turn spinning — if reject_once is absent, fall back to reject_always,
// then to "" (the caller then sends {"outcome":"cancelled"}).
//
// The broker selects by KIND from the agent's list and echoes the exact
// optionId — it never invents a decision string (unlike codex's fixed
// accept/decline/cancel enum).
func acpOptionIDForAnswer(answer string, options []acpPermissionOption) string {
	approve := strings.EqualFold(strings.TrimSpace(answer), acpApproveLabel)
	if approve {
		if id := acpOptionIDForKind(options, acpPermAllowOnce); id != "" {
			return id
		}
		return acpOptionIDForKind(options, acpPermAllowAlways)
	}
	if id := acpOptionIDForKind(options, acpPermRejectOnce); id != "" {
		return id
	}
	return acpOptionIDForKind(options, acpPermRejectAlways)
}

// acpOptionIDForKind returns the optionId of the first option with the given
// kind, or "" when none matches.
func acpOptionIDForKind(options []acpPermissionOption, kind string) string {
	for _, o := range options {
		if o.kind == kind {
			return o.optionID
		}
	}
	return ""
}

// acpSelectedOutcome builds the session/request_permission response for a chosen
// option: {"outcome":{"outcome":"selected","optionId":<id>}}.
func acpSelectedOutcome(optionID string) map[string]any {
	return map[string]any{
		"outcome": map[string]any{
			"outcome":  "selected",
			"optionId": optionID,
		},
	}
}

// acpCancelledOutcome is the deny/timeout/disconnect terminus:
// {"outcome":{"outcome":"cancelled"}}.
func acpCancelledOutcome() map[string]any {
	return map[string]any{
		"outcome": map[string]any{"outcome": "cancelled"},
	}
}

// acpPermissionResponseFor builds the permission response for the user's answer:
// the selected outcome echoing the mapped optionId, or the cancelled outcome
// when no matching option exists (a deny with no reject option → cancel, which
// is always a valid terminus).
func acpPermissionResponseFor(answer string, options []acpPermissionOption) map[string]any {
	if id := acpOptionIDForAnswer(answer, options); id != "" {
		return acpSelectedOutcome(id)
	}
	return acpCancelledOutcome()
}

// acpModeForOverride maps a conduit SpawnOverride to the ACP modeId to apply via
// session/set_mode after session/new. PermissionMode "plan" → the "plan" mode
// (read-only); empty/other → "" (leave the agent's default mode). Only modes
// the agent actually advertised are applied (ok=false otherwise) so a set_mode
// for an unknown id is never sent.
func acpModeForOverride(o SpawnOverride, modes []acpMode) (string, bool) {
	mode := strings.TrimSpace(o.PermissionMode)
	if mode != "plan" {
		return "", false
	}
	for _, m := range modes {
		if m.id == "plan" {
			return "plan", true
		}
	}
	return "", false
}

// acpModelForOverride maps a conduit SpawnOverride.Model to the ACP modelId to
// apply via session/set_model after session/new (gemini-cli's
// unstable_setSessionModel extension). Only a model the agent actually
// advertised in session/new's availableModels is applied (ok=false otherwise)
// — same drop-if-unknown safety rule as the argv model override: a bad/stale
// model id must never fail the spawn, it just leaves the agent's own default
// (session/new's currentModelId) in place.
func acpModelForOverride(o SpawnOverride, models []acpModel) (string, bool) {
	model := strings.TrimSpace(o.Model)
	if model == "" {
		return "", false
	}
	for _, m := range models {
		if m.id == model {
			return model, true
		}
	}
	return "", false
}

// acpRPCErrorMessage lifts a human message from a JSON-RPC error object
// ({code,message,data}). Falls back to the raw JSON when there's no message.
func acpRPCErrorMessage(errRaw json.RawMessage) string {
	var e struct {
		Message string `json:"message"`
	}
	if json.Unmarshal(errRaw, &e) == nil && strings.TrimSpace(e.Message) != "" {
		return acpTrimMessage(e.Message)
	}
	return acpTrimMessage(string(errRaw))
}

// acpMessageCap bounds a surfaced error message so a verbose error doesn't blow
// up the chat bubble (mirrors codexTrimMessage's 200-char cap).
const acpMessageCap = 200

func acpTrimMessage(s string) string {
	s = strings.TrimSpace(s)
	if len(s) > acpMessageCap {
		return s[:acpMessageCap] + "…"
	}
	return s
}

// acpStopReasonNotice maps a non-end_turn / non-cancelled stopReason to a
// user-facing notice (so a refusal / token-limit terminus isn't silent), or ""
// for the quiet termini (end_turn, cancelled, empty).
func acpStopReasonNotice(stopReason string) string {
	switch stopReason {
	case "", "end_turn", acpStopReasonCancelled:
		return ""
	case "max_tokens":
		return "⚠️ gemini: reply truncated (token limit reached)."
	case "max_turn_requests":
		return "⚠️ gemini: turn ended (max tool requests reached)."
	case "refusal":
		return "⚠️ gemini: the model declined to respond."
	default:
		return fmt.Sprintf("⚠️ gemini: turn ended (%s).", stopReason)
	}
}
