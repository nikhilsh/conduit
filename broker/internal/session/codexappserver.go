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
	// onTurn fires at each turn's NORMAL end with the turn's final assistant
	// text + the id (ts) the apps tied it to — driving the AI niceties
	// (titles + quick replies), the codex twin of claudechat.go's turn-end
	// hook. nil when no AI provider is selected for the session.
	onTurn func(lastAssistant, msgID string)
	// onTurnIdle fires after any turn end (completed, interrupted, or failed)
	// once turnActive is cleared. Used by the session to fire push
	// notifications when no client is attached. nil = no-op. Set once at
	// wiring time before any Send.
	onTurnIdle func()
	// onPendingInput fires when an approval card is stashed (the agent is
	// now blocked on a decision). Used by the session to push a "Needs your
	// input" notification when no client is attached. nil = no-op. Set once
	// at wiring time.
	onPendingInput func()

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
	// (the Stop button) and turn/steer (mid-turn user inject). Empty until
	// turn/started arrives and after the turn ends.
	turnID string
	// steerReqID is the JSON-RPC id of the pending turn/steer request (0 when
	// none is in flight). The steer response is routed back here: on success the
	// steer is silently confirmed; on -32600 ("no active turn") the steer text
	// is re-sent via a normal turn/start (fallback path). Only one steer can be
	// pending at a time — a second steer replaces the first's id and text.
	steerReqID int
	// steerText is the user's message that was sent as a steer, kept for the
	// turn/start fallback path if the steer gets a -32600 error response.
	steerText string
	// interrupting is set when the user Stopped this turn (turn/interrupt sent).
	// While set, the turn's terminus is QUIET regardless of which path ends it
	// (turn/completed:interrupted, a racing thread `idle` status, or an error) —
	// a deliberate stop must never surface a "no reply" / error notice. Cleared
	// by finishTurn.
	interrupting bool
	// turnStderrOffset is the stderr-buffer length at this turn's START. A turn
	// failure surfaces only stderr written AFTER it (the turn's own error), never
	// the startup residue — codex logs a benign "project not trusted" line at
	// launch, and surfacing that stale line on every later turn read as a
	// recurring error (device report: identical-timestamp "codex error" lines).
	turnStderrOffset int
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
	// turnLastAssistant / turnLastTS hold the active turn's most recent
	// assistant prose + its event ts, handed to onTurn at the turn's end so
	// the AI niceties see the same message the apps render. Reset at endTurn.
	turnLastAssistant string
	turnLastTS        string
	closed            bool
	// pendingApprovalID is the server→client approval REQUEST's id (echoed
	// back verbatim in the response — codex's RequestId is string|integer, and
	// the approval id is a server-side counter starting at 0, independent of our
	// client request ids). Non-nil while an approval card is awaiting the user's
	// tap. The card surfaced as a chat view_event; the user's NEXT chat message
	// (AnswerApproval) carries the decision. Guarded by c.mu.
	pendingApprovalID json.RawMessage
	// pendingApprovalCard is the rendered card content for the outstanding
	// approval, kept so a reattaching client can re-see it (PendingApprovalCard,
	// the codex twin of PendingAskChatContent). "" when none is pending.
	pendingApprovalCard string
	// pendingApprovalDecline is true when the outstanding approval offered
	// `decline` in availableDecisions, so a deny answers `decline` (turn
	// continues) instead of `cancel` (turn interrupted). Captured from the
	// request; read by AnswerApproval.
	pendingApprovalDecline bool
	// pendingKind records WHICH server→client request the outstanding card
	// answers (approval / requestUserInput / elicitation), so AnswerApproval and
	// the safety-net paths (timeout / EOF / Close) build the correct response
	// shape. codexReqUnknown when nothing is pending.
	pendingKind codexServerRequestKind
	// pendingUserInput / pendingElicitation hold the parsed request for the
	// non-approval kinds, needed to build their response payloads from the user's
	// answer. Only the field matching pendingKind is meaningful.
	pendingUserInput   codexUserInputRequest
	pendingElicitation codexElicitationRequest
	// approvalTimer auto-denies an unanswered approval after askAnswerTimeout
	// (mirrors claude's askcontrol.go give-up timer), so a never-tapped card
	// can't wedge the turn forever. nil when no approval is pending.
	approvalTimer *time.Timer
	// lastFileChange is the most recently seen fileChange item (its id + the
	// path/diff of each change), stashed from item/started|completed so a later
	// item/fileChange/requestApproval — which carries ONLY the itemId — can join
	// to it and render the real path/diff. Reset at turn end. Guarded by c.mu.
	lastFileChange *codexFileChangeItem
}

// setTurnHook installs the AI-niceties turn-end callback (titles + quick
// replies). Called once at wiring time, before any Send.
func (c *codexAppServerProcess) setTurnHook(onTurn func(lastAssistant, msgID string)) {
	c.mu.Lock()
	c.onTurn = onTurn
	c.mu.Unlock()
}

// setTurnIdleHook installs the turn-idle push-notification callback. Called
// once at wiring time before any Send. Fires on ALL turn termini
// (completed, interrupted, failed) once turnActive is cleared.
func (c *codexAppServerProcess) setTurnIdleHook(fn func()) {
	c.mu.Lock()
	c.onTurnIdle = fn
	c.mu.Unlock()
}

// setPendingInputHook installs the pending-input push-notification callback.
// Called once at wiring time before any Send. Fires when an approval card
// is stashed and the agent is waiting for the user's decision.
func (c *codexAppServerProcess) setPendingInputHook(fn func()) {
	c.mu.Lock()
	c.onPendingInput = fn
	c.mu.Unlock()
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
// turn.
//
// When a turn is currently active AND the turn id has been latched from
// turn/started, Send attempts a turn/steer instead of returning
// errCodexTurnInFlight — the steer injects the user's text into the running
// turn at the next reasoning/step boundary without interrupting it. If the
// steer is rejected with -32600 ("no active turn"), the response handler
// falls back to a normal turn/start so the message is never lost.
//
// When the turn is active but the turn id hasn't arrived yet (turn/started
// not seen), or when compaction is in flight, the message is rejected as
// errCodexTurnInFlight — the client-side composer disables itself while the
// agent works, so this is a backstop for races.
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
		// A turn is in flight. If the turn id has been latched (turn/started
		// was seen), steer the running turn rather than rejecting the message.
		if c.turnID != "" && !isCodexCompactCommand(text) {
			c.mu.Unlock()
			return c.Steer(text)
		}
		c.mu.Unlock()
		return errCodexTurnInFlight
	}
	tid := c.threadID
	id := c.allocIDLocked()
	c.turnActive = true
	c.turnReqID = id
	c.published = false
	c.interrupting = false
	c.turnStderrOffset = c.stderrLenLocked()
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
// TurnActive reports whether a codex turn is in flight (the authoritative
// app-server latch). Read under c.mu; safe for the status-frame path.
func (c *codexAppServerProcess) TurnActive() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.turnActive
}

// published / closing snapshot so the caller can decide what notice (if any) to
// surface. Idempotent: a second terminus for the same turn returns active=false
// and the caller does nothing. Caller must NOT hold c.mu.
func (c *codexAppServerProcess) finishTurn() (active, published, intentional, interrupting bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if !c.turnActive {
		return false, false, false, false
	}
	c.turnActive = false
	c.turnID = ""
	interrupting = c.interrupting
	c.interrupting = false
	c.stopTurnWatchdogLocked()
	// A turn can't end with a card still outstanding (the request blocks the
	// turn). If the turn ended another way (e.g. interrupt, error) while a card
	// was up, drop the stash + timer — a later tap would have no live request to
	// answer. Best-effort response is skipped here (we hold c.mu and the turn is
	// already over); the abandoned request simply clears.
	c.clearPendingLocked()
	// Reset the stashed fileChange so a new turn's approval doesn't join a stale
	// edit from the previous turn.
	c.lastFileChange = nil
	return true, c.published, c.closed, interrupting
}

// endTurn ends the active turn on a NORMAL terminus (turn/completed=completed,
// thread idle, EOF). If the turn produced no chat event and wasn't an
// intentional close, it surfaces a "no reply" notice so the typing indicator
// clears (mirrors codexchatproc.go's safety net). A user-Stopped turn is silent
// — InterruptTurn already published the "Stopped." line — even when an `idle`
// status races ahead of the turn/completed:interrupted terminus.
func (c *codexAppServerProcess) endTurn() {
	active, published, intentional, interrupting := c.finishTurn()
	if active && !published && !intentional && !interrupting {
		msg := "⚠️ codex: no reply from agent (turn failed or timed out)"
		// Only the THIS-TURN stderr (not startup residue like codex's benign
		// "project not trusted" launch warning) is a real per-turn error.
		if snip := firstMeaningfulLine(c.stderrSinceTurn()); snip != "" {
			msg = "⚠️ codex error: " + snip
		}
		publishChatSystem(c.publish, msg)
	}
	// Drive the AI niceties (titles + quick replies) off the turn's final
	// assistant message on a real, completed turn (not an intentional close
	// or a user Stop). Snapshot + reset the latch under the lock.
	c.mu.Lock()
	hook := c.onTurn
	idleHook := c.onTurnIdle
	lastAssistant, lastTS := c.turnLastAssistant, c.turnLastTS
	c.turnLastAssistant, c.turnLastTS = "", ""
	c.mu.Unlock()
	if hook != nil && active && !intentional && !interrupting {
		hook(lastAssistant, lastTS)
	}
	// Fire the session-level idle hook for push notifications. Fires on all
	// NORMAL and interrupted termini (not intentional Close), so the device
	// gets a notification when the agent finishes — even on interrupted turns
	// where the user tapped Stop and then backgrounded.
	if idleHook != nil && active && !intentional {
		idleHook()
	}
}

// failTurn ends the active turn with an explicit error message. Unlike endTurn
// it ALWAYS shows the message (even if the turn had already streamed output),
// because the caller has a concrete failure to report — suppressed only when
// the session is intentionally closing OR the user Stopped the turn.
func (c *codexAppServerProcess) failTurn(msg string) {
	active, _, intentional, interrupting := c.finishTurn()
	if active && !intentional && !interrupting {
		publishChatSystem(c.publish, msg)
	}
	// Fire the idle hook on a terminal failure too — the user needs to know
	// the agent stopped, even if it stopped with an error.
	if active && !intentional {
		c.mu.Lock()
		idleHook := c.onTurnIdle
		c.mu.Unlock()
		if idleHook != nil {
			idleHook()
		}
	}
}

// endTurnQuiet ends the active turn without any notice — for an interrupted
// turn, where the composer just needs to unlock.
func (c *codexAppServerProcess) endTurnQuiet() {
	active, _, intentional, _ := c.finishTurn()
	if active && !intentional {
		c.mu.Lock()
		idleHook := c.onTurnIdle
		c.mu.Unlock()
		if idleHook != nil {
			idleHook()
		}
	}
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
		// A server→client REQUEST carries BOTH an id AND a method (e.g. an
		// approval request). It expects a response echoing the id. Demux it
		// before the response/notification cases — a response has an id but NO
		// method, a notification a method but NO id.
		if env.ID != nil && env.Method != "" {
			// Copy: the params alias the scanner's reused buffer and the
			// handler stashes them past this iteration.
			pcopy := make(json.RawMessage, len(env.Params))
			copy(pcopy, env.Params)
			idcopy := make(json.RawMessage, len(env.ID))
			copy(idcopy, env.ID)
			c.handleServerRequest(idcopy, env.Method, pcopy)
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
	// EOF: the app-server exited. Drop any pending approval (its response
	// channel — stdin — is gone) and close out any in-flight turn; if not an
	// intentional Close, tell the user.
	c.clearPendingApproval()
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
	case "item/started":
		// Stash a fileChange item's path/diff so a following
		// item/fileChange/requestApproval (which carries only the itemId) can
		// join to it and render the real change. Other item/started kinds are
		// nothing to render here.
		if fc, ok := parseCodexFileChangeItem(params); ok {
			c.mu.Lock()
			cp := fc
			c.lastFileChange = &cp
			c.mu.Unlock()
		}
	case "item/agentMessage/delta", "item/completed":
		// item/completed for a fileChange also refreshes the stashed change
		// (the completed item carries the final diff).
		if method == "item/completed" {
			if fc, ok := parseCodexFileChangeItem(params); ok {
				c.mu.Lock()
				cp := fc
				c.lastFileChange = &cp
				c.mu.Unlock()
			}
		}
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

// handleServerRequest routes a server→client REQUEST (one carrying both an id
// AND a method) to a tappable pending-input card — the same view_event shape
// claude's AskUserQuestion produces — and stashes the request id + kind so the
// user's NEXT chat message (AnswerApproval) sends the correct JSON-RPC response.
// Handled kinds:
//   - approval (command / file-change) → {"decision": …}
//   - item/tool/requestUserInput → {"answers": {id:{answers:[…]}}}
//   - mcpServer/elicitation/request → {"action": …, "content"?}
//
// Any OTHER server request is auto-replied with an empty result so it doesn't
// block codex (it never expects a card from us). A pending request counts as
// turn activity (pushes the silence watchdog out).
func (c *codexAppServerProcess) handleServerRequest(rawID json.RawMessage, method string, params json.RawMessage) {
	c.mu.Lock()
	if c.turnActive {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()

	kind := codexServerRequestKindFor(method)
	switch kind {
	case codexReqApproval:
		c.handleApprovalRequest(rawID, method, params)
	case codexReqUserInput:
		c.handleUserInputRequest(rawID, method, params)
	case codexReqElicitation:
		c.handleElicitationRequest(rawID, method, params)
	default:
		// Unknown server request — acknowledge with an empty result rather than
		// leave codex blocked waiting for us (attestation/generate,
		// account/chatgptAuthTokens/refresh, item/tool/call, etc.).
		fmt.Fprintf(os.Stderr, "codex app-server: unhandled server request %q (id %s) — replying empty\n", method, string(rawID))
		c.respondServerRequest(rawID, map[string]any{})
	}
}

// handleApprovalRequest renders a command/file-change approval card and stashes
// it for AnswerApproval. A file-change request carries only the itemId, so it
// joins the stashed lastFileChange (path/diff) for the summary.
func (c *codexAppServerProcess) handleApprovalRequest(rawID json.RawMessage, method string, params json.RawMessage) {
	c.mu.Lock()
	joined := c.lastFileChange
	c.mu.Unlock()

	req, ok := parseCodexApprovalRequest(method, params, joined)
	if !ok {
		fmt.Fprintf(os.Stderr, "codex app-server: unparseable approval request %q — denying\n", method)
		c.respondApproval(rawID, codexDecisionCancel)
		return
	}
	content, ok := codexApprovalCardContent(method, req)
	if !ok {
		fmt.Fprintf(os.Stderr, "codex app-server: approval request %q with empty summary — denying\n", method)
		c.respondApproval(rawID, codexDecisionCancel)
		return
	}
	c.stashPending(rawID, content, codexReqApproval, func(p *codexAppServerProcess) {
		p.pendingApprovalDecline = req.declineAvailable
	})
	fmt.Fprintf(os.Stderr, "codex app-server: approval request %q (id %s): %s\n", method, string(rawID), req.summary)
	c.emitPendingCard(content)
}

// handleUserInputRequest renders an item/tool/requestUserInput question as a
// pending-input card. On a parse failure / empty question it auto-answers
// (empty) so the turn doesn't hang.
func (c *codexAppServerProcess) handleUserInputRequest(rawID json.RawMessage, method string, params json.RawMessage) {
	req, ok := parseCodexUserInputRequest(params)
	if !ok {
		fmt.Fprintf(os.Stderr, "codex app-server: unparseable requestUserInput %q — answering empty\n", method)
		c.respondServerRequest(rawID, codexBuildUserInputResult(codexUserInputRequest{}, ""))
		return
	}
	content, ok := codexUserInputCardContent(req)
	if !ok {
		c.respondServerRequest(rawID, codexBuildUserInputResult(req, ""))
		return
	}
	c.stashPending(rawID, content, codexReqUserInput, func(p *codexAppServerProcess) {
		p.pendingUserInput = req
	})
	fmt.Fprintf(os.Stderr, "codex app-server: requestUserInput (id %s): %s\n", string(rawID), req.questions[0].prompt)
	c.emitPendingCard(content)
}

// handleElicitationRequest renders an mcpServer/elicitation/request as a
// pending-input Approve/Decline card. On a parse failure it declines as a
// safety net (never hang the turn).
func (c *codexAppServerProcess) handleElicitationRequest(rawID json.RawMessage, method string, params json.RawMessage) {
	req, ok := parseCodexElicitationRequest(params)
	if !ok {
		fmt.Fprintf(os.Stderr, "codex app-server: unparseable elicitation %q — declining\n", method)
		c.respondServerRequest(rawID, map[string]any{"action": codexElicitationDecline})
		return
	}
	content, ok := codexElicitationCardContent(req)
	if !ok {
		fmt.Fprintf(os.Stderr, "codex app-server: elicitation with no message — declining\n")
		c.respondServerRequest(rawID, map[string]any{"action": codexElicitationDecline})
		return
	}
	c.stashPending(rawID, content, codexReqElicitation, func(p *codexAppServerProcess) {
		p.pendingElicitation = req
	})
	fmt.Fprintf(os.Stderr, "codex app-server: elicitation (id %s) from %q\n", string(rawID), req.serverName)
	c.emitPendingCard(content)
}

// stashPending records the outstanding server request (id, card, kind) and arms
// the give-up timer BEFORE the card is emitted, so a fast tap (AnswerApproval)
// always finds it. A prior unanswered request is superseded (codex blocks one at
// a time per turn). extra sets kind-specific fields under the same lock.
func (c *codexAppServerProcess) stashPending(rawID json.RawMessage, content string, kind codexServerRequestKind, extra func(*codexAppServerProcess)) {
	c.mu.Lock()
	if c.approvalTimer != nil {
		c.approvalTimer.Stop()
	}
	idForTimer := make(json.RawMessage, len(rawID))
	copy(idForTimer, rawID)
	c.pendingApprovalID = idForTimer
	c.pendingApprovalCard = content
	c.pendingKind = kind
	// Reset kind-specific fields, then let extra set the relevant one.
	c.pendingApprovalDecline = false
	c.pendingUserInput = codexUserInputRequest{}
	c.pendingElicitation = codexElicitationRequest{}
	if extra != nil {
		extra(c)
	}
	c.approvalTimer = time.AfterFunc(askAnswerTimeout, func() { c.expireApproval(idForTimer) })
	c.mu.Unlock()
}

// emitPendingCard publishes the pending-input card and fires the
// pending-input push hook (a reattaching client re-sees the card via
// PendingApprovalCard).
func (c *codexAppServerProcess) emitPendingCard(content string) {
	c.emit(codexAppEvent{role: "assistant", content: content})
	c.mu.Lock()
	pendingHook := c.onPendingInput
	c.mu.Unlock()
	if pendingHook != nil {
		pendingHook()
	}
}

// AnswerApproval delivers the user's tap/reply to a pending server request: it
// builds the right JSON-RPC response for the request's KIND and reports
// handled=true so SendChat skips the normal turn send (the message WAS the
// answer, not a new prompt). handled=false when nothing is pending — SendChat
// then routes the message as a normal turn.
//
//   - approval     → {"decision": accept|decline|cancel}
//   - requestUserInput → {"answers": {questionId:{answers:[<reply>]}}}
//   - elicitation  → {"action": accept|decline}
func (c *codexAppServerProcess) AnswerApproval(msg string) bool {
	p, ok := c.takePending()
	if !ok {
		return false
	}
	switch p.kind {
	case codexReqUserInput:
		fmt.Fprintf(os.Stderr, "codex app-server: requestUserInput answered (id %s)\n", string(p.id))
		c.respondServerRequest(p.id, codexBuildUserInputResult(p.userInput, msg))
	case codexReqElicitation:
		action := codexElicitationActionFor(msg)
		fmt.Fprintf(os.Stderr, "codex app-server: elicitation answered (id %s) → %s\n", string(p.id), action)
		c.respondServerRequest(p.id, map[string]any{"action": action})
	default: // codexReqApproval
		decision := codexApprovalDecisionFor(msg, p.declineAvailable)
		fmt.Fprintf(os.Stderr, "codex app-server: approval answered (id %s) → %s\n", string(p.id), decision)
		c.respondApproval(p.id, decision)
	}
	return true
}

// codexPending is a snapshot of the outstanding server request, returned by
// takePending so AnswerApproval (and the safety-net paths) can build the right
// response after releasing the lock.
type codexPending struct {
	id               json.RawMessage
	kind             codexServerRequestKind
	declineAvailable bool
	userInput        codexUserInputRequest
}

// takePending atomically consumes the stashed server request (and stops its
// timer), returning a snapshot. ok=false when none is pending.
func (c *codexAppServerProcess) takePending() (codexPending, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pendingApprovalID == nil {
		return codexPending{}, false
	}
	p := codexPending{
		id:               c.pendingApprovalID,
		kind:             c.pendingKind,
		declineAvailable: c.pendingApprovalDecline,
		userInput:        c.pendingUserInput,
	}
	c.clearPendingLocked()
	return p, true
}

// clearPendingLocked resets all pending-server-request state and stops the
// give-up timer. Caller holds c.mu.
func (c *codexAppServerProcess) clearPendingLocked() {
	c.pendingApprovalID = nil
	c.pendingApprovalCard = ""
	c.pendingApprovalDecline = false
	c.pendingKind = codexReqUnknown
	c.pendingUserInput = codexUserInputRequest{}
	c.pendingElicitation = codexElicitationRequest{}
	if c.approvalTimer != nil {
		c.approvalTimer.Stop()
		c.approvalTimer = nil
	}
}

// codexSafetyNetResult builds the deny/decline response for the given request
// kind, used when an outstanding card is abandoned (timeout / EOF / Close) so
// the turn never hangs.
func codexSafetyNetResult(kind codexServerRequestKind, userInput codexUserInputRequest) map[string]any {
	switch kind {
	case codexReqUserInput:
		// Empty answer arrays for every question (no answer at all) — distinct
		// from a deliberate blank reply.
		return codexBuildEmptyUserInputResult(userInput)
	case codexReqElicitation:
		return map[string]any{"action": codexElicitationDecline}
	default: // codexReqApproval
		return map[string]any{"decision": codexDecisionCancel}
	}
}

// PendingApprovalCard returns the rendered card for an outstanding server
// request (and true), or ok=false when none is pending — the codex twin of
// PendingAskChatContent, for re-surfacing the card to a reattaching client.
func (c *codexAppServerProcess) PendingApprovalCard() (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pendingApprovalID == nil || c.pendingApprovalCard == "" {
		return "", false
	}
	return c.pendingApprovalCard, true
}

// clearPendingApproval denies any outstanding server request on EOF/Close so the
// turn doesn't wedge waiting for a tap that can never arrive. No-op when nothing
// is pending. Safe to call after stdin is gone — the write just errors
// harmlessly. The deny shape matches the request kind (cancel / empty answers /
// decline).
func (c *codexAppServerProcess) clearPendingApproval() {
	p, ok := c.takePending()
	if !ok {
		return
	}
	fmt.Fprintf(os.Stderr, "codex app-server: pending request (id %s, kind %d) abandoned — denying\n", string(p.id), p.kind)
	c.respondServerRequest(p.id, codexSafetyNetResult(p.kind, p.userInput))
}

// expireApproval auto-denies a server request the user never answered (the
// give-up timer fired). Guarded against a race with AnswerApproval: only acts if
// the still-pending id matches (an answered/superseded request already cleared
// it). The deny shape matches the request kind.
func (c *codexAppServerProcess) expireApproval(rawID json.RawMessage) {
	c.mu.Lock()
	if c.pendingApprovalID == nil || !bytes.Equal(c.pendingApprovalID, rawID) {
		c.mu.Unlock()
		return
	}
	kind := c.pendingKind
	userInput := c.pendingUserInput
	c.clearPendingLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "codex app-server: request (id %s, kind %d) timed out — denying\n", string(rawID), kind)
	c.respondServerRequest(rawID, codexSafetyNetResult(kind, userInput))
}

// respondApproval sends the JSON-RPC decision response for an approval request
// ({"id":<echo>,"result":{"decision":<accept|cancel|…>}}).
func (c *codexAppServerProcess) respondApproval(rawID json.RawMessage, decision string) {
	c.respondServerRequest(rawID, map[string]any{"decision": decision})
}

// respondServerRequest writes a JSON-RPC result response echoing the request id.
// Best-effort: a write error (stdin gone) is logged, not surfaced — the turn's
// own terminus handling covers a dead app-server.
func (c *codexAppServerProcess) respondServerRequest(rawID json.RawMessage, result any) {
	line, err := encodeCodexResponse(rawID, result)
	if err != nil {
		fmt.Fprintf(os.Stderr, "codex app-server: encode server-request response: %v\n", err)
		return
	}
	if err := c.writeLine(line); err != nil {
		fmt.Fprintf(os.Stderr, "codex app-server: write server-request response: %v\n", err)
	}
}

// routeTurnResponse handles a JSON-RPC response correlated to the active
// turn/compact request OR a pending turn/steer request. Returns true when it
// owns the response (so the reader won't also forward it to the handshake
// waiter).
//
// Turn/compact responses: a JSON-RPC error means the request was rejected
// outright (e.g. activeTurnNotSteerable, badRequest) — no turn/completed will
// arrive, so the turn must be failed here or it wedges turnActive forever. A
// success ack is swallowed; the turn then streams via notifications.
//
// Steer responses: a success means the steer was accepted (turn continues
// unchanged). An error — especially -32600 "no active turn" — triggers the
// turn/start fallback path so the message is never lost. Either way the
// steer latch is cleared.
func (c *codexAppServerProcess) routeTurnResponse(rawID, errRaw json.RawMessage) bool {
	var id int
	if json.Unmarshal(rawID, &id) != nil {
		return false
	}
	c.mu.Lock()
	isTurnReq := c.turnActive && id == c.turnReqID
	isSteerReq := c.steerReqID != 0 && id == c.steerReqID
	var steerText string
	if isSteerReq {
		steerText = c.steerText
		c.steerReqID = 0
		c.steerText = ""
	}
	if isTurnReq || isSteerReq {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()

	if isSteerReq {
		c.handleSteerResponse(steerText, errRaw)
		return true
	}
	if !isTurnReq {
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
	ts := claudeChatNow().UTC().Format(time.RFC3339Nano)
	payload, err := json.Marshal(map[string]any{
		"type": "view_event",
		"view": "chat",
		"event": map[string]any{
			"role":    ev.role,
			"content": ev.content,
			"ts":      ts,
			"files":   []any{},
		},
	})
	if err != nil {
		return
	}
	c.mu.Lock()
	c.published = true
	if ev.role == "assistant" {
		// Latch the turn's final assistant message for the AI-niceties hook.
		c.turnLastAssistant, c.turnLastTS = ev.content, ts
	}
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
	// Mark the turn as user-Stopped so its terminus (turn/completed:interrupted,
	// a racing thread `idle` status, or a stray error) stays silent — no "no
	// reply"/error notice. The "Stopped." line is published by InterruptTurn.
	c.interrupting = true
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "codex app-server: turn interrupt (thread %s, turn %s, id %d)\n", tid, turnID, id)
	return c.writeRequest(id, "turn/interrupt", map[string]any{"threadId": tid, "turnId": turnID})
}

// Steer injects a user message into the currently-running turn via
// turn/steer. The steer is delivered to the model at the next reasoning/step
// boundary — it does NOT retroactively delete already-emitted tokens. codex
// responds with either a success {"id":N,"result":{"turnId":"…"}} or an
// error {"id":N,"error":{…}}; the response is routed in routeTurnResponse:
//
//   - success → steer confirmed; the turn continues on the same turn id.
//   - -32600 "no active turn" (turn finished before steer arrived) → fall
//     back to a normal turn/start so the message is never lost.
//
// Steer is a no-op (returns nil) when no turn is in flight or the turn id
// has not yet been latched — the caller (Send) already checks this before
// delegating.
func (c *codexAppServerProcess) Steer(text string) error {
	c.mu.Lock()
	if c.closed || !c.turnActive || c.turnID == "" {
		c.mu.Unlock()
		return nil
	}
	tid := c.threadID
	turnID := c.turnID
	id := c.allocIDLocked()
	c.steerReqID = id
	c.steerText = text
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "codex app-server: turn steer (thread %s, turn %s, id %d)\n", tid, turnID, id)
	if err := c.writeRequest(id, "turn/steer", codexTurnSteerParams(tid, turnID, text)); err != nil {
		c.mu.Lock()
		if c.steerReqID == id {
			c.steerReqID = 0
			c.steerText = ""
		}
		c.mu.Unlock()
		fmt.Fprintf(os.Stderr, "codex app-server: turn steer write error: %v\n", err)
	}
	return nil
}

// handleSteerResponse acts on the JSON-RPC response to a pending turn/steer
// request. On success the steer is confirmed (the turn continues, no action
// needed). On any error — especially -32600 "no active turn" (the turn
// completed before the steer arrived) — the steer text is re-sent via a
// normal turn/start so the user's message is never lost.
//
// Caller must NOT hold c.mu.
func (c *codexAppServerProcess) handleSteerResponse(steerText string, errRaw json.RawMessage) {
	if len(errRaw) == 0 || string(errRaw) == "null" {
		// Steer accepted — turn continues, nothing more to do.
		fmt.Fprintf(os.Stderr, "codex app-server: turn steer accepted\n")
		return
	}
	// Steer rejected. Check for -32600 "no active turn to steer" specifically —
	// that means the turn finished just before our steer arrived, so we fall back
	// to a normal turn/start with the same text. Any other error is also treated
	// as a fallback to be safe: if we can't steer, the message must still land.
	code := codexRPCErrorCode(errRaw)
	msg := codexRPCErrorMessage(errRaw)
	fmt.Fprintf(os.Stderr, "codex app-server: turn steer rejected (code %d, %s) — falling back to turn/start\n", code, msg)

	// End the current turn if it's still considered active (a racing
	// turn/completed may already have cleared it). Then start a fresh turn.
	// We call endTurn(), not failTurn(): the steer failure is not a user-visible
	// error — the fallback turn/start will carry the message forward.
	c.mu.Lock()
	if c.turnActive {
		c.mu.Unlock()
		c.endTurn()
	} else {
		c.mu.Unlock()
	}

	// Start a new turn with the original steer text.
	c.mu.Lock()
	if c.closed || !c.inited || c.turnActive {
		c.mu.Unlock()
		return
	}
	tid := c.threadID
	id := c.allocIDLocked()
	c.turnActive = true
	c.turnReqID = id
	c.published = false
	c.interrupting = false
	c.turnStderrOffset = c.stderrLenLocked()
	c.beginTurnWatchdogLocked()
	c.mu.Unlock()

	fmt.Fprintf(os.Stderr, "codex app-server: steer fallback — turn start (thread %s, id %d)\n", tid, id)
	if err := c.writeRequest(id, "turn/start", codexTurnStartParams(tid, steerText, c.override)); err != nil {
		c.endTurn()
		publishChatSystem(c.publish, "⚠️ codex: turn failed to send: "+err.Error())
	}
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
	// Deny any outstanding server request before stdin closes (best-effort: the
	// write may race the close, which is fine — the dead app-server can't act on
	// it). The deny shape matches the request kind.
	if c.pendingApprovalID != nil {
		id := c.pendingApprovalID
		result := codexSafetyNetResult(c.pendingKind, c.pendingUserInput)
		c.clearPendingLocked()
		if line, err := encodeCodexResponse(id, result); err == nil && c.stdin != nil {
			_, _ = c.stdin.Write(line)
		}
	}
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

// stderrLenLocked returns the current captured-stderr length (the turn-start
// offset). Caller holds c.mu.
func (c *codexAppServerProcess) stderrLenLocked() int {
	if c.stderrBuf == nil {
		return 0
	}
	return c.stderrBuf.Len()
}

// stderrSinceTurn returns only the stderr written AFTER the active turn started,
// so a turn-failure notice reflects the turn's own error and not the startup
// residue (codex's benign "project not trusted" launch line). Falls back to the
// full buffer if the offset is out of range (defensive).
func (c *codexAppServerProcess) stderrSinceTurn() string {
	c.mu.Lock()
	off := c.turnStderrOffset
	c.mu.Unlock()
	s := c.stderrString()
	if off > 0 && off <= len(s) {
		return s[off:]
	}
	return s
}
