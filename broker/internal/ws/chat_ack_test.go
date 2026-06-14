package ws

import (
	"encoding/json"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// readChatAcks drains text frames until the read deadline fires and returns
// every chat_ack payload seen for the given client_msg_id. gorilla's Conn
// permanently fails after a read error, so we set ONE deadline for the whole
// window and stop at the first error rather than re-reading a dead conn.
func readChatAcks(t *testing.T, c *websocket.Conn, clientMsgID string, window time.Duration) []map[string]any {
	t.Helper()
	var acks []map[string]any
	_ = c.SetReadDeadline(time.Now().Add(window))
	for {
		mt, payload, err := c.ReadMessage()
		if err != nil {
			return acks
		}
		if mt != websocket.TextMessage {
			continue
		}
		var env map[string]any
		if err := json.Unmarshal(payload, &env); err != nil {
			continue
		}
		if env["type"] == "chat_ack" && env["client_msg_id"] == clientMsgID {
			acks = append(acks, env)
		}
	}
}

// TestChatAckDedupSameIDAcksTwice asserts the wire half of the task-K invariant
// end to end: sending the same (session, client_msg_id) twice acks BOTH copies
// (so a resend whose first ack was lost still confirms). The "forwards to the
// agent only once" half is proven deterministically by TestChatDedupMarkSeen
// below — the PTY echo of the `cat` test agent is too noisy (terminal line
// discipline echoes input AND cat re-emits it) to count forwards reliably.
func TestChatAckDedupSameIDAcksTwice(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c1", tok)
	// Drain the initial status frame.
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	const id = "local-abc-123"
	frame, _ := json.Marshal(map[string]any{
		"type":          "chat",
		"from":          "mobile",
		"msg":           "hello durable world",
		"client_msg_id": id,
	})
	// Send the same message twice (simulating a resend after an app kill).
	if err := c.WriteMessage(websocket.TextMessage, frame); err != nil {
		t.Fatalf("write chat #1: %v", err)
	}
	if err := c.WriteMessage(websocket.TextMessage, frame); err != nil {
		t.Fatalf("write chat #2: %v", err)
	}

	acks := readChatAcks(t, c, id, 2*time.Second)
	if len(acks) != 2 {
		t.Fatalf("want 2 chat_acks for duplicate sends, got %d", len(acks))
	}
	if acks[0]["session_id"] != "00000000-0000-0000-0000-0000000000c1" {
		t.Fatalf("ack carries wrong session_id: %v", acks[0]["session_id"])
	}
}

// TestChatNoIDNoAck asserts backcompat: an old client that omits client_msg_id
// gets NO chat_ack (and the message is still forwarded — covered by other
// chat tests). Absence-of-ack proves the broker doesn't ack unkeyed sends.
func TestChatNoIDNoAck(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000c2", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	frame, _ := json.Marshal(map[string]any{
		"type": "chat",
		"from": "mobile",
		"msg":  "no id here",
	})
	if err := c.WriteMessage(websocket.TextMessage, frame); err != nil {
		t.Fatalf("write chat: %v", err)
	}

	acks := readChatAcks(t, c, "", 1*time.Second)
	if len(acks) != 0 {
		t.Fatalf("old client (no client_msg_id) must not be acked, got %d acks", len(acks))
	}
}

// TestChatDedupMarkSeen unit-tests the dedup core: a fresh id is new (false),
// the same id is a duplicate (true), and distinct ids/sessions are independent.
func TestChatDedupMarkSeen(t *testing.T) {
	d := newChatDedup()
	if d.markSeen("s1", "a") {
		t.Fatal("first sight of (s1,a) must be new, got duplicate")
	}
	if !d.markSeen("s1", "a") {
		t.Fatal("second sight of (s1,a) must be a duplicate")
	}
	if d.markSeen("s1", "b") {
		t.Fatal("(s1,b) is a different id, must be new")
	}
	if d.markSeen("s2", "a") {
		t.Fatal("(s2,a) is a different session, must be new")
	}
}

// TestChatDedupEvictsExpired asserts the TTL frees memory: an id older than the
// TTL is evicted and re-seeing it reports new again.
func TestChatDedupEvictsExpired(t *testing.T) {
	d := newChatDedup()
	d.markSeen("s1", "old")
	// Backdate the entry past the TTL.
	d.mu.Lock()
	d.seen["s1"]["old"] = time.Now().Add(-2 * chatDedupTTL)
	d.mu.Unlock()
	// A fresh markSeen triggers eviction; the stale id should be gone, so the
	// re-sight reports new (false) rather than duplicate.
	if d.markSeen("s1", "old") {
		t.Fatal("expired id must be treated as new after TTL eviction")
	}
}
