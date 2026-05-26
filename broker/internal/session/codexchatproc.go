package session

import (
	"bufio"
	"encoding/json"
	"os/exec"
	"sync"
	"time"
)

// codexChatProcess drives the structured Chat tab for codex. Unlike claude
// (a persistent stream-json stdin process), `codex exec` is one-shot, so
// each composer message spawns a fresh subprocess: the first turn runs
// `codex exec --json -C <dir> "<msg>"` and captures the thread_id from
// thread.started; subsequent turns run `codex exec resume <thread_id>
// --json "<msg>"` (verified to preserve context on codex-cli 0.132). Output
// JSONL is mapped to chat view_events via parseCodexStreamLine.
//
// This is codex slice 2 of task #24. See docs/PLAN-CHAT-CHANNEL.md.
type codexChatProcess struct {
	binary  string   // adapter.Command[0], e.g. "codex"
	dir     string   // session worktree (first turn's -C)
	env     []string // commandEnv
	extra   []string // reasoning-effort / model override flags (may be nil)
	publish func([]byte)

	mu       sync.Mutex
	threadID string
	closed   bool
	running  *exec.Cmd // the in-flight turn, if any (killed on Close)
}

func newCodexChatProcess(binary, dir string, env, extra []string, publish func([]byte)) *codexChatProcess {
	return &codexChatProcess{binary: binary, dir: dir, env: env, extra: extra, publish: publish}
}

// codexTurnArgv builds the argv for one turn. The first turn (empty
// threadID) runs `exec` with `-C <dir>`; later turns `exec resume
// <threadID>` (resume reuses the recorded cwd and rejects -C). `extra`
// carries the optional reasoning-effort / model override flags, inserted
// after the `exec`/`resume` subcommand and before the message. Pure, so the
// branch is unit-testable without spawning codex.
func codexTurnArgv(binary, dir, threadID string, extra []string, msg string) []string {
	if threadID == "" {
		argv := []string{binary, "exec", "--json", "--skip-git-repo-check", "-C", dir}
		argv = append(argv, extra...)
		return append(argv, msg)
	}
	argv := []string{binary, "exec", "resume", threadID, "--json", "--skip-git-repo-check"}
	argv = append(argv, extra...)
	return append(argv, msg)
}

// Send runs one codex turn for the user's message. It returns immediately;
// the turn runs in a goroutine and streams chat events via publish. Safe
// for concurrent callers (codex serializes turns by resuming the thread).
func (c *codexChatProcess) Send(text string) error {
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return errChatProcessClosed
	}
	tid := c.threadID
	c.mu.Unlock()
	go c.runTurn(codexTurnArgv(c.binary, c.dir, tid, c.extra, text))
	return nil
}

func (c *codexChatProcess) runTurn(argv []string) {
	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = c.env
	cmd.Dir = c.dir
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return
	}
	if err := cmd.Start(); err != nil {
		return
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		_ = cmd.Process.Kill()
		return
	}
	c.running = cmd
	c.mu.Unlock()

	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
	for sc.Scan() {
		evs, tid, ok := parseCodexStreamLine(sc.Bytes())
		if tid != "" {
			c.mu.Lock()
			if c.threadID == "" {
				c.threadID = tid
			}
			c.mu.Unlock()
		}
		if !ok {
			continue
		}
		for _, e := range evs {
			if e.Text == "" {
				continue
			}
			payload, perr := json.Marshal(map[string]any{
				"type": "view_event",
				"view": "chat",
				"event": map[string]any{
					"role":    "assistant",
					"content": e.Text,
					"ts":      claudeChatNow().UTC().Format(time.RFC3339Nano),
					"files":   []any{},
				},
			})
			if perr == nil {
				c.publish(payload)
			}
		}
	}
	_ = cmd.Wait()
	c.mu.Lock()
	if c.running == cmd {
		c.running = nil
	}
	c.mu.Unlock()
}

// Close stops the codex backend: no persistent process, but kill any
// in-flight turn and refuse further Sends. Idempotent.
func (c *codexChatProcess) Close() error {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.closed {
		return nil
	}
	c.closed = true
	if c.running != nil && c.running.Process != nil {
		_ = c.running.Process.Kill()
	}
	return nil
}
