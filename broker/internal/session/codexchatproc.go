package session

import (
	"bufio"
	"bytes"
	"encoding/json"
	"io"
	"os/exec"
	"regexp"
	"strings"
	"sync"
	"time"
)

// ansiStripRe matches ANSI/VT escape sequences so we can strip colour codes
// from codex stderr before surfacing error snippets in the Chat tab.
var ansiStripRe = regexp.MustCompile(`\x1b\[[0-9;]*[mKHJABCDsuGfnr]`)

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
	onUsage func(usageDelta) // folds each turn.completed's token usage

	mu       sync.Mutex
	threadID string
	closed   bool
	running  *exec.Cmd // the in-flight turn, if any (killed on Close)
}

func newCodexChatProcess(binary, dir string, env, extra []string, publish func([]byte), onUsage func(usageDelta)) *codexChatProcess {
	return &codexChatProcess{binary: binary, dir: dir, env: env, extra: extra, publish: publish, onUsage: onUsage}
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
		publishChatSystem(c.publish, "⚠️ codex: failed to start turn (stdout pipe): "+err.Error())
		return
	}
	// Capture stderr so auth / startup errors surface in the Chat tab
	// rather than vanishing silently. We cap the read to 4 KB — enough
	// to show the first meaningful error line without buffering the full
	// stderr of a verbose run.
	var stderrBuf bytes.Buffer
	cmd.Stderr = &limitWriter{w: &stderrBuf, limit: 4096}
	if err := cmd.Start(); err != nil {
		publishChatSystem(c.publish, "⚠️ codex: failed to start: "+err.Error())
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
	published := false
	for sc.Scan() {
		evs, tid, ok := parseCodexStreamLine(sc.Bytes())
		if tid != "" {
			c.mu.Lock()
			if c.threadID == "" {
				c.threadID = tid
			}
			c.mu.Unlock()
		}
		// turn.completed carries the turn's token usage (no cost/window);
		// parseCodexStreamLine returns ok=false for it, so fold it here.
		if c.onUsage != nil {
			if u, uok := parseCodexUsage(sc.Bytes()); uok {
				c.onUsage(u)
			}
		}
		if !ok {
			continue
		}
		for _, e := range evs {
			var role, content string
			switch {
			case e.Text != "":
				role, content = "assistant", e.Text
			case e.ToolName != "":
				// command_execution etc. → role:"tool" card, same shape
				// the claude path uses.
				role, content = "tool", toolCardContent(e.ToolName, e.ToolInput)
			default:
				continue
			}
			payload, perr := json.Marshal(map[string]any{
				"type": "view_event",
				"view": "chat",
				"event": map[string]any{
					"role":    role,
					"content": content,
					"ts":      claudeChatNow().UTC().Format(time.RFC3339Nano),
					"files":   []any{},
				},
			})
			if perr == nil {
				c.publish(payload)
				published = true
			}
		}
	}
	_ = cmd.Wait()
	c.mu.Lock()
	intentional := c.closed
	if c.running == cmd {
		c.running = nil
	}
	c.mu.Unlock()

	// If the turn ended without emitting any assistant message (e.g. an
	// auth failure or codex crash), the client's typing indicator would
	// spin forever — the user's message stays as the last chat item and
	// agentWorking stays true. Emit a system message so the indicator
	// clears and the user sees what went wrong. Skip when the session
	// was intentionally closed (killed by Close()) — that's just the
	// user ending the session, not an error.
	if !published && !intentional {
		msg := "⚠️ codex: no reply from agent (turn failed or timed out)"
		if stderrBuf.Len() > 0 {
			// Surface the first useful error line from stderr. Skip ANSI
			// colour codes and blank lines; cap the snippet at 200 chars.
			if snip := firstMeaningfulLine(stderrBuf.String()); snip != "" {
				msg = "⚠️ codex error: " + snip
			}
		}
		publishChatSystem(c.publish, msg)
	}
}

// limitWriter is an io.Writer that stops writing after limit bytes.
// Used to cap codex's verbose stderr so we don't buffer megabytes.
type limitWriter struct {
	w     io.Writer
	limit int
	n     int
}

func (l *limitWriter) Write(p []byte) (int, error) {
	if l.n >= l.limit {
		return len(p), nil // silently discard once full
	}
	room := l.limit - l.n
	if len(p) > room {
		p = p[:room]
	}
	n, err := l.w.Write(p)
	l.n += n
	return len(p), err // lie about count so cmd doesn't see a short write
}

// firstMeaningfulLine returns the first non-blank line from s that doesn't
// look like an ANSI escape or a purely-numeric/date prefix. Caps at 200 chars.
func firstMeaningfulLine(s string) string {
	for _, line := range strings.Split(s, "\n") {
		// Strip ANSI escapes (ESC [ … m sequences)
		line = ansiStripRe.ReplaceAllString(line, "")
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		// Skip lines that are just log prefixes (timestamps, log levels)
		// like "2026-05-27T08:39:11.384060Z ERROR codex_login…".
		// We want the actual human message after the module path.
		if idx := strings.Index(line, "] "); idx >= 0 {
			line = strings.TrimSpace(line[idx+2:])
		}
		if line == "" {
			continue
		}
		if len(line) > 200 {
			line = line[:200] + "…"
		}
		return line
	}
	return ""
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
