package ws

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/harness/internal/auth"
	"github.com/nikhilsh/swe-kitty/harness/internal/session"
)

func newTestServer(t *testing.T) (*httptest.Server, string) {
	t.Helper()
	a := auth.NewStore()
	tok := a.Mint()
	m := session.NewManager()
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok
}

func dial(t *testing.T, srv *httptest.Server, sessID, tok string) *websocket.Conn {
	t.Helper()
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws/" + sessID + "?assistant=claude&token=" + tok
	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return conn
}

func TestUnauthorizedRejected(t *testing.T) {
	srv, _ := newTestServer(t)
	wsURL := "ws" + strings.TrimPrefix(srv.URL, "http") + "/ws/abc?assistant=claude"
	_, resp, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err == nil {
		t.Fatal("expected dial to fail without token")
	}
	if resp == nil || resp.StatusCode != 401 {
		t.Fatalf("expected 401, got %v", resp)
	}
}

func TestStatusFrameOnConnect(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-000000000001", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	mt, payload, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if mt != websocket.TextMessage {
		t.Fatalf("expected text status, got mt=%d", mt)
	}
	var env map[string]any
	if err := json.Unmarshal(payload, &env); err != nil {
		t.Fatalf("json: %v", err)
	}
	if env["type"] != "status" {
		t.Fatalf("expected type=status, got %v", env["type"])
	}
}

func TestPingPong(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-000000000002", tok)
	// Drain the status frame first.
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatal(err)
	}
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	mt, payload, err := c.ReadMessage()
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	if mt != websocket.TextMessage {
		t.Fatalf("expected pong text, got mt=%d", mt)
	}
	var env map[string]any
	_ = json.Unmarshal(payload, &env)
	if env["type"] != "pong" {
		t.Fatalf("expected pong, got %v", env["type"])
	}
}

func TestPTYEcho(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-000000000003", tok)
	// Drain status.
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	// Send "echo hi\n" as raw PTY (no tag byte; 'e' = 0x65, not reserved).
	if err := c.WriteMessage(websocket.BinaryMessage, []byte("echo hi\n")); err != nil {
		t.Fatal(err)
	}

	deadline := time.Now().Add(3 * time.Second)
	var out bytes.Buffer
	for time.Now().Before(deadline) {
		_ = c.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		mt, payload, err := c.ReadMessage()
		if err != nil {
			break
		}
		if mt == websocket.BinaryMessage {
			out.Write(payload)
			if strings.Contains(out.String(), "hi") {
				return
			}
		}
	}
	t.Fatalf("did not observe 'hi' echo within deadline; got: %q", out.String())
}

func TestResizeFrameValid(t *testing.T) {
	srv, tok := newTestServer(t)
	c := dial(t, srv, "00000000-0000-0000-0000-000000000004", tok)
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c.ReadMessage()

	buf := make([]byte, 5)
	buf[0] = 0x00 // tagResize
	binary.BigEndian.PutUint16(buf[1:3], 50)
	binary.BigEndian.PutUint16(buf[3:5], 200)
	if err := c.WriteMessage(websocket.BinaryMessage, buf); err != nil {
		t.Fatalf("write resize: %v", err)
	}
	// Resize never produces a frame in response; just ensure the socket
	// stays open by sending a ping after.
	if err := c.WriteMessage(websocket.TextMessage, []byte(`{"type":"ping"}`)); err != nil {
		t.Fatalf("write ping: %v", err)
	}
	_ = c.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, _, err := c.ReadMessage(); err != nil {
		t.Fatalf("connection closed after resize: %v", err)
	}
}

func TestSnapshotRoundtripOnRejoin(t *testing.T) {
	srv, tok := newTestServer(t)
	sessID := "00000000-0000-0000-0000-000000000005"

	// First client: create session, send some input that produces output,
	// then disconnect.
	c1 := dial(t, srv, sessID, tok)
	_ = c1.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c1.ReadMessage() // status

	if err := c1.WriteMessage(websocket.BinaryMessage, []byte("echo marker_text\n")); err != nil {
		t.Fatal(err)
	}
	// Drain for a bit to let the PTY produce output.
	deadline := time.Now().Add(2 * time.Second)
	saw := false
	for time.Now().Before(deadline) && !saw {
		_ = c1.SetReadDeadline(time.Now().Add(300 * time.Millisecond))
		_, payload, err := c1.ReadMessage()
		if err != nil {
			break
		}
		if bytes.Contains(payload, []byte("marker_text")) {
			saw = true
		}
	}
	_ = c1.Close()
	if !saw {
		t.Fatal("first client never saw marker_text echo")
	}

	// Second client: rejoin same session, expect a 0x02 snapshot frame
	// whose gunzipped payload contains marker_text.
	c2 := dial(t, srv, sessID, tok)
	_ = c2.SetReadDeadline(time.Now().Add(2 * time.Second))
	_, _, _ = c2.ReadMessage() // status

	var gzbuf bytes.Buffer
	var totalChunks int
	gotChunks := 0
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		_ = c2.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
		mt, payload, err := c2.ReadMessage()
		if err != nil {
			break
		}
		if mt != websocket.BinaryMessage || len(payload) < 5 || payload[0] != 0x02 {
			continue
		}
		idx := binary.BigEndian.Uint16(payload[1:3])
		total := binary.BigEndian.Uint16(payload[3:5])
		if int(idx) != gotChunks {
			t.Fatalf("snapshot chunk out of order: idx=%d expected=%d", idx, gotChunks)
		}
		gzbuf.Write(payload[5:])
		gotChunks++
		totalChunks = int(total)
		if gotChunks == totalChunks {
			break
		}
	}
	if totalChunks == 0 {
		t.Fatal("never received any snapshot chunks")
	}
	gr, err := gzip.NewReader(&gzbuf)
	if err != nil {
		t.Fatalf("gunzip: %v", err)
	}
	out := new(bytes.Buffer)
	_, _ = out.ReadFrom(gr)
	if !bytes.Contains(out.Bytes(), []byte("marker_text")) {
		t.Fatalf("snapshot missing marker_text; got: %q", out.String())
	}
}

func TestEscapeByteOnPTYOutput(t *testing.T) {
	// Smoke-test isReservedTag — full PTY-escape integration is
	// hard to drive deterministically from shell output.
	if !isReservedTag(0x00) || !isReservedTag(0x01) || !isReservedTag(0x02) || !isReservedTag(0xFF) {
		t.Fatal("reserved tags not flagged")
	}
	if isReservedTag('a') {
		t.Fatal("'a' should not be flagged as reserved")
	}
}
