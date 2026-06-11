package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// This file is the opencode-server backend — the pilot of the Phase-2
// AgentBackend platform for an agent whose integration surface is an HTTP
// server (`opencode serve`) rather than stdio (claude stream-json, codex
// app-server). One long-lived `opencode serve --port <alloc> --hostname
// 127.0.0.1` per session hosts the conversation; the backend creates a
// `ses_…` via POST /session, streams GET /event (SSE) → chat events, sends
// turns with POST /session/{id}/prompt_async, interrupts with
// /session/{id}/abort, and resumes by persisting the ses_ id (meta.json,
// riding the CodexThreadID slot) and re-prompting it after a restart.
//
// Wire protocol: docs/OPENCODE-PROTOCOL.md (opencode 1.17.0), cross-checked
// live against the no-auth "OpenCode Zen" free provider. The pure parsers live
// in backend_opencodewire.go (table-tested); this file owns the process + HTTP
// + SSE I/O.

// --- backend registration ---

// opencodeBackend is the AgentBackend for protocol "opencode-server". Capabilities:
// no usage (scoped out), no compact/ask/effort in v1, resume + interrupt yes.
type opencodeBackend struct{}

func init() { registerBackend("opencode-server", opencodeBackend{}) }

func (opencodeBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         false, // /session/{id}/summarize exists; a follow-up
		AskUserQuestion: false, // /permissions reply exists; a follow-up
		Effort:          false, // model variants carry effort; not wired in v1
		Resume:          true,  // global session store, re-prompt the same ses_
		Interrupt:       true,  // POST /session/{id}/abort
		Usage:           false, // scoped out (zen models report cost:0 anyway)
	}
}

// CatalogProbe spawns a throwaway `opencode serve`, GETs /config/providers, and
// maps it to ModelInfo (providerID/modelID). It runs the server because the
// structured catalog lives behind the HTTP surface; the server is killed when
// the probe returns.
func (opencodeBackend) CatalogProbe(ctx context.Context, bin string) ([]ModelInfo, error) {
	return probeOpencodeCatalog(ctx, bin)
}

// Usage is unsupported for opencode (Capabilities.Usage=false), so the session
// never fires a doomed fetch.
func (opencodeBackend) Usage(ctx context.Context, do httpDoFunc, homeDir string) (AccountUsage, bool, error) {
	return AccountUsage{}, false, nil
}

// Spawn launches the session's long-lived `opencode serve`, creates (or
// resumes) a session, and wires the SSE reader into the chat channel. The
// resumeCodexThreadID slot carries the persisted ses_ id (the generic "agent's
// own conversation id" — opencode reuses codex's plumbing). On a hard spawn
// failure the error is returned so chat is disabled gracefully (the PTY tab is
// unaffected), matching the other backends.
func (opencodeBackend) Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error) {
	// Seed the persisted ses_ id (recovery) and clear any prior respawn — like
	// codexSeedThread. The backend's own latch (s.latchCodexThreadID) persists
	// the id once POST /session returns it.
	s.mu.Lock()
	s.codexThreadID = req.resumeCodexThreadID
	s.chatRespawn = nil
	s.mu.Unlock()

	proc, err := newOpencodeServerProcess(
		adapter.Command[0],
		adapter.Args,
		s.workspaceDir,
		s.commandEnv(nil),
		s.PublishText,
		req.resumeCodexThreadID,
		s.latchCodexThreadID,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "session %s: opencode serve spawn failed: %v (chat disabled)\n", s.ID, err)
		return spawnResult{}, err
	}
	wireOpencodeTurnHook(s, req.aiGen, proc)
	return spawnResult{backend: proc}, nil
}

// wireOpencodeTurnHook builds the per-session AI-niceties generators (titles +
// quick replies) and attaches them to the opencode backend via its native
// setTurnHook. nil aiGen → nil generators → the hook no-ops, so an opencode
// session with no creds behaves identically. Twin of wireCodexTurnHook.
func wireOpencodeTurnHook(s *Session, aiGen aiGenProvider, proc *opencodeServerProcess) {
	qrGen := newQuickReplyGeneratorWithProvider(s.ID, aiGen, s.PublishText)
	s.titleGen = newTitleGeneratorWithProvider(s.ID, aiGen, s.firstPrompt, s.applyAITitle)
	if qrGen == nil && s.titleGen == nil {
		return
	}
	proc.setTurnHook(func(lastAssistant, msgID string) {
		qrGen.kickoff(lastAssistant, msgID)
		s.titleGen.onTurnEnd(lastAssistant)
	})
}

// --- the long-lived server process ---

// opencodeServerReadyTimeout bounds how long Spawn waits for `opencode serve`
// to report healthy on GET /global/health. A warm box is ready in ~2-3s, but
// the FIRST run against a fresh agent-home downloads the @opencode-ai/plugin
// tree + the models.dev cache (verified: a cold temp-HOME run can take >30s),
// so the window is generous to avoid a spurious "not healthy" on first launch.
const opencodeServerReadyTimeout = 90 * time.Second

// opencodeTurnSilenceTimeout force-ends a turn that has produced no SSE frame
// for this long, so a hung server / dropped stream self-heals instead of
// wedging the composer forever. Every frame for the owned session resets it.
//
// opencode streams message.part.delta tokens as the provider generates, so
// genuine silence means the provider has not produced ANYTHING — it is either
// stalled (Zen rate-limited / slow / down) or dead. 2 minutes is long enough
// to absorb a slow first-token from the free "OpenCode Zen" provider (empirical
// cold-start ~5-10s, even on a busy box well under 60s) while still surfacing a
// dead-provider situation in a reasonable time instead of the previous 10-minute
// wait. The codex backend keeps its own separate 10-minute value (codex streams
// lines of reasoning so short silences are normal); opencode's SSE model makes
// silence unambiguous.
const opencodeTurnSilenceTimeout = 2 * time.Minute

// opencodeServerProcess drives one session's `opencode serve` child + its
// REST/SSE control plane.
type opencodeServerProcess struct {
	binary   string
	baseArgs []string // adapter args, e.g. ["serve","--hostname","127.0.0.1"]
	dir      string
	env      []string

	publish   func([]byte)
	onSession func(string) // fires once when the ses_ id is first latched
	// onTurn fires at each turn's normal end with the final assistant text +
	// the ts the apps tied it to — drives AI niceties. nil when no provider.
	onTurn func(lastAssistant, msgID string)
	// onTurnIdle fires after any turn end once turnActive clears (push notify).
	onTurnIdle func()

	baseURL string
	hc      *http.Client

	cmd       *exec.Cmd
	stderrBuf *bytes.Buffer
	cancelSSE context.CancelFunc

	mu sync.Mutex
	// sessionID is the opencode ses_ id (latched on POST /session or seeded on
	// resume). Empty until the server session is created.
	sessionID string
	closed    bool
	// turnActive serializes one turn at a time (the composer is disabled
	// client-side while the agent works; this is the backstop).
	turnActive bool
	// turn accumulates the active turn's parts into one assistant bubble.
	turn *opencodeTurnState
	// published records whether the active turn emitted any chat event.
	published bool
	// interrupting marks a user-Stopped turn so its terminus is quiet.
	interrupting bool
	// lastActivity / watchdog / turnGen back the silence watchdog (codex twin).
	lastActivity   time.Time
	watchdog       *time.Timer
	turnGen        int
	silenceTimeout time.Duration
}

// newOpencodeServerProcess allocates a port, spawns `opencode serve`, waits for
// health, opens the SSE stream, and creates (or seeds on resume) the server
// session. On any failure it cleans up the child and returns the error so the
// caller can disable chat gracefully. baseArgs is the adapter's args (e.g.
// ["serve","--hostname","127.0.0.1"]); the allocated --port is appended.
func newOpencodeServerProcess(binary string, baseArgs []string, dir string, env []string, publish func([]byte), seedSessionID string, onSession func(string)) (*opencodeServerProcess, error) {
	port, err := allocFreeTCPPort()
	if err != nil {
		return nil, fmt.Errorf("opencode serve: alloc port: %w", err)
	}
	c := &opencodeServerProcess{
		binary:         binary,
		baseArgs:       baseArgs,
		dir:            dir,
		env:            env,
		publish:        publish,
		onSession:      onSession,
		sessionID:      seedSessionID,
		baseURL:        fmt.Sprintf("http://127.0.0.1:%d", port),
		hc:             &http.Client{Timeout: 30 * time.Second},
		silenceTimeout: opencodeTurnSilenceTimeout,
	}
	if err := c.spawn(port); err != nil {
		c.killChild()
		publishChatSystem(c.publish, "⚠️ opencode: server failed to start: "+err.Error())
		return nil, err
	}
	return c, nil
}

// spawn starts `opencode serve --port <port>`, waits for health, opens the SSE
// reader, and creates/seeds the server session.
func (c *opencodeServerProcess) spawn(port int) error {
	cmd := exec.Command(c.binary, c.serveArgs(port)...)
	cmd.Env = c.env
	cmd.Dir = c.dir
	c.stderrBuf = &bytes.Buffer{}
	cmd.Stderr = &limitWriter{w: c.stderrBuf, limit: 4096}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("opencode serve: start: %w", err)
	}
	c.cmd = cmd
	fmt.Fprintf(os.Stderr, "opencode serve: spawned (pid %d, port %d, dir %s)\n", cmd.Process.Pid, port, c.dir)

	if err := c.waitHealthy(); err != nil {
		return err
	}
	fmt.Fprintf(os.Stderr, "opencode serve: healthy at %s\n", c.baseURL)
	return c.connect()
}

// connect opens the SSE stream and creates (or seeds, on resume) the server
// session against the already-healthy baseURL. Split from spawn so a test can
// drive it against an httptest server without launching a real binary.
func (c *opencodeServerProcess) connect() error {
	// Open the SSE stream BEFORE creating the session so we don't miss the
	// first turn's frames (the stream is server-wide; we filter to our ses_).
	sctx, cancel := context.WithCancel(context.Background())
	c.cancelSSE = cancel
	ready := make(chan struct{})
	go c.readEvents(sctx, ready)
	select {
	case <-ready:
	case <-time.After(10 * time.Second):
		return errors.New("opencode serve: SSE stream did not connect")
	}

	seed := c.sessionID
	if seed != "" {
		// Resume: the global DB already holds the session; just keep prompting
		// the same ses_ id. (Best-effort rehydrate is implicit — opencode keeps
		// the conversation; we don't replay old frames into chat.)
		fmt.Fprintf(os.Stderr, "opencode serve: resuming session %s\n", seed)
		return nil
	}
	id, err := c.createSession()
	if err != nil {
		return err
	}
	c.latchSession(id)
	fmt.Fprintf(os.Stderr, "opencode serve: created session %s\n", id)
	return nil
}

// serveArgs builds the `opencode` argv: the adapter's serve args plus the
// allocated --port. Falls back to the documented default args when the adapter
// supplies none (defensive — the manifest always sets them).
func (c *opencodeServerProcess) serveArgs(port int) []string {
	base := c.baseArgs
	if len(base) == 0 {
		base = []string{"serve", "--hostname", "127.0.0.1"}
	}
	return append(append([]string{}, base...), "--port", strconv.Itoa(port))
}

// waitHealthy polls GET /global/health until the server reports healthy or the
// readiness deadline elapses. A non-healthy body keeps polling; a hard
// connection refused early in startup is expected and retried.
func (c *opencodeServerProcess) waitHealthy() error {
	deadline := time.Now().Add(opencodeServerReadyTimeout)
	for time.Now().Before(deadline) {
		if c.childExited() {
			return fmt.Errorf("opencode serve: exited during startup: %s", firstMeaningfulLine(c.stderrString()))
		}
		req, _ := http.NewRequest(http.MethodGet, c.baseURL+"/global/health", nil)
		resp, err := c.hc.Do(req)
		if err == nil {
			var body struct {
				Healthy bool `json:"healthy"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&body)
			_ = resp.Body.Close()
			if body.Healthy {
				return nil
			}
		}
		time.Sleep(200 * time.Millisecond)
	}
	return errors.New("opencode serve: not healthy before deadline")
}

// createSession POSTs /session and returns the ses_ id.
func (c *opencodeServerProcess) createSession() (string, error) {
	body, _ := json.Marshal(map[string]any{"title": "conduit"})
	req, err := http.NewRequest(http.MethodPost, c.baseURL+"/session", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("content-type", "application/json")
	resp, err := c.hc.Do(req)
	if err != nil {
		return "", fmt.Errorf("opencode serve: POST /session: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return "", fmt.Errorf("opencode serve: POST /session: status %d", resp.StatusCode)
	}
	var created struct {
		ID string `json:"id"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&created); err != nil {
		return "", fmt.Errorf("opencode serve: decode /session: %w", err)
	}
	if created.ID == "" {
		return "", errors.New("opencode serve: /session returned no id")
	}
	return created.ID, nil
}

// latchSession records the ses_ id (first time only) and fires onSession so the
// session persists it (meta.json) for resume. Twin of codex latchThread.
func (c *opencodeServerProcess) latchSession(id string) {
	if id == "" {
		return
	}
	c.mu.Lock()
	first := c.sessionID == ""
	if first {
		c.sessionID = id
	}
	c.mu.Unlock()
	if first && c.onSession != nil {
		c.onSession(id)
	}
}

// readEvents reads the server-wide GET /event SSE stream, demuxes frames for
// our session, and drives the turn state machine. It closes `ready` once the
// stream connects (the first server.connected frame, or the HTTP 200). On a
// stream drop while not intentionally closed it surfaces a chat notice.
func (c *opencodeServerProcess) readEvents(ctx context.Context, ready chan<- struct{}) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, c.baseURL+"/event", nil)
	if err != nil {
		close(ready)
		return
	}
	req.Header.Set("accept", "text/event-stream")
	// The SSE stream is long-lived; use a client with no overall timeout.
	sseClient := &http.Client{}
	resp, err := sseClient.Do(req)
	if err != nil {
		close(ready)
		c.mu.Lock()
		intentional := c.closed
		c.mu.Unlock()
		if !intentional {
			fmt.Fprintf(os.Stderr, "opencode serve: SSE connect failed: %v\n", err)
			publishChatSystem(c.publish, "⚠️ opencode: event stream failed to connect")
		}
		return
	}
	defer resp.Body.Close()
	close(ready)
	fmt.Fprintf(os.Stderr, "opencode serve: SSE connected\n")

	sc := bufio.NewScanner(resp.Body)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		payload, ok := sseDataPayload(line)
		if !ok {
			continue
		}
		ev, ok := parseOpencodeEvent([]byte(payload))
		if !ok {
			continue
		}
		c.handleEvent(ev)
	}
	// Stream ended.
	c.mu.Lock()
	intentional := c.closed
	active := c.turnActive
	c.mu.Unlock()
	if active {
		c.endTurn()
	}
	if !intentional {
		fmt.Fprintf(os.Stderr, "opencode serve: SSE stream ended\n")
		publishChatSystem(c.publish, "⚠️ The opencode server ended. Start a new session to continue.")
	}
}

// handleEvent routes one decoded SSE event for OUR session. Frames for other
// sessions (or before our session is created) are dropped. session.status busy
// starts a turn's accumulator; message.part.* fold prose; step-finish carries
// tokens (dropped — usage scoped out); session.idle ends the turn.
func (c *opencodeServerProcess) handleEvent(ev opencodeEvent) {
	sid := ev.Properties.SessionID
	c.mu.Lock()
	mySID := c.sessionID
	c.mu.Unlock()
	// Drop frames for sessions we don't own (the stream is server-wide). A
	// frame with no sessionID (server.connected / server.heartbeat) is also
	// dropped. The silence watchdog (lastActivity) is reset BELOW — only by
	// frames that belong to OUR session. Resetting it here, before the filter,
	// was the silent-hang root cause: opencode emits a server-wide
	// `server.heartbeat` (empty properties, no sessionID) every ~10s, so a turn
	// that went `busy` and then stalled — the hosted "OpenCode Zen" provider
	// rate-limited / slow / down, producing NO further per-session frames and
	// NO session.idle/session.error — had its watchdog perpetually rearmed by
	// those heartbeats. The 10-minute silence backstop could therefore NEVER
	// fire, so the composer's typing indicator spun forever with no reply and
	// no error (the device-reported hang that survived #459).
	if sid == "" || (mySID != "" && sid != mySID) {
		return
	}
	// A frame for our session is real turn activity: reset the silence watchdog.
	c.mu.Lock()
	if c.turnActive {
		c.lastActivity = opencodeNow()
	}
	c.mu.Unlock()

	switch ev.Type {
	case "session.status":
		if ev.Properties.Status != nil && ev.Properties.Status.Type == "busy" {
			c.startTurnIfIdle()
		}
	case "message.part.updated":
		if ev.Properties.Part != nil {
			c.foldPart(*ev.Properties.Part)
		}
	case "message.part.delta":
		c.foldDelta(ev.Properties.PartID, ev.Properties.Field, ev.Properties.Delta)
	case "session.idle":
		// Terminal per-session turn-end signal.
		c.endTurn()
	case "session.error":
		// A turn failure (bad model, provider auth, context overflow, API
		// error, abort). opencode does NOT always follow this with
		// session.idle, so it MUST end the turn here — otherwise the composer's
		// typing indicator spins forever with no reply (the device-reported
		// hang). Surface the cause in the Chat tab unless it's a plain abort
		// (the Stop button already handled that quietly). endTurn is idempotent,
		// so a later session.idle for the same turn is a harmless no-op.
		c.failTurn(ev.Properties.Error)
	}
}

// failTurn surfaces a session.error in the Chat tab (unless it is an abort) and
// ends the active turn so the typing indicator clears. Safe to call when no
// turn is active (a stray error frame just emits the notice).
func (c *opencodeServerProcess) failTurn(e *opencodeError) {
	c.mu.Lock()
	intentional := c.closed
	interrupting := c.interrupting
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "opencode serve: session.error (session %s, name=%q)\n", c.sessionID, errName(e))
	if !intentional && !interrupting && !e.isAbort() {
		publishChatSystem(c.publish, "⚠️ opencode: "+e.message())
	}
	c.endTurn()
}

// errName returns the error class for logging (empty string when nil).
func errName(e *opencodeError) string {
	if e == nil {
		return ""
	}
	return e.Name
}

// startTurnIfIdle begins a turn accumulator on the first busy status. Re-entry
// while a turn is active is a no-op (the same turn emits busy multiple times).
func (c *opencodeServerProcess) startTurnIfIdle() {
	c.mu.Lock()
	if c.closed || c.turnActive {
		c.mu.Unlock()
		return
	}
	c.turnActive = true
	c.turn = newOpencodeTurnState()
	c.published = false
	c.beginWatchdogLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "opencode serve: turn start (session %s)\n", c.sessionID)
}

// foldPart folds a message.part.updated into the active turn (text parts only).
func (c *opencodeServerProcess) foldPart(p opencodePart) {
	c.mu.Lock()
	if c.turn != nil {
		c.turn.observePart(p)
	}
	c.mu.Unlock()
}

// foldDelta folds a message.part.delta into the active turn.
func (c *opencodeServerProcess) foldDelta(partID, field, delta string) {
	c.mu.Lock()
	if c.turn != nil {
		c.turn.observeDelta(partID, field, delta)
	}
	c.mu.Unlock()
}

// endTurn ends the active turn: emit the consolidated assistant bubble (unless
// the turn was a user Stop or produced no prose), fire the AI-niceties + idle
// hooks. Idempotent — a second session.idle for an already-ended turn no-ops.
func (c *opencodeServerProcess) endTurn() {
	c.mu.Lock()
	if !c.turnActive {
		c.mu.Unlock()
		return
	}
	c.turnActive = false
	interrupting := c.interrupting
	c.interrupting = false
	answer := ""
	if c.turn != nil {
		answer = c.turn.answer()
	}
	c.turn = nil
	c.stopWatchdogLocked()
	hook := c.onTurn
	idleHook := c.onTurnIdle
	intentional := c.closed
	c.mu.Unlock()

	fmt.Fprintf(os.Stderr, "opencode serve: turn end (session %s, len=%d, interrupting=%v)\n", c.sessionID, len(answer), interrupting)

	if !interrupting && !intentional && strings.TrimSpace(answer) != "" {
		ts := c.emitAssistant(answer)
		if hook != nil {
			hook(answer, ts)
		}
	}
	if idleHook != nil && !intentional {
		idleHook()
	}
}

// emitAssistant publishes one assistant chat view_event with the turn's full
// prose and returns its ts. Mirrors codex emit().
func (c *opencodeServerProcess) emitAssistant(content string) string {
	ts := opencodeNow().UTC().Format(time.RFC3339Nano)
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    "assistant",
			"content": content,
			"ts":      ts,
			"files":   []any{},
		},
	})
	if err != nil {
		return ts
	}
	c.mu.Lock()
	c.published = true
	c.mu.Unlock()
	c.publish(payload)
	return ts
}

// Send sends one turn via POST /session/{id}/prompt_async. It returns
// immediately; output streams over SSE. Concurrent Sends while a turn is in
// flight are rejected (the server serializes one turn per session).
func (c *opencodeServerProcess) Send(text string) error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	sid := c.sessionID
	if sid == "" {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	if c.turnActive {
		c.mu.Unlock()
		return errOpencodeTurnInFlight
	}
	c.mu.Unlock()

	status, err := c.postPrompt(sid, text)
	if err != nil {
		publishChatSystem(c.publish, "⚠️ opencode: prompt failed to send: "+err.Error())
		return nil
	}
	if status == http.StatusNotFound {
		// The persisted ses_ id no longer exists in opencode's global DB —
		// the conversation store was wiped/rotated under us (broker redeploy
		// against a fresh agent-home, a GC of the data_dir, or a DB reset) while
		// meta.json still carried the stale id we resumed. Re-prompting it 404s
		// EVERY turn with no SSE frames at all, so without recovery the session
		// is permanently dead. Self-heal: create a fresh server session and
		// retry the prompt once, so the conversation continues (a new ses_, the
		// old transcript stays in the app's own log).
		fmt.Fprintf(os.Stderr, "opencode serve: prompt_async 404 (stale session %s); recreating\n", sid)
		newID, cerr := c.createSession()
		if cerr != nil {
			publishChatSystem(c.publish, "⚠️ opencode: session was lost and could not be recreated: "+cerr.Error())
			return nil
		}
		c.mu.Lock()
		c.sessionID = newID
		c.mu.Unlock()
		if c.onSession != nil {
			c.onSession(newID) // re-persist so the next resume targets the live id
		}
		status, err = c.postPrompt(newID, text)
		if err != nil {
			publishChatSystem(c.publish, "⚠️ opencode: prompt failed to send: "+err.Error())
			return nil
		}
	}
	if status/100 != 2 {
		publishChatSystem(c.publish, fmt.Sprintf("⚠️ opencode: prompt rejected (status %d)", status))
	}
	return nil
}

// postPrompt POSTs one turn to /session/{id}/prompt_async and returns the HTTP
// status. The body is drained/closed. Split from Send so the stale-session
// (404) recovery can re-issue against a freshly created session.
func (c *opencodeServerProcess) postPrompt(sid, text string) (int, error) {
	body, _ := json.Marshal(opencodePromptBody(text))
	req, err := http.NewRequest(http.MethodPost, c.baseURL+"/session/"+sid+"/prompt_async", bytes.NewReader(body))
	if err != nil {
		return 0, err
	}
	req.Header.Set("content-type", "application/json")
	fmt.Fprintf(os.Stderr, "opencode serve: prompt_async (session %s)\n", sid)
	resp, err := c.hc.Do(req)
	if err != nil {
		return 0, err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.StatusCode, nil
}

// Interrupt aborts the active turn via POST /session/{id}/abort (the Stop
// button) without ending the session. The stream settles to session.idle,
// which endTurn clears quietly. No-op when no turn is in flight.
func (c *opencodeServerProcess) Interrupt() error {
	c.mu.Lock()
	if c.closed || !c.turnActive || c.sessionID == "" {
		c.mu.Unlock()
		return nil
	}
	sid := c.sessionID
	c.interrupting = true
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "opencode serve: abort (session %s)\n", sid)
	req, err := http.NewRequest(http.MethodPost, c.baseURL+"/session/"+sid+"/abort", nil)
	if err != nil {
		return err
	}
	resp, err := c.hc.Do(req)
	if err != nil {
		return err
	}
	_, _ = io.Copy(io.Discard, resp.Body)
	return resp.Body.Close()
}

// TurnActive reports whether a turn is in flight (the authoritative SSE-driven
// latch the broker folds into the status frame).
func (c *opencodeServerProcess) TurnActive() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.turnActive
}

// Close stops the server: refuse further Sends, cancel the SSE reader, kill the
// child. Idempotent.
func (c *opencodeServerProcess) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	cancel := c.cancelSSE
	c.stopWatchdogLocked()
	c.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	c.killChild()
	return nil
}

// setTurnHook installs the AI-niceties turn-end callback. Called once at wiring
// time before any Send.
func (c *opencodeServerProcess) setTurnHook(fn func(lastAssistant, msgID string)) {
	c.mu.Lock()
	c.onTurn = fn
	c.mu.Unlock()
}

// setTurnIdleHook installs the turn-idle push-notification callback (the
// turnIdleHooker interface). Called once at wiring time before any Send.
func (c *opencodeServerProcess) setTurnIdleHook(fn func()) {
	c.mu.Lock()
	c.onTurnIdle = fn
	c.mu.Unlock()
}

// --- watchdog (codex twin) ---

func (c *opencodeServerProcess) beginWatchdogLocked() {
	c.turnGen++
	c.lastActivity = opencodeNow()
	c.armWatchdogLocked(c.silenceTimeout)
}

func (c *opencodeServerProcess) armWatchdogLocked(d time.Duration) {
	if c.watchdog != nil {
		c.watchdog.Stop()
		c.watchdog = nil
	}
	if d <= 0 || !c.turnActive {
		return
	}
	gen := c.turnGen
	c.watchdog = time.AfterFunc(d, func() { c.fireWatchdog(gen) })
}

func (c *opencodeServerProcess) stopWatchdogLocked() {
	c.turnGen++
	if c.watchdog != nil {
		c.watchdog.Stop()
		c.watchdog = nil
	}
}

func (c *opencodeServerProcess) fireWatchdog(gen int) {
	c.mu.Lock()
	if gen != c.turnGen || !c.turnActive {
		c.mu.Unlock()
		return
	}
	if idle := opencodeNow().Sub(c.lastActivity); idle < c.silenceTimeout {
		c.armWatchdogLocked(c.silenceTimeout - idle)
		c.mu.Unlock()
		return
	}
	published := c.published
	c.turnActive = false
	c.turn = nil
	idleHook := c.onTurnIdle
	c.stopWatchdogLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "opencode serve: turn watchdog fired after %s of silence\n", c.silenceTimeout)
	if !published {
		publishChatSystem(c.publish, "⚠️ opencode: no response from the agent — ending the turn so you can try again.")
	}
	if idleHook != nil {
		idleHook()
	}
}

// --- child/process helpers ---

func (c *opencodeServerProcess) killChild() {
	c.mu.Lock()
	cmd := c.cmd
	c.mu.Unlock()
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
}

// childExited reports whether the spawned `opencode serve` has already exited
// (used by the health poll to fail fast on a crashed startup).
func (c *opencodeServerProcess) childExited() bool {
	c.mu.Lock()
	cmd := c.cmd
	c.mu.Unlock()
	if cmd == nil || cmd.ProcessState != nil {
		return cmd != nil && cmd.ProcessState != nil
	}
	// Non-blocking liveness check: signal 0 succeeds while the process lives.
	if cmd.Process == nil {
		return false
	}
	return cmd.Process.Signal(syscall.Signal(0)) != nil
}

func (c *opencodeServerProcess) stderrString() string {
	if c.stderrBuf == nil {
		return ""
	}
	return c.stderrBuf.String()
}

// --- catalog probe ---

// probeOpencodeCatalog spawns a throwaway `opencode serve`, GETs
// /config/providers once it is healthy, and maps the response to the catalog.
// The server is always killed before returning (success or failure). ctx bounds
// the whole probe; the server is launched with the broker's own env (the
// catalog is provider-independent — the built-in zen provider always lists).
func probeOpencodeCatalog(ctx context.Context, bin string) ([]ModelInfo, error) {
	port, err := allocFreeTCPPort()
	if err != nil {
		return nil, fmt.Errorf("opencode catalog probe: alloc port: %w", err)
	}
	args := []string{"serve", "--hostname", "127.0.0.1", "--port", strconv.Itoa(port)}
	cmd := exec.CommandContext(ctx, bin, args...)
	cmd.Stdout = io.Discard
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("opencode catalog probe: start: %w", err)
	}
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	hc := &http.Client{Timeout: 10 * time.Second}
	// Poll health until ready or ctx expires.
	for {
		if ctx.Err() != nil {
			return nil, fmt.Errorf("opencode catalog probe: %w", ctx.Err())
		}
		req, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/global/health", nil)
		if resp, herr := hc.Do(req); herr == nil {
			var body struct {
				Healthy bool `json:"healthy"`
			}
			_ = json.NewDecoder(resp.Body).Decode(&body)
			_ = resp.Body.Close()
			if body.Healthy {
				break
			}
		}
		time.Sleep(200 * time.Millisecond)
	}

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/config/providers", nil)
	if err != nil {
		return nil, err
	}
	resp, err := hc.Do(req)
	if err != nil {
		return nil, fmt.Errorf("opencode catalog probe: GET /config/providers: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("opencode catalog probe: /config/providers status %d", resp.StatusCode)
	}
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	return parseOpencodeProviders(raw)
}

// --- small free helpers ---

// allocFreeTCPPort binds 127.0.0.1:0, reads the OS-assigned port, and releases
// it so `opencode serve --port <n>` can claim it. There is a tiny TOCTOU window
// before the server rebinds, acceptable for a localhost-only child (the codex
// chat port uses the same OS-allocation idea via $PORT).
func allocFreeTCPPort() (int, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	port := l.Addr().(*net.TCPAddr).Port
	_ = l.Close()
	return port, nil
}

// opencodePromptBody builds the POST /session/{id}/prompt_async body for a
// plain text turn. Model is omitted so the server picks its default; a model
// override would split via splitOpencodeModelID into {providerID, modelID}.
func opencodePromptBody(text string) map[string]any {
	return map[string]any{
		"parts": []map[string]any{{"type": "text", "text": text}},
	}
}

// opencodeNow is the clock for ts/watchdog — a var so tests can pin it.
var opencodeNow = time.Now
