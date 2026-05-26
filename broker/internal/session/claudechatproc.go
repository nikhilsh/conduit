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
	go func() {
		// processClaudeStreamOutput returns at EOF (agent exit); the
		// goroutine then ends. Reap the process so it doesn't zombie.
		_ = processClaudeStreamOutput(stdout, publish, gen)
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

// Send writes the user's composer text to the agent as one stream-json
// `user` event. Safe for concurrent callers.
func (c *chatProcess) Send(text string) error {
	line, err := encodeClaudeUserMessage(text)
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return errChatProcessClosed
	}
	_, err = c.stdin.Write(line)
	return err
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
	_ = c.stdin.Close()
	if c.cmd.Process != nil {
		_ = c.cmd.Process.Kill()
	}
	return nil
}
