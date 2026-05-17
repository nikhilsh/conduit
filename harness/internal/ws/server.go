// Package ws implements the WebSocket protocol described in
// docs/WEBSOCKET-PROTOCOL.md. The wire format is byte-identical to
// upstream swe-swe so that swe-swe's own browser UI works against
// this server.
package ws

import (
	"bytes"
	"compress/gzip"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/harness/internal/auth"
	"github.com/nikhilsh/swe-kitty/harness/internal/session"
)

const (
	tagResize   byte = 0x00
	tagUpload   byte = 0x01
	tagSnapshot byte = 0x02
	tagEscape   byte = 0xFF
	snapChunk        = 32 * 1024
	pongWait         = 90 * time.Second
)

var upgrader = websocket.Upgrader{
	ReadBufferSize:  4096,
	WriteBufferSize: 4096,
	CheckOrigin:     func(r *http.Request) bool { return true },
}

type Server struct {
	Auth     *auth.Store
	Sessions *session.Manager
}

func New(a *auth.Store, m *session.Manager) *Server {
	return &Server{Auth: a, Sessions: m}
}

// Handler returns the registered HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/", s.serveWS)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	return mux
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	if !s.Auth.Check(r) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/ws/")
	if id == "" {
		http.Error(w, "missing session id", http.StatusBadRequest)
		return
	}
	assistant := r.URL.Query().Get("assistant")
	if assistant == "" {
		assistant = "claude"
	}
	sess, created, err := s.Sessions.GetOrCreate(id, assistant)
	if err != nil {
		status := http.StatusInternalServerError
		if strings.Contains(err.Error(), "unknown assistant") {
			status = http.StatusBadRequest
		}
		http.Error(w, "session: "+err.Error(), status)
		return
	}

	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		return
	}
	c := newClient(conn, sess)
	defer c.close()

	if err := c.sendStatus(assistant, created); err != nil {
		return
	}
	if !created {
		if err := c.sendSnapshot(sess.Snapshot()); err != nil {
			return
		}
	}

	sub := sess.Subscribe()
	textSub := sess.SubscribeText()
	defer sess.Unsubscribe(sub)
	defer sess.UnsubscribeText(textSub)

	go c.readLoop()
	c.writeLoop(sub, textSub, sess.Done())
}

// client wraps a websocket connection with a write mutex. gorilla
// requires single-writer.
type client struct {
	conn *websocket.Conn
	sess *session.Session
	wmu  sync.Mutex
	once sync.Once
}

func newClient(c *websocket.Conn, s *session.Session) *client {
	cl := &client{conn: c, sess: s}
	_ = c.SetReadDeadline(time.Now().Add(pongWait))
	c.SetPongHandler(func(string) error {
		return c.SetReadDeadline(time.Now().Add(pongWait))
	})
	return cl
}

func (c *client) close() { c.once.Do(func() { _ = c.conn.Close() }) }

func (c *client) writeBinary(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteMessage(websocket.BinaryMessage, b)
}

func (c *client) writeText(b []byte) error {
	c.wmu.Lock()
	defer c.wmu.Unlock()
	return c.conn.WriteMessage(websocket.TextMessage, b)
}

func (c *client) writeJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return c.writeText(b)
}

func (c *client) sendStatus(assistant string, created bool) error {
	phase := "running"
	if !created {
		phase = "running"
	}
	return c.writeJSON(map[string]any{
		"type":      "status",
		"session":   c.sess.ID,
		"viewers":   1,
		"rows":      40,
		"cols":      120,
		"assistant": assistant,
		"yolo":      false,
		"health":    "healthy",
		"phase":     phase,
		"ts":        time.Now().UTC().Format(time.RFC3339Nano),
	})
}

// sendSnapshot gzips `data` and emits one or more 0x02 chunked frames.
func (c *client) sendSnapshot(data []byte) error {
	if len(data) == 0 {
		return nil
	}
	var buf bytes.Buffer
	gw := gzip.NewWriter(&buf)
	if _, err := gw.Write(data); err != nil {
		return err
	}
	if err := gw.Close(); err != nil {
		return err
	}
	gz := buf.Bytes()
	total := (len(gz) + snapChunk - 1) / snapChunk
	for i := 0; i < total; i++ {
		end := (i + 1) * snapChunk
		if end > len(gz) {
			end = len(gz)
		}
		hdr := make([]byte, 5)
		hdr[0] = tagSnapshot
		binary.BigEndian.PutUint16(hdr[1:3], uint16(i))
		binary.BigEndian.PutUint16(hdr[3:5], uint16(total))
		frame := append(hdr, gz[i*snapChunk:end]...)
		if err := c.writeBinary(frame); err != nil {
			return err
		}
	}
	return nil
}

// readLoop pumps messages from the WebSocket into the session.
func (c *client) readLoop() {
	defer c.close()
	for {
		mt, payload, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		switch mt {
		case websocket.BinaryMessage:
			c.handleBinary(payload)
		case websocket.TextMessage:
			c.handleText(payload)
		}
	}
}

func (c *client) handleBinary(payload []byte) {
	if len(payload) == 0 {
		return
	}
	switch payload[0] {
	case tagResize:
		if len(payload) < 5 {
			return
		}
		rows := binary.BigEndian.Uint16(payload[1:3])
		cols := binary.BigEndian.Uint16(payload[3:5])
		_ = c.sess.Resize(rows, cols)
	case tagUpload:
		// File upload — out of v1 scope for task 001; just ignore.
	case tagEscape:
		// Escape byte for raw PTY that would otherwise collide with a tag.
		_, _ = c.sess.Write(payload[1:])
	default:
		// Raw PTY input.
		_, _ = c.sess.Write(payload)
	}
}

func (c *client) handleText(payload []byte) {
	var env struct {
		Type      string `json:"type"`
		Assistant string `json:"assistant"`
		Name      string `json:"name"`
	}
	if err := json.Unmarshal(payload, &env); err != nil {
		return
	}
	switch env.Type {
	case "ping":
		_ = c.writeJSON(map[string]any{"type": "pong", "ts": time.Now().UTC().Format(time.RFC3339Nano)})
	case "exit":
		c.sess.Close()
	case "switch_agent":
		if env.Assistant == "" {
			_ = c.writeJSON(map[string]any{
				"type": "chat",
				"msg":  "switch_agent requires assistant",
				"from": "system",
				"ts":   time.Now().UTC().Format(time.RFC3339Nano),
			})
			return
		}
		_ = c.writeJSON(map[string]any{
			"type":      "status",
			"session":   c.sess.ID,
			"viewers":   1,
			"rows":      40,
			"cols":      120,
			"assistant": c.sess.Assistant,
			"yolo":      false,
			"health":    "healthy",
			"phase":     "swapping",
			"ts":        time.Now().UTC().Format(time.RFC3339Nano),
		})
		if err := c.sess.SwitchAdapter(env.Assistant); err != nil {
			_ = c.writeJSON(map[string]any{
				"type": "chat",
				"msg":  err.Error(),
				"from": "system",
				"ts":   time.Now().UTC().Format(time.RFC3339Nano),
			})
			return
		}
		_ = c.writeJSON(map[string]any{
			"type":      "status",
			"session":   c.sess.ID,
			"viewers":   1,
			"rows":      40,
			"cols":      120,
			"assistant": c.sess.Assistant,
			"yolo":      false,
			"health":    "healthy",
			"phase":     "running",
			"ts":        time.Now().UTC().Format(time.RFC3339Nano),
		})
	case "rename_session", "toggle_yolo", "chat":
		// Acknowledged in v1 protocol but still no-op here.
	default:
		// Per protocol §3.3: unknown types are logged and ignored.
	}
}

// writeLoop forwards PTY output to the WebSocket and emits periodic pings.
func (c *client) writeLoop(sub chan []byte, textSub chan []byte, done <-chan struct{}) {
	defer c.close()
	ticker := time.NewTicker(30 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case chunk, ok := <-sub:
			if !ok {
				return
			}
			if len(chunk) > 0 && isReservedTag(chunk[0]) {
				chunk = append([]byte{tagEscape}, chunk...)
			}
			if err := c.writeBinary(chunk); err != nil {
				return
			}
		case payload, ok := <-textSub:
			if !ok {
				return
			}
			if err := c.writeText(payload); err != nil {
				return
			}
		case <-ticker.C:
			if err := c.writeJSON(map[string]any{"type": "ping", "ts": time.Now().UTC().Format(time.RFC3339Nano)}); err != nil {
				return
			}
		case <-done:
			_ = c.writeJSON(map[string]any{"type": "exit", "session": c.sess.ID, "code": 0})
			return
		}
	}
}

func isReservedTag(b byte) bool {
	return b == tagResize || b == tagUpload || b == tagSnapshot || b == tagEscape
}
