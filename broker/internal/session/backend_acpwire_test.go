package session

import (
	"encoding/json"
	"strings"
	"testing"
)

// Table tests over the PURE ACP wire helpers (backend_acpwire.go): the
// session/update demux (sessionUpdate variants), the prompt-result stopReason +
// usage parse, and the session/request_permission option echo. No process is
// spawned — these pin the wire contract against the live frames captured in
// docs/ACP-PROTOCOL.md (gemini-cli 0.42.0).

func TestParseACPInitializeResult(t *testing.T) {
	// loadSession=true (gemini) and a base-ACP result with no caps.
	cases := []struct {
		name string
		raw  string
		want bool
	}{
		{"gemini-load", `{"protocolVersion":1,"agentCapabilities":{"loadSession":true,"promptCapabilities":{"image":true}}}`, true},
		{"no-load", `{"protocolVersion":1,"agentCapabilities":{"loadSession":false}}`, false},
		{"no-caps", `{"protocolVersion":1}`, false},
		{"malformed", `not json`, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := parseACPInitializeResult(json.RawMessage(c.raw)).loadSession; got != c.want {
				t.Fatalf("loadSession = %v, want %v", got, c.want)
			}
		})
	}
}

func TestParseACPSessionNewResult(t *testing.T) {
	// The live gemini session/new result (trimmed): sessionId + modes + models.
	const raw = `{"sessionId":"ed948159-9de6-473e-8559-d75e89d8f2bc",
		"modes":{"currentModeId":"default","availableModes":[
			{"id":"default","name":"Default","description":"Prompts for approval"},
			{"id":"plan","name":"Plan","description":"Read-only mode"}]},
		"models":{"currentModelId":"auto-gemini-3","availableModels":[
			{"modelId":"auto-gemini-3","name":"Auto (Gemini 3)","description":"pick best"},
			{"modelId":"gemini-2.5-pro","name":"gemini-2.5-pro"}]}}`
	r, ok := parseACPSessionNewResult(json.RawMessage(raw))
	if !ok {
		t.Fatal("ok=false for a valid session/new result")
	}
	if r.sessionID != "ed948159-9de6-473e-8559-d75e89d8f2bc" {
		t.Fatalf("sessionID = %q", r.sessionID)
	}
	if r.currentMode != "default" || len(r.modes) != 2 || r.modes[1].id != "plan" {
		t.Fatalf("modes = %+v", r.modes)
	}
	if r.currentModel != "auto-gemini-3" || len(r.models) != 2 {
		t.Fatalf("models = %+v", r.models)
	}

	// No sessionId → ok=false.
	if _, ok := parseACPSessionNewResult(json.RawMessage(`{"modes":null,"models":null}`)); ok {
		t.Fatal("ok=true for a result with no sessionId")
	}
	// Base ACP: sessionId present, modes/models null.
	r2, ok := parseACPSessionNewResult(json.RawMessage(`{"sessionId":"abc","modes":null,"models":null}`))
	if !ok || r2.sessionID != "abc" || len(r2.modes) != 0 || len(r2.models) != 0 {
		t.Fatalf("base ACP result: ok=%v r=%+v", ok, r2)
	}
}

func TestACPModelsToCatalog(t *testing.T) {
	r := acpSessionNewResult{
		currentModel: "gemini-2.5-pro",
		models: []acpModel{
			{id: "auto-gemini-3", name: "Auto (Gemini 3)", description: "pick best"},
			{id: "gemini-2.5-pro", name: "gemini-2.5-pro"},
			{id: "", name: "skip-me"}, // empty id dropped
		},
	}
	cat := acpModelsToCatalog(r)
	if len(cat) != 2 {
		t.Fatalf("catalog len = %d, want 2 (%+v)", len(cat), cat)
	}
	if cat[0].ID != "auto-gemini-3" || cat[0].DisplayName != "Auto (Gemini 3)" || cat[0].IsDefault {
		t.Fatalf("model[0] = %+v", cat[0])
	}
	if cat[1].ID != "gemini-2.5-pro" || !cat[1].IsDefault {
		t.Fatalf("model[1] not marked default: %+v", cat[1])
	}
	if len(cat[0].Efforts) != 0 {
		t.Fatalf("ACP catalog must have no per-model efforts, got %v", cat[0].Efforts)
	}
}

func TestParseACPPromptResultAndUsage(t *testing.T) {
	// Live end_turn response with gemini's _meta.quota usage.
	const raw = `{"stopReason":"end_turn","_meta":{"quota":{"token_count":{"input_tokens":9939,"output_tokens":5},"model_usage":[]}}}`
	pr := parseACPPromptResult(json.RawMessage(raw))
	if pr.stopReason != "end_turn" {
		t.Fatalf("stopReason = %q", pr.stopReason)
	}
	if pr.inputTokens != 9939 || pr.outputTokens != 5 {
		t.Fatalf("tokens = %d/%d", pr.inputTokens, pr.outputTokens)
	}
	u, ok := acpUsageFromPromptResult(pr)
	if !ok || u.input != 9939 || u.output != 5 || u.contextUsed != 9939 {
		t.Fatalf("usage = %+v ok=%v", u, ok)
	}

	// cancelled terminus, no usage.
	prc := parseACPPromptResult(json.RawMessage(`{"stopReason":"cancelled"}`))
	if prc.stopReason != acpStopReasonCancelled {
		t.Fatalf("stopReason = %q", prc.stopReason)
	}
	if _, ok := acpUsageFromPromptResult(prc); ok {
		t.Fatal("usage ok=true for a zero-token result")
	}
}

func TestParseACPUpdateVariants(t *testing.T) {
	const sid = `"sessionId":"s1"`
	cases := []struct {
		name     string
		params   string
		wantKind string
		wantText string
		wantTool string // toolTitle when applicable
	}{
		{
			"agent_message_chunk",
			`{` + sid + `,"update":{"sessionUpdate":"agent_message_chunk","content":{"type":"text","text":"The sky is blue."}}}`,
			acpUpdateAgentMessageChunk, "The sky is blue.", "",
		},
		{
			"agent_thought_chunk",
			`{` + sid + `,"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"**Responding...**"}}}`,
			acpUpdateAgentThoughtChunk, "**Responding...**", "",
		},
		{
			"tool_call",
			`{` + sid + `,"update":{"sessionUpdate":"tool_call","toolCallId":"h523ji2j","status":"in_progress","title":"Reading file","kind":"read"}}`,
			acpUpdateToolCall, "", "Reading file",
		},
		{
			"tool_call_update",
			`{` + sid + `,"update":{"sessionUpdate":"tool_call_update","toolCallId":"yiosok0h","status":"completed","title":"Writing to acp_demo.txt","kind":"edit"}}`,
			acpUpdateToolCallUpdate, "", "Writing to acp_demo.txt",
		},
		{
			"available_commands_update",
			`{` + sid + `,"update":{"sessionUpdate":"available_commands_update","availableCommands":[{"name":"memory"}]}}`,
			acpUpdateAvailableCommands, "", "",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			u, ok := parseACPUpdate(json.RawMessage(c.params))
			if !ok {
				t.Fatalf("ok=false")
			}
			if u.kind != c.wantKind {
				t.Fatalf("kind = %q, want %q", u.kind, c.wantKind)
			}
			if u.text != c.wantText {
				t.Fatalf("text = %q, want %q", u.text, c.wantText)
			}
			if u.toolTitle != c.wantTool {
				t.Fatalf("toolTitle = %q, want %q", u.toolTitle, c.wantTool)
			}
			if u.sessionID != "s1" {
				t.Fatalf("sessionID = %q", u.sessionID)
			}
		})
	}

	// The discriminator is sessionUpdate, NOT type — a frame using `type`
	// must NOT decode as a known variant.
	if u, ok := parseACPUpdate(json.RawMessage(`{"sessionId":"s1","update":{"type":"agent_message_chunk","content":{"type":"text","text":"x"}}}`)); ok {
		t.Fatalf("a `type`-discriminated frame must not parse as a known kind (got kind=%q)", u.kind)
	}
}

func TestACPToolCardContent(t *testing.T) {
	u := acpUpdate{kind: acpUpdateToolCall, toolTitle: "Reading file", toolKind: "read", toolStatus: "in_progress"}
	content, ok := acpToolCardContent(u)
	if !ok {
		t.Fatal("ok=false for a tool_call with a title")
	}
	if !strings.Contains(content, "Reading file") {
		t.Fatalf("card missing title: %q", content)
	}
	// No title → no card.
	if _, ok := acpToolCardContent(acpUpdate{kind: acpUpdateToolCall}); ok {
		t.Fatal("ok=true for a tool_call with no title")
	}
}

func TestParseACPPermissionRequestAndEcho(t *testing.T) {
	// The spec'd request: a gated tool call + the four agent-supplied options.
	const raw = `{"sessionId":"s1","toolCall":{"toolCallId":"t1","title":"run rm -rf /tmp/x"},
		"options":[
			{"optionId":"o1","name":"Allow once","kind":"allow_once"},
			{"optionId":"o2","name":"Allow always","kind":"allow_always"},
			{"optionId":"o3","name":"Reject once","kind":"reject_once"},
			{"optionId":"o4","name":"Reject always","kind":"reject_always"}]}`
	req, ok := parseACPPermissionRequest(json.RawMessage(raw))
	if !ok {
		t.Fatal("ok=false for a valid permission request")
	}
	if req.title != "run rm -rf /tmp/x" || len(req.options) != 4 {
		t.Fatalf("req = %+v", req)
	}

	// Approve echoes the allow_once optionId; Deny echoes reject_once. The
	// broker NEVER invents a decision string.
	if id := acpOptionIDForAnswer("Approve", req.options); id != "o1" {
		t.Fatalf("Approve → %q, want o1 (allow_once)", id)
	}
	if id := acpOptionIDForAnswer("Deny", req.options); id != "o3" {
		t.Fatalf("Deny → %q, want o3 (reject_once)", id)
	}

	// The full response payload shape: selected with the mapped optionId.
	resp := acpPermissionResponseFor("Approve", req.options)
	outcome := resp["outcome"].(map[string]any)
	if outcome["outcome"] != "selected" || outcome["optionId"] != "o1" {
		t.Fatalf("approve response = %v", resp)
	}

	// The card renders as a tappable Approve/Deny menu (sentinel-prefixed).
	card := acpPermissionCardContent(req)
	if !strings.HasPrefix(card, pendingInputSentinel) {
		t.Fatalf("card not sentinel-prefixed: %q", card)
	}
	if !strings.Contains(card, acpApproveLabel) || !strings.Contains(card, acpDenyLabel) {
		t.Fatalf("card missing Approve/Deny: %q", card)
	}
}

func TestACPPermissionEchoFallbacks(t *testing.T) {
	// Only allow_always + reject_always offered (no _once variants): Approve
	// falls back to allow_always, Deny to reject_always.
	opts := []acpPermissionOption{
		{optionID: "a", kind: acpPermAllowAlways},
		{optionID: "r", kind: acpPermRejectAlways},
	}
	if id := acpOptionIDForAnswer("Approve", opts); id != "a" {
		t.Fatalf("Approve fallback → %q, want a", id)
	}
	if id := acpOptionIDForAnswer("Deny", opts); id != "r" {
		t.Fatalf("Deny fallback → %q, want r", id)
	}

	// No reject option at all: a Deny → cancelled outcome (never wedge the turn).
	approveOnly := []acpPermissionOption{{optionID: "a", kind: acpPermAllowOnce}}
	resp := acpPermissionResponseFor("Deny", approveOnly)
	outcome := resp["outcome"].(map[string]any)
	if outcome["outcome"] != "cancelled" {
		t.Fatalf("deny with no reject option → %v, want cancelled", resp)
	}

	// A request with no options at all parses ok=false (caller cancels).
	if _, ok := parseACPPermissionRequest(json.RawMessage(`{"sessionId":"s1","toolCall":{"title":"x"},"options":[]}`)); ok {
		t.Fatal("ok=true for a permission request with no options")
	}
}

func TestACPModeForOverride(t *testing.T) {
	modes := []acpMode{{id: "default"}, {id: "plan"}, {id: "yolo"}}
	// plan override + plan mode advertised → apply "plan".
	if id, ok := acpModeForOverride(SpawnOverride{PermissionMode: "plan"}, modes); !ok || id != "plan" {
		t.Fatalf("plan override → %q ok=%v, want plan", id, ok)
	}
	// no override → no set_mode.
	if _, ok := acpModeForOverride(SpawnOverride{}, modes); ok {
		t.Fatal("empty override applied a mode")
	}
	// plan override but agent doesn't advertise plan → no-op.
	if _, ok := acpModeForOverride(SpawnOverride{PermissionMode: "plan"}, []acpMode{{id: "default"}}); ok {
		t.Fatal("plan applied when agent has no plan mode")
	}
}

func TestACPStopReasonNotice(t *testing.T) {
	cases := map[string]bool{ // stopReason → expect a non-empty notice
		"end_turn":          false,
		"cancelled":         false,
		"":                  false,
		"max_tokens":        true,
		"max_turn_requests": true,
		"refusal":           true,
		"weird_future":      true,
	}
	for reason, wantNotice := range cases {
		got := acpStopReasonNotice(reason)
		if (got != "") != wantNotice {
			t.Fatalf("stopReason %q → notice %q (wantNonEmpty=%v)", reason, got, wantNotice)
		}
	}
}

// TestACPBackendRegistration pins the protocol-keyed seam: the "acp" protocol
// resolves to the ACP backend with the documented capability set. This is the
// invariant that makes a new ACP agent cheap — it routes by protocol, never by
// adapter name.
func TestACPBackendRegistration(t *testing.T) {
	b, err := backendFor("acp")
	if err != nil {
		t.Fatalf("backendFor(acp): %v", err)
	}
	caps := b.Capabilities()
	if !caps.AskUserQuestion || !caps.Effort || !caps.Resume || !caps.Interrupt {
		t.Fatalf("ACP caps missing a true flag: %+v", caps)
	}
	if caps.Compact || caps.Usage || caps.Steer {
		t.Fatalf("ACP caps has an unexpected true flag: %+v", caps)
	}
}

func TestACPFrameEncoders(t *testing.T) {
	// Request: jsonrpc + id + method + params, newline-terminated.
	line, err := encodeACPRequest(3, "session/prompt", acpPromptParams("s1", "hi"))
	if err != nil {
		t.Fatal(err)
	}
	if line[len(line)-1] != '\n' {
		t.Fatal("request not newline-terminated")
	}
	var req map[string]any
	if err := json.Unmarshal(line, &req); err != nil {
		t.Fatal(err)
	}
	if req["jsonrpc"] != "2.0" || req["method"] != "session/prompt" {
		t.Fatalf("request = %v", req)
	}

	// Notification: no id (session/cancel).
	nline, err := encodeACPNotification("session/cancel", acpCancelParams("s1"))
	if err != nil {
		t.Fatal(err)
	}
	var notif map[string]any
	if err := json.Unmarshal(nline, &notif); err != nil {
		t.Fatal(err)
	}
	if _, hasID := notif["id"]; hasID {
		t.Fatal("notification must not carry an id")
	}

	// Response echoes the raw id verbatim (server-side counter, may be 0).
	rline, err := encodeACPResponse(json.RawMessage("0"), acpCancelledOutcome())
	if err != nil {
		t.Fatal(err)
	}
	var resp map[string]any
	if err := json.Unmarshal(rline, &resp); err != nil {
		t.Fatal(err)
	}
	if resp["id"] != float64(0) {
		t.Fatalf("response id = %v, want 0", resp["id"])
	}
}
