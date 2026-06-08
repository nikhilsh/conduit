package session

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"
)

// codexAppServerProcess drives the structured Chat tab for codex via its
// long-lived **app-server** (JSON-RPC 2.0 as JSONL over stdio) instead of a
// one-shot `codex exec` per turn (the older codexChatProcess path). One
// `codex app-server` subprocess is spawned on construction and lives for the
// whole session, like claude's persistent chatProcess. The persistent thread
// is what unlocks manual context compaction (`/compact` → thread/compact/start;
// task #18) — `codex exec` has no equivalent.
//
// Wire protocol (verified against codex-cli 0.132.0; see the captured trace
// + JSON Schema the constructor comment references):
//   - handshake: id:1 initialize → result, then notification `initialized`.
//   - id:2 thread/start (or thread/resume on recovery) → result + a
//     `thread/started` notification carrying params.thread.id (the thread id).
//   - per user message: id:N turn/start → result, then a stream of
//     notifications (turn/started, item/started, item/agentMessage/delta,
//     item/completed, thread/tokenUsage/updated, turn/completed) all carrying
//     params.threadId.
//   - /compact: id:M thread/compact/start → empty result, then a turn whose
//     item is a contextCompaction.
//
// The `jsonrpc` field is omitted on the wire (codex tolerates its absence —
// confirmed by the trace). Requests carry an integer `id`; notifications
// don't. A single background reader goroutine demuxes responses (by `id`) from
// notifications (by `method`) and routes notifications to the active turn.
type codexAppServerProcess struct {
	binary   string // adapter.Command[0], e.g. "codex"
	dir      string // session worktree (thread/start cwd)
	env      []string
	override SpawnOverride // model / effort / permission mode (params, not flags)

	publish  func([]byte)
	onUsage  func(usageDelta)
	onThread func(string) // fires once when the thread id is first latched

	cmd       *exec.Cmd
	stdin     io.WriteCloser
	stderrBuf *bytes.Buffer

	mu sync.Mutex
	// nextID is the JSON-RPC request id counter (initialize=1, thread start=2,
	// then turns/compacts take 3,4,…).
	nextID   int
	threadID string // latched on thread/started (or seeded on resume)
	// inited is true once the initialize handshake completed.
	inited bool
	// turnActive guards single-turn-at-a-time serialization: codex app-server
	// handles one turn per thread, so concurrent Sends are rejected while a
	// turn is in flight.
	turnActive bool
	// turnReqID is the JSON-RPC id of the active turn/compact request, so the
	// reader can correlate a turn-rejecting error RESPONSE (e.g.
	// activeTurnNotSteerable, badRequest) back to the turn and end it — those
	// never produce a turn/completed notification, so without this the turn
	// would wedge turnActive forever.
	turnReqID int
	// turnID is the codex turn id (turn.id) of the active turn, latched from the
	// turn/started notification. Required (with threadID) to target turn/interrupt
	// — the Stop button. Empty until turn/started arrives and after the turn ends.
	turnID string
	// turnGen increments on every turn start/end so a stale watchdog timer from
	// a prior turn can detect it no longer owns the current turn and bow out.
	turnGen int
	// lastActivity is when the app-server last produced output for the active
	// turn; the silence watchdog measures idleness against it.
	lastActivity time.Time
	// watchdog force-ends a turn that has gone COMPLETELY silent (see
	// codexTurnSilenceTimeout). nil when no turn is in flight.
	watchdog *time.Timer
	// silenceTimeout is the watchdog window (a field so tests can shorten it).
	silenceTimeout time.Duration
	// published records whether the active turn has emitted any chat event, so
	// Close/EOF can surface a "no reply" notice (mirrors codexchatproc.go's
	// safety net) rather than leave the typing indicator spinning.
	published bool
	closed    bool
}

// codexAppServerClientVersion is the clientInfo.version reported on
// initialize. Informational only (codex echoes it back in its userAgent).
const codexAppServerClientVersion = "0.0.1"

// codexTurnSilenceTimeout bounds how long a turn may go COMPLETELY silent — no
// notifications, no response, no thread-status change — before the backend
// force-ends it so the session self-heals instead of wedging forever. It is a
// last-resort backstop: every normal terminus (turn/completed, the `error`
// notification, a turn-rejecting error response, a thread `idle` status) ends
// the turn instantly, and ANY server output resets this window — so only a
// genuinely hung codex (sending nothing at all) trips it.
const codexTurnSilenceTimeout = 10 * time.Minute

// newCodexAppServerProcess spawns the codex app-server and runs the initialize
// handshake + thread start/resume synchronously, mirroring
// newCodexChatProcess's argument shape so manager.go can swap the two by
// chat_mode. When seedThreadID is non-empty (recovery), it resumes that thread
// (thread/resume) instead of starting a new one (thread/start). The model /
// effort / permission-mode overrides are carried as JSON-RPC params (not CLI
// flags), so callers pass the SpawnOverride directly rather than the exec
// path's pre-built `extra` argv.
//
// On any spawn/handshake/thread error the returned process is non-nil but its
// first Send will report the failure to chat; we still return it (not the
// error) so the session lifecycle stays identical to the exec path — except a
// hard spawn failure (binary missing) returns the error so the caller can fall
// back. Errors are surfaced to chat via publishChatSystem.
func newCodexAppServerProcess(binary, dir string, env []string, override SpawnOverride, publish func([]byte), onUsage func(usageDelta), seedThreadID string, onThread func(string)) (*codexAppServerProcess, error) {
	c := &codexAppServerProcess{
		binary:   binary,
		dir:      dir,
		env:      env,
		override: override,
		publish:  publish,
		onUsage:  onUsage,
		onThread: onThread,
		threadID: seedThreadID,
		// initialize=1, thread start/resume=2 are sent literally during the
		// handshake; allocIDLocked hands turns/compacts 3,4,… (matching the wire
		// doc above) and keeps turn ids distinct from the handshake ids so the
		// reader's turn-response correlation can't alias a handshake response.
		nextID:         2,
		silenceTimeout: codexTurnSilenceTimeout,
	}
	if err := c.spawn(); err != nil {
		return nil, err
	}
	return c, nil
}

// spawn starts the `codex app-server` subprocess, wires stdin/stdout/stderr,
// starts the reader goroutine, and runs the handshake + thread start/resume.
func (c *codexAppServerProcess) spawn() error {
	cmd := exec.Command(c.binary, "app-server")
	cmd.Env = c.env
	cmd.Dir = c.dir
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	// Capture stderr (codex logs auth / sandbox errors there) so a fatal
	// startup error can be surfaced in chat. Cap at 4 KB like the exec path.
	c.stderrBuf = &bytes.Buffer{}
	cmd.Stderr = &limitWriter{w: c.stderrBuf, limit: 4096}
	if err := cmd.Start(); err != nil {
		return err
	}
	c.cmd = cmd
	c.stdin = stdin

	resp := make(chan json.RawMessage, 1)
	go c.readLoop(stdout, resp)

	fmt.Fprintf(os.Stderr, "codex app-server: spawned (pid %d, dir %s)\n", cmd.Process.Pid, c.dir)

	if err := c.handshake(resp); err != nil {
		publishChatSystem(c.publish, "⚠️ codex: app-server failed to start: "+err.Error())
		return err
	}
	return nil
}

// handshake runs initialize → initialized → thread/start|resume synchronously.
// resp delivers the next correlated response from the reader goroutine.
func (c *codexAppServerProcess) handshake(resp <-chan json.RawMessage) error {
	// initialize (id:1)
	if err := c.writeRequest(1, "initialize", codexInitializeParams()); err != nil {
		return fmt.Errorf("initialize write: %w", err)
	}
	if _, err := waitCodexResult(resp); err != nil {
		fmt.Fprintf(os.Stderr, "codex app-server: initialize failed: %v\n", err)
		return fmt.Errorf("initialize: %w", err)
	}
	fmt.Fprintf(os.Stderr, "codex app-server: initialize ok\n")

	// initialized (notification, no id)
	if err := c.writeNotification("initialized", map[string]any{}); err != nil {
		return fmt.Errorf("initialized write: %w", err)
	}

	c.mu.Lock()
	seed := c.threadID
	c.mu.Unlock()

	if seed != "" {
		// Recovery: resume the prior thread (no id latch — we already have it).
		if err := c.writeRequest(2, "thread/resume", codexThreadResumeParams(seed, c.dir, c.override)); err != nil {
			return fmt.Errorf("thread/resume write: %w", err)
		}
		if _, err := waitCodexResult(resp); err != nil {
			fmt.Fprintf(os.Stderr, "codex app-server: thread/resume(%s) failed: %v\n", seed, err)
			return fmt.Errorf("thread/resume: %w", err)
		}
		fmt.Fprintf(os.Stderr, "codex app-server: resumed thread %s\n", seed)
	} else {
		// Fresh thread (id:2). The thread id arrives both in this result's
		// thread.id and in a thread/started notification; we latch it from the
		// result here so it's available before the first turn.
		if err := c.writeRequest(2, "thread/start", codexThreadStartParams(c.dir, c.override)); err != nil {
			return fmt.Errorf("thread/start write: %w", err)
		}
		raw, err := waitCodexResult(resp)
		if err != nil {
			fmt.Fprintf(os.Stderr, "codex app-server: thread/start failed: %v\n", err)
			return fmt.Errorf("thread/start: %w", err)
		}
		tid := codexThreadIDFromStartResult(raw)
		if tid == "" {
			return fmt.Errorf("thread/start: no thread id in result")
		}
		c.latchThread(tid)
		fmt.Fprintf(os.Stderr, "codex app-server: started thread %s\n", tid)
	}

	c.mu.Lock()
	c.inited = true
	c.mu.Unlock()
	return nil
}

// latchThread records the thread id (first time only) and fires onThread so
// the session persists it for recovery.
func (c *codexAppServerProcess) latchThread(tid string) {
	if tid == "" {
		return
	}
	c.mu.Lock()
	first := c.threadID == ""
	if first {
		c.threadID = tid
	}
	c.mu.Unlock()
	if first && c.onThread != nil {
		c.onThread(tid)
	}
}

// Send runs one codex turn (or a compaction) for the user's message. It
// returns immediately; notifications stream via publish from the reader
// goroutine. A bare "/compact" triggers thread/compact/start instead of a
// turn. Concurrent Sends while a turn is in flight are rejected (codex
// serializes one turn per thread).
func (c *codexAppServerProcess) Send(text string) error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	if !c.inited {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	if c.turnActive {
		c.mu.Unlock()
		return errCodexTurnInFlight
	}
	tid := c.threadID
	id := c.allocIDLocked()
	c.turnActive = true
	c.turnReqID = id
	c.published = false
	c.beginTurnWatchdogLocked()
	c.mu.Unlock()

	if isCodexCompactCommand(text) {
		fmt.Fprintf(os.Stderr, "codex app-server: compact start (thread %s, id %d)\n", tid, id)
		if err := c.writeRequest(id, "thread/compact/start", map[string]any{"threadId": tid}); err != nil {
			c.endTurn()
			publishChatSystem(c.publish, "⚠️ codex: compact failed to send: "+err.Error())
			return nil
		}
		return nil
	}

	fmt.Fprintf(os.Stderr, "codex app-server: turn start (thread %s, id %d)\n", tid, id)
	if err := c.writeRequest(id, "turn/start", codexTurnStartParams(tid, text, c.override)); err != nil {
		c.endTurn()
		publishChatSystem(c.publish, "⚠️ codex: turn failed to send: "+err.Error())
		return nil
	}
	return nil
}

// finishTurn clears the in-flight turn flag and stops the silence watchdog,
// returning whether a turn was actually active (false = already ended) plus the
// published / closing snapshot so the caller can decide what notice (if any) to
// surface. Idempotent: a second terminus for the same turn returns active=false
// and the caller does nothing. Caller must NOT hold c.mu.
func (c *codexAppServerProcess) finishTurn() (active, published, intentional bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.turnActive {
		return false, false, false
	}
	c.turnActive = false
	c.turnID = ""
	c.stopTurnWatchdogLocked()
	return true, c.published, c.closed
}

// endTurn ends the active turn on a NORMAL terminus (turn/completed=completed,
// thread idle, EOF). If the turn produced no chat event and wasn't an
// intentional close, it surfaces a "no reply" notice so the typing indicator
// clears (mirrors codexchatproc.go's safety net).
func (c *codexAppServerProcess) endTurn() {
	active, published, intentional := c.finishTurn()
	if active && !published && !intentional {
		msg := "⚠️ codex: no reply from agent (turn failed or timed out)"
		if snip := firstMeaningfulLine(c.stderrString()); snip != "" {
			msg = "⚠️ codex error: " + snip
		}
		publishChatSystem(c.publish, msg)
	}
}

// failTurn ends the active turn with an explicit error message. Unlike endTurn
// it ALWAYS shows the message (even if the turn had already streamed output),
// because the caller has a concrete failure to report — suppressed only when
// the session is intentionally closing.
func (c *codexAppServerProcess) failTurn(msg string) {
	active, _, intentional := c.finishTurn()
	if active && !intentional {
		publishChatSystem(c.publish, msg)
	}
}

// endTurnQuiet ends the active turn without any notice — for an interrupted
// turn, where the composer just needs to unlock.
func (c *codexAppServerProcess) endTurnQuiet() {
	c.finishTurn()
}

// beginTurnWatchdogLocked (re)starts the silence watchdog for a freshly-started
// turn. Caller holds c.mu and has just set turnActive=true.
func (c *codexAppServerProcess) beginTurnWatchdogLocked() {
	c.turnGen++
	c.lastActivity = claudeChatNow()
	c.armTurnWatchdogLocked(c.silenceTimeout)
}

// armTurnWatchdogLocked schedules a watchdog fire `d` from now for the current
// turn generation. A non-positive d (or no active turn) disarms. Caller holds
// c.mu.
func (c *codexAppServerProcess) armTurnWatchdogLocked(d time.Duration) {
	if c.watchdog != nil {
		c.watchdog.Stop()
		c.watchdog = nil
	}
	if d <= 0 || !c.turnActive {
		return
	}
	gen := c.turnGen
	c.watchdog = time.AfterFunc(d, func() { c.fireTurnWatchdog(gen) })
}

// stopTurnWatchdogLocked cancels any pending watchdog and bumps the generation
// so a timer already past Stop (waiting on c.mu in fireTurnWatchdog) bows out.
// Caller holds c.mu.
func (c *codexAppServerProcess) stopTurnWatchdogLocked() {
	c.turnGen++
	if c.watchdog != nil {
		c.watchdog.Stop()
		c.watchdog = nil
	}
}

// fireTurnWatchdog runs when the watchdog elapses. If the turn produced output
// since the timer was armed it RE-ARMS for the remaining window (cheap activity
// tracking, no per-notification timer churn); only a turn that stayed fully
// silent for the whole window is force-ended.
func (c *codexAppServerProcess) fireTurnWatchdog(gen int) {
	c.mu.Lock()
	if gen != c.turnGen || !c.turnActive {
		c.mu.Unlock()
		return
	}
	if idle := claudeChatNow().Sub(c.lastActivity); idle < c.silenceTimeout {
		c.armTurnWatchdogLocked(c.silenceTimeout - idle)
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "codex app-server: turn watchdog fired after %s of silence\n", c.silenceTimeout)
	c.failTurn("⚠️ codex: no response from the agent — ending the turn so you can try again or start a new session.")
}

// readLoop scans the app-server's stdout JSONL. Responses (lines with an `id`)
// are forwarded to resp for the synchronous request waiters; notifications
// (lines with a `method`, no id) are routed to the active turn. A large
// scanner buffer (8 MB) matches the exec path so a big agent message doesn't
// overflow a line.
func (c *codexAppServerProcess) readLoop(stdout io.Reader, resp chan<- json.RawMessage) {
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		var env codexRPCEnvelope
		if err := json.Unmarshal(line, &env); err != nil {
			continue
		}
		// A response carries an id and no method. If it correlates to the
		// active turn, the reader owns it (an error response ends the turn);
		// otherwise forward a copy — the scanner reuses its buffer — to the
		// handshake waiter.
		if env.ID != nil && env.Method == "" {
			if c.routeTurnResponse(env.ID, env.Error) {
				continue
			}
			cp := make(json.RawMessage, len(line))
			copy(cp, line)
			select {
			case resp <- cp:
			default:
			}
			continue
		}
		if env.Method != "" {
			c.handleNotification(env.Method, env.Params)
		}
	}
	// EOF: the app-server exited. Close out any in-flight turn and, if not an
	// intentional Close, tell the user.
	c.mu.Lock()
	intentional := c.closed
	active := c.turnActive
	c.mu.Unlock()
	if active {
		c.endTurn()
	}
	if !intentional {
		msg := "⚠️ The codex app-server ended. Start a new session to continue."
		if snip := firstMeaningfulLine(c.stderrString()); snip != "" {
			msg = "⚠️ codex app-server exited: " + snip
		}
		publishChatSystem(c.publish, msg)
	}
}

// handleNotification routes one server notification to its effect: chat
// view_events for assistant text / tool cards / compaction, token usage folding
// for thread/tokenUsage/updated, and turn lifecycle (turn/completed, the
// `error` notification, thread/status/changed). Any notification arriving for
// an active turn counts as activity and pushes the silence watchdog out.
func (c *codexAppServerProcess) handleNotification(method string, params json.RawMessage) {
	c.mu.Lock()
	if c.turnActive {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()

	switch method {
	case "thread/started":
		// Belt-and-suspenders thread-id latch (the start result already
		// latched it; resume seeds it). Harmless if already set.
		if tid := codexStartedThreadID(params); tid != "" {
			c.latchThread(tid)
		}
	case "turn/started":
		// Latch the turn id so Interrupt() (the Stop button) can target
		// turn/interrupt {threadId, turnId}. Only meaningful while the turn
		// is active; finishTurn clears it.
		if id := codexStartedTurnID(params); id != "" {
			c.mu.Lock()
			if c.turnActive {
				c.turnID = id
			}
			c.mu.Unlock()
		}
	case "thread/tokenUsage/updated":
		if c.onUsage != nil {
			if u, ok := codexUsageFromNotification(params); ok {
				c.onUsage(u)
			}
		}
	case "item/agentMessage/delta", "item/completed":
		if ev, ok := codexNotificationToEvent(method, params); ok {
			c.emit(ev)
		}
	case "turn/completed":
		// codex v0.132 emits turn/completed for failed/interrupted turns too,
		// distinguished by turn.status — surface the real failure rather than
		// the generic "no reply".
		status, errMsg := codexTurnCompletion(params)
		fmt.Fprintf(os.Stderr, "codex app-server: turn completed (status=%q)\n", status)
		switch status {
		case "failed":
			if errMsg == "" {
				errMsg = "the turn failed"
			}
			c.failTurn("⚠️ codex: " + errMsg)
		case "interrupted":
			c.endTurnQuiet()
		default:
			c.endTurn()
		}
	case "error":
		// The terminus for most turn failures (no turn/failed exists in 0.132).
		c.handleErrorNotification(params)
	case "thread/status/changed":
		// Deterministic backstop: `idle` while we still think a turn is running
		// means it ended (a turn/completed we never saw, or a dropped response);
		// `systemError` is a terminal failure. No-op once the turn already ended.
		switch codexThreadStatusType(params) {
		case "systemError":
			c.failTurn("⚠️ codex: the agent hit a system error — start a new session to continue.")
		case "idle":
			c.endTurn()
		}
	default:
		// item/started, turn/started, account/rateLimits/updated,
		// configWarning, mcpServer/*, etc. Nothing to render.
	}
}

// handleErrorNotification acts on an `error` notification. willRetry=true keeps
// the turn in flight (codex retries internally) and only surfaces a transient
// notice; willRetry=false is a terminal failure that ends the turn.
func (c *codexAppServerProcess) handleErrorNotification(params json.RawMessage) {
	msg, willRetry, ok := codexErrorNotificationMessage(params)
	if !ok {
		// Don't end a turn on a payload we can't read — just log it.
		fmt.Fprintf(os.Stderr, "codex app-server: unparseable error notification: %s\n", string(params))
		return
	}
	if msg == "" {
		msg = "the agent reported an error"
	}
	if willRetry {
		fmt.Fprintf(os.Stderr, "codex app-server: turn error (retrying): %s\n", msg)
		publishChatSystem(c.publish, "⚠️ codex: "+msg+" (retrying…)")
		return
	}
	fmt.Fprintf(os.Stderr, "codex app-server: turn error (terminal): %s\n", msg)
	c.failTurn("⚠️ codex: " + msg)
}

// routeTurnResponse handles a JSON-RPC response correlated to the active
// turn/compact request. Returns true when it owns the response (so the reader
// won't also forward it to the handshake waiter). A turn response carrying a
// JSON-RPC error means the request was rejected outright (e.g.
// activeTurnNotSteerable, badRequest) — no turn runs and no turn/completed will
// arrive, so the turn must be failed here or it wedges turnActive forever. A
// success ack is swallowed; the turn then streams via notifications.
func (c *codexAppServerProcess) routeTurnResponse(rawID, errRaw json.RawMessage) bool {
	var id int
	if json.Unmarshal(rawID, &id) != nil {
		return false
	}
	c.mu.Lock()
	match := c.turnActive && id == c.turnReqID
	if match {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()
	if !match {
		return false
	}
	if len(errRaw) > 0 && string(errRaw) != "null" {
		fmt.Fprintf(os.Stderr, "codex app-server: turn request %d rejected: %s\n", id, string(errRaw))
		c.failTurn("⚠️ codex: " + codexRPCErrorMessage(errRaw))
	}
	return true
}

// emit publishes one chat view_event (assistant / tool / system) and marks the
// turn as having produced output.
func (c *codexAppServerProcess) emit(ev codexAppEvent) {
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    ev.role,
			"content": ev.content,
			"ts":      claudeChatNow().UTC().Format(time.RFC3339Nano),
			"files":   []any{},
		},
	})
	if err != nil {
		return
	}
	c.mu.Lock()
	c.published = true
	c.mu.Unlock()
	c.publish(payload)
}

// Interrupt aborts the active turn via `turn/interrupt {threadId, turnId}` (the
// Stop button) without closing the app-server. codex replies with an empty
// result and emits `turn/completed` with status "interrupted", which endTurnQuiet
// clears. A no-op when no turn is in flight, the session is closed, or the turn
// id hasn't been latched yet (turn/started not seen) — the watchdog still backs
// that rare gap.
func (c *codexAppServerProcess) Interrupt() error {
	c.mu.Lock()
	if c.closed || !c.turnActive || c.turnID == "" {
		c.mu.Unlock()
		return nil
	}
	tid := c.threadID
	turnID := c.turnID
	id := c.allocIDLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "codex app-server: turn interrupt (thread %s, turn %s, id %d)\n", tid, turnID, id)
	return c.writeRequest(id, "turn/interrupt", map[string]any{"threadId": tid, "turnId": turnID})
}

// Close stops the app-server: refuse further Sends, close stdin, kill the
// subprocess. Idempotent.
func (c *codexAppServerProcess) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	if c.stdin != nil {
		_ = c.stdin.Close()
	}
	if c.cmd != nil && c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	return nil
}

// allocIDLocked returns the next JSON-RPC request id. Caller holds c.mu.
func (c *codexAppServerProcess) allocIDLocked() int {
	c.nextID++
	return c.nextID
}

// stderrString returns the captured stderr text (best-effort; empty when the
// buffer is unset, e.g. bare test fixtures).
func (c *codexAppServerProcess) stderrString() string {
	if c.stderrBuf == nil {
		return ""
	}
	return c.stderrBuf.String()
}
