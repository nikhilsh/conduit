package session

import (
	"encoding/json"
	"errors"
	"sort"
	"strings"
)

// errOpencodeTurnInFlight is returned by Send when a turn is already running:
// the opencode server serializes one turn per session, so a concurrent send is
// rejected (the composer should be disabled client-side while the agent works;
// this is the backstop).
var errOpencodeTurnInFlight = errors.New("opencode serve: turn already in flight")

// This file holds the PURE wire helpers for the opencode-server backend
// (backend_opencode.go): the SSE-frame decoders, the turn-event state machine,
// and the /config/providers → []ModelInfo mapper. Keeping them pure (no
// process, no HTTP) makes them table-testable against the frames captured
// verbatim in docs/OPENCODE-PROTOCOL.md without spawning a real server.
//
// Wire shapes are from opencode 1.17.0 (npm opencode-ai@1.17.0), cross-checked
// live against the no-auth "OpenCode Zen" free provider on the dev box.

// opencodeEvent is the minimal decode of one `data: {json}` SSE frame from
// GET /event. `type` selects the handler; `properties` carries the per-event
// payload, always namespaced by `properties.sessionID` so one server-wide
// stream multiplexes every session (the backend filters to the one it owns).
type opencodeEvent struct {
	Type       string                  `json:"type"`
	Properties opencodeEventProperties `json:"properties"`
}

// opencodeEventProperties is the union of the property fields the backend
// reads across the event types it handles. Unused fields for a given type stay
// zero — opencode's frames are a flat tagged union keyed by the outer `type`.
type opencodeEventProperties struct {
	SessionID string               `json:"sessionID"`
	Status    *opencodeStatus      `json:"status"`    // session.status
	MessageID string               `json:"messageID"` // message.part.delta
	PartID    string               `json:"partID"`    // message.part.delta
	Field     string               `json:"field"`     // message.part.delta ("text" | "reasoning")
	Delta     string               `json:"delta"`     // message.part.delta
	Part      *opencodePart        `json:"part"`      // message.part.updated
	Info      *opencodeMessageInfo `json:"info"`      // message.updated
	Error     *opencodeError       `json:"error"`     // session.error
}

// opencodeError is the session.error payload. opencode emits this when a turn
// fails (bad/unconnected model, provider auth, context overflow, API error,
// aborted, …) — a tagged union {name, data}. `name` is the error class
// (ProviderAuthError / UnknownError / APIError / MessageAbortedError / …) and
// `data.message` is the human string (absent on MessageOutputLengthError). The
// backend MUST treat this as a turn terminus: a real provider can emit
// session.error WITHOUT a following session.idle, which is the "typing forever,
// no reply" hang — only session.idle was recognized before.
type opencodeError struct {
	Name string `json:"name"`
	Data struct {
		Message    string `json:"message"`
		ProviderID string `json:"providerID"` // ProviderAuthError
	} `json:"data"`
}

// isAbort reports whether the error is a user/agent abort (MessageAbortedError),
// which the interrupt path already handles quietly — no scary error bubble.
func (e *opencodeError) isAbort() bool {
	return e != nil && e.Name == "MessageAbortedError"
}

// message renders a session.error into a user-facing one-liner for the Chat
// tab. Falls back to the error class name when no message string is present
// (e.g. MessageOutputLengthError carries no data), and to a generic notice when
// even the name is empty.
func (e *opencodeError) message() string {
	if e == nil {
		return "the agent reported an error"
	}
	msg := strings.TrimSpace(e.Data.Message)
	// opencode sometimes packs a JS stack trace into the message; keep only the
	// first line so the Chat tab shows a readable cause, not a $bunfs trace.
	if i := strings.IndexAny(msg, "\r\n"); i >= 0 {
		msg = strings.TrimSpace(msg[:i])
	}
	switch {
	case msg != "" && e.Name != "":
		return e.Name + ": " + msg
	case msg != "":
		return msg
	case e.Name != "":
		return e.Name
	default:
		return "the agent reported an error"
	}
}

// opencodeStatus is the session.status payload: {"type":"busy"|"idle"}.
type opencodeStatus struct {
	Type string `json:"type"`
}

// opencodePart is one message part (message.part.updated). The backend cares
// about `type` ("text" = answer prose, "reasoning" = chain-of-thought,
// "step-finish" = token usage) and, for text parts, the FULL accumulated
// `text` (the final message.part.updated carries the whole string — the
// authoritative answer, deltas are just the incremental preview).
type opencodePart struct {
	ID        string          `json:"id"`
	MessageID string          `json:"messageID"`
	Type      string          `json:"type"`
	Text      string          `json:"text"`
	Tokens    *opencodeTokens `json:"tokens"` // step-finish only
}

// opencodeMessageInfo is the message.updated `info` block: role + an optional
// `finish` reason on the assistant terminus.
type opencodeMessageInfo struct {
	ID     string `json:"id"`
	Role   string `json:"role"`
	Finish string `json:"finish"`
}

// opencodeTokens is the step-finish / message.updated token block.
type opencodeTokens struct {
	Total     uint64 `json:"total"`
	Input     uint64 `json:"input"`
	Output    uint64 `json:"output"`
	Reasoning uint64 `json:"reasoning"`
	Cache     struct {
		Read  uint64 `json:"read"`
		Write uint64 `json:"write"`
	} `json:"cache"`
}

// parseOpencodeEvent decodes one SSE `data:` line's JSON into an opencodeEvent.
// Returns ok=false on a non-JSON or empty line (heartbeats / blank frames).
func parseOpencodeEvent(jsonBody []byte) (opencodeEvent, bool) {
	jsonBody = []byte(strings.TrimSpace(string(jsonBody)))
	if len(jsonBody) == 0 {
		return opencodeEvent{}, false
	}
	var ev opencodeEvent
	if err := json.Unmarshal(jsonBody, &ev); err != nil {
		return opencodeEvent{}, false
	}
	if ev.Type == "" {
		return opencodeEvent{}, false
	}
	return ev, true
}

// sseDataPayload extracts the JSON body of an SSE `data: <json>` line, or
// ok=false for any other line (event:, id:, comments, blanks). opencode frames
// every event as a single `data:` line followed by a blank line.
func sseDataPayload(line string) (string, bool) {
	const prefix = "data:"
	if !strings.HasPrefix(line, prefix) {
		return "", false
	}
	return strings.TrimSpace(line[len(prefix):]), true
}

// opencodeUsageFromTokens folds a step-finish token block into the broker's
// usageDelta. The context gauge is input+cache (this turn's prompt size); the
// window is unknown from the frame (0). opencode's free zen models report
// cost:0, and the platform scopes usage OUT for opencode anyway — this exists
// for completeness/tests but the backend does not wire onUsage.
func opencodeUsageFromTokens(tok opencodeTokens) usageDelta {
	cached := tok.Cache.Read + tok.Cache.Write
	return usageDelta{
		input:       tok.Input,
		output:      tok.Output,
		cached:      cached,
		contextUsed: tok.Input + cached,
	}
}

// --- catalog probe mapping (GET /config/providers) ---

// opencodeProvidersResponse is the GET /config/providers shape. `models` is a
// MAP keyed by model id (opencode 1.17.0 live shape) — the doc's array form
// was an older capture. Each value is an object; we only need its id (the map
// key is authoritative). `default` maps providerID → default model id.
type opencodeProvidersResponse struct {
	Providers []opencodeProvider `json:"providers"`
	Default   map[string]string  `json:"default"`
}

type opencodeProvider struct {
	ID     string                       `json:"id"`
	Name   string                       `json:"name"`
	Models map[string]opencodeModelMeta `json:"models"`
}

type opencodeModelMeta struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

// parseOpencodeProviders maps GET /config/providers to the normalized catalog.
// Model id is "<providerID>/<modelID>" (what a prompt body / the picker uses);
// the per-provider `default` marks IsDefault. Models are sorted by id for a
// stable order (the map iteration is otherwise random). DisplayName falls back
// to the model id when the provider gives no name.
func parseOpencodeProviders(body []byte) ([]ModelInfo, error) {
	var resp opencodeProvidersResponse
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, err
	}
	var out []ModelInfo
	for _, p := range resp.Providers {
		defModel := resp.Default[p.ID]
		ids := make([]string, 0, len(p.Models))
		for modelID := range p.Models {
			ids = append(ids, modelID)
		}
		sort.Strings(ids)
		for _, modelID := range ids {
			meta := p.Models[modelID]
			display := strings.TrimSpace(meta.Name)
			if display == "" {
				display = modelID
			}
			out = append(out, ModelInfo{
				ID:          p.ID + "/" + modelID,
				DisplayName: display,
				IsDefault:   modelID == defModel,
			})
		}
	}
	return out, nil
}

// splitOpencodeModelID splits a "providerID/modelID" catalog id back into the
// {providerID, modelID} the prompt body wants. A bare id with no slash is
// treated as a modelID under the default provider "opencode" (the built-in zen
// provider) so a lone model name still prompts. An empty id yields the two
// empty strings (the backend then prompts with no model override → server
// default).
func splitOpencodeModelID(id string) (providerID, modelID string) {
	id = strings.TrimSpace(id)
	if id == "" {
		return "", ""
	}
	if i := strings.Index(id, "/"); i >= 0 {
		return id[:i], id[i+1:]
	}
	return "opencode", id
}

// opencodeTurnState is the per-turn accumulator the SSE reader drives. It folds
// the part stream into ONE assistant bubble (matching the other backends'
// "single bubble per message" rendering): text-type parts contribute prose,
// reasoning parts are dropped, and the order is first-seen so the answer reads
// top to bottom. The final message.part.updated for a part carries its FULL
// text (authoritative); deltas are folded as a fallback for parts that never
// get a final update.
type opencodeTurnState struct {
	// order preserves first-seen text part ids so the joined answer is stable.
	order []string
	// text maps a text-part id → its latest full text.
	text map[string]string
	// kind maps any part id → its type, so a delta can be routed to a text
	// part and ignored for a reasoning part.
	kind map[string]string
}

func newOpencodeTurnState() *opencodeTurnState {
	return &opencodeTurnState{text: map[string]string{}, kind: map[string]string{}}
}

// observePart folds a message.part.updated into the turn. A text part records
// (and overwrites) its full text; any part records its kind. Non-text/reasoning
// parts (step-start, step-finish, tool, file) are ignored for prose.
func (t *opencodeTurnState) observePart(p opencodePart) {
	if p.ID == "" {
		return
	}
	t.kind[p.ID] = p.Type
	if p.Type != "text" {
		return
	}
	if _, seen := t.text[p.ID]; !seen {
		t.order = append(t.order, p.ID)
	}
	t.text[p.ID] = p.Text
}

// observeDelta folds a message.part.delta into the turn. Only text deltas for a
// text-type part are accumulated (reasoning deltas are dropped). A delta for a
// part not yet seen via observePart is treated as a text part (the delta
// arrives before the part's first updated frame in some orderings).
func (t *opencodeTurnState) observeDelta(partID, field, delta string) {
	if partID == "" || field != "text" {
		return
	}
	if k, ok := t.kind[partID]; ok && k != "text" {
		return
	}
	if _, seen := t.text[partID]; !seen {
		t.order = append(t.order, partID)
		t.kind[partID] = "text"
	}
	t.text[partID] += delta
}

// answer returns the turn's consolidated assistant prose: the text parts in
// first-seen order, joined. Empty when the turn produced no text (e.g. a pure
// tool turn or an aborted turn) — the caller then emits no bubble.
func (t *opencodeTurnState) answer() string {
	var b strings.Builder
	for _, id := range t.order {
		b.WriteString(t.text[id])
	}
	return b.String()
}
