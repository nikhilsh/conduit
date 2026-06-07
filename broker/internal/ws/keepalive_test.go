package ws

import (
	"testing"
	"time"

	"github.com/gorilla/websocket"
)

// Keep-alive regression tests (post-v0.0.116 disconnect investigation).
//
// The bug: newClient armed the read deadline ONCE at connect and only the
// PongHandler ever re-armed it — but nothing solicited a protocol-level
// Pong (both 30s heartbeats were JSON text frames, which don't touch the
// deadline), so EVERY socket was hard-closed exactly pongWait after
// connect, no matter how chatty. Users saw it as a random
// "Disconnected → Reconnecting" flap every ~90s.
//
// The fix is two independent refresh paths, each pinned below with the
// other disabled:
//   1. readLoop re-arms the deadline on ANY inbound frame.
//   2. writeLoop sends a protocol-level Ping each tick; the peer's
//      automatic Pong re-arms via the PongHandler.

// shrinkKeepAlive rescales the keep-alive clocks for a fast test and
// restores them on cleanup.
func shrinkKeepAlive(t *testing.T, wait, ping time.Duration) {
	t.Helper()
	oldWait, oldPing := pongWait, pingInterval
	pongWait, pingInterval = wait, ping
	t.Cleanup(func() { pongWait, pingInterval = oldWait, oldPing })
}

// assertAliveFor fails the test if the server closes the connection
// within `window`. A dedicated reader goroutine drains frames (which
// also lets the client's default ping handler auto-pong); gorilla
// forbids further reads after any read error, so the reader exits on
// the first one. When `chatty`, the client also sends a JSON ping
// every 300ms.
func assertAliveFor(t *testing.T, c *websocket.Conn, window time.Duration, chatty bool) {
	t.Helper()
	errCh := make(chan error, 1)
	go func() {
		for {
			if _, _, err := c.ReadMessage(); err != nil {
				errCh <- err
				return
			}
		}
	}()
	deadline := time.After(window)
	ticker := time.NewTicker(300 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case err := <-errCh:
			t.Fatalf("server closed the connection before %v: %v", window, err)
		case <-ticker.C:
			if chatty {
				if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
					t.Fatalf("write failed before %v: %v", window, err)
				}
			}
		case <-deadline:
			return // survived the window — deadline was re-armed
		}
	}
}

// A client that keeps SENDING (JSON pings) must outlive pongWait even
// when the server never pings (path 1: inbound traffic re-arms).
func TestChattyClientSurvivesPastPongWait(t *testing.T) {
	shrinkKeepAlive(t, 1200*time.Millisecond, time.Hour) // no server pings
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-00000000a001", tok)
	assertAliveFor(t, c, 3*pongWait, true)
}

// A QUIET client (sends nothing, only reads) must outlive pongWait via
// the server's protocol Ping → automatic client Pong → PongHandler
// re-arm (path 2).
func TestQuietClientSurvivesPastPongWait(t *testing.T) {
	shrinkKeepAlive(t, 1200*time.Millisecond, 300*time.Millisecond)
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-00000000a002", tok)
	assertAliveFor(t, c, 3*pongWait, false)
}
