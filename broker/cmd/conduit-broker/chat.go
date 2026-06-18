package main

// runChat implements `conduit-broker chat [--list | <session-id>]`.
//
// It is a PURE CLIENT that talks the existing broker wire protocol over
// loopback — no imports of internal/session or internal/ws, no new HTTP
// routes, no new WS message types.  Architecture: §2 of
// docs/PLAN-SSH-CHAT-TAKEOVER.md.
//
// NOTE: until Phase 2 (push-gate fix, Option A) lands, attaching this CLI
// increments SubscriberCount and suppresses the phone's turn-done /
// pending-input push notifications while the CLI is connected.  This is
// acceptable for an owner-only, opt-in-by-running-a-command tool.

import (
	"bufio"
	"crypto/rand"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"

	"github.com/gorilla/websocket"
)

// --- wire types (read-only, no internal package imports) -----------------

// sessionListResponse mirrors the broker's GET /api/sessions body.
type sessionListResponse struct {
	Sessions    []sessionInfo `json:"sessions"`
	Recoverable []sessionInfo `json:"recoverable"`
}

type sessionInfo struct {
	ID        string `json:"id"`
	Assistant string `json:"assistant"`
	Phase     string `json:"phase"`
	Health    string `json:"health"`
	Running   bool   `json:"running"`
	Title     string `json:"title,omitempty"`
}

// convResponse mirrors GET /api/session/conversation/<id>.
type convResponse struct {
	Items    []convEntry `json:"items"`
	LatestTs int64       `json:"latest_ts"`
}

type convEntry struct {
	Role    string `json:"role"`
	Content string `json:"content"`
	Ts      string `json:"ts"`
}

// wsEnvelope is the minimal shape we parse from every incoming text frame.
type wsEnvelope struct {
	Type  string          `json:"type"`
	View  string          `json:"view"`
	Event json.RawMessage `json:"event"`
	// status top-level fields
	Session    string `json:"session"`
	Phase      string `json:"phase"`
	Health     string `json:"health"`
	Assistant  string `json:"assistant"`
	TurnActive bool   `json:"turn_active"`
	// chat_ack
	ClientMsgID string `json:"client_msg_id"`
	SessionID   string `json:"session_id"`
	// exit
	Code       int    `json:"code"`
	ReasonCode string `json:"reason_code"`
	// ping
	Ts string `json:"ts"`
}

// chatEvent is the `event` field inside view_event/view:"chat".
type chatEvent struct {
	Role    string `json:"role"`
	Content string `json:"content"`
	Ts      string `json:"ts"`
}

const (
	// Sentinel prefix defined in broker/internal/session/askcontrol.go:55
	pendingInputSentinel = "[[conduit:needs-input]]"

	// ANSI colour codes (cheap, no dependency)
	ansiReset  = "\033[0m"
	ansiGray   = "\033[90m"
	ansiGreen  = "\033[32m"
	ansiYellow = "\033[33m"
	ansiCyan   = "\033[36m"
	ansiBold   = "\033[1m"
)

// runChat is the entry point for `conduit-broker chat <args>`.
func runChat(args []string) int {
	fs := flag.NewFlagSet("chat", flag.ContinueOnError)
	addrFlag := fs.String("addr", "", "broker base URL (default http://127.0.0.1:1977, or CONDUIT_BROKER_ADDR)")
	tokenFlag := fs.String("token", "", "bearer token (default CONDUIT_TOKEN)")
	listFlag := fs.Bool("list", false, "list sessions and exit")
	tailFlag := fs.Int("tail", 50, "number of history messages to load on attach")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, `conduit-broker chat — tail and compose in a running session

Usage:
  conduit-broker chat [flags] <session-id>
  conduit-broker chat [flags] --list

Flags:`)
		fs.PrintDefaults()
		fmt.Fprintln(os.Stderr, `
In-session commands:
  /stop   interrupt the agent's current turn
  /quit   detach from the session (Ctrl-D also works)`)
	}
	if err := fs.Parse(args); err != nil {
		return 2
	}

	// --- resolve addr ---
	addr := strings.TrimSpace(*addrFlag)
	if addr == "" {
		addr = strings.TrimSpace(os.Getenv("CONDUIT_BROKER_ADDR"))
	}
	if addr == "" {
		addr = "http://127.0.0.1:1977"
	}
	addr = strings.TrimRight(addr, "/")

	// --- resolve token ---
	token := strings.TrimSpace(*tokenFlag)
	if token == "" {
		token = strings.TrimSpace(os.Getenv("CONDUIT_TOKEN"))
	}
	if token == "" {
		fmt.Fprintln(os.Stderr, "chat: no token: set --token or export CONDUIT_TOKEN")
		fmt.Fprintln(os.Stderr, "  hint: systemctl show -p Environment conduit-broker | tr ' ' '\\n' | grep CONDUIT_TOKEN")
		return 1
	}

	// --- list / validate session ---
	sessions, err := fetchSessions(addr, token)
	if err != nil {
		fmt.Fprintf(os.Stderr, "chat: fetch sessions: %v\n", err)
		return 1
	}

	if *listFlag || fs.NArg() == 0 {
		printSessionList(sessions)
		return 0
	}

	sessionID := fs.Arg(0)
	recoverable := validateSession(sessions, sessionID)
	if recoverable < 0 {
		// Not found at all
		fmt.Fprintf(os.Stderr, "chat: session %q not found\n", sessionID)
		fmt.Fprintln(os.Stderr, "  run: conduit-broker chat --list")
		return 1
	}
	if recoverable == 1 {
		fmt.Fprintf(os.Stderr, "chat: session %q is recoverable (not currently running); "+
			"attaching will spawn it\n", sessionID)
	}

	// --- attach loop (reconnects on WS close) ---
	log.SetFlags(0)
	log.SetPrefix("[chat] ")
	log.Printf("attaching to session %s addr=%s", sessionID, addr)
	log.Printf("NOTE: while attached, the phone's turn-done pushes are suppressed (Phase 2 fix pending)")

	return attachLoop(addr, token, sessionID, *tailFlag)
}

// attachLoop loads history + tails WS, reconnecting on close.
func attachLoop(addr, token, sessionID string, tail int) int {
	var latestTs int64

	// Phase: load initial history.
	entries, lt, err := fetchHistory(addr, token, sessionID, tail, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "chat: load history: %v\n", err)
		return 1
	}
	latestTs = lt
	renderHistory(entries)

	// stdin → send channel (unbuffered so Ctrl-D closes cleanly).
	inputCh := make(chan string)
	go func() {
		scanner := bufio.NewScanner(os.Stdin)
		for scanner.Scan() {
			inputCh <- scanner.Text()
		}
		close(inputCh)
	}()

	reconnects := 0
	for {
		log.Printf("connecting ws addr=%s session=%s (reconnect#%d)", addr, sessionID, reconnects)
		wsErr := tailWS(addr, token, sessionID, inputCh, &latestTs)

		if wsErr == io.EOF {
			// Session exit frame received — clean shutdown.
			return 0
		}
		if wsErr == errInputClosed {
			// User closed stdin — detach cleanly.
			log.Println("stdin closed; detaching")
			return 0
		}

		reconnects++
		if reconnects > 20 {
			fmt.Fprintln(os.Stderr, "chat: too many reconnects; giving up")
			return 1
		}

		delay := time.Duration(reconnects) * 500 * time.Millisecond
		if delay > 5*time.Second {
			delay = 5 * time.Second
		}
		log.Printf("WS closed (%v); reconnecting in %v …", wsErr, delay)
		time.Sleep(delay)

		// Re-load history since last seen timestamp.
		newEntries, lt, err := fetchHistory(addr, token, sessionID, tail, latestTs)
		if err != nil {
			log.Printf("history reload failed: %v", err)
		} else {
			if lt > latestTs {
				latestTs = lt
			}
			for _, e := range newEntries {
				renderEntry(e)
			}
		}
	}
}

// errInputClosed signals the stdin goroutine finished.
var errInputClosed = fmt.Errorf("stdin closed")

// tailWS opens the WS, fans out frames to stdout, and drives stdin → sends.
// Returns io.EOF on a clean session-exit frame, errInputClosed when stdin
// closes, or a WS error on unexpected close.
func tailWS(addr, token, sessionID string, inputCh <-chan string, latestTs *int64) error {
	wsURL := buildWSURL(addr, token, sessionID)
	log.Printf("dial %s", wsURL)

	conn, _, err := websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return fmt.Errorf("dial: %w", err)
	}
	defer conn.Close()

	// Breadcrumb: connected.
	log.Printf("connected session=%s", sessionID)

	// Outbound channel so the send goroutine and the ping ticker share the
	// write path (gorilla requires single-writer).
	sendCh := make(chan []byte, 16)

	// WS sender goroutine.
	sendDone := make(chan struct{})
	go func() {
		defer close(sendDone)
		for payload := range sendCh {
			if err := conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				log.Printf("ws write error: %v", err)
				return
			}
		}
	}()

	// Ping ticker.
	pingTicker := time.NewTicker(30 * time.Second)
	defer pingTicker.Stop()
	go func() {
		for range pingTicker.C {
			b, _ := json.Marshal(map[string]any{"type": "ping"})
			select {
			case sendCh <- b:
			default:
			}
		}
	}()

	// Read frames from WS.
	frameCh := make(chan []byte, 64)
	readDone := make(chan error, 1)
	go func() {
		for {
			mt, payload, err := conn.ReadMessage()
			if err != nil {
				readDone <- err
				return
			}
			if mt == websocket.BinaryMessage {
				// Discard PTY snapshot/stream frames.
				continue
			}
			if mt == websocket.TextMessage {
				p := make([]byte, len(payload))
				copy(p, payload)
				select {
				case frameCh <- p:
				default:
					// Drop if consumer is slow — same policy as broker's backpressure.
				}
			}
		}
	}()

	// Main select loop.
	for {
		select {
		case payload, ok := <-frameCh:
			if !ok {
				return fmt.Errorf("frame channel closed")
			}
			if done, wsErr := handleFrame(payload, latestTs); done {
				return wsErr
			}

		case line, ok := <-inputCh:
			if !ok {
				close(sendCh)
				return errInputClosed
			}
			if b := buildSend(line); b != nil {
				// Breadcrumb: send.
				log.Printf("send type=%s", msgType(line))
				select {
				case sendCh <- b:
				default:
					log.Printf("send buffer full; dropping")
				}
			}

		case err := <-readDone:
			return err
		}
	}
}

// handleFrame parses and renders one WS text frame.
// Returns (true, err) when the caller should exit the loop.
func handleFrame(payload []byte, latestTs *int64) (bool, error) {
	var env wsEnvelope
	if err := json.Unmarshal(payload, &env); err != nil {
		return false, nil
	}
	switch env.Type {
	case "view_event":
		switch env.View {
		case "chat":
			var ev chatEvent
			if err := json.Unmarshal(env.Event, &ev); err == nil {
				renderEntry(convEntry{Role: ev.Role, Content: ev.Content, Ts: ev.Ts})
				if ts := parseTsMillis(ev.Ts); ts > *latestTs {
					*latestTs = ts
				}
			}
		case "status":
			// Parse viewer count / phase from the view_event status mirror.
			var ev struct {
				ViewerCount int `json:"viewer_count"`
			}
			if err := json.Unmarshal(env.Event, &ev); err == nil && ev.ViewerCount > 0 {
				fmt.Printf("%s[status] viewers=%d%s\n", ansiGray, ev.ViewerCount, ansiReset)
			}
		}
	case "status":
		// Top-level status frame: print assistant + phase.
		if env.Assistant != "" || env.Phase != "" {
			fmt.Printf("%s[status] assistant=%s phase=%s%s\n",
				ansiGray, env.Assistant, env.Phase, ansiReset)
		}
	case "chat_ack":
		// Breadcrumb: ack received.
		log.Printf("ack client_msg_id=%s session=%s", env.ClientMsgID, env.SessionID)
	case "exit":
		fmt.Printf("\n%s[session exited: code=%d reason=%s]%s\n",
			ansiYellow, env.Code, env.ReasonCode, ansiReset)
		return true, io.EOF
	case "ping":
		// Broker-level JSON ping — no reply needed; gorilla handles protocol-level pings automatically.
	}
	return false, nil
}

// buildSend converts a stdin line into a wire frame.
// Returns nil for empty lines (no-op).
func buildSend(line string) []byte {
	line = strings.TrimRight(line, "\r\n")
	if line == "" {
		return nil
	}
	if line == "/stop" {
		b, _ := json.Marshal(map[string]any{"type": "stop"})
		return b
	}
	if line == "/quit" {
		return nil // handled by returning errInputClosed from caller
	}
	b, _ := json.Marshal(map[string]any{
		"type":          "chat",
		"msg":           line,
		"client_msg_id": newUUID(),
	})
	return b
}

// msgType returns a short type label for logging a stdin line.
func msgType(line string) string {
	if line == "/stop" {
		return "stop"
	}
	return "chat"
}

// --- rendering ------------------------------------------------------------

func renderHistory(entries []convEntry) {
	if len(entries) == 0 {
		fmt.Println(ansiGray + "(no history)" + ansiReset)
		return
	}
	fmt.Println(ansiGray + "--- history ---" + ansiReset)
	for _, e := range entries {
		renderEntry(e)
	}
	fmt.Println(ansiGray + "--- live ---" + ansiReset)
}

func renderEntry(e convEntry) {
	switch e.Role {
	case "assistant":
		content := e.Content
		if strings.HasPrefix(content, pendingInputSentinel) {
			// Strip sentinel line and render as AskUserQuestion card.
			content = strings.TrimPrefix(content, pendingInputSentinel)
			content = strings.TrimLeft(content, "\n")
			fmt.Printf("\n%s%s[ask] agent is waiting for input:%s\n%s\n%s\n",
				ansiBold, ansiYellow, ansiReset,
				content,
				ansiYellow+"(type your answer and press Enter)"+ansiReset)
			return
		}
		fmt.Printf("%sassistant:%s %s\n", ansiGreen, ansiReset, content)
	case "user":
		fmt.Printf("%suser:%s %s\n", ansiCyan, ansiReset, e.Content)
	case "tool":
		fmt.Printf("%s[tool] %s%s\n", ansiGray, e.Content, ansiReset)
	case "system":
		fmt.Printf("%s[system] %s%s\n", ansiYellow, e.Content, ansiReset)
	default:
		fmt.Printf("[%s] %s\n", e.Role, e.Content)
	}
}

// --- session list ---------------------------------------------------------

func printSessionList(sessions *sessionListResponse) {
	all := append(sessions.Sessions, sessions.Recoverable...)
	if len(all) == 0 {
		fmt.Println("(no sessions)")
		return
	}
	fmt.Printf("%-38s  %-10s  %-12s  %s\n", "ID", "ASSISTANT", "PHASE", "TITLE")
	fmt.Println(strings.Repeat("-", 80))
	for _, s := range all {
		marker := ""
		if s.Title == "" {
			s.Title = "(no title)"
		}
		fmt.Printf("%-38s  %-10s  %-12s  %s%s\n",
			s.ID, s.Assistant, s.Phase, s.Title, marker)
	}
}

// validateSession checks whether id exists.
// Returns: 0 = live, 1 = recoverable only, -1 = not found.
func validateSession(sessions *sessionListResponse, id string) int {
	for _, s := range sessions.Sessions {
		if s.ID == id {
			return 0
		}
	}
	for _, s := range sessions.Recoverable {
		if s.ID == id {
			return 1
		}
	}
	return -1
}

// --- HTTP helpers ---------------------------------------------------------

func fetchSessions(addr, token string) (*sessionListResponse, error) {
	resp, err := doGet(addr+"/api/sessions", token)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("GET /api/sessions status=%d", resp.StatusCode)
	}
	var out sessionListResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, fmt.Errorf("decode sessions: %w", err)
	}
	return &out, nil
}

// fetchHistory loads conversation history.  If sinceTs > 0 it polls for
// entries newer than that unix-millisecond cursor; otherwise it loads the
// last `tail` messages.
//
// Dedup note: callers accumulate latestTs and on reconnect call with that
// cursor, so entries already rendered are not duplicated. On a v1 gap at
// the seam (between REST load and WS attach) the duplicate live `chat`
// view_event for the same content+ts is visible — handleFrame also advances
// latestTs so a second REST poll would be clean, but we accept one possible
// dupe at the seam rather than adding a cursor compare on every frame.
func fetchHistory(addr, token, sessionID string, tail int, sinceTs int64) ([]convEntry, int64, error) {
	u := fmt.Sprintf("%s/api/session/conversation/%s", addr, sessionID)
	if sinceTs > 0 {
		u += fmt.Sprintf("?since_ts=%d", sinceTs)
	} else {
		u += fmt.Sprintf("?tail=%d", tail)
	}
	resp, err := doGet(u, token)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, 0, fmt.Errorf("GET conversation status=%d", resp.StatusCode)
	}
	var out convResponse
	if err := json.NewDecoder(resp.Body).Decode(&out); err != nil {
		return nil, 0, fmt.Errorf("decode conversation: %w", err)
	}
	return out.Items, out.LatestTs, nil
}

func doGet(rawURL, token string) (*http.Response, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	return http.DefaultClient.Do(req)
}

// buildWSURL converts an http base addr to the ws:// endpoint for a session.
// Deliberately omits device_id, rows, cols (§2.5 of the plan).
func buildWSURL(addr, token, sessionID string) string {
	wsBase := addr
	wsBase = strings.TrimPrefix(wsBase, "https://")
	wsBase = strings.TrimPrefix(wsBase, "http://")
	// Preserve scheme upgrade: https → wss, http → ws.
	scheme := "ws"
	if strings.HasPrefix(addr, "https://") {
		scheme = "wss"
	}
	u := url.URL{
		Scheme:   scheme,
		Host:     wsBase,
		Path:     "/ws/" + sessionID,
		RawQuery: "token=" + url.QueryEscape(token),
	}
	return u.String()
}

// --- utility --------------------------------------------------------------

// newUUID returns a random UUID v4 string.  We use crypto/rand so the
// client_msg_id is unpredictable and won't collide across reconnects.
func newUUID() string {
	var b [16]byte
	_, _ = rand.Read(b[:])
	b[6] = (b[6] & 0x0f) | 0x40 // version 4
	b[8] = (b[8] & 0x3f) | 0x80 // variant bits
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x",
		b[0:4], b[4:6], b[6:8], b[8:10], b[10:])
}

// parseTsMillis parses an RFC3339Nano timestamp and returns unix milliseconds.
// Returns 0 on error so callers can use it as "unknown / no update".
func parseTsMillis(ts string) int64 {
	if ts == "" {
		return 0
	}
	t, err := time.Parse(time.RFC3339Nano, ts)
	if err != nil {
		return 0
	}
	return t.UnixMilli()
}
