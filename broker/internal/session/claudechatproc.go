package session

import (
	"context"
	"errors"
	"io"
	"os/exec"
	"sync"
)

// chatProcess manages a single agent subprocess running in structured
// stream-json mode (e.g. `claude -p --input-format stream-json
// --output-format stream-json`). Unlike the PTY-attached TUI agent, this
// one talks over plain stdin/stdout pipes: the user's composer messages go
// in as stream-json `user` events, and assistant events come out and are
// mapped to chat view_events by processClaudeStreamOutput.
//
// This is slice 2b's foundation (task #24, decision B + B-i). Wiring it
// into the session lifecycle behind the `chat_mode = "stream-json"` adapter
// flag — and giving the Terminal tab its own shell PTY — is the next step.
type chatProcess struct {
	cmd   *exec.Cmd
	stdin io.WriteCloser

	mu     sync.Mutex
	closed bool
	// turnActive is true between a user Send and the stream-json `result`
	// envelope that ends the turn (claude has no native latch — we infer it
	// from the same turn-end signal the title/quick-reply generators use).
	// Folded into the status frame's `turn_active` so a reconnecting client
	// doesn't have to guess "is the agent working" from the trailing log
	// role. Guarded by mu.
	turnActive bool
	// onTurnIdle, when non-nil, fires after each turn ends (after
	// markTurnActive(false)). Used by the session to fire push notifications
	// when no client is attached. Set once at wiring time.
	onTurnIdle func()
	// onTurnStart, when non-nil, fires when a turn begins (Send is called).
	// Used to start the Live Activity card as early as possible.
	// Set once at wiring time.
	onTurnStart func()
}

// errChatProcessClosed is returned by Send after the process has been
// closed (or its agent exited).
var errChatProcessClosed = errors.New("chat process: closed")

// startChatProcess spawns the stream-json agent. command is the full argv
// (e.g. ["claude","-p","--input-format","stream-json",…]); env and dir
// mirror the session's commandEnv / worktree. A goroutine pumps stdout
// through processClaudeStreamOutput, calling publish for each chat event,
// until the agent exits (EOF). Cancel ctx (or call Close) to stop it.
func startChatProcess(
	ctx context.Context,
	command []string,
	env []string,
	dir string,
	publish func([]byte),
	gen *quickReplyGenerator,
	titleGen *titleGenerator,
	onUsage func(usageDelta),
	onAsk func(controlRequest, *chatProcess, string),
	onInit func(string),
	onSubagent *subagentRegistryHandle,
) (*chatProcess, error) {
	if len(command) == 0 {
		return nil, errors.New("chat process: empty command")
	}
	cmd := exec.CommandContext(ctx, command[0], command[1:]...)
	cmd.Env = env
	cmd.Dir = dir

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	cp := &chatProcess{cmd: cmd, stdin: stdin}
	// Control-protocol dispatch (--permission-prompt-tool stdio):
	// AskUserQuestion goes to the session's bridge (which holds it for
	// the user's answer); every other can_use_tool is auto-allowed with
	// unchanged input right here, preserving the
	// --dangerously-skip-permissions semantics the rest of the harness
	// assumes. See askcontrol.go.
	onControl := func(req controlRequest, ts string) {
		if req.ToolName == "AskUserQuestion" && onAsk != nil {
			onAsk(req, cp, ts)
			return
		}
		_ = cp.SendRaw(encodeControlAllow(req.RequestID, req.Input))
	}
	go func() {
		// processClaudeStreamOutput returns at EOF (agent exit); the
		// goroutine then ends. Reap the process so it doesn't zombie.
		// onTurnEnd clears the turn-in-flight latch on each `result`
		// envelope; do it BEFORE the usage fold so the status broadcast
		// that rides accumulateUsage carries turn_active=false.
		_ = processClaudeStreamOutput(stdout, publish, gen, titleGen, onUsage, onControl, onInit,
			func() {
				cp.markTurnActive(false)
				cp.mu.Lock()
				idle := cp.onTurnIdle
				cp.mu.Unlock()
				if idle != nil {
					idle()
				}
			}, onSubagent)
		// EOF / agent exit: whatever turn was in flight is over.
		cp.markTurnActive(false)
		werr := cmd.Wait()
		// Surface an *unexpected* exit in the Chat tab so a dead
		// stream-json agent isn't just silence (the original #6
		// symptom). Stay quiet on an intentional Close() — that's the
		// user ending the session, not a crash.
		cp.mu.Lock()
		intentional := cp.closed
		cp.mu.Unlock()
		if !intentional {
			msg := "⚠️ The agent process ended. Start a new session to continue."
			if werr != nil {
				msg = "⚠️ The agent process exited (" + werr.Error() + "). Start a new session to continue."
			}
			publishChatSystem(publish, msg)
		}
	}()
	return cp, nil
}

// setTurnIdleHook installs the turn-end notification callback. Called once at
// wiring time (manager.go), before any Send. The hook fires after the turn-active
// latch is cleared so the session's SubscriberCount check is accurate.
func (c *chatProcess) setTurnIdleHook(fn func()) {
	c.mu.Lock()
	c.onTurnIdle = fn
	c.mu.Unlock()
}

// setTurnStartHook installs the turn-start callback (turnStartHooker interface).
// Called once at wiring time before any Send.
func (c *chatProcess) setTurnStartHook(fn func()) {
	c.mu.Lock()
	c.onTurnStart = fn
	c.mu.Unlock()
}

// Send writes the user's composer text to the agent as one stream-json
// `user` event. Safe for concurrent callers.
func (c *chatProcess) Send(text string) error {
	line, err := encodeClaudeUserMessage(text)
	if err != nil {
		return err
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	if _, err = c.stdin.Write(line); err != nil {
		c.mu.Unlock()
		return err
	}
	// Latch the turn as in flight; the stream pump clears it on the
	// turn-end `result` (see startChatProcess's onTurnEnd) or on EOF/Close.
	c.turnActive = true
	startHook := c.onTurnStart
	c.mu.Unlock()
	// Fire turn-start hook outside the lock so it doesn't nest under c.mu.
	if startHook != nil {
		startHook()
	}
	return nil
}

// markTurnActive sets the turn-in-flight latch under c.mu. Used by the
// stream pump (false on `result`/EOF) and Close.
func (c *chatProcess) markTurnActive(active bool) {
	c.mu.Lock()
	c.turnActive = active
	c.mu.Unlock()
}

// TurnActive reports whether a claude turn is in flight. See turnActive.
func (c *chatProcess) TurnActive() bool {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.turnActive
}

// SendRaw writes one pre-encoded stream-json line (a control_response)
// to the agent's stdin. Safe for concurrent callers; shares Send's lock.
func (c *chatProcess) SendRaw(line []byte) error {
	if len(line) == 0 {
		return errors.New("chat process: empty control line")
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errChatProcessClosed
	}
	_, err := c.stdin.Write(line)
	return err
}

// Interrupt aborts the agent's current turn by writing an `interrupt`
// control_request to stdin (the SDK / mobile mechanism — see
// encodeControlInterrupt). The CLI stays alive for the next turn; a no-op
// after Close. Safe for concurrent callers (shares Send's lock via SendRaw).
func (c *chatProcess) Interrupt() error {
	line := encodeControlInterrupt()
	if line == nil {
		return errors.New("chat process: encode interrupt")
	}
	return c.SendRaw(line)
}

// Close stops the agent: closes stdin (signals EOF to a well-behaved
// stream-json reader) and kills the process if still running. Idempotent.
func (c *chatProcess) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	c.turnActive = false
	_ = c.stdin.Close()
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	return nil
}
