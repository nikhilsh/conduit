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
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/broker/internal/auth"
	"github.com/nikhilsh/swe-kitty/broker/internal/session"
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
	mux.HandleFunc("/api/capabilities", s.serveCapabilities)
	mux.HandleFunc("/api/session/start", s.serveSessionStart)
	mux.HandleFunc("/api/recent-projects", s.serveRecentProjects)
	mux.HandleFunc("/api/fs/list", s.serveFSList)
	return mux
}

func (s *Server) serveWS(w http.ResponseWriter, r *http.Request) {
	if !s.requireAuth(w, r) {
		return
	}
	id := strings.TrimPrefix(r.URL.Path, "/ws/")
	if id == "" {
		writeAPIError(w, http.StatusBadRequest, "missing_session_id", "missing session id")
		return
	}
	assistant := r.URL.Query().Get("assistant")
	if assistant == "" {
		assistant = "claude"
	}
	cwd := strings.TrimSpace(r.URL.Query().Get("cwd"))
	sess, created, err := s.Sessions.GetOrCreateWithOptions(id, assistant, session.CreateOptions{
		CWD: cwd,
	})
	if err != nil {
		msg := err.Error()
		switch {
		case strings.Contains(msg, "unknown assistant"):
			writeAPIError(w, http.StatusBadRequest, "assistant_unknown", msg)
		case strings.Contains(msg, "invalid cwd"):
			writeAPIError(w, http.StatusBadRequest, "invalid_cwd", msg)
		default:
			writeAPIError(w, http.StatusInternalServerError, "session_start_failed", msg)
		}
		return
	}

	// Initial client dimensions: prefer the rows/cols query params if
	// present (mobile clients pass these on connect). Falls back to
	// 0,0 — which makes SnapshotForSize use the session's current PTY
	// size. When the client subsequently sends a 0x00 resize frame with
	// different dimensions, handleBinary will emit a fresh snapshot
	// reflowed to that size, so the URL params are an optimization, not
	// a correctness requirement.
	initRows := parseDim(r.URL.Query().Get("rows"))
	initCols := parseDim(r.URL.Query().Get("cols"))

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
		if initRows != 0 && initCols != 0 {
			// Apply the hint so the agent's PTY sees the real viewport
			// immediately, and so SnapshotForSize reflows the grid.
			_ = sess.Resize(initRows, initCols)
		}
		snap := sess.SnapshotForSize(initRows, initCols)
		if err := c.sendSnapshot(snap); err != nil {
			return
		}
		// Mark that we've already shipped an initial snapshot; if the
		// client's first resize frame disagrees with what we used, we
		// re-emit a size-correct snapshot.
		c.snapshotRows, c.snapshotCols = initRows, initCols
		c.snapshotSent = true
	}

	sub := sess.Subscribe()
	textSub := sess.SubscribeText()
	defer sess.Unsubscribe(sub)
	defer sess.UnsubscribeText(textSub)

	go c.readLoop()
	c.writeLoop(sub, textSub, sess.Done())
}

// parseDim parses a uint16 dimension query param. Returns 0 on parse
// failure or out-of-range value (clients shouldn't pass either).
func parseDim(v string) uint16 {
	if v == "" {
		return 0
	}
	n, err := strconv.Atoi(v)
	if err != nil || n <= 0 || n > 65535 {
		return 0
	}
	return uint16(n)
}

// client wraps a websocket connection with a write mutex. gorilla
// requires single-writer.
type client struct {
	conn *websocket.Conn
	sess *session.Session
	wmu  sync.Mutex
	once sync.Once

	// snapshotSent records whether we've shipped an initial snapshot to
	// this client and at what dimensions, so we can re-emit a
	// size-correct snapshot if the first client resize disagrees.
	snapshotSent bool
	snapshotRows uint16
	snapshotCols uint16
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
	st := c.sess.Status()
	reason := st.ReasonCode
	if reason == "" {
		reason = "ok"
	}
	payload := map[string]any{
		"type":        "status",
		"session":     c.sess.ID,
		"viewers":     1,
		"rows":        40,
		"cols":        120,
		"assistant":   assistant,
		"yolo":        false,
		"health":      st.Health,
		"phase":       st.Phase,
		"reason_code": reason,
		"ts":          time.Now().UTC().Format(time.RFC3339Nano),
	}
	// Info-sheet fields. Optional so older clients ignore unknown
	// keys safely; the iOS/Android decoder reads them via #[serde(default)].
	if cwd := c.sess.WorkspaceDir(); cwd != "" {
		payload["cwd"] = cwd
	}
	if !st.StartedAt.IsZero() {
		payload["started_at"] = st.StartedAt.Format(time.RFC3339Nano)
	}
	if !st.LastOutput.IsZero() {
		payload["last_activity_at"] = st.LastOutput.Format(time.RFC3339Nano)
	}
	// `reasoning_effort` is a placeholder until adapter configs surface
	// it. iOS already shows "medium" as a fallback, so emitting the
	// same value is a no-op visually but keeps the schema consistent.
	payload["reasoning_effort"] = "medium"
	return c.writeJSON(payload)
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
		// If we shipped an initial snapshot at different (or unknown)
		// dimensions, re-emit a snapshot reflowed to the client's
		// just-declared size. Headless xterm.js makes this cheap.
		if c.snapshotSent && (c.snapshotRows != rows || c.snapshotCols != cols) {
			c.snapshotRows, c.snapshotCols = rows, cols
			c.snapshotSent = false // only re-emit once
			snap := c.sess.SnapshotForSize(rows, cols)
			_ = c.sendSnapshot(snap)
		}
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
		Msg       string `json:"msg"`
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
			"type":        "status",
			"session":     c.sess.ID,
			"viewers":     1,
			"rows":        40,
			"cols":        120,
			"assistant":   c.sess.Assistant,
			"yolo":        false,
			"health":      "healthy",
			"phase":       "swapping",
			"reason_code": "agent_switch_in_progress",
			"ts":          time.Now().UTC().Format(time.RFC3339Nano),
		})
		if err := c.sess.SwitchAdapter(env.Assistant); err != nil {
			_ = c.writeJSON(map[string]any{
				"type": "chat",
				"msg":  err.Error(),
				"from": "system",
				"ts":   time.Now().UTC().Format(time.RFC3339Nano),
			})
			// Don't leave the client stuck on phase=swapping: emit a
			// status frame that flips it back to running with the
			// previous assistant so the UI un-sticks. Reason code
			// surfaces in mobile telemetry for triage.
			_ = c.writeJSON(map[string]any{
				"type":        "status",
				"session":     c.sess.ID,
				"viewers":     1,
				"rows":        40,
				"cols":        120,
				"assistant":   c.sess.Assistant,
				"yolo":        false,
				"health":      "healthy",
				"phase":       "running",
				"reason_code": "agent_switch_failed",
				"ts":          time.Now().UTC().Format(time.RFC3339Nano),
			})
			return
		}
		_ = c.writeJSON(map[string]any{
			"type":        "status",
			"session":     c.sess.ID,
			"viewers":     1,
			"rows":        40,
			"cols":        120,
			"assistant":   c.sess.Assistant,
			"yolo":        false,
			"health":      "healthy",
			"phase":       "running",
			"reason_code": "agent_switched",
			"ts":          time.Now().UTC().Format(time.RFC3339Nano),
		})
	case "chat":
		// Route mobile chat sends into the agent's PTY stdin. Until we
		// wire a structured chat_event channel (AGENT_CHAT_PORT —
		// claude.toml/codex.toml define the env var but no agent
		// currently connects to it), this is how the agent actually
		// receives what the user typed. The reply comes back through
		// PTY output, which mobile renders in the terminal tab.
		// Mobile-side optimistic local echo (SessionStore.sendChat)
		// handles the chat-tab visibility for the outgoing message.
		if env.Msg != "" {
			// Prime the chat scraper to capture the agent's reply.
			// Must happen before the Write — drain may start producing
			// reply bytes immediately, and we want them captured.
			c.sess.MarkUserChatSent(env.Msg)
			// TUI agents (Claude, Codex) submit on CR, not LF — writing
			// "\n" left the typed text in the prompt without actually
			// being entered, forcing users to switch to the Terminal
			// tab and press Return manually.
			_, _ = c.sess.Write([]byte(env.Msg + "\r"))
		}
	case "rename_session", "toggle_yolo":
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
			st := c.sess.Status()
			_ = c.writeJSON(map[string]any{
				"type":        "exit",
				"session":     c.sess.ID,
				"code":        st.ExitCode,
				"reason_code": st.ReasonCode,
			})
			return
		}
	}
}

func isReservedTag(b byte) bool {
	return b == tagResize || b == tagUpload || b == tagSnapshot || b == tagEscape
}
