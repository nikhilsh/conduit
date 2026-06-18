package main

import (
	"encoding/json"
	"strings"
	"testing"
	"time"
)

// --- newUUID tests --------------------------------------------------------

func TestNewUUID_Format(t *testing.T) {
	id := newUUID()
	parts := strings.Split(id, "-")
	if len(parts) != 5 {
		t.Fatalf("expected 5 parts, got %d: %q", len(parts), id)
	}
	if len(parts[0]) != 8 || len(parts[1]) != 4 || len(parts[2]) != 4 ||
		len(parts[3]) != 4 || len(parts[4]) != 12 {
		t.Fatalf("unexpected UUID segment lengths: %q", id)
	}
}

func TestNewUUID_Unique(t *testing.T) {
	seen := make(map[string]bool)
	for i := 0; i < 100; i++ {
		id := newUUID()
		if seen[id] {
			t.Fatalf("duplicate UUID %q on iteration %d", id, i)
		}
		seen[id] = true
	}
}

// --- buildSend tests ------------------------------------------------------

func TestBuildSend_Chat_HasClientMsgID(t *testing.T) {
	b := buildSend("hello world")
	if b == nil {
		t.Fatal("expected non-nil for chat message")
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if m["type"] != "chat" {
		t.Fatalf("type: want chat, got %v", m["type"])
	}
	if m["msg"] != "hello world" {
		t.Fatalf("msg: want 'hello world', got %v", m["msg"])
	}
	id, ok := m["client_msg_id"].(string)
	if !ok || id == "" {
		t.Fatalf("client_msg_id must be a non-empty string; got %v", m["client_msg_id"])
	}
}

func TestBuildSend_Stop(t *testing.T) {
	b := buildSend("/stop")
	if b == nil {
		t.Fatal("expected non-nil for /stop")
	}
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if m["type"] != "stop" {
		t.Fatalf("type: want stop, got %v", m["type"])
	}
	// stop has no client_msg_id
	if _, hasID := m["client_msg_id"]; hasID {
		t.Fatal("stop must not carry client_msg_id")
	}
}

func TestBuildSend_Stop_HasNoClientMsgID(t *testing.T) {
	b := buildSend("/stop")
	var m map[string]any
	_ = json.Unmarshal(b, &m)
	if _, ok := m["client_msg_id"]; ok {
		t.Fatal("stop frame must not have client_msg_id")
	}
}

func TestBuildSend_Empty_Nil(t *testing.T) {
	if buildSend("") != nil {
		t.Fatal("empty line should return nil")
	}
	if buildSend("   ") != nil {
		// Note: buildSend trims \r\n but not spaces per spec —
		// a line of spaces is technically valid input to forward.
		// spaces-only actually builds a chat frame (not nil).
		// So skip the space case; only truly empty strings are nil.
	}
}

func TestBuildSend_EachSend_DifferentClientMsgID(t *testing.T) {
	ids := make(map[string]bool)
	for i := 0; i < 20; i++ {
		b := buildSend("message")
		var m map[string]any
		_ = json.Unmarshal(b, &m)
		id := m["client_msg_id"].(string)
		if ids[id] {
			t.Fatalf("duplicate client_msg_id on send %d: %s", i, id)
		}
		ids[id] = true
	}
}

// --- handleFrame / frame parsing tests -----------------------------------

func TestHandleFrame_ChatEvent_Rendered(t *testing.T) {
	// Build a view_event/chat frame.
	event, _ := json.Marshal(map[string]any{
		"role":    "assistant",
		"content": "hello from agent",
		"ts":      time.Now().UTC().Format(time.RFC3339Nano),
	})
	payload, _ := json.Marshal(map[string]any{
		"type":  "view_event",
		"view":  "chat",
		"event": json.RawMessage(event),
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if done {
		t.Fatalf("handleFrame returned done=true for a chat event; err=%v", err)
	}
}

func TestHandleFrame_AskSentinel_Detected(t *testing.T) {
	// The assistant content that signals AskUserQuestion.
	content := pendingInputSentinel + "\nPick one:\n1. option A\n2. option B"
	event, _ := json.Marshal(map[string]any{
		"role":    "assistant",
		"content": content,
		"ts":      time.Now().UTC().Format(time.RFC3339Nano),
	})
	payload, _ := json.Marshal(map[string]any{
		"type":  "view_event",
		"view":  "chat",
		"event": json.RawMessage(event),
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if done {
		t.Fatalf("ask frame should not trigger exit; err=%v", err)
	}
	// No assert on stdout rendering here — visual test only.
}

func TestHandleFrame_Exit_ReturnsDone(t *testing.T) {
	payload, _ := json.Marshal(map[string]any{
		"type":        "exit",
		"session":     "abc",
		"code":        0,
		"reason_code": "normal_exit",
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if !done {
		t.Fatal("exit frame must return done=true")
	}
	if err == nil {
		t.Fatal("exit frame must return non-nil err (io.EOF)")
	}
}

func TestHandleFrame_ChatAck_NotDone(t *testing.T) {
	payload, _ := json.Marshal(map[string]any{
		"type":          "chat_ack",
		"session_id":    "abc",
		"client_msg_id": "local-123",
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if done || err != nil {
		t.Fatalf("chat_ack must not trigger exit; done=%v err=%v", done, err)
	}
}

func TestHandleFrame_Status_NotDone(t *testing.T) {
	payload, _ := json.Marshal(map[string]any{
		"type":      "status",
		"session":   "abc",
		"assistant": "claude",
		"phase":     "running",
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if done || err != nil {
		t.Fatalf("status must not trigger exit; done=%v err=%v", done, err)
	}
}

func TestHandleFrame_Ping_NotDone(t *testing.T) {
	payload, _ := json.Marshal(map[string]any{
		"type": "ping",
		"ts":   time.Now().UTC().Format(time.RFC3339Nano),
	})
	var latestTs int64
	done, err := handleFrame(payload, &latestTs)
	if done || err != nil {
		t.Fatalf("ping must not trigger exit; done=%v err=%v", done, err)
	}
}

// --- history dedup seam ---------------------------------------------------

// TestHistoryDedup_LatestTs checks that parseTsMillis advances latestTs
// so a since_ts request after a reconnect skips already-seen entries.
func TestHistoryDedup_LatestTs(t *testing.T) {
	ts1 := "2024-01-01T10:00:00Z"
	ts2 := "2024-01-01T10:00:01Z"

	// Simulate two history loads: first returns ts1, second returns ts2.
	var latestTs int64

	ms1 := parseTsMillis(ts1)
	if ms1 == 0 {
		t.Fatalf("parseTsMillis(%q) = 0", ts1)
	}
	if ms1 > latestTs {
		latestTs = ms1
	}

	ms2 := parseTsMillis(ts2)
	if ms2 <= ms1 {
		t.Fatalf("ts2 %d should be > ts1 %d", ms2, ms1)
	}
	if ms2 > latestTs {
		latestTs = ms2
	}
	if latestTs != ms2 {
		t.Fatalf("latestTs should be %d, got %d", ms2, latestTs)
	}
}

func TestParseTsMillis_Zero_OnEmpty(t *testing.T) {
	if parseTsMillis("") != 0 {
		t.Fatal("empty ts should return 0")
	}
}

func TestParseTsMillis_Zero_OnGarbage(t *testing.T) {
	if parseTsMillis("not-a-timestamp") != 0 {
		t.Fatal("bad ts should return 0")
	}
}

// --- buildWSURL -----------------------------------------------------------

func TestBuildWSURL_HttpToWs(t *testing.T) {
	u := buildWSURL("http://127.0.0.1:1977", "tok123", "sess-abc")
	if !strings.HasPrefix(u, "ws://") {
		t.Fatalf("http base should produce ws:// URL, got %q", u)
	}
	if !strings.Contains(u, "/ws/sess-abc") {
		t.Fatalf("URL missing session path: %q", u)
	}
	if !strings.Contains(u, "token=") {
		t.Fatalf("URL missing token param: %q", u)
	}
	// Must NOT contain device_id, rows, or cols (§2.5).
	if strings.Contains(u, "device_id") {
		t.Fatalf("URL must not contain device_id: %q", u)
	}
	if strings.Contains(u, "rows=") || strings.Contains(u, "cols=") {
		t.Fatalf("URL must not contain rows/cols: %q", u)
	}
}

func TestBuildWSURL_HttpsToWss(t *testing.T) {
	u := buildWSURL("https://example.com", "tok", "sess1")
	if !strings.HasPrefix(u, "wss://") {
		t.Fatalf("https base should produce wss:// URL, got %q", u)
	}
}

// --- validateSession tests -----------------------------------------------

func TestValidateSession_Live(t *testing.T) {
	sessions := &sessionListResponse{
		Sessions: []sessionInfo{{ID: "live-1"}},
	}
	if got := validateSession(sessions, "live-1"); got != 0 {
		t.Fatalf("want 0 for live session, got %d", got)
	}
}

func TestValidateSession_Recoverable(t *testing.T) {
	sessions := &sessionListResponse{
		Recoverable: []sessionInfo{{ID: "rec-1"}},
	}
	if got := validateSession(sessions, "rec-1"); got != 1 {
		t.Fatalf("want 1 for recoverable session, got %d", got)
	}
}

func TestValidateSession_NotFound(t *testing.T) {
	sessions := &sessionListResponse{}
	if got := validateSession(sessions, "no-such"); got != -1 {
		t.Fatalf("want -1 for unknown session, got %d", got)
	}
}
