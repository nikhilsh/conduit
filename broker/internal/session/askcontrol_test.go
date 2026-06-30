package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Shapes captured live against claude-code 2.1.168 with
// `--permission-prompt-tool stdio` (post-v0.0.118 AskUserQuestion probe).

const askControlLine = `{"type":"control_request","request_id":"req-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Which colors?","multiSelect":true,"options":[{"label":"Red"},{"label":"Green"}]}]},"tool_use_id":"toolu_1"}}`

func TestParseControlRequest(t *testing.T) {
	req, ok := parseControlRequest([]byte(askControlLine))
	if !ok {
		t.Fatal("expected control_request to parse")
	}
	if req.RequestID != "req-1" || req.ToolName != "AskUserQuestion" {
		t.Fatalf("parsed %+v", req)
	}
	if !strings.Contains(string(req.Input), "Which colors?") {
		t.Fatalf("input not carried: %s", req.Input)
	}

	for _, bad := range []string{
		`{"type":"assistant","message":{}}`,
		`{"type":"control_request","request":{"subtype":"other"}}`,
		`not json`,
	} {
		if _, ok := parseControlRequest([]byte(bad)); ok {
			t.Fatalf("should not parse: %s", bad)
		}
	}
}

// Reattach re-surfacing (background→foreground bug): a client that reconnects
// while an AskUserQuestion is outstanding must get the interactive card back.
// PendingAskChatContent renders the current pending ask as the same
// pending-input chat line the live path emits; nil when nothing is blocked.
func TestPendingAskChatContent(t *testing.T) {
	// No outstanding ask → nothing to re-surface.
	s := &Session{ID: "s-noask"}
	if _, ok := s.PendingAskChatContent(); ok {
		t.Fatal("expected ok=false when no pending ask")
	}

	// With an outstanding ask, content matches the live-rendered card exactly.
	req, ok := parseControlRequest([]byte(askControlLine))
	if !ok {
		t.Fatal("control_request should parse")
	}
	s.pendingAsk = &pendingAsk{requestID: req.RequestID, input: req.Input}
	content, ok := s.PendingAskChatContent()
	if !ok {
		t.Fatal("expected ok=true with a pending ask")
	}
	if !strings.HasPrefix(content, pendingInputSentinel) {
		t.Fatalf("content missing pending-input sentinel: %q", content)
	}
	if !strings.Contains(content, "Which colors?") || !strings.Contains(content, "1. Red") {
		t.Fatalf("content missing question/options: %q", content)
	}
	// Must equal the live path's rendering so reattach and live agree.
	want, _ := askUserQuestionContent(req.Input)
	if content != want {
		t.Fatalf("reattach content %q != live content %q", content, want)
	}
}

func TestEncodeControlAllowUnchanged(t *testing.T) {
	line := encodeControlAllow("req-9", json.RawMessage(`{"a":1}`))
	var env struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string `json:"subtype"`
			RequestID string `json:"request_id"`
			Response  struct {
				Behavior     string          `json:"behavior"`
				UpdatedInput json.RawMessage `json:"updatedInput"`
			} `json:"response"`
		} `json:"response"`
	}
	if err := json.Unmarshal(line, &env); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if env.Type != "control_response" || env.Response.RequestID != "req-9" ||
		env.Response.Response.Behavior != "allow" {
		t.Fatalf("envelope: %s", line)
	}
	if string(env.Response.Response.UpdatedInput) != `{"a":1}` {
		t.Fatalf("updatedInput: %s", env.Response.Response.UpdatedInput)
	}
	if line[len(line)-1] != '\n' {
		t.Fatal("control line must be newline-terminated")
	}
}

func TestEncodeAskAnswerSingleQuestionUsesAnswers(t *testing.T) {
	req, _ := parseControlRequest([]byte(askControlLine))
	line, err := encodeAskAnswer(req.RequestID, req.Input, "Red, Green")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	s := string(line)
	if !strings.Contains(s, `"answers":{"Which colors?":"Red, Green"}`) {
		t.Fatalf("expected answers map, got: %s", s)
	}
	// Original questions must ride along unchanged.
	if !strings.Contains(s, `"questions":[`) {
		t.Fatalf("expected original questions preserved: %s", s)
	}
}

func TestEncodeAskAnswerMultiQuestionUsesFreeText(t *testing.T) {
	input := json.RawMessage(`{"questions":[{"question":"A?"},{"question":"B?"}]}`)
	line, err := encodeAskAnswer("req-2", input, "A: yes. B: no.")
	if err != nil {
		t.Fatalf("encode: %v", err)
	}
	if !strings.Contains(string(line), `"response":"A: yes. B: no."`) {
		t.Fatalf("expected free-text response, got: %s", line)
	}
}

// A pending ask consumes the next SendChat message as the control answer
// (no plain user turn), and a second message goes through normally.
func TestSendChatAnswersPendingAsk(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.conduitRoot = dir
	s.ID = "ask-test"
	s.applyPaths()
	fake := &fakeChatBackend{}
	s.chat = fake

	req, _ := parseControlRequest([]byte(askControlLine))
	// Stash without a real chatProcess: drive takePendingAsk directly.
	s.mu.Lock()
	s.pendingAsk = &pendingAsk{requestID: req.RequestID, input: req.Input}
	s.mu.Unlock()

	ask := s.takePendingAsk()
	if ask == nil || ask.requestID != "req-1" {
		t.Fatalf("takePendingAsk: %+v", ask)
	}
	if again := s.takePendingAsk(); again != nil {
		t.Fatalf("pending ask must be consumed once, got %+v", again)
	}
	line, err := encodeAskAnswer(ask.requestID, ask.input, "Green")
	if err != nil || !strings.Contains(string(line), `"Green"`) {
		t.Fatalf("answer encode: %v %s", err, line)
	}
}

type fakeChatBackend struct{ sent []string }

func (f *fakeChatBackend) Send(text string) error { f.sent = append(f.sent, text); return nil }
func (f *fakeChatBackend) Interrupt() error       { return nil }
func (f *fakeChatBackend) Close() error           { return nil }
func (f *fakeChatBackend) TurnActive() bool       { return false }

// The multi-select marker rides inside the rendered card text.
func TestAskUserQuestionContentMultiSelectMarker(t *testing.T) {
	input := json.RawMessage(`{"questions":[
		{"question":"Pick colors","multiSelect":true,"options":[{"label":"Red"},{"label":"Green"}]},
		{"question":"Pick one","options":[{"label":"A"},{"label":"B"}]}
	]}`)
	content, ok := askUserQuestionContent(input)
	if !ok {
		t.Fatal("expected content")
	}
	// The deterministic sentinel leads a genuine AskUserQuestion.
	if !strings.HasPrefix(content, pendingInputSentinel+"\n") {
		t.Fatalf("content must start with the pending-input sentinel: %q", content)
	}
	if !strings.Contains(content, "Pick colors"+multiSelectMarker+"\n1. Red") {
		t.Fatalf("multi-select question missing marker: %q", content)
	}
	if strings.Contains(content, "Pick one"+multiSelectMarker) {
		t.Fatalf("single-select question must not carry the marker: %q", content)
	}
}

// TestRecordPendingResolutionPersistsExactlyOnce: recordPendingResolution
// writes the resolved card to the transcript (so the answered state survives
// reopen) AND re-publishes it live — but the live PublishText path (which
// re-routes through appendRaw) must NOT double-persist it (appendRaw skips
// the sentinel-prefixed card). Result: exactly one persisted resolution
// entry, carrying the answer, keyed to the original ask ts.
func TestRecordPendingResolutionPersistsExactlyOnce(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.conduitRoot = dir
	s.ID = "resolve-test"
	s.applyPaths()

	req, _ := parseControlRequest([]byte(askControlLine))
	ask := &pendingAsk{requestID: req.RequestID, input: req.Input, ts: "2026-06-22T12:00:00Z"}

	s.recordPendingResolution(ask, "Red, Green", true)

	got, err := readConvLog(s.convLog.path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want exactly 1 persisted resolution (no double-write), got %d: %+v", len(got), got)
	}
	if got[0].Ts != "2026-06-22T12:00:00Z" {
		t.Fatalf("resolution must reuse the original ask ts, got %q", got[0].Ts)
	}
	res, ok := parsePendingResolution(got[0].Content)
	if !ok || !res.Answered || res.Answer != "Red, Green" {
		t.Fatalf("persisted resolution mismatch: ok=%v res=%+v", ok, res)
	}
}

// TestResolvedPendingInputContentAnswered: an answered AskUserQuestion
// renders a resolution card that (1) keeps the sentinel as its FIRST line
// (so core still classifies it pending_input and strips only that line),
// (2) carries the resolution marker on the SECOND line, and (3) preserves
// the original question + options so the card still renders fully. The
// round-trip parse recovers answered=true + the chosen answer text.
func TestResolvedPendingInputContentAnswered(t *testing.T) {
	input := json.RawMessage(`{"questions":[{"question":"Proceed with the merge?","options":[{"label":"Merge now"},{"label":"Hold off"}]}]}`)
	content, ok := resolvedPendingInputContent(input, "Merge now", true)
	if !ok {
		t.Fatal("expected resolution content")
	}
	lines := strings.Split(content, "\n")
	if lines[0] != pendingInputSentinel {
		t.Fatalf("first line must be the sentinel, got %q", lines[0])
	}
	if !strings.HasPrefix(lines[1], pendingResolvedMarker) {
		t.Fatalf("second line must be the resolution marker, got %q", lines[1])
	}
	if !strings.Contains(content, "Proceed with the merge?") ||
		!strings.Contains(content, "1. Merge now") {
		t.Fatalf("question + options must survive: %q", content)
	}
	res, ok := parsePendingResolution(content)
	if !ok {
		t.Fatal("expected to parse the resolution")
	}
	if !res.Answered || res.Answer != "Merge now" {
		t.Fatalf("round-trip mismatch: %+v", res)
	}
}

// TestResolvedPendingInputContentTimedOut: a timed-out / no-answer ask is
// marked resolved with answered=false and NO answer text, so the card stops
// showing "needs input" without highlighting any option.
func TestResolvedPendingInputContentTimedOut(t *testing.T) {
	input := json.RawMessage(`{"questions":[{"question":"Ship it?","options":[{"label":"Yes"},{"label":"No"}]}]}`)
	content, ok := resolvedPendingInputContent(input, "", false)
	if !ok {
		t.Fatal("expected resolution content")
	}
	res, ok := parsePendingResolution(content)
	if !ok {
		t.Fatal("expected to parse the resolution")
	}
	if res.Answered {
		t.Fatalf("timed-out ask must be answered=false: %+v", res)
	}
	if res.Answer != "" {
		t.Fatalf("timed-out ask must carry no answer text: %+v", res)
	}
	// answer:"" must be OMITTED from the wire (omitempty), not serialized.
	if strings.Contains(content, `"answer"`) {
		t.Fatalf("no-answer resolution must omit the answer field: %q", content)
	}
}

// TestParsePendingResolutionBackwardCompat: a plain pending-input card with
// NO resolution marker (an unanswered card, or a legacy transcript written
// before this feature) parses as "no resolution" — the app then renders it
// unanswered exactly as today.
func TestParsePendingResolutionBackwardCompat(t *testing.T) {
	legacy := pendingInputSentinel + "\nProceed?\n1. Yes\n2. No"
	if _, ok := parsePendingResolution(legacy); ok {
		t.Fatalf("unmarked card must not parse as resolved: %q", legacy)
	}
	// A non-card message likewise carries no resolution.
	if _, ok := parsePendingResolution("just a normal reply"); ok {
		t.Fatal("plain message must not parse as resolved")
	}
}

// TestAppendResolvedPendingInputPersists: unlike a live unanswered card
// (skipped by appendRaw), a RESOLVED card MUST land in the transcript so the
// answered state survives reopen. Verifies readConvLog recovers it with the
// resolution intact and the original ts preserved.
func TestAppendResolvedPendingInputPersists(t *testing.T) {
	path := filepath.Join(t.TempDir(), "conversation.jsonl")
	l := newConvLogger(path)

	input := json.RawMessage(`{"questions":[{"question":"Proceed with the merge?","options":[{"label":"Merge now"},{"label":"Hold off"}]}]}`)
	content, ok := resolvedPendingInputContent(input, "Merge now", true)
	if !ok {
		t.Fatal("expected resolution content")
	}
	l.appendResolvedPendingInput(content, "2026-06-22T10:00:00Z")

	got, err := readConvLog(path)
	if err != nil {
		t.Fatalf("readConvLog: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("want 1 persisted resolution entry, got %d: %+v", len(got), got)
	}
	if got[0].Role != "assistant" || got[0].Ts != "2026-06-22T10:00:00Z" {
		t.Fatalf("entry metadata mismatch: %+v", got[0])
	}
	res, ok := parsePendingResolution(got[0].Content)
	if !ok || !res.Answered || res.Answer != "Merge now" {
		t.Fatalf("persisted resolution mismatch: ok=%v res=%+v", ok, res)
	}
}

// Resume-on-respawn (round-4 device feedback: "session went down and
// lost where it was" — a broker restart/self-heal respawned the claude
// agent WITHOUT --resume, so it started a brand-new conversation).

func TestClaudeStreamCommandResume(t *testing.T) {
	argv := claudeStreamCommand([]string{"claude"}, nil, "sess-123", false)
	joined := strings.Join(argv, " ")
	if !strings.Contains(joined, "--resume sess-123") {
		t.Fatalf("expected --resume in argv: %v", argv)
	}
	fresh := claudeStreamCommand([]string{"claude"}, nil, "", false)
	if strings.Contains(strings.Join(fresh, " "), "--resume") {
		t.Fatalf("fresh spawn must not carry --resume: %v", fresh)
	}
	// Pre-latch recovery fallback: no id but conversation files on disk.
	cont := claudeStreamCommand([]string{"claude"}, nil, "", true)
	if !strings.Contains(strings.Join(cont, " "), "--continue") {
		t.Fatalf("expected --continue fallback: %v", cont)
	}
	// An explicit id wins over the fallback flag.
	both := strings.Join(claudeStreamCommand([]string{"claude"}, nil, "id-1", true), " ")
	if strings.Contains(both, "--continue") || !strings.Contains(both, "--resume id-1") {
		t.Fatalf("id must win over --continue: %v", both)
	}
}

func TestClaudeStreamInitSessionID(t *testing.T) {
	id, ok := claudeStreamInitSessionID([]byte(`{"type":"system","subtype":"init","session_id":"abc-1"}`))
	if !ok || id != "abc-1" {
		t.Fatalf("init parse: %q %v", id, ok)
	}
	for _, bad := range []string{
		`{"type":"system","subtype":"status"}`,
		`{"type":"assistant"}`,
		`{"type":"system","subtype":"init"}`, // no id
	} {
		if _, ok := claudeStreamInitSessionID([]byte(bad)); ok {
			t.Fatalf("should not parse: %s", bad)
		}
	}
}

func TestLatchChatSessionIDPersists(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.metaPath = filepath.Join(dir, "meta.json")
	s.latchChatSessionID("conv-42")

	raw, err := os.ReadFile(s.metaPath)
	if err != nil {
		t.Fatalf("meta.json not written: %v", err)
	}
	var meta sessionMetadata
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if meta.ClaudeChatSessionID != "conv-42" {
		t.Fatalf("persisted id = %q", meta.ClaudeChatSessionID)
	}
}

func TestLatchCodexThreadIDPersists(t *testing.T) {
	dir := t.TempDir()
	s := &Session{}
	s.metaPath = filepath.Join(dir, "meta.json")
	s.latchCodexThreadID("thread-7")

	raw, err := os.ReadFile(s.metaPath)
	if err != nil {
		t.Fatalf("meta.json not written: %v", err)
	}
	var meta sessionMetadata
	if err := json.Unmarshal(raw, &meta); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if meta.CodexThreadID != "thread-7" {
		t.Fatalf("persisted thread = %q", meta.CodexThreadID)
	}
}

func TestChatConversationOnDisk(t *testing.T) {
	dir := t.TempDir()
	if chatConversationOnDisk(dir, ".claude") {
		t.Fatal("empty session dir must report no conversation")
	}
	proj := filepath.Join(dir, "agent-home", ".claude", "projects", "-root-x")
	if err := os.MkdirAll(proj, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(proj, "abc.jsonl"), []byte("{}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if !chatConversationOnDisk(dir, ".claude") {
		t.Fatal("expected conversation to be detected")
	}
	if chatConversationOnDisk(dir, ".codex") {
		t.Fatal(".codex must not match .claude files")
	}
}

// Close must scrub only the materialized credentials — never the CLIs'
// conversation files, which recovery's --resume depends on (a broker
// shutdown Closes every live session; the old RemoveAll(agentHomeDir)
// destroyed every conversation on every redeploy).
func TestCleanupAgentHomeKeepsConversations(t *testing.T) {
	// cleanupAgentHomeCredentials is a flag-OFF concern: under
	// CONDUIT_SHARED_AGENT_CREDS credentials never live in the per-session
	// HOME so there is nothing to clean. Force flag OFF so the test exercises
	// the credential-removal path regardless of the ambient environment.
	t.Setenv("CONDUIT_SHARED_AGENT_CREDS", "")
	home := t.TempDir()
	conv := filepath.Join(home, ".claude", "projects", "-root-x", "abc.jsonl")
	cred := filepath.Join(home, ".claude", ".credentials.json")
	codexCred := filepath.Join(home, ".codex", "auth.json")
	for _, f := range []string{conv, cred, codexCred} {
		if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(f, []byte("{}"), 0o600); err != nil {
			t.Fatal(err)
		}
	}

	cleanupAgentHomeCredentials(home, "test")

	if _, err := os.Stat(cred); !os.IsNotExist(err) {
		t.Fatal("claude credential must be removed")
	}
	if _, err := os.Stat(codexCred); !os.IsNotExist(err) {
		t.Fatal("codex credential must be removed")
	}
	if _, err := os.Stat(conv); err != nil {
		t.Fatalf("conversation file must SURVIVE Close: %v", err)
	}
}
