package ws

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/conduit/broker/internal/session"
)

// writeReplayConvLog creates a conversation.jsonl at
// <conduitRoot>/sessions/<id>/conversation.jsonl with the given entries.
func writeReplayConvLog(t *testing.T, conduitRoot, sessionID string, entries []session.ConvEntry) {
	t.Helper()
	dir := filepath.Join(conduitRoot, "sessions", sessionID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	f, err := os.Create(filepath.Join(dir, "conversation.jsonl"))
	if err != nil {
		t.Fatalf("create convlog: %v", err)
	}
	defer f.Close()
	for _, e := range entries {
		b, _ := json.Marshal(e)
		fmt.Fprintf(f, "%s\n", b)
	}
}

// drainChatViewEvents reads frames from fc until it has collected n
// chat view_events (type=view_event, view=chat) or the deadline elapses.
func drainChatViewEvents(t *testing.T, fc *frameCollector, n int, timeout time.Duration) []map[string]any {
	t.Helper()
	var got []map[string]any
	deadline := time.After(timeout)
	for len(got) < n {
		select {
		case f, ok := <-fc.frames:
			if !ok {
				t.Fatalf("frame channel closed; collected %d/%d chat view_events", len(got), n)
			}
			if f.mt != websocket.TextMessage {
				continue
			}
			var env map[string]any
			if err := json.Unmarshal(f.payload, &env); err != nil {
				continue
			}
			if env["type"] != "view_event" || env["view"] != "chat" {
				continue
			}
			got = append(got, env)
		case <-deadline:
			t.Fatalf("timeout waiting for chat view_events: got %d/%d", len(got), n)
		}
	}
	return got
}

// TestReattachReplayChatTranscript verifies that when a client reattaches
// to an existing session whose conversation.jsonl has entries, those
// entries arrive as chat view_event frames to the reattaching client,
// in order, before any live events.
func TestReattachReplayChatTranscript(t *testing.T) {
	root := t.TempDir()
	conduitRoot := filepath.Join(root, ".conduit")
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	sessID := "00000000-0000-0000-0000-0000000000r1"

	base := time.Date(2026, 3, 1, 10, 0, 0, 0, time.UTC)
	entries := []session.ConvEntry{
		{Role: "user", Content: "hello broker", Ts: base.UTC().Format(time.RFC3339Nano)},
		{Role: "assistant", Content: "hello back", Ts: base.Add(time.Second).UTC().Format(time.RFC3339Nano)},
		{Role: "user", Content: "do the thing", Ts: base.Add(2 * time.Second).UTC().Format(time.RFC3339Nano)},
	}
	writeReplayConvLog(t, conduitRoot, sessID, entries)

	srv, tok := newTestServer(t)

	// First connection — creates the session.
	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	// Drain the viewer-count view_event that fires on first connect.
	fc1.waitForStatusViewerCount(t, 1, 2*time.Second)

	// Second connection to same session — this is the "reattach" path
	// (created==false). It should receive the transcript replay.
	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)

	// c2 gets: type=status, then a binary snapshot, then viewer_count=2,
	// then the 3 replay frames. Drain them all.
	_ = fc2.waitForStatusFrame(t, 2*time.Second)
	chatFrames := drainChatViewEvents(t, fc2, len(entries), 3*time.Second)

	if len(chatFrames) != len(entries) {
		t.Fatalf("replay: want %d chat frames, got %d", len(entries), len(chatFrames))
	}

	// Verify order (oldest→newest) and content.
	for i, frame := range chatFrames {
		ev, _ := frame["event"].(map[string]any)
		if ev == nil {
			t.Fatalf("frame %d: no event field", i)
		}
		role, _ := ev["role"].(string)
		content, _ := ev["content"].(string)
		if role != entries[i].Role {
			t.Errorf("frame %d: role want %q got %q", i, entries[i].Role, role)
		}
		if content != entries[i].Content {
			t.Errorf("frame %d: content want %q got %q", i, entries[i].Content, content)
		}
		if _, hasTs := ev["ts"]; !hasTs {
			t.Errorf("frame %d: missing ts field", i)
		}
		if _, hasFiles := ev["files"]; !hasFiles {
			t.Errorf("frame %d: missing files field", i)
		}
	}

	// First connection (c1) must NOT have received the replay frames —
	// they were direct-writes to c2 only, not PublishText.
	// Drain fc1's channel briefly and confirm no extra chat view_events arrived.
	extraDeadline := time.After(300 * time.Millisecond)
	extraCount := 0
drainLoop:
	for {
		select {
		case f, ok := <-fc1.frames:
			if !ok {
				break drainLoop
			}
			if f.mt != websocket.TextMessage {
				continue
			}
			var env map[string]any
			if err := json.Unmarshal(f.payload, &env); err != nil {
				continue
			}
			if env["type"] == "view_event" && env["view"] == "chat" {
				extraCount++
			}
		case <-extraDeadline:
			break drainLoop
		}
	}
	if extraCount > 0 {
		t.Errorf("c1 received %d unexpected chat view_events from the replay (replay must be direct-write only)", extraCount)
	}
}

// TestReattachReplayTailCap verifies that when the transcript has more
// than reattachReplayTail entries, only the last reattachReplayTail are
// replayed (chronological order preserved).
func TestReattachReplayTailCap(t *testing.T) {
	root := t.TempDir()
	conduitRoot := filepath.Join(root, ".conduit")
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	sessID := "00000000-0000-0000-0000-0000000000r2"

	n := reattachReplayTail + 50 // 250 entries total
	base := time.Date(2026, 3, 1, 0, 0, 0, 0, time.UTC)
	entries := make([]session.ConvEntry, n)
	for i := range entries {
		entries[i] = session.ConvEntry{
			Role:    "user",
			Content: fmt.Sprintf("msg %d", i+1),
			Ts:      base.Add(time.Duration(i) * time.Second).UTC().Format(time.RFC3339Nano),
		}
	}
	writeReplayConvLog(t, conduitRoot, sessID, entries)

	srv, tok := newTestServer(t)

	// First connect to create session.
	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	fc1.waitForStatusViewerCount(t, 1, 2*time.Second)

	// Second connect — reattach path; should get exactly reattachReplayTail frames.
	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)
	_ = fc2.waitForStatusFrame(t, 2*time.Second)

	chatFrames := drainChatViewEvents(t, fc2, reattachReplayTail, 5*time.Second)

	if len(chatFrames) != reattachReplayTail {
		t.Fatalf("tail cap: want %d frames, got %d", reattachReplayTail, len(chatFrames))
	}

	// First replayed entry should be entry at index (n - reattachReplayTail) = 50,
	// i.e. "msg 51".
	firstExpected := fmt.Sprintf("msg %d", n-reattachReplayTail+1)
	firstEv, _ := chatFrames[0]["event"].(map[string]any)
	firstContent, _ := firstEv["content"].(string)
	if firstContent != firstExpected {
		t.Errorf("tail cap first: want %q, got %q", firstExpected, firstContent)
	}

	// Last replayed entry should be the final entry "msg N".
	lastExpected := fmt.Sprintf("msg %d", n)
	lastEv, _ := chatFrames[reattachReplayTail-1]["event"].(map[string]any)
	lastContent, _ := lastEv["content"].(string)
	if lastContent != lastExpected {
		t.Errorf("tail cap last: want %q, got %q", lastExpected, lastContent)
	}
}

// TestReattachReplayEmptyTranscript verifies that a session with no
// conversation.jsonl (new session, broker restart before any chat) does
// not cause any error or unexpected frames — connect succeeds normally.
func TestReattachReplayEmptyTranscript(t *testing.T) {
	root := t.TempDir()
	conduitRoot := filepath.Join(root, ".conduit")
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	sessID := "00000000-0000-0000-0000-0000000000r3"
	// No convlog written — directory doesn't even exist.

	srv, tok := newTestServer(t)

	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	fc1.waitForStatusViewerCount(t, 1, 2*time.Second)

	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)
	_ = fc2.waitForStatusFrame(t, 2*time.Second)

	// Confirm no chat view_events arrive within a short window (no transcript).
	extraDeadline := time.After(400 * time.Millisecond)
	chatCount := 0
drainLoop2:
	for {
		select {
		case f, ok := <-fc2.frames:
			if !ok {
				break drainLoop2
			}
			if f.mt != websocket.TextMessage {
				continue
			}
			var env map[string]any
			if err := json.Unmarshal(f.payload, &env); err != nil {
				continue
			}
			if env["type"] == "view_event" && env["view"] == "chat" {
				chatCount++
			}
		case <-extraDeadline:
			break drainLoop2
		}
	}
	if chatCount > 0 {
		t.Errorf("empty transcript: got %d unexpected chat view_events", chatCount)
	}
}
