// Package ws implements the WebSocket protocol described in
// docs/WEBSOCKET-PROTOCOL.md. The wire format is byte-identical to
// upstream swe-swe so that swe-swe's own browser UI works against
// this server.
package ws

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/binary"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/nikhilsh/swe-kitty/broker/internal/auth"
	"github.com/nikhilsh/swe-kitty/broker/internal/credentials"
	"github.com/nikhilsh/swe-kitty/broker/internal/oauth"
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
	// Credentials is the per-identity OAuth credential store wired in
	// at broker startup. Nil-safe: when nil, set_agent_credentials
	// control messages are rejected with a chat error and the session
	// spawn path falls back to the legacy global host-mirror.
	Credentials *credentials.Store
	// OAuth drives the v2 server-side login flow (PLAN-AGENT-OAUTH.md
	// "Approach v2 — litter-faithful"). Spawns `codex login` or
	// `claude auth login` on the broker host, ferries the phone's
	// captured `?code=...` query string to the CLI's loopback. Nil-safe:
	// when nil, start_agent_login / agent_login_callback /
	// cancel_agent_login control messages are rejected with a chat-tool
	// error and the wire stays open.
	OAuth *oauth.Manager
}

func New(a *auth.Store, m *session.Manager) *Server {
	s := &Server{Auth: a, Sessions: m}
	currentServer = s
	return s
}

// WithCredentials wires the per-identity credential store into the
// server. Called from cmd/swe-kitty-broker/main.go after the store is
// constructed. Returning the same *Server keeps the call site fluent.
func (s *Server) WithCredentials(store *credentials.Store) *Server {
	s.Credentials = store
	if s.Sessions != nil {
		s.Sessions.SetCredentialStore(store)
	}
	return s
}

// WithOAuth wires the v2 login-session manager into the server. Same
// fluent style as WithCredentials. Nil-safe: a server constructed
// without WithOAuth simply rejects start_agent_login control messages
// with a chat-tool error.
func (s *Server) WithOAuth(mgr *oauth.Manager) *Server {
	s.OAuth = mgr
	return s
}

// Handler returns the registered HTTP handler.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/ws/", s.serveWS)
	// /health stays as a soft liveness probe — returns 200 as long as
	// the broker is responding. Kept the trailing newline for
	// curl-script compatibility.
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok\n"))
	})
	// /healthz is the strict probe — returns 200 only when every
	// expected subsystem (broker + sidecar, when present) is
	// answering. Use this for systemd / k8s liveness checks; the
	// response body is JSON with per-component detail so silent
	// degradation surfaces in the operator's logs.
	mux.HandleFunc("/healthz", s.serveHealthz)
	mux.HandleFunc("/api/capabilities", s.serveCapabilities)
	mux.HandleFunc("/api/session/start", s.serveSessionStart)
	mux.HandleFunc("/api/recent-projects", s.serveRecentProjects)
	mux.HandleFunc("/api/fs/list", s.serveFSList)
	return mux
}

func (s *Server) serveHealthz(w http.ResponseWriter, r *http.Request) {
	h := s.Sessions.Health()
	body := map[string]any{
		"live":             h.Live,
		"sidecar_expected": h.SidecarExpected,
		"sidecar_healthy":  h.SidecarHealthy,
	}
	if h.SidecarError != "" {
		body["sidecar_error"] = h.SidecarError
	}
	w.Header().Set("Content-Type", "application/json")
	// Degraded state — sidecar was expected but isn't answering. 503
	// is the right code; load balancers and systemd Restart=on-failure
	// can act on it.
	if h.SidecarExpected && !h.SidecarHealthy {
		w.WriteHeader(http.StatusServiceUnavailable)
	}
	_ = json.NewEncoder(w).Encode(body)
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
	// Defer cleanup ordering matters: unsubscribe FIRST so the
	// SubscriberCount reflects the post-leave total when we
	// broadcast. tied to function return; gorilla's read/write loops
	// both exit via c.close() which ripples back here.
	defer func() {
		sess.Unsubscribe(sub)
		sess.UnsubscribeText(textSub)
		emitViewerStatus(sess)
	}()

	// Announce the new viewer to every subscriber. Subscribe happens
	// before this call so SubscriberCount already includes us; our
	// own writeLoop will forward this view_event back through textSub.
	emitViewerStatus(sess)

	go c.readLoop()
	c.writeLoop(sub, textSub, sess.Done())
}

// emitViewerStatus broadcasts a `view: "status"` view_event reflecting
// the current viewer_count + PTY dimensions. Optional `display_name`
// is omitted until rename_session lands the persistence side; older
// clients ignore unknown keys, so adding it later is wire-safe.
func emitViewerStatus(sess *session.Session) {
	rows, cols := sess.Dimensions()
	event := map[string]any{
		"viewer_count": sess.SubscriberCount(),
	}
	if rows > 0 {
		event["terminal_rows"] = rows
	}
	if cols > 0 {
		event["terminal_cols"] = cols
	}
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": sess.ID,
		"view":    "status",
		"event":   event,
		"ts":      time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	sess.PublishText(payload)
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
	// viewers reflects existing subscribers PLUS this one — we haven't
	// called Subscribe() yet on the connect path, but the client is
	// definitely about to count itself as a viewer. Add 1 so the very
	// first status frame agrees with the view_event mirror's
	// viewer_count emitted right after Subscribe.
	viewers := c.sess.SubscriberCount() + 1
	rows, cols := c.sess.Dimensions()
	if rows == 0 {
		rows = 40
	}
	if cols == 0 {
		cols = 120
	}
	payload := map[string]any{
		"type":        "status",
		"session":     c.sess.ID,
		"viewers":     viewers,
		"rows":        rows,
		"cols":        cols,
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
	// Per-agent reasoning effort comes from the adapter toml. Fall
	// back to "medium" when the toml didn't specify one, so the iOS
	// pill stays stable regardless of which agents are installed.
	if effort := c.sess.ReasoningEffort(); effort != "" {
		payload["reasoning_effort"] = effort
	} else {
		payload["reasoning_effort"] = "medium"
	}
	// Human-readable label set by `rename_session` (protocol §3.3).
	// Emitted as both `session_name` (top-level mirror) and
	// `display_name` — older clients ignore unknown keys, newer ones
	// can switch their title binding without a flag day.
	if name := c.sess.DisplayName(); name != "" {
		payload["session_name"] = name
		payload["display_name"] = name
	}
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
		// 0x01 file-upload frame (sweswe-parity #file-upload). Decode,
		// validate the embedded session id against the socket's bound
		// session, sanitize the filename, then land the bytes under
		// <workspace>/uploads/<session>/<filename>.
		//
		// Errors here never close the socket — chat-driven uploads
		// are user-visible; surfacing the failure as a tool view_event
		// is enough. The protocol's "forbidden first byte" rules only
		// fire on shape violations of the tag itself (truncated frames
		// fall through to a no-op).
		frame, err := parseUploadFrame(payload[1:])
		if err != nil {
			c.emitUploadToolEvent("upload rejected: " + err.Error())
			return
		}
		if frame.SessionID != c.sess.ID {
			c.emitUploadToolEvent("upload rejected: session id mismatch")
			return
		}
		dst, err := writeUpload(c.sess.WorkspaceDir(), frame.SessionID, frame.Filename, frame.Body)
		if err != nil {
			c.emitUploadToolEvent("upload rejected: " + err.Error())
			return
		}
		c.emitUploadToolEvent("uploaded " + dst + " (" + frame.MIME + ", " + strconv.Itoa(len(frame.Body)) + " bytes)")
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
		// set_agent_credentials (docs/PLAN-AGENT-OAUTH.md §D.1). Body
		// fields are decoded into the same envelope to keep the
		// switch-on-type contract simple; unrelated control messages
		// just ignore them.
		Provider   string          `json:"provider"`
		Kind       string          `json:"kind"`
		Credential json.RawMessage `json:"credential"`
		// v2 agent-login fields (PLAN-AGENT-OAUTH.md "Approach v2"):
		//   start_agent_login uses Provider.
		//   agent_login_callback uses SessionToken + QueryString.
		//   cancel_agent_login uses SessionToken.
		// All three messages reuse Provider/SessionToken/QueryString
		// rather than carrying a nested object; protocol §3.3 forward-
		// extensibility lets us add fields without a flag day.
		SessionToken string `json:"session_token"`
		QueryString  string `json:"query_string"`
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
	case "rename_session":
		// Protocol §3.3: validate against `^[A-Za-z0-9 _-]{1,32}$`,
		// last-writer-wins, no ack. Invalid renames are silently
		// dropped (the socket stays open). On success, broadcast a
		// fresh status envelope + view_event status mirror to every
		// subscriber so multi-viewer UIs converge instantly.
		if !c.sess.SetDisplayName(env.Name) {
			return
		}
		c.broadcastRenameStatus()
	case "toggle_yolo":
		// Acknowledged in v1 protocol but still no-op here.
	case "set_agent_credentials":
		// Per-user OAuth landing path (docs/PLAN-AGENT-OAUTH.md §D.1).
		// The WS upgrade already required a valid bearer (serveWS
		// requireAuth), so by the time we're here the connection is
		// authenticated; we don't recheck. But we DO guard against a
		// broker that was started without --credentials-dir wiring —
		// in that mode the control message is structurally valid but
		// the broker has nowhere to put the blob, so we surface a
		// chat error instead of silently dropping it.
		c.handleSetAgentCredentials(env.Provider, env.Kind, env.Credential)
	case "start_agent_login":
		// v2 agent-login entry point (PLAN-AGENT-OAUTH.md "Approach
		// v2 — litter-faithful"). Spawns the CLI's own login
		// subcommand on the broker host, captures the authorize URL,
		// and emits an `agent_login_url` view_event so the phone can
		// open the URL in ASWebAuthenticationSession / CustomTabs.
		c.handleStartAgentLogin(env.Provider)
	case "agent_login_callback":
		// Phone finished the browser flow and captured the
		// `?code=...&state=...` query string on its local 127.0.0.1
		// loopback. The broker ferries that query string to the CLI's
		// own loopback (running on the broker host) so the CLI sees a
		// "normal" redirect and performs the token exchange itself.
		c.handleAgentLoginCallback(env.SessionToken, env.QueryString)
	case "cancel_agent_login":
		// Phone aborted (user dismissed the sheet, browser failed,
		// timeout). Kill the CLI subprocess so we don't leak a
		// listening loopback. Silent no-op when the token is unknown.
		c.handleCancelAgentLogin(env.SessionToken)
	default:
		// Per protocol §3.3: unknown types are logged and ignored.
	}
}

// handleSetAgentCredentials validates a set_agent_credentials control
// frame and either stores the blob (success) or surfaces a chat-tool
// error frame (failure). On success, broadcasts a typed view_event
// carrying `agent_credentials_refreshed: { provider }` so the phone
// learns that the credential landed without needing a separate ack.
//
// Failure cases are emitted as `view_event { view: "chat", role: "tool" }`
// (matching the file-upload rejection idiom) so they show up in the
// chat tab and don't crash the socket — the protocol's forward-extensibility
// rule (§3.3) treats unknown / invalid control payloads as soft errors.
func (c *client) handleSetAgentCredentials(provider, kind string, credential json.RawMessage) {
	server := c.serverRef()
	if server == nil || server.Credentials == nil {
		c.emitCredentialsToolEvent("set_agent_credentials rejected: broker has no credentials store configured")
		return
	}
	if !credentials.ValidProvider(provider) {
		c.emitCredentialsToolEvent("set_agent_credentials rejected: unknown provider " + provider)
		return
	}
	// Stage 1 only ships the oauth kind. Future kinds (api_key,
	// signed_jwt, etc.) will key off this field; reject anything else
	// up front so the wire schema fails loudly when the protocol
	// extends.
	if kind != "oauth" {
		c.emitCredentialsToolEvent("set_agent_credentials rejected: unsupported kind " + kind)
		return
	}
	if len(credential) == 0 {
		c.emitCredentialsToolEvent("set_agent_credentials rejected: empty credential payload")
		return
	}
	if err := server.Credentials.Set(provider, credential); err != nil {
		c.emitCredentialsToolEvent("set_agent_credentials failed: " + err.Error())
		return
	}
	// Success path: broadcast a status mirror so every viewer learns
	// the credential landed. Routed through the session's text
	// fan-out so multi-viewer surfaces stay consistent.
	c.broadcastCredentialsRefreshed(provider)
}

// serverRef walks back to the parent Server. Right now the client
// struct doesn't hold a server pointer, so we stash it on the session
// manager via a package-level accessor — simpler than rewiring every
// client constructor for one field. The set_agent_credentials path is
// the only consumer.
func (c *client) serverRef() *Server { return currentServer }

// currentServer is the package-level handle to the active Server.
// Updated by New() so handleSetAgentCredentials can find the credentials
// store without threading a *Server pointer through every client. The
// broker today runs exactly one Server per process; if that ever
// changes we'll need to push this onto the client.
var currentServer *Server

// emitCredentialsToolEvent surfaces a credentials-rejection message
// through the chat-tool view_event channel, matching the file-upload
// rejection idiom in handleBinary.
func (c *client) emitCredentialsToolEvent(message string) {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "chat",
		"event": map[string]any{
			"role":      "tool",
			"content":   message,
			"ts":        time.Now().UTC().Format(time.RFC3339Nano),
			"files":     []any{},
			"tool_name": "set_agent_credentials",
		},
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
}

// broadcastCredentialsRefreshed emits the success-side view_event the
// client uses to confirm the blob landed. The shape mirrors the §D.1
// `agent_credentials_refreshed` server → client message but is routed
// through the typed view_event channel for consistency with other
// fan-out frames (see protocol §3.2).
func (c *client) broadcastCredentialsRefreshed(provider string) {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "status",
		"event": map[string]any{
			"agent_credentials_refreshed": map[string]any{
				"provider": provider,
			},
		},
		"ts": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
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

// broadcastRenameStatus serializes a fresh `status` envelope plus the
// typed `view_event { view: "status" }` mirror (per protocol §3.2 +
// §3.3) and fans both out to every viewer attached to the session.
// Used right after a successful `rename_session` so the new label
// reaches everyone — including the originating client — without
// waiting for the next periodic status refresh.
func (c *client) broadcastRenameStatus() {
	st := c.sess.Status()
	reason := st.ReasonCode
	if reason == "" {
		reason = "ok"
	}
	displayName := c.sess.DisplayName()

	statusPayload := map[string]any{
		"type":        "status",
		"session":     c.sess.ID,
		"viewers":     1,
		"rows":        40,
		"cols":        120,
		"assistant":   c.sess.Assistant,
		"yolo":        false,
		"health":      st.Health,
		"phase":       st.Phase,
		"reason_code": reason,
		"ts":          time.Now().UTC().Format(time.RFC3339Nano),
	}
	if cwd := c.sess.WorkspaceDir(); cwd != "" {
		statusPayload["cwd"] = cwd
	}
	if !st.StartedAt.IsZero() {
		statusPayload["started_at"] = st.StartedAt.Format(time.RFC3339Nano)
	}
	if !st.LastOutput.IsZero() {
		statusPayload["last_activity_at"] = st.LastOutput.Format(time.RFC3339Nano)
	}
	if effort := c.sess.ReasoningEffort(); effort != "" {
		statusPayload["reasoning_effort"] = effort
	} else {
		statusPayload["reasoning_effort"] = "medium"
	}
	if displayName != "" {
		statusPayload["session_name"] = displayName
		statusPayload["display_name"] = displayName
	}
	if b, err := json.Marshal(statusPayload); err == nil {
		c.sess.PublishText(b)
	}

	mirror := map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "status",
		"event": map[string]any{
			"display_name": displayName,
		},
		"ts": time.Now().UTC().Format(time.RFC3339Nano),
	}
	if b, err := json.Marshal(mirror); err == nil {
		c.sess.PublishText(b)
	}
}

// handleStartAgentLogin spawns the CLI login subprocess on the broker
// and emits an `agent_login_url` view_event on success. On any failure
// (no OAuth manager wired, unknown provider, CLI not on PATH, URL
// parse timeout) it emits an `agent_login_failed` view_event with a
// human-readable reason so the phone sheet can surface the issue.
//
// Started as a goroutine so the WS read loop isn't blocked while
// `codex login` warms up (typically <500ms, but the parse timeout is
// 15s in the worst case — see oauth.scanAuthorizeURL).
func (c *client) handleStartAgentLogin(provider string) {
	server := c.serverRef()
	if server == nil || server.OAuth == nil {
		c.emitAgentLoginFailed(provider, "broker has no oauth manager configured")
		return
	}
	if oauth.ProviderFor(provider) == nil {
		c.emitAgentLoginFailed(provider, "unknown provider: "+provider)
		return
	}
	// Run the spawn off the WS read loop. The handler returns
	// immediately; the view_event arrives whenever Start completes.
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		sess, err := server.OAuth.StartSession(ctx, provider)
		if err != nil {
			c.emitAgentLoginFailed(provider, err.Error())
			return
		}
		c.emitAgentLoginURL(sess)
	}()
}

// handleAgentLoginCallback delivers the phone's captured query string
// to the CLI's loopback via the OAuth manager. Bounded by the
// manager's internal 30s wait on the CLI exit (see Session.Forward).
// On success emits `agent_login_complete { ok: true }`; on any error
// emits `agent_login_failed`.
func (c *client) handleAgentLoginCallback(sessionToken, queryString string) {
	server := c.serverRef()
	if server == nil || server.OAuth == nil {
		c.emitAgentLoginFailed("", "broker has no oauth manager configured")
		return
	}
	if strings.TrimSpace(sessionToken) == "" {
		c.emitAgentLoginFailed("", "agent_login_callback missing session_token")
		return
	}
	go func() {
		if err := server.OAuth.ForwardCallback(sessionToken, queryString); err != nil {
			c.emitAgentLoginFailed("", "forward callback: "+err.Error())
			return
		}
		c.emitAgentLoginComplete()
	}()
}

// handleCancelAgentLogin kills the CLI subprocess for the named
// session_token. No view_event reply — the phone already knows it
// aborted. Silent no-op when the token is unknown.
func (c *client) handleCancelAgentLogin(sessionToken string) {
	server := c.serverRef()
	if server == nil || server.OAuth == nil {
		return
	}
	if strings.TrimSpace(sessionToken) == "" {
		return
	}
	server.OAuth.CancelSession(sessionToken)
}

// emitAgentLoginURL fans out the `agent_login_url` view_event carrying
// the broker-issued session_token + authorize URL + loopback port.
// Shape pinned in PLAN-AGENT-OAUTH.md "Approach v2" wire section.
func (c *client) emitAgentLoginURL(sess *oauth.Session) {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "status",
		"event": map[string]any{
			"agent_login_url": map[string]any{
				"provider":      sess.Provider,
				"url":           sess.AuthorizeURL,
				"loopback_port": sess.LoopbackPort,
				"session_token": sess.SessionToken,
			},
		},
		"ts": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
}

// emitAgentLoginComplete signals the phone that the CLI finished the
// token exchange and wrote the on-disk credential file. The phone
// can then dismiss its login sheet and trust that the next session
// the broker spawns will inherit the new credentials (PR #106's
// per-session HOME materialization).
func (c *client) emitAgentLoginComplete() {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "status",
		"event": map[string]any{
			"agent_login_complete": map[string]any{
				"ok": true,
			},
		},
		"ts": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
}

// emitAgentLoginFailed reports an error to the phone via the typed
// view_event channel. The `provider` field may be empty when the
// failure happened before we even knew which provider (e.g. missing
// oauth manager wiring); the phone falls back to a generic message
// in that case.
func (c *client) emitAgentLoginFailed(provider, reason string) {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "status",
		"event": map[string]any{
			"agent_login_failed": map[string]any{
				"provider": provider,
				"reason":   reason,
			},
		},
		"ts": time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
}

// emitUploadToolEvent broadcasts a `view_event { view: "chat" }` with
// role=tool noting the result of a file upload (success or rejection).
// Routed through the session's text fan-out so every viewer of the
// session sees the same tool turn — matches the chat scraper's own
// publish path.
func (c *client) emitUploadToolEvent(message string) {
	payload, err := json.Marshal(map[string]any{
		"type":    "view_event",
		"session": c.sess.ID,
		"view":    "chat",
		"event": map[string]any{
			"role":      "tool",
			"content":   message,
			"ts":        time.Now().UTC().Format(time.RFC3339Nano),
			"files":     []any{},
			"tool_name": "file_upload",
		},
	})
	if err != nil {
		return
	}
	c.sess.PublishText(payload)
}
