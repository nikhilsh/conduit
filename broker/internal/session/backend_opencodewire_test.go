package session

import (
	"testing"
)

// These are PURE wire-mapping tests against the frames captured verbatim in
// docs/OPENCODE-PROTOCOL.md (opencode 1.17.0). No process, no HTTP.

func TestSseDataPayload(t *testing.T) {
	cases := []struct {
		line   string
		want   string
		wantOK bool
	}{
		{`data: {"type":"server.connected","properties":{}}`, `{"type":"server.connected","properties":{}}`, true},
		{`data:{"type":"x"}`, `{"type":"x"}`, true},
		{`event: message`, "", false},
		{`id: 1`, "", false},
		{``, "", false},
		{`: heartbeat`, "", false},
	}
	for _, c := range cases {
		got, ok := sseDataPayload(c.line)
		if ok != c.wantOK || got != c.want {
			t.Errorf("sseDataPayload(%q) = (%q,%v), want (%q,%v)", c.line, got, ok, c.want, c.wantOK)
		}
	}
}

func TestParseOpencodeEvent(t *testing.T) {
	// server.connected has empty properties.
	if ev, ok := parseOpencodeEvent([]byte(`{"id":"evt_1","type":"server.connected","properties":{}}`)); !ok || ev.Type != "server.connected" {
		t.Fatalf("server.connected parse: ev=%+v ok=%v", ev, ok)
	}
	// session.status busy.
	ev, ok := parseOpencodeEvent([]byte(`{"id":"evt_2","type":"session.status","properties":{"sessionID":"ses_A","status":{"type":"busy"}}}`))
	if !ok || ev.Type != "session.status" || ev.Properties.SessionID != "ses_A" || ev.Properties.Status == nil || ev.Properties.Status.Type != "busy" {
		t.Fatalf("session.status parse: ev=%+v ok=%v", ev, ok)
	}
	// message.part.delta text.
	ev, ok = parseOpencodeEvent([]byte(`{"id":"evt_3","type":"message.part.delta","properties":{"sessionID":"ses_A","messageID":"msg_1","partID":"prt_1","field":"text","delta":"The"}}`))
	if !ok || ev.Properties.PartID != "prt_1" || ev.Properties.Field != "text" || ev.Properties.Delta != "The" {
		t.Fatalf("delta parse: ev=%+v ok=%v", ev, ok)
	}
	// step-finish carries tokens.
	ev, ok = parseOpencodeEvent([]byte(`{"id":"evt_4","type":"message.part.updated","properties":{"sessionID":"ses_A","part":{"id":"prt_2","reason":"stop","messageID":"msg_1","sessionID":"ses_A","type":"step-finish","tokens":{"total":8593,"input":8578,"output":3,"reasoning":12,"cache":{"write":0,"read":0}},"cost":0}}}`))
	if !ok || ev.Properties.Part == nil || ev.Properties.Part.Type != "step-finish" || ev.Properties.Part.Tokens == nil || ev.Properties.Part.Tokens.Input != 8578 {
		t.Fatalf("step-finish parse: ev=%+v ok=%v", ev, ok)
	}
	// non-JSON / heartbeat lines.
	if _, ok := parseOpencodeEvent([]byte(`not json`)); ok {
		t.Error("non-JSON should not parse")
	}
	if _, ok := parseOpencodeEvent([]byte(`   `)); ok {
		t.Error("blank should not parse")
	}
}

func TestOpencodeUsageFromTokens(t *testing.T) {
	tok := opencodeTokens{Total: 8593, Input: 8578, Output: 3, Reasoning: 12}
	tok.Cache.Read = 5
	tok.Cache.Write = 2
	u := opencodeUsageFromTokens(tok)
	if u.input != 8578 || u.output != 3 || u.cached != 7 || u.contextUsed != 8585 {
		t.Fatalf("usage = %+v", u)
	}
}

func TestSplitOpencodeModelID(t *testing.T) {
	cases := []struct{ in, wp, wm string }{
		{"opencode/big-pickle", "opencode", "big-pickle"},
		{"anthropic/claude-sonnet-4", "anthropic", "claude-sonnet-4"},
		{"big-pickle", "opencode", "big-pickle"}, // bare → default provider
		{"", "", ""},
		{"  opencode/x  ", "opencode", "x"},
	}
	for _, c := range cases {
		p, m := splitOpencodeModelID(c.in)
		if p != c.wp || m != c.wm {
			t.Errorf("split(%q) = (%q,%q), want (%q,%q)", c.in, p, m, c.wp, c.wm)
		}
	}
}

func TestParseOpencodeProviders_LiveMapShape(t *testing.T) {
	// The LIVE opencode 1.17.0 shape: models is a MAP keyed by model id.
	body := []byte(`{"providers":[{"id":"opencode","name":"OpenCode Zen","models":{
	  "big-pickle":{"id":"big-pickle","name":"Big Pickle"},
	  "deepseek-v4-flash-free":{"id":"deepseek-v4-flash-free","name":"DeepSeek V4 Flash Free"}
	}}],"default":{"opencode":"big-pickle"}}`)
	models, err := parseOpencodeProviders(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(models) != 2 {
		t.Fatalf("want 2 models, got %d: %+v", len(models), models)
	}
	// Sorted by model id: big-pickle then deepseek-...
	if models[0].ID != "opencode/big-pickle" || models[0].DisplayName != "Big Pickle" || !models[0].IsDefault {
		t.Errorf("model[0] = %+v", models[0])
	}
	if models[1].ID != "opencode/deepseek-v4-flash-free" || models[1].IsDefault {
		t.Errorf("model[1] = %+v", models[1])
	}
}

func TestParseOpencodeProviders_NoNameFallsBackToID(t *testing.T) {
	body := []byte(`{"providers":[{"id":"opencode","models":{"x":{"id":"x"}}}],"default":{}}`)
	models, err := parseOpencodeProviders(body)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if len(models) != 1 || models[0].ID != "opencode/x" || models[0].DisplayName != "x" {
		t.Fatalf("models = %+v", models)
	}
}

// TestOpencodeTurnState drives the part/delta accumulator with the EXACT
// ordering captured live: reasoning streams first (field:"text" deltas on a
// reasoning part — must be dropped), then the answer streams on a separate
// text part. The consolidated bubble must be only the answer prose.
func TestOpencodeTurnState_ReasoningDropped(t *testing.T) {
	st := newOpencodeTurnState()
	// reasoning part opens, gets text deltas, finalizes.
	st.observePart(opencodePart{ID: "prt_reason", Type: "reasoning", Text: ""})
	st.observeDelta("prt_reason", "text", "The user wants ")
	st.observeDelta("prt_reason", "text", "PONG.")
	st.observePart(opencodePart{ID: "prt_reason", Type: "reasoning", Text: "The user wants PONG."})
	// answer text part opens, deltas, finalizes with the full text.
	st.observePart(opencodePart{ID: "prt_answer", Type: "text", Text: ""})
	st.observeDelta("prt_answer", "text", "PON")
	st.observeDelta("prt_answer", "text", "G")
	st.observePart(opencodePart{ID: "prt_answer", Type: "text", Text: "PONG"})

	if got := st.answer(); got != "PONG" {
		t.Fatalf("answer = %q, want PONG (reasoning must be dropped)", got)
	}
}

// TestOpencodeTurnState_DeltaBeforePart covers the ordering where a text delta
// arrives before the part's first message.part.updated (the part is then
// treated as text and accumulated).
func TestOpencodeTurnState_DeltaBeforePart(t *testing.T) {
	st := newOpencodeTurnState()
	st.observeDelta("prt_a", "text", "Hel")
	st.observeDelta("prt_a", "text", "lo")
	if got := st.answer(); got != "Hello" {
		t.Fatalf("answer = %q, want Hello", got)
	}
}

// TestOpencodeTurnState_FinalTextWins: when both deltas and a final full-text
// update arrive for a text part, the final update is authoritative.
func TestOpencodeTurnState_FinalTextWins(t *testing.T) {
	st := newOpencodeTurnState()
	st.observeDelta("prt_a", "text", "par")
	st.observePart(opencodePart{ID: "prt_a", Type: "text", Text: "partial-then-full"})
	if got := st.answer(); got != "partial-then-full" {
		t.Fatalf("answer = %q, want full text", got)
	}
}

// TestOpencodeTurnState_MultiTextPartsJoined: multiple text parts (e.g. across
// steps) join in first-seen order into one bubble.
func TestOpencodeTurnState_MultiTextPartsJoined(t *testing.T) {
	st := newOpencodeTurnState()
	st.observePart(opencodePart{ID: "p1", Type: "text", Text: "Hello "})
	st.observePart(opencodePart{ID: "p2", Type: "text", Text: "world"})
	if got := st.answer(); got != "Hello world" {
		t.Fatalf("answer = %q", got)
	}
}
