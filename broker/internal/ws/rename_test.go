package ws

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// readNextStatus drains text frames until it sees a `status` envelope
// (or hits the deadline). Returns the decoded payload so the caller
// can assert on individual keys without juggling a slow-status flake.
func readNextStatus(t *testing.T, c *websocket.Conn) map[string]any {
	t.Helper()
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		mt, payload, err := c.ReadMessage()
		if err != nil {
			t.Fatalf("read: %v", err)
		}
		if mt != websocket.TextMessage {
			continue
		}
		var env map[string]any
		if err := json.Unmarshal(payload, &env); err != nil {
			continue
		}
		if env["type"] == "status" {
			return env
		}
	}
	t.Fatal("did not observe a status frame before deadline")
	return nil
}

// TestRenameSessionValid covers the happy path: a rename matching the
// §3.3 regex must trigger a fresh status broadcast whose
// `session_name` + `display_name` carry the new label.
func TestRenameSessionValid(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000a1", tok)
	// Drain the initial status frame.
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	if err := c.WriteMessage(websocket.TextMessage,
		[]byte(`{"type":"rename_session","name":"my-feature_42"}`)); err != nil {
		t.Fatalf("write rename: %v", err)
	}
	st := readNextStatus(t, c)
	if got := st["session_name"]; got != "my-feature_42" {
		t.Fatalf("session_name: want my-feature_42, got %v", got)
	}
	if got := st["display_name"]; got != "my-feature_42" {
		t.Fatalf("display_name: want my-feature_42, got %v", got)
	}
}

// TestRenameSessionInvalid covers the regex-reject branch: an invalid
// name (too long, empty, illegal chars, whitespace-only) is silently
// ignored — the socket stays open, no status broadcast follows, and a
// subsequent ping still round-trips.
func TestRenameSessionInvalid(t *testing.T) {
	cases := []struct {
		label, name string
	}{
		{"empty", ""},
		{"whitespace-only", "   "},
		{"too-long", strings.Repeat("x", 33)},
		{"illegal-slash", "feature/branch"},
		{"illegal-newline", "feature\n"},
		{"unicode-disallowed", "naïve"},
	}
	for _, tc := range cases {
		t.Run(tc.label, func(t *testing.T) {
			srv, tok := newTestServer(t)
			c := dial(t, srv, "00000000-0000-0000-0000-0000000000a2", tok)
			_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
			_, _, _ = c.ReadMessage() // initial status

			env := map[string]any{"type": "rename_session", "name": tc.name}
			payload, err := json.Marshal(env)
			if err != nil {
				t.Fatalf("marshal: %v", err)
			}
			if err := c.WriteMessage(websocket.TextMessage, payload); err != nil {
				t.Fatalf("write rename: %v", err)
			}

			// Expect no follow-up status frame; a ping/pong must still
			// round-trip, proving the socket survived the rejected rename.
			if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
				t.Fatalf("write ping: %v", err)
			}
			deadline := time.Now().Add(2 * time.Second)
			for time.Now().Before(deadline) {
				_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
				mt, b, err := c.ReadMessage()
				if err != nil {
					t.Fatalf("read after invalid rename: %v", err)
				}
				if mt != websocket.TextMessage {
					continue
				}
				var got map[string]any
				if err := json.Unmarshal(b, &got); err != nil {
					continue
				}
				if got["type"] == "status" {
					if got["session_name"] != nil || got["display_name"] != nil {
						t.Fatalf("invalid rename leaked into status: %v", got)
					}
					continue
				}
				if got["type"] == "pong" {
					return
				}
			}
			t.Fatal("did not observe pong after invalid rename")
		})
	}
}

// TestRenameSessionLastWriterWins replays two valid renames in sequence
// and confirms the second label clobbers the first — last-writer-wins
// is the v1 contract (§3.3, no ack, no merge).
func TestRenameSessionLastWriterWins(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000a3", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage() // initial status

	if err := c.WriteMessage(websocket.TextMessage,
		[]byte(`{"type":"rename_session","name":"first"}`)); err != nil {
		t.Fatalf("write rename 1: %v", err)
	}
	if got := readNextStatus(t, c)["session_name"]; got != "first" {
		t.Fatalf("first rename: want session_name=first, got %v", got)
	}

	if err := c.WriteMessage(websocket.TextMessage,
		[]byte(`{"type":"rename_session","name":"second"}`)); err != nil {
		t.Fatalf("write rename 2: %v", err)
	}
	if got := readNextStatus(t, c)["session_name"]; got != "second" {
		t.Fatalf("second rename: want session_name=second, got %v", got)
	}
}
