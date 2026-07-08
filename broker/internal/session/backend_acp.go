package session

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// This file is the ACP (Agent Client Protocol) backend — a new protocol family
// in the protocol-keyed AgentBackend registry, alongside stream-json (claude),
// codex-app-server (codex) and opencode-server (opencode). ACP is the
// Zed-originated open standard for client⇄agent integration; gemini-cli speaks
// it natively (`gemini --acp`). Adding the protocol once makes every
// ACP-speaking agent (gemini today; Zed family, goose, later a native pi
// backend) cheap to onboard via a manifest alone.
//
// ACP = "codex app-server's stdio JSON-RPC reader" + "opencode's
// turn-accumulator + server→client approval bridge". Both halves already exist
// in-tree; this file composes them for the ACP wire (docs/ACP-PROTOCOL.md,
// verified live against gemini-cli 0.42.0). The pure wire helpers live in
// backend_acpwire.go (table-tested); this file owns the process + stdio I/O.

// --- backend registration ---

// acpBackend is the AgentBackend for protocol "acp". One long-lived
// `<agent> --acp` child per session hosts the conversation; the backend runs
// the initialize → session/new handshake, streams session/update notifications
// into one assistant bubble per turn, bridges session/request_permission onto
// the approval card, interrupts via session/cancel, and resumes via
// session/load (when the agent's loadSession capability is set).
type acpBackend struct{}

func init() { registerBackend("acp", acpBackend{}) }

// Capabilities declares the ACP protocol's feature set (docs/ACP-PROTOCOL.md
// §8). Compact/Effort/Usage/Steer are unsupported in v1 (no base-ACP verb);
// the rest map to native ACP methods.
func (acpBackend) Capabilities() BackendCapabilities {
	return BackendCapabilities{
		Compact:         false, // no session/compact in base ACP
		AskUserQuestion: true,  // session/request_permission → approval card
		Effort:          false, // ACP modes are permission/editor modes, not reasoning effort
		ModelOverride:   true,  // session/set_model (gemini-cli unstable_setSessionModel)
		Resume:          true,  // session/load when agentCapabilities.loadSession
		Interrupt:       true,  // session/cancel
		Usage:           false, // no account-usage source (per-turn tokens only)
		Steer:           false, // no mid-turn-inject verb
	}
}

// CatalogProbe spawns a throwaway `<agent> --acp`, runs initialize + session/new,
// reads the embedded models block, and kills the child. The model catalog is a
// free per-session side effect of session/new (no extra RPC), so the probe is
// just a truncated handshake.
func (acpBackend) CatalogProbe(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
	return probeACPCatalog(ctx, bin, extraEnv)
}

// Usage is unsupported for ACP (Capabilities.Usage=false): there is no
// account-level subscription-usage source in base ACP, only the per-turn token
// deltas that feed the context gauge. The session never fires a doomed fetch.
func (acpBackend) Usage(ctx context.Context, do httpDoFunc, homeDir string) (AccountUsage, bool, error) {
	return AccountUsage{}, false, nil
}

// Spawn launches the session's long-lived `<agent> --acp`, runs the handshake
// (initialize → session/new or session/load on resume), and wires the reader
// into the chat channel. The resumeCodexThreadID slot carries the persisted ACP
// sessionId (the generic "agent's own conversation id" — ACP reuses codex's
// plumbing, like opencode). On a hard spawn failure the error is returned so
// chat is disabled gracefully (the Terminal tab is unaffected).
func (acpBackend) Spawn(s *Session, adapter agents.Adapter, req spawnRequest) (spawnResult, error) {
	// Seed the persisted ACP sessionId (recovery) and clear any prior respawn,
	// like codexSeedThread / opencode. The backend's own latch
	// (s.latchCodexThreadID) persists the id once session/new returns it.
	s.mu.Lock()
	s.codexThreadID = req.resumeCodexThreadID
	s.chatRespawn = nil
	s.mu.Unlock()

	proc, err := newACPProcess(
		adapter.Command[0],
		s.workspaceDir,
		s.commandEnv(nil),
		s.override,
		s.PublishText,
		s.accumulateUsage,
		req.resumeCodexThreadID,
		s.latchCodexThreadID,
	)
	if err != nil {
		fmt.Fprintf(os.Stderr, "session %s: acp (%s --acp) spawn failed: %v (chat disabled)\n", s.ID, adapter.Command[0], err)
		return spawnResult{}, err
	}
	wireACPTurnHook(s, req.aiGen, proc)
	return spawnResult{backend: proc}, nil
}

// wireACPTurnHook builds the per-session AI-niceties generators (titles + quick
// replies) and attaches them to the ACP backend via its native setTurnHook.
// nil aiGen → nil generators → the hook no-ops. Twin of wireCodexTurnHook /
// wireOpencodeTurnHook.
func wireACPTurnHook(s *Session, aiGen aiGenProvider, proc *acpProcess) {
	qrGen := newQuickReplyGeneratorWithProvider(s.ID, aiGen, s.PublishText, s.SubscriberCount)
	s.titleGen = newTitleGeneratorWithProvider(s.ID, aiGen, s.firstPrompt, s.applyAITitle)
	if qrGen == nil && s.titleGen == nil {
		return
	}
	proc.setTurnHook(func(lastAssistant, msgID string) {
		qrGen.kickoff(lastAssistant, msgID)
		s.titleGen.onTurnEnd(lastAssistant)
	})
}

// --- the long-lived process ---

// acpTurnSilenceTimeout force-ends a turn that has produced no ACP frame for
// this long, so a hung provider / dropped stream self-heals instead of wedging
// the composer forever. Every owned-session frame resets it. 2 minutes is
// generous for gemini's first-token latency (the opencode 2-min pattern from
// #471) while still surfacing a dead provider in reasonable time.
const acpTurnSilenceTimeout = 2 * time.Minute

// acpProcess drives one session's `<agent> --acp` child + its JSON-RPC control
// plane over stdio. One prompt (turn) is outstanding at a time; the prompt
// response carries the terminal stopReason.
type acpProcess struct {
	binary   string
	dir      string
	env      []string
	override SpawnOverride

	publish   func([]byte)
	onUsage   func(usageDelta)
	onSession func(string) // fires once when the ACP sessionId is first latched
	// onTurn fires at each turn's normal end with the final assistant text +
	// the ts the apps tied it to — drives AI niceties. nil when no provider.
	onTurn func(lastAssistant, msgID string)
	// onTurnIdle fires after any turn end once turnActive clears (push notify).
	onTurnIdle func()
	// onPendingInput fires when a permission card is stashed (push notify).
	onPendingInput func()
	// onTurnStart fires when a turn begins (push notify / LA start).
	onTurnStart func()

	cmd       *exec.Cmd
	stdin     io.WriteCloser
	stderrBuf *bytes.Buffer

	mu sync.Mutex
	// nextID is the JSON-RPC request id counter (initialize=1, session new/load=2,
	// then prompts/set_mode take 3,4,…).
	nextID int
	// sessionID is the ACP session id (latched on session/new or seeded on
	// resume). Empty until the handshake completes.
	sessionID string
	// loadSession records the agent's loadSession capability (from initialize),
	// gating whether resume uses session/load vs a fresh session/new.
	loadSession bool
	// modes is the per-session mode catalog from session/new (default/plan/…),
	// used to apply the conduit PermissionMode override via session/set_mode.
	modes []acpMode
	// models is the per-session model catalog from session/new, used to apply
	// the conduit SpawnOverride.Model via session/set_model (drop-if-unknown).
	models []acpModel
	inited bool
	closed bool

	// turnActive guards one turn at a time. The prompt id is outstanding for the
	// whole turn; the reader resolves it on the id response (stopReason).
	turnActive bool
	// turnReqID is the JSON-RPC id of the active session/prompt request, so the
	// reader correlates its response (the turn terminus) back to the turn.
	turnReqID int
	// interrupting marks a user-Stopped turn (session/cancel sent) so its
	// terminus (stopReason:cancelled) is quiet.
	interrupting bool
	// turn accumulates the active turn's agent_message_chunk text into one bubble.
	turn *strings.Builder
	// published records whether the active turn emitted any chat event.
	published bool
	// turnLastAssistant / turnLastTS hold the active turn's emitted assistant
	// prose + ts, handed to onTurn at turn end for the AI niceties.
	turnLastAssistant string
	turnLastTS        string

	// lastActivity / watchdog / turnGen / silenceTimeout back the silence
	// watchdog (codex/opencode twin).
	lastActivity   time.Time
	watchdog       *time.Timer
	turnGen        int
	silenceTimeout time.Duration

	// pendingPermID is the server→client session/request_permission request's id
	// (echoed back verbatim — gemini's server-side id is its own counter space).
	// Non-nil while a permission card awaits the user's tap. Guarded by mu.
	pendingPermID json.RawMessage
	// pendingPermCard is the rendered card for the outstanding permission, kept so
	// a reattaching client can re-see it (PendingApprovalCard).
	pendingPermCard string
	// pendingPermOptions is the agent-supplied option list for the outstanding
	// permission — the broker echoes the chosen option's id, never inventing one.
	pendingPermOptions []acpPermissionOption
	// permTimer auto-cancels an unanswered permission after askAnswerTimeout so a
	// never-tapped card can't wedge the turn forever. nil when none is pending.
	permTimer *time.Timer
	// currentModel is the model identifier reported by the agent during
	// session/new (acpSessionNewResult.currentModel). Latched in
	// latchSessionResult; satisfies the modelReporter interface.
	currentModel string
}

// newACPProcess spawns `<agent> --acp` and runs the initialize → session
// handshake synchronously (mirroring newCodexAppServerProcess / opencode). When
// seedSessionID is non-empty (recovery) and the agent supports loadSession, it
// resumes via session/load; otherwise it starts a fresh session/new. On a hard
// spawn / handshake failure the error is returned so the caller can disable chat
// gracefully.
func newACPProcess(binary, dir string, env []string, override SpawnOverride, publish func([]byte), onUsage func(usageDelta), seedSessionID string, onSession func(string)) (*acpProcess, error) {
	c := &acpProcess{
		binary:    binary,
		dir:       dir,
		env:       env,
		override:  override,
		publish:   publish,
		onUsage:   onUsage,
		onSession: onSession,
		sessionID: seedSessionID,
		// initialize=1, session new/load=2 are sent literally during the
		// handshake; allocIDLocked hands prompts/set_mode 3,4,… and keeps them
		// distinct from handshake ids so the reader's turn-response correlation
		// can't alias a handshake response.
		nextID:         2,
		silenceTimeout: acpTurnSilenceTimeout,
	}
	if err := c.spawn(); err != nil {
		return nil, err
	}
	return c, nil
}

// spawn starts the `<agent> --acp` subprocess, wires stdin/stdout/stderr, starts
// the reader goroutine, and runs the handshake.
func (c *acpProcess) spawn() error {
	cmd := exec.Command(c.binary, "--acp")
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
	c.stderrBuf = &bytes.Buffer{}
	cmd.Stderr = &limitWriter{w: c.stderrBuf, limit: 4096}
	if err := cmd.Start(); err != nil {
		return err
	}
	c.cmd = cmd
	c.stdin = stdin

	resp := make(chan json.RawMessage, 1)
	go c.readLoop(stdout, resp)

	fmt.Fprintf(os.Stderr, "acp: spawned %s --acp (pid %d, dir %s)\n", c.binary, cmd.Process.Pid, c.dir)

	if err := c.handshake(resp); err != nil {
		publishChatSystem(c.publish, "⚠️ acp: agent failed to start: "+err.Error())
		return err
	}
	return nil
}

// handshake runs initialize → session/new (or session/load on resume)
// synchronously, then applies the permission-mode override via session/set_mode.
// resp delivers the next correlated response from the reader goroutine.
func (c *acpProcess) handshake(resp <-chan json.RawMessage) error {
	// initialize (id:1)
	if err := c.writeRequest(1, "initialize", acpInitializeParams()); err != nil {
		return fmt.Errorf("initialize write: %w", err)
	}
	initRaw, err := waitACPResult(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "acp: initialize failed: %v\n", err)
		return fmt.Errorf("initialize: %w", err)
	}
	c.mu.Lock()
	c.loadSession = parseACPInitializeResult(initRaw).loadSession
	loadSession := c.loadSession
	seed := c.sessionID
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "acp: initialize ok (loadSession=%v)\n", loadSession)

	// session/new or session/load (id:2)
	if seed != "" && loadSession {
		if err := c.writeRequest(2, "session/load", acpSessionLoadParams(seed, c.dir)); err != nil {
			return fmt.Errorf("session/load write: %w", err)
		}
		raw, lerr := waitACPResult(resp)
		if lerr != nil {
			// Resume failed (the agent forgot the session, store rotated): fall
			// back to a fresh session/new so chat continues (opencode posture).
			fmt.Fprintf(os.Stderr, "acp: session/load(%s) failed: %v — starting fresh\n", seed, lerr)
			c.mu.Lock()
			c.sessionID = ""
			c.mu.Unlock()
			return c.startFreshSession(resp)
		}
		// session/load returns the same modes/models shape as session/new.
		if r, ok := parseACPSessionNewResult(raw); ok {
			c.latchSessionResult(r, false)
		}
		fmt.Fprintf(os.Stderr, "acp: resumed session %s\n", seed)
	} else {
		if err := c.startFreshSession(resp); err != nil {
			return err
		}
	}

	c.applyModeOverride()
	c.applyModelOverride()

	c.mu.Lock()
	c.inited = true
	c.mu.Unlock()
	return nil
}

// startFreshSession sends session/new (id:2), latches the returned sessionId +
// catalog, and persists the id for resume.
func (c *acpProcess) startFreshSession(resp <-chan json.RawMessage) error {
	if err := c.writeRequest(2, "session/new", acpSessionNewParams(c.dir)); err != nil {
		return fmt.Errorf("session/new write: %w", err)
	}
	raw, err := waitACPResult(resp)
	if err != nil {
		fmt.Fprintf(os.Stderr, "acp: session/new failed: %v\n", err)
		return fmt.Errorf("session/new: %w", err)
	}
	r, ok := parseACPSessionNewResult(raw)
	if !ok {
		return fmt.Errorf("session/new: no session id in result")
	}
	c.latchSessionResult(r, true)
	fmt.Fprintf(os.Stderr, "acp: started session %s (%d models, %d modes)\n", r.sessionID, len(r.models), len(r.modes))
	return nil
}

// latchSessionResult records the sessionId (firing onSession the first time so
// the session persists it for resume) and stashes the mode catalog. fresh marks
// a session/new (the id is genuinely new); on session/load the id is the seed we
// already had.
func (c *acpProcess) latchSessionResult(r acpSessionNewResult, fresh bool) {
	c.mu.Lock()
	first := c.sessionID == ""
	if r.sessionID != "" {
		c.sessionID = r.sessionID
	}
	c.modes = r.modes
	c.models = r.models
	if r.currentModel != "" {
		c.currentModel = r.currentModel
	}
	c.mu.Unlock()
	if fresh && first && c.onSession != nil {
		c.onSession(r.sessionID)
	}
}

// applyModeOverride applies the conduit PermissionMode override via
// session/set_mode (the protocol-level mode switch — ACP has no model/effort CLI
// flag). A no-op when the override isn't "plan" or the agent didn't advertise a
// plan mode. Best-effort: a write/response error is logged, not fatal.
func (c *acpProcess) applyModeOverride() {
	c.mu.Lock()
	sid := c.sessionID
	modes := c.modes
	c.mu.Unlock()
	modeID, ok := acpModeForOverride(c.override, modes)
	if !ok || sid == "" {
		return
	}
	id := c.allocID()
	fmt.Fprintf(os.Stderr, "acp: session/set_mode %q (session %s, id %d)\n", modeID, sid, id)
	if err := c.writeRequest(id, "session/set_mode", acpSetModeParams(sid, modeID)); err != nil {
		fmt.Fprintf(os.Stderr, "acp: session/set_mode write: %v\n", err)
	}
	// The response (and any racing session/update current_mode_update) is
	// handled by the reader; we don't block the handshake on it.
}

// applyModelOverride applies the conduit SpawnOverride.Model via
// session/set_model (gemini-cli's unstable_setSessionModel extension — see
// docs/ACP-PROTOCOL.md). A no-op when the override is empty or the model
// isn't one of session/new's advertised availableModels — same
// drop-if-unknown safety rule as the argv model override (a stale/bad model
// id must never fail the spawn). Best-effort like applyModeOverride: the
// write is fire-and-forget, but on a successful write c.currentModel is
// latched optimistically to the requested model (there is no
// model-changed session/update notification to wait for), so the status
// frame reflects the override immediately rather than the pre-override
// currentModelId from session/new.
func (c *acpProcess) applyModelOverride() {
	c.mu.Lock()
	sid := c.sessionID
	models := c.models
	c.mu.Unlock()
	modelID, ok := acpModelForOverride(c.override, models)
	if !ok || sid == "" {
		return
	}
	id := c.allocID()
	fmt.Fprintf(os.Stderr, "acp: session/set_model %q (session %s, id %d)\n", modelID, sid, id)
	if err := c.writeRequest(id, "session/set_model", acpSetModelParams(sid, modelID)); err != nil {
		fmt.Fprintf(os.Stderr, "acp: session/set_model write: %v\n", err)
		return
	}
	c.mu.Lock()
	c.currentModel = modelID
	c.mu.Unlock()
}

// Send runs one ACP turn for the user's message: session/prompt with the
// response outstanding for the whole turn. It returns immediately; output
// streams via publish from the reader. Concurrent Sends while a turn is in
// flight are rejected (one prompt per session; the composer is disabled
// client-side while the agent works).
func (c *acpProcess) Send(text string) error {
	c.mu.Lock()
	if c.closed || !c.inited {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	if c.turnActive {
		c.mu.Unlock()
		return errACPTurnInFlight
	}
	sid := c.sessionID
	if sid == "" {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	id := c.allocIDLocked()
	c.turnActive = true
	c.turnReqID = id
	c.published = false
	c.interrupting = false
	c.turn = &strings.Builder{}
	c.turnLastAssistant = ""
	c.turnLastTS = ""
	c.beginWatchdogLocked()
	startHook := c.onTurnStart
	c.mu.Unlock()

	// Fire turn-start hook outside the lock so it doesn't nest under c.mu.
	if startHook != nil {
		startHook()
	}

	fmt.Fprintf(os.Stderr, "acp: prompt (session %s, id %d)\n", sid, id)
	if err := c.writeRequest(id, "session/prompt", acpPromptParams(sid, text)); err != nil {
		c.endTurnQuiet()
		publishChatSystem(c.publish, "⚠️ acp: prompt failed to send: "+err.Error())
		return nil
	}
	return nil
}

// Interrupt aborts the active turn via the session/cancel notification (the Stop
// button) without closing the agent. The agent resolves the outstanding
// session/prompt with stopReason:cancelled, which endTurn clears quietly. A
// no-op when no turn is in flight or the session is closed.
func (c *acpProcess) Interrupt() error {
	c.mu.Lock()
	if c.closed || !c.turnActive || c.sessionID == "" {
		c.mu.Unlock()
		return nil
	}
	sid := c.sessionID
	c.interrupting = true
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "acp: cancel (session %s)\n", sid)
	// session/cancel is a NOTIFICATION (no id) — fire-and-forget; the turn's
	// completion is observed via the prompt response (stopReason:cancelled).
	return c.writeNotification("session/cancel", acpCancelParams(sid))
}

// TurnActive reports whether a turn is in flight (the authoritative latch the
// broker folds into the status frame).
func (c *acpProcess) TurnActive() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.turnActive
}

// CurrentModel returns the model the ACP session started with, as reported
// by the agent in the session/new result. Implements modelReporter; returns ""
// when the agent did not advertise a current model.
func (c *acpProcess) CurrentModel() string {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.currentModel
}

// Close stops the agent: refuse further Sends, cancel any pending permission,
// close stdin, kill the child. Idempotent.
func (c *acpProcess) Close() error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return nil
	}
	c.closed = true
	// Cancel any outstanding permission before stdin closes (best-effort).
	if c.pendingPermID != nil {
		id := c.pendingPermID
		c.clearPendingLocked()
		if line, err := encodeACPResponse(id, acpCancelledOutcome()); err == nil && c.stdin != nil {
			_, _ = c.stdin.Write(line)
		}
	}
	c.stopWatchdogLocked()
	stdin := c.stdin
	cmd := c.cmd
	c.mu.Unlock()
	if stdin != nil {
		_ = stdin.Close()
	}
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Kill()
	}
	return nil
}

// setTurnHook installs the AI-niceties turn-end callback. Called once at wiring
// time before any Send.
func (c *acpProcess) setTurnHook(fn func(lastAssistant, msgID string)) {
	c.mu.Lock()
	c.onTurn = fn
	c.mu.Unlock()
}

// setTurnIdleHook installs the turn-idle push-notification callback (the
// turnIdleHooker interface). Called once at wiring time before any Send.
func (c *acpProcess) setTurnIdleHook(fn func()) {
	c.mu.Lock()
	c.onTurnIdle = fn
	c.mu.Unlock()
}

// setPendingInputHook installs the pending-input push-notification callback (the
// pendingInputHooker interface). Called once at wiring time before any Send.
func (c *acpProcess) setPendingInputHook(fn func()) {
	c.mu.Lock()
	c.onPendingInput = fn
	c.mu.Unlock()
}

// setTurnStartHook installs the turn-start callback (turnStartHooker interface).
// Called once at wiring time before any Send.
func (c *acpProcess) setTurnStartHook(fn func()) {
	c.mu.Lock()
	c.onTurnStart = fn
	c.mu.Unlock()
}

// --- reader / demux ---

// readLoop scans the agent's stdout JSONL. Demux is identical to codex: a line
// with id+method is a server→client request (echo the id); id-only is a response
// (forwarded to the handshake waiter or owned by the active turn); method-only
// is a notification (session/update).
func (c *acpProcess) readLoop(stdout io.Reader, resp chan<- json.RawMessage) {
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		line := sc.Bytes()
		if len(strings.TrimSpace(string(line))) == 0 {
			continue
		}
		var env acpRPCEnvelope
		if err := json.Unmarshal(line, &env); err != nil {
			continue
		}
		// Server→client REQUEST: id AND method. Copy (the params alias the
		// scanner's reused buffer and the handler stashes them past this
		// iteration).
		if env.ID != nil && env.Method != "" {
			pcopy := make(json.RawMessage, len(env.Params))
			copy(pcopy, env.Params)
			idcopy := make(json.RawMessage, len(env.ID))
			copy(idcopy, env.ID)
			c.handleServerRequest(idcopy, env.Method, pcopy)
			continue
		}
		// Response: id, no method. If it correlates to the active turn the
		// reader owns it (the prompt terminus); otherwise forward a copy to the
		// handshake waiter.
		if env.ID != nil && env.Method == "" {
			if c.routeTurnResponse(env.ID, env.Result, env.Error) {
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
	// EOF: the agent exited. Cancel any pending permission (its response channel
	// — stdin — is gone), close out any in-flight turn, and tell the user unless
	// the close was intentional.
	c.clearPendingPermission()
	c.mu.Lock()
	intentional := c.closed
	active := c.turnActive
	c.mu.Unlock()
	if active {
		c.endTurnQuiet()
	}
	if !intentional {
		msg := "⚠️ The agent ended. Start a new session to continue."
		if snip := firstMeaningfulLine(c.stderrString()); snip != "" {
			msg = "⚠️ acp: agent exited: " + snip
		}
		publishChatSystem(c.publish, msg)
	}
}

// handleNotification routes one server notification. The only streaming verb in
// ACP is session/update, demuxed by its sessionUpdate discriminator. Any
// notification for an active turn counts as activity (resets the watchdog).
func (c *acpProcess) handleNotification(method string, params json.RawMessage) {
	c.mu.Lock()
	if c.turnActive {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()

	if method != "session/update" {
		// Unknown notification — nothing to render.
		return
	}
	u, ok := parseACPUpdate(params)
	if !ok {
		return
	}
	switch u.kind {
	case acpUpdateAgentMessageChunk:
		// Accumulate the assistant prose — emit ONE bubble at turn end (the
		// posture all proven backends share).
		c.mu.Lock()
		if c.turn != nil {
			c.turn.WriteString(u.text)
		}
		c.mu.Unlock()
	case acpUpdateAgentThoughtChunk:
		// Reasoning — dropped from the answer (do NOT fold into the bubble). A
		// future pass could route this to a thinking lane.
	case acpUpdateToolCall, acpUpdateToolCallUpdate:
		// A tool started / progressed. v1 surfaces a tool card; the load-bearing
		// output is still the answer text at turn end.
		if content, ok := acpToolCardContent(u); ok {
			c.emit(acpEvent{role: "tool", content: content})
		}
	case acpUpdatePlan, acpUpdateAvailableCommands, acpUpdateCurrentModeUpdate:
		// Plan/todo lane, slash-command catalog, mode-change echo — dropped in v1.
	}
}

// routeTurnResponse handles a JSON-RPC response correlated to the active
// session/prompt request (the turn terminus). Returns true when it owns the
// response (so the reader won't also forward it to the handshake waiter). A
// JSON-RPC error means the prompt was rejected outright — fail the turn so it
// doesn't wedge turnActive forever. A success carries the stopReason + usage.
func (c *acpProcess) routeTurnResponse(rawID, result, errRaw json.RawMessage) bool {
	var id int
	if json.Unmarshal(rawID, &id) != nil {
		return false
	}
	c.mu.Lock()
	isTurn := c.turnActive && id == c.turnReqID
	if isTurn {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()
	if !isTurn {
		return false
	}
	if len(errRaw) > 0 && string(errRaw) != "null" {
		fmt.Fprintf(os.Stderr, "acp: prompt %d rejected: %s\n", id, string(errRaw))
		c.failTurn("⚠️ acp: " + acpRPCErrorMessage(errRaw))
		return true
	}
	pr := parseACPPromptResult(result)
	if u, ok := acpUsageFromPromptResult(pr); ok && c.onUsage != nil {
		c.onUsage(u)
	}
	fmt.Fprintf(os.Stderr, "acp: turn complete (id %d, stopReason=%q)\n", id, pr.stopReason)
	c.endTurn(pr.stopReason)
	return true
}

// --- turn lifecycle ---

// endTurn ends the active turn on the prompt-response terminus: emit the
// consolidated assistant bubble (unless the turn was a user Stop / cancelled or
// produced no prose), surface any non-quiet stopReason notice, then fire the
// AI-niceties + idle hooks. Idempotent.
func (c *acpProcess) endTurn(stopReason string) {
	c.mu.Lock()
	if !c.turnActive {
		c.mu.Unlock()
		return
	}
	c.turnActive = false
	c.turnReqID = 0
	interrupting := c.interrupting
	c.interrupting = false
	answer := ""
	if c.turn != nil {
		answer = c.turn.String()
	}
	c.turn = nil
	c.stopWatchdogLocked()
	hook := c.onTurn
	idleHook := c.onTurnIdle
	intentional := c.closed
	c.mu.Unlock()

	cancelled := interrupting || stopReason == acpStopReasonCancelled
	if !cancelled && !intentional && strings.TrimSpace(answer) != "" {
		ts := c.emitAssistant(answer)
		if hook != nil {
			hook(answer, ts)
		}
	}
	// Surface a non-quiet terminus (refusal / token-limit) so it isn't silent —
	// but only when the turn isn't a deliberate stop.
	if !cancelled && !intentional {
		if notice := acpStopReasonNotice(stopReason); notice != "" {
			publishChatSystem(c.publish, notice)
		}
		// No prose AND no notice → a real "no reply" so the typing indicator
		// clears (mirrors the other backends' safety net).
		c.mu.Lock()
		published := c.published
		c.mu.Unlock()
		if !published && acpStopReasonNotice(stopReason) == "" && strings.TrimSpace(answer) == "" {
			publishChatSystem(c.publish, "⚠️ acp: no reply from the agent.")
		}
	}
	if idleHook != nil && !intentional {
		idleHook()
	}
}

// endTurnQuiet ends the active turn without any notice — for an interrupted turn
// or an EOF/spawn-error path where the composer just needs to unlock. Fires the
// idle hook (unless intentionally closing) so a backgrounded device still gets a
// push when the turn stops.
func (c *acpProcess) endTurnQuiet() {
	c.mu.Lock()
	if !c.turnActive {
		c.mu.Unlock()
		return
	}
	c.turnActive = false
	c.turnReqID = 0
	c.interrupting = false
	c.turn = nil
	c.stopWatchdogLocked()
	idleHook := c.onTurnIdle
	intentional := c.closed
	c.mu.Unlock()
	if idleHook != nil && !intentional {
		idleHook()
	}
}

// failTurn ends the active turn with an explicit error message (always shown,
// even if the turn streamed output) unless the session is closing or the user
// Stopped the turn.
func (c *acpProcess) failTurn(msg string) {
	c.mu.Lock()
	if !c.turnActive {
		c.mu.Unlock()
		return
	}
	c.turnActive = false
	c.turnReqID = 0
	interrupting := c.interrupting
	c.interrupting = false
	c.turn = nil
	c.stopWatchdogLocked()
	idleHook := c.onTurnIdle
	intentional := c.closed
	c.mu.Unlock()
	if !intentional && !interrupting {
		publishChatSystem(c.publish, msg)
	}
	if idleHook != nil && !intentional {
		idleHook()
	}
}

// emit publishes one chat view_event (assistant / tool / system) and marks the
// turn as having produced output. Latches the final assistant prose for the AI
// niceties.
func (c *acpProcess) emit(ev acpEvent) {
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
		c.turnLastAssistant, c.turnLastTS = ev.content, ts
	}
	c.mu.Unlock()
	c.publish(payload)
}

// emitAssistant publishes one assistant chat view_event with the turn's full
// prose and returns its ts.
func (c *acpProcess) emitAssistant(content string) string {
	ts := claudeChatNow().UTC().Format(time.RFC3339Nano)
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
	c.turnLastAssistant, c.turnLastTS = content, ts
	c.mu.Unlock()
	c.publish(payload)
	return ts
}

// --- permission bridge ---

// handleServerRequest routes a server→client request. session/request_permission
// becomes a tappable approval card (the codex bridge, verbatim). fs/* and
// terminal/* never arrive (we advertised those caps false), but any OTHER server
// request is auto-acked with an empty result so the agent isn't left blocked.
func (c *acpProcess) handleServerRequest(rawID json.RawMessage, method string, params json.RawMessage) {
	c.mu.Lock()
	if c.turnActive {
		c.lastActivity = claudeChatNow()
	}
	c.mu.Unlock()

	if method == "session/request_permission" {
		c.handlePermissionRequest(rawID, params)
		return
	}
	// Unknown / un-advertised server request (fs/*, terminal/*): we never set
	// those capabilities, so the agent shouldn't call them. Ack empty so a
	// stray call doesn't wedge the agent.
	fmt.Fprintf(os.Stderr, "acp: unhandled server request %q (id %s) — replying empty\n", method, string(rawID))
	c.respondServerRequest(rawID, map[string]any{})
}

// handlePermissionRequest renders a session/request_permission as a pending-input
// Approve/Deny card and stashes it for AnswerApproval. On a parse failure /
// no-options request it cancels (safety net: never hang the turn).
func (c *acpProcess) handlePermissionRequest(rawID json.RawMessage, params json.RawMessage) {
	req, ok := parseACPPermissionRequest(params)
	if !ok {
		fmt.Fprintf(os.Stderr, "acp: unparseable permission request — cancelling\n")
		c.respondServerRequest(rawID, acpCancelledOutcome())
		return
	}
	content := acpPermissionCardContent(req)
	c.stashPending(rawID, content, req.options)
	fmt.Fprintf(os.Stderr, "acp: permission request (id %s): %s\n", string(rawID), req.title)
	c.emitPendingCard(content)
}

// stashPending records the outstanding permission (id, card, options) and arms
// the give-up timer BEFORE the card is emitted so a fast tap (AnswerApproval)
// always finds it. A prior unanswered request is superseded.
func (c *acpProcess) stashPending(rawID json.RawMessage, content string, options []acpPermissionOption) {
	c.mu.Lock()
	if c.permTimer != nil {
		c.permTimer.Stop()
	}
	idForTimer := make(json.RawMessage, len(rawID))
	copy(idForTimer, rawID)
	c.pendingPermID = idForTimer
	c.pendingPermCard = content
	c.pendingPermOptions = options
	c.permTimer = time.AfterFunc(askAnswerTimeout, func() { c.expirePermission(idForTimer) })
	c.mu.Unlock()
}

// emitPendingCard publishes the permission card and fires the pending-input push
// hook (a reattaching client re-sees the card via PendingApprovalCard).
func (c *acpProcess) emitPendingCard(content string) {
	c.emit(acpEvent{role: "assistant", content: content})
	c.mu.Lock()
	pendingHook := c.onPendingInput
	c.mu.Unlock()
	if pendingHook != nil {
		pendingHook()
	}
}

// AnswerApproval delivers the user's tap/reply to a pending permission: it
// echoes the agent-supplied optionId for the chosen kind (Approve → allow_once,
// Deny → reject_once) and reports handled=true so SendChat skips the normal turn
// send. handled=false when nothing is pending.
func (c *acpProcess) AnswerApproval(msg string) bool {
	c.mu.Lock()
	if c.pendingPermID == nil {
		c.mu.Unlock()
		return false
	}
	id := c.pendingPermID
	options := c.pendingPermOptions
	c.clearPendingLocked()
	c.mu.Unlock()
	resp := acpPermissionResponseFor(msg, options)
	fmt.Fprintf(os.Stderr, "acp: permission answered (id %s) → %v\n", string(id), resp["outcome"])
	c.respondServerRequest(id, resp)
	return true
}

// PendingApprovalCard returns the rendered card for an outstanding permission
// (and true), or ok=false when none is pending — for re-surfacing the card to a
// reattaching client.
func (c *acpProcess) PendingApprovalCard() (string, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.pendingPermID == nil || c.pendingPermCard == "" {
		return "", false
	}
	return c.pendingPermCard, true
}

// clearPendingLocked resets all pending-permission state and stops the timer.
// Caller holds c.mu.
func (c *acpProcess) clearPendingLocked() {
	c.pendingPermID = nil
	c.pendingPermCard = ""
	c.pendingPermOptions = nil
	if c.permTimer != nil {
		c.permTimer.Stop()
		c.permTimer = nil
	}
}

// clearPendingPermission cancels any outstanding permission on EOF/Close so the
// turn doesn't wedge waiting for a tap that can never arrive.
func (c *acpProcess) clearPendingPermission() {
	c.mu.Lock()
	if c.pendingPermID == nil {
		c.mu.Unlock()
		return
	}
	id := c.pendingPermID
	c.clearPendingLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "acp: pending permission (id %s) abandoned — cancelling\n", string(id))
	c.respondServerRequest(id, acpCancelledOutcome())
}

// expirePermission auto-cancels a permission the user never answered (the
// give-up timer fired). Guarded against a race with AnswerApproval: only acts if
// the still-pending id matches.
func (c *acpProcess) expirePermission(rawID json.RawMessage) {
	c.mu.Lock()
	if c.pendingPermID == nil || !bytes.Equal(c.pendingPermID, rawID) {
		c.mu.Unlock()
		return
	}
	c.clearPendingLocked()
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "acp: permission (id %s) timed out — cancelling\n", string(rawID))
	c.respondServerRequest(rawID, acpCancelledOutcome())
}

// respondServerRequest writes a JSON-RPC result response echoing the request id.
// Best-effort: a write error (stdin gone) is logged, not surfaced.
func (c *acpProcess) respondServerRequest(rawID json.RawMessage, result any) {
	line, err := encodeACPResponse(rawID, result)
	if err != nil {
		fmt.Fprintf(os.Stderr, "acp: encode server-request response: %v\n", err)
		return
	}
	if err := c.writeLine(line); err != nil {
		fmt.Fprintf(os.Stderr, "acp: write server-request response: %v\n", err)
	}
}

// --- watchdog (codex/opencode twin) ---

func (c *acpProcess) beginWatchdogLocked() {
	c.turnGen++
	c.lastActivity = claudeChatNow()
	c.armWatchdogLocked(c.silenceTimeout)
}

func (c *acpProcess) armWatchdogLocked(d time.Duration) {
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

func (c *acpProcess) stopWatchdogLocked() {
	c.turnGen++
	if c.watchdog != nil {
		c.watchdog.Stop()
		c.watchdog = nil
	}
}

func (c *acpProcess) fireWatchdog(gen int) {
	c.mu.Lock()
	if gen != c.turnGen || !c.turnActive {
		c.mu.Unlock()
		return
	}
	if idle := claudeChatNow().Sub(c.lastActivity); idle < c.silenceTimeout {
		c.armWatchdogLocked(c.silenceTimeout - idle)
		c.mu.Unlock()
		return
	}
	c.mu.Unlock()
	fmt.Fprintf(os.Stderr, "acp: turn watchdog fired after %s of silence\n", c.silenceTimeout)
	c.failTurn("⚠️ acp: no response from the agent — ending the turn so you can try again or start a new session.")
}

// --- write helpers ---

func (c *acpProcess) writeRequest(id int, method string, params any) error {
	line, err := encodeACPRequest(id, method, params)
	if err != nil {
		return err
	}
	return c.writeLine(line)
}

func (c *acpProcess) writeNotification(method string, params any) error {
	line, err := encodeACPNotification(method, params)
	if err != nil {
		return err
	}
	return c.writeLine(line)
}

func (c *acpProcess) writeLine(line []byte) error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed || c.stdin == nil {
		return errChatProcessClosed
	}
	_, err := c.stdin.Write(line)
	return err
}

// allocIDLocked returns the next JSON-RPC request id. Caller holds c.mu.
func (c *acpProcess) allocIDLocked() int {
	c.nextID++
	return c.nextID
}

// allocID returns the next request id, taking the lock (for callers not already
// holding it, e.g. applyModeOverride during the handshake).
func (c *acpProcess) allocID() int {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.allocIDLocked()
}

func (c *acpProcess) stderrString() string {
	if c.stderrBuf == nil {
		return ""
	}
	return c.stderrBuf.String()
}

// waitACPResult extracts the result from the next response on the channel,
// returning an error for a JSON-RPC error response. The reader only forwards
// correlated responses, so reading one is correct here (the handshake is
// strictly sequential).
func waitACPResult(resp <-chan json.RawMessage) (json.RawMessage, error) {
	raw, ok := <-resp
	if !ok {
		return nil, fmt.Errorf("acp: agent closed before response")
	}
	var env acpRPCEnvelope
	if err := json.Unmarshal(raw, &env); err != nil {
		return nil, err
	}
	if len(env.Error) > 0 && string(env.Error) != "null" {
		return nil, fmt.Errorf("rpc error: %s", string(env.Error))
	}
	return env.Result, nil
}

// --- catalog probe ---

// probeACPCatalog spawns a throwaway `<agent> --acp`, runs initialize +
// session/new, reads the embedded models block, and kills the child. The model
// catalog is a free per-session result of session/new (no extra RPC). ctx bounds
// the whole probe.
func probeACPCatalog(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
	cmd := exec.CommandContext(ctx, bin, "--acp")
	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	cmd.Stderr = io.Discard
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("acp catalog probe: start: %w", err)
	}
	defer func() {
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	resp := make(chan acpRPCEnvelope, 8)
	go func() {
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for sc.Scan() {
			var env acpRPCEnvelope
			if json.Unmarshal(sc.Bytes(), &env) != nil {
				continue
			}
			// Only forward correlated responses (id, no method); drop
			// notifications + server requests (we never answer them in the probe).
			if env.ID != nil && env.Method == "" {
				select {
				case resp <- env:
				default:
				}
			}
		}
		close(resp)
	}()

	write := func(id int, method string, params any) error {
		line, werr := encodeACPRequest(id, method, params)
		if werr != nil {
			return werr
		}
		_, werr = stdin.Write(line)
		return werr
	}
	wait := func(wantID int) (json.RawMessage, error) {
		for {
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case env, ok := <-resp:
				if !ok {
					return nil, fmt.Errorf("acp catalog probe: agent closed before response")
				}
				var id int
				if json.Unmarshal(env.ID, &id) != nil || id != wantID {
					continue
				}
				if len(env.Error) > 0 && string(env.Error) != "null" {
					return nil, fmt.Errorf("acp catalog probe: rpc error: %s", string(env.Error))
				}
				return env.Result, nil
			}
		}
	}

	if err := write(1, "initialize", acpInitializeParams()); err != nil {
		return nil, err
	}
	if _, err := wait(1); err != nil {
		return nil, err
	}
	// A throwaway probe cwd: the agent's own temp dir. Use the OS temp dir so the
	// probe never writes into a real workspace.
	if err := write(2, "session/new", acpSessionNewParams(os.TempDir())); err != nil {
		return nil, err
	}
	raw, err := wait(2)
	if err != nil {
		return nil, err
	}
	r, ok := parseACPSessionNewResult(raw)
	if !ok {
		return nil, fmt.Errorf("acp catalog probe: no session in result")
	}
	return acpModelsToCatalog(r), nil
}
