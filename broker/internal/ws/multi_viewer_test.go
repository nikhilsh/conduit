package ws

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/broker/internal/session"
)

// frameCollector wraps a websocket.Conn in a background drain
// goroutine that pushes every successfully-read frame into a channel.
// This is necessary because gorilla.Conn treats any read error
// (including an i/o timeout) as terminal — subsequent calls return
// the cached error and panic after enough retries. Our tests want
// to poll for "did we see frame X yet?", which the synchronous
// SetReadDeadline + ReadMessage loop can't do safely.
type frameCollector struct {
	frames chan frame
}

type frame struct {
	mt      int
	payload []byte
}

func collect(t *testing.T, c *websocket.Conn) *frameCollector {
	t.Helper()
	fc := &frameCollector{frames: make(chan frame, 256)}
	go func() {
		defer close(fc.frames)
		for {
			mt, payload, err := c.ReadMessage()
			if err != nil {
				return
			}
			// Copy payload — gorilla may reuse the buffer.
			p := make([]byte, len(payload))
			copy(p, payload)
			select {
			case fc.frames <- frame{mt: mt, payload: p}:
			default:
				// Test isn't draining fast enough; drop to avoid blocking
				// the read goroutine. Tests that care about completeness
				// should size the channel buffer up.
			}
		}
	}()
	return fc
}

// waitForStatusViewerCount drains fc until a view_event { view:
// "status", viewer_count: want } is observed.
func (fc *frameCollector) waitForStatusViewerCount(t *testing.T, want int, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case f, ok := <-fc.frames:
			if !ok {
				t.Fatalf("frame channel closed before viewer_count=%d", want)
			}
			if f.mt != websocket.TextMessage {
				continue
			}
			var env map[string]any
			if err := json.Unmarshal(f.payload, &env); err != nil {
				continue
			}
			if env["type"] != "view_event" || env["view"] != "status" {
				continue
			}
			ev, ok := env["event"].(map[string]any)
			if !ok {
				continue
			}
			vc, ok := ev["viewer_count"].(float64)
			if !ok {
				continue
			}
			if int(vc) == want {
				return
			}
		case <-deadline:
			t.Fatalf("did not observe view: status with viewer_count=%d before deadline", want)
		}
	}
}

// waitForBinaryContaining drains fc until a binary frame containing
// needle is observed (or it times out).
func (fc *frameCollector) waitForBinaryContaining(t *testing.T, needle []byte, timeout time.Duration) {
	t.Helper()
	deadline := time.After(timeout)
	var seen bytes.Buffer
	for {
		select {
		case f, ok := <-fc.frames:
			if !ok {
				t.Fatalf("frame channel closed before seeing %q (saw %q)", needle, seen.String())
			}
			if f.mt != websocket.BinaryMessage {
				continue
			}
			seen.Write(f.payload)
			if bytes.Contains(seen.Bytes(), needle) {
				return
			}
		case <-deadline:
			t.Fatalf("did not observe binary frame containing %q before deadline (saw %q)", needle, seen.String())
		}
	}
}

// waitForStatusFrame drains fc until a top-level type=status frame
// arrives, then returns it.
func (fc *frameCollector) waitForStatusFrame(t *testing.T, timeout time.Duration) map[string]any {
	t.Helper()
	deadline := time.After(timeout)
	for {
		select {
		case f, ok := <-fc.frames:
			if !ok {
				t.Fatal("frame channel closed before type=status")
			}
			if f.mt != websocket.TextMessage {
				continue
			}
			var env map[string]any
			if err := json.Unmarshal(f.payload, &env); err != nil {
				continue
			}
			if env["type"] == "status" {
				return env
			}
		case <-deadline:
			t.Fatal("never observed type=status frame")
		}
	}
}

// TestStatusViewerCountSingle verifies the existing single-viewer
// behavior: status.viewers == 1, view_event status.viewer_count == 1,
// and byte fan-out works.
func TestStatusViewerCountSingle(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-0000000000a1", tok)
	fc := collect(t, c)

	st := fc.waitForStatusFrame(t, 2*time.Second)
	if v, _ := st["viewers"].(float64); int(v) != 1 {
		t.Fatalf("status.viewers = %v, want 1", st["viewers"])
	}
	fc.waitForStatusViewerCount(t, 1, 2*time.Second)

	// Byte fan-out smoke: PTY echo still works in single-viewer mode.
	if err := c.WriteMessage(websocket.BinaryMessage, []byte("hi-solo\n")); err != nil {
		t.Fatal(err)
	}
	fc.waitForBinaryContaining(t, []byte("hi-solo"), 3*time.Second)
}

// TestStatusViewerCountTwoViewers verifies that 2 connections to the
// same session each see viewer_count=2 in a view: status event, and
// that a single PTY write reaches both viewers.
func TestStatusViewerCountTwoViewers(t *testing.T) {
	srv, tok := newTestServer(t)
	sessID := "00000000-0000-0000-0000-0000000000a2"

	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	fc1.waitForStatusViewerCount(t, 1, 2*time.Second)

	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)
	st2 := fc2.waitForStatusFrame(t, 2*time.Second)
	if v, _ := st2["viewers"].(float64); int(v) != 2 {
		t.Fatalf("c2 status.viewers = %v, want 2", st2["viewers"])
	}
	// Both should observe viewer_count=2 via the view: status mirror.
	fc2.waitForStatusViewerCount(t, 2, 2*time.Second)
	fc1.waitForStatusViewerCount(t, 2, 2*time.Second)

	// Fan-out: write once via c1, both should receive the bytes.
	if err := c1.WriteMessage(websocket.BinaryMessage, []byte("fanout-2\n")); err != nil {
		t.Fatal(err)
	}
	fc1.waitForBinaryContaining(t, []byte("fanout-2"), 3*time.Second)
	fc2.waitForBinaryContaining(t, []byte("fanout-2"), 3*time.Second)
}

// TestStatusViewerCountThreeViewers does the same as the two-viewer
// case with one more subscriber, as a sanity check.
func TestStatusViewerCountThreeViewers(t *testing.T) {
	srv, tok := newTestServer(t)
	sessID := "00000000-0000-0000-0000-0000000000a3"

	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	fc1.waitForStatusViewerCount(t, 1, 2*time.Second)

	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)
	_ = fc2.waitForStatusFrame(t, 2*time.Second)
	fc2.waitForStatusViewerCount(t, 2, 2*time.Second)

	c3 := dial(t, srv, sessID, tok)
	fc3 := collect(t, c3)
	st3 := fc3.waitForStatusFrame(t, 2*time.Second)
	if v, _ := st3["viewers"].(float64); int(v) != 3 {
		t.Fatalf("c3 status.viewers = %v, want 3", st3["viewers"])
	}
	fc1.waitForStatusViewerCount(t, 3, 2*time.Second)
	fc2.waitForStatusViewerCount(t, 3, 2*time.Second)
	fc3.waitForStatusViewerCount(t, 3, 2*time.Second)

	// Fan-out: c2 writes; c1, c2, c3 all see the bytes.
	if err := c2.WriteMessage(websocket.BinaryMessage, []byte("fanout-3\n")); err != nil {
		t.Fatal(err)
	}
	fc1.waitForBinaryContaining(t, []byte("fanout-3"), 3*time.Second)
	fc2.waitForBinaryContaining(t, []byte("fanout-3"), 3*time.Second)
	fc3.waitForBinaryContaining(t, []byte("fanout-3"), 3*time.Second)
}

// TestSubscriberLeaveKeepsOthersStreaming verifies that disconnecting
// one viewer mid-session does not interrupt PTY fan-out to the others,
// and that viewer_count drops to reflect the departure.
func TestSubscriberLeaveKeepsOthersStreaming(t *testing.T) {
	srv, tok := newTestServer(t)
	sessID := "00000000-0000-0000-0000-0000000000a4"

	c1 := dial(t, srv, sessID, tok)
	fc1 := collect(t, c1)
	_ = fc1.waitForStatusFrame(t, 2*time.Second)
	c2 := dial(t, srv, sessID, tok)
	fc2 := collect(t, c2)
	_ = fc2.waitForStatusFrame(t, 2*time.Second)

	// Both observe viewer_count=2.
	fc1.waitForStatusViewerCount(t, 2, 2*time.Second)
	fc2.waitForStatusViewerCount(t, 2, 2*time.Second)

	// c2 leaves. fc2's collector goroutine will exit when the conn
	// closes; that's fine, we don't read from fc2 anymore.
	_ = c2.Close()

	// c1 sends a write to drive PTY traffic. This is what makes the
	// server-side c2 writeLoop notice its dead connection (the next
	// chunk fan-out tries to write, fails, and the deferred unsubscribe
	// + emitViewerStatus run). Without traffic, writeLoop would stay
	// blocked in select{} until the 30s ping ticker. This isn't a
	// production concern (live PTYs always have output), but a clean
	// test needs the tickle.
	if err := c1.WriteMessage(websocket.BinaryMessage, []byte("after-leave\n")); err != nil {
		t.Fatal(err)
	}

	fc1.waitForBinaryContaining(t, []byte("after-leave"), 3*time.Second)

	// c1 should observe the post-leave viewer_count=1 broadcast — once
	// c2's serveWS handler returns the deferred emitViewerStatus fires.
	fc1.waitForStatusViewerCount(t, 1, 3*time.Second)
}

// TestSlowSubscriberDoesNotBlockFastOnes uses the session's Subscribe
// API directly to attach a fast subscriber and a stalled subscriber
// (one that never drains its channel). After many fan-outs, the fast
// subscriber should still see fresh data — the stalled one must not
// stall the PTY reader or starve its peer.
//
// Per protocol: slow subscriber's chunks are dropped, not held; the
// PTY drain goroutine never blocks.
func TestSlowSubscriberDoesNotBlockFastOnes(t *testing.T) {
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	defer m.Close()

	// Test adapter's command is `cat` — input drives output via echo,
	// which gives us a steady stream to fan-out under load.
	sess, _, err := m.GetOrCreate("00000000-0000-0000-0000-0000000000a5", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}

	// Fast subscriber: a buffered channel we drain promptly.
	fast := sess.Subscribe()
	// Slow subscriber: we never drain it. The fan-out's drop-oldest
	// policy must let `fast` keep getting fresh bytes.
	slow := sess.Subscribe()
	defer sess.Unsubscribe(fast)
	defer sess.Unsubscribe(slow)

	if got := sess.SubscriberCount(); got != 2 {
		t.Fatalf("SubscriberCount after 2 subscribes = %d, want 2", got)
	}

	// Drive a lot of bytes through the PTY so the slow channel's
	// 64-slot buffer fills up.
	go func() {
		for i := 0; i < 200; i++ {
			_, _ = sess.Write([]byte("burst-marker\n"))
			time.Sleep(2 * time.Millisecond)
		}
	}()

	deadline := time.Now().Add(3 * time.Second)
	var fastBuf bytes.Buffer
	for time.Now().Before(deadline) {
		select {
		case chunk, ok := <-fast:
			if !ok {
				t.Fatal("fast subscriber channel closed unexpectedly")
			}
			fastBuf.Write(chunk)
			if strings.Contains(fastBuf.String(), "burst-marker") {
				return
			}
		case <-time.After(500 * time.Millisecond):
			// Loop again — fast must continue making progress even with
			// a slow peer wedged.
		}
	}
	t.Fatalf("fast subscriber did not observe any burst-marker bytes; slow peer may have blocked the reader. captured=%q", fastBuf.String())
}

// TestSubscriberCountDirect pins SubscriberCount() correctness at the
// session level, independent of the WS layer.
func TestSubscriberCountDirect(t *testing.T) {
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	defer m.Close()

	sess, _, err := m.GetOrCreate("00000000-0000-0000-0000-0000000000a6", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if got := sess.SubscriberCount(); got != 0 {
		t.Fatalf("initial SubscriberCount = %d, want 0", got)
	}
	a := sess.Subscribe()
	b := sess.Subscribe()
	if got := sess.SubscriberCount(); got != 2 {
		t.Fatalf("SubscriberCount after 2 subs = %d, want 2", got)
	}
	sess.Unsubscribe(a)
	if got := sess.SubscriberCount(); got != 1 {
		t.Fatalf("SubscriberCount after 1 unsub = %d, want 1", got)
	}
	sess.Unsubscribe(b)
	if got := sess.SubscriberCount(); got != 0 {
		t.Fatalf("SubscriberCount after 2 unsubs = %d, want 0", got)
	}
}
