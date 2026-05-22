package session

import (
	"bytes"
	"errors"
	"fmt"
	"html"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"syscall"
	"time"

	"github.com/creack/pty"

	"github.com/nikhilsh/swe-kitty/broker/internal/agents"
)

var handoffSectionPattern = regexp.MustCompile(`(?is)<section[^>]*data-section=["']handoff["'][^>]*>(.*?)</section>`)

func (s *Session) prepareFilesystem() error {
	dirs := []string{
		s.sessionDir,
		s.worktreeDir,
		filepath.Dir(s.memoryPath),
		filepath.Dir(s.handoffPath),
	}
	for _, dir := range dirs {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.scrollbackPath); errors.Is(err, os.ErrNotExist) {
		if err := atomicWriteFile(s.scrollbackPath, nil); err != nil {
			return err
		}
	}
	if _, err := os.Stat(s.memoryPath); errors.Is(err, os.ErrNotExist) {
		if err := s.writeMemoryHTML(nil); err != nil {
			return err
		}
	}
	return nil
}

func (s *Session) commandDir(adapter agents.Adapter) string {
	if s.requestedCWD != "" && dirExists(s.requestedCWD) {
		return s.requestedCWD
	}
	if adapter.Workdir != "" {
		if filepath.IsAbs(adapter.Workdir) {
			if dirExists(adapter.Workdir) {
				return adapter.Workdir
			}
		} else {
			if dirExists(adapter.Workdir) {
				return adapter.Workdir
			}
			if dirExists(filepath.Join(s.repoRoot, adapter.Workdir)) {
				return filepath.Join(s.repoRoot, adapter.Workdir)
			}
		}
	}
	return s.worktreeDir
}

func (s *Session) commandEnv(extra map[string]string) []string {
	env := append([]string{}, os.Environ()...)
	env = append(env, "TERM=xterm-256color", "PS1=$ ")
	pairs := map[string]string{
		"SESSION_UUID":           s.ID,
		"AGENT_NAME":             s.Assistant,
		"KITTY_HANDOFF_PATH":     s.handoffPath,
		"KITTY_HANDOFF_OUT_PATH": s.handoffOutPath,
	}
	// docs/PLAN-AGENT-OAUTH.md §G.2: when a per-session ephemeral
	// agent home was materialized, point the agent process at it via
	// HOME. Codex additionally honours $CODEX_HOME for its auth.json
	// path, so we set both to make the lookup explicit and
	// host-cwd-independent. When agentHomeDir is empty, we leave HOME
	// alone — the agent inherits the broker process's HOME, exactly
	// the legacy host-mirror behaviour.
	if s.agentHomeDir != "" {
		pairs["HOME"] = s.agentHomeDir
		if s.Assistant == "codex" {
			pairs["CODEX_HOME"] = filepath.Join(s.agentHomeDir, ".codex")
		}
	}
	for k, v := range extra {
		pairs[k] = v
	}
	for k, v := range pairs {
		env = append(env, k+"="+v)
	}
	return env
}

// providerForAssistant maps the broker's adapter name to the OAuth
// provider key used by the credential store. Adapters that don't have
// a per-user OAuth flow return "" so the spawn path skips
// materialization (and falls back to the host-mirror behaviour).
// Keep this in lockstep with credentials.ValidProvider.
func providerForAssistant(assistant string) string {
	switch assistant {
	case "claude":
		return "anthropic"
	case "codex":
		return "openai"
	default:
		return ""
	}
}

// hostHomeDir returns the broker's real $HOME — the place where claude
// / codex stash their per-user credentials when the operator runs them
// interactively for the first login. Honours $SWE_KITTY_HOST_HOME for
// tests; otherwise mirrors `os.UserHomeDir()`. Returns "" when the home
// can't be resolved; callers must treat that as "no host creds, skip
// the mirror and let the agent prompt for /login".
func hostHomeDir() string {
	if v := strings.TrimSpace(os.Getenv("SWE_KITTY_HOST_HOME")); v != "" {
		return v
	}
	h, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return h
}

// mirrorHostCredentials copies the broker's own per-user agent
// credential files into the per-session ephemeral HOME so each spawned
// agent gets its own private copy. This is the fallback used when the
// in-app credStore doesn't have a stored OAuth blob yet (i.e. before
// OAuth Stage 2 is wired up on the iOS/Android client). Without it,
// every concurrent claude/codex would share the broker's real
// `.credentials.json` and race each other on refresh-token rotation —
// only the last writer keeps a valid token, and all peers get bounced
// to "Please run /login".
//
// Per provider, the mirror copies:
//
//   - anthropic → ~/.claude/.credentials.json + ~/.claude.json
//   - openai    → ~/.codex/auth.json + ~/.codex/config.toml
//
// Missing source files are silently skipped (the agent will prompt for
// /login on first use — a clean error rather than a race). Returns the
// first hard error (mkdir / read / atomic-write); callers should log
// and continue so a broken mirror doesn't refuse the session.
func mirrorHostCredentials(provider, ephemeralHome string) error {
	host := hostHomeDir()
	if host == "" {
		return errors.New("host home unresolved")
	}
	var sources []hostCredSource
	switch provider {
	case "anthropic":
		sources = []hostCredSource{
			{src: filepath.Join(host, ".claude", ".credentials.json"), dst: filepath.Join(ephemeralHome, ".claude", ".credentials.json"), mode: 0o600},
			{src: filepath.Join(host, ".claude.json"), dst: filepath.Join(ephemeralHome, ".claude.json"), mode: 0o600},
		}
	case "openai":
		sources = []hostCredSource{
			{src: filepath.Join(host, ".codex", "auth.json"), dst: filepath.Join(ephemeralHome, ".codex", "auth.json"), mode: 0o600},
			{src: filepath.Join(host, ".codex", "config.toml"), dst: filepath.Join(ephemeralHome, ".codex", "config.toml"), mode: 0o644},
		}
	default:
		return fmt.Errorf("unknown provider %q", provider)
	}
	anyCopied := false
	for _, s := range sources {
		data, err := os.ReadFile(s.src)
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				// Missing source — skip; agent will prompt for /login.
				continue
			}
			return fmt.Errorf("read %s: %w", s.src, err)
		}
		if err := os.MkdirAll(filepath.Dir(s.dst), 0o700); err != nil {
			return fmt.Errorf("mkdir %s: %w", filepath.Dir(s.dst), err)
		}
		if err := atomicWriteFileMode(s.dst, data, s.mode); err != nil {
			return fmt.Errorf("write %s: %w", s.dst, err)
		}
		anyCopied = true
	}
	if !anyCopied {
		return errors.New("no host credential files found")
	}
	return nil
}

type hostCredSource struct {
	src  string
	dst  string
	mode os.FileMode
}

// atomicWriteFileMode is atomicWriteFile but lets the caller pin the
// final file mode (credentials want 0o600, not the default 0o644).
// Race-safe: concurrent spawns each write to a unique temp file and
// rename into place, so no reader ever sees a torn credential file.
func atomicWriteFileMode(path string, data []byte, mode os.FileMode) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".swk-home-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpPath) }
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Chmod(mode); err != nil {
		_ = tmp.Close()
		cleanup()
		return err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return err
	}
	if err := os.Rename(tmpPath, path); err != nil {
		cleanup()
		return err
	}
	return nil
}

func (s *Session) startBackgroundLoops() {
	go s.checkpointLoop()
	go s.watchdogLoop()
}

func (s *Session) checkpointLoop() {
	ticker := time.NewTicker(s.checkpointEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			_ = s.Checkpoint("ticker")
		case <-s.closed:
			return
		}
	}
}

func (s *Session) watchdogLoop() {
	ticker := time.NewTicker(s.watchdogEvery)
	defer ticker.Stop()
	for {
		select {
		case <-ticker.C:
			s.runWatchdogChecks()
		case <-s.closed:
			return
		}
	}
}

func (s *Session) Checkpoint(reason string) error {
	s.checkpointMu.Lock()
	defer s.checkpointMu.Unlock()

	snapshot := s.Snapshot()
	if err := atomicWriteFile(s.scrollbackPath, snapshot); err != nil {
		s.setHealth("warning", "stalled")
		return err
	}
	if err := s.writeMemoryHTML(snapshot); err != nil {
		s.setHealth("warning", "stalled")
		return err
	}
	s.maybeAutoWIP()
	s.mu.Lock()
	s.lastCheckpoint = time.Now().UTC()
	s.phase = "running"
	s.mu.Unlock()
	return s.persistMetadata()
}

func (s *Session) writeMemoryHTML(snapshot []byte) error {
	if info, err := os.Stat(s.memoryPath); err == nil {
		s.lastMemoryModTime = info.ModTime()
	}
	if current := s.loadHandoffHTML(); current != "" {
		s.handoffHTML = current
	}
	var tail []byte
	if len(snapshot) > 4096 {
		tail = snapshot[len(snapshot)-4096:]
	} else {
		tail = snapshot
	}
	lastCheckpoint := ""
	s.mu.Lock()
	if !s.lastCheckpoint.IsZero() {
		lastCheckpoint = s.lastCheckpoint.UTC().Format(time.RFC3339Nano)
	}
	assistant := s.Assistant
	s.mu.Unlock()
	var buf bytes.Buffer
	buf.WriteString("<!doctype html>\n<html><body>\n")
	buf.WriteString(`<section data-section="meta">`)
	buf.WriteString("<p>session: " + html.EscapeString(s.ID) + "</p>")
	buf.WriteString("<p>assistant: " + html.EscapeString(assistant) + "</p>")
	if lastCheckpoint != "" {
		buf.WriteString("<p>last-checkpoint: " + html.EscapeString(lastCheckpoint) + "</p>")
	}
	buf.WriteString("</section>\n")
	buf.WriteString(`<section data-section="handoff">`)
	if strings.TrimSpace(s.handoffHTML) != "" {
		buf.WriteString(s.handoffHTML)
	}
	buf.WriteString("</section>\n")
	buf.WriteString(`<section data-section="env-snapshot"><pre>`)
	buf.WriteString(html.EscapeString(string(tail)))
	buf.WriteString("</pre></section>\n")
	buf.WriteString("</body></html>\n")
	if err := atomicWriteFile(s.memoryPath, buf.Bytes()); err != nil {
		return err
	}
	if info, err := os.Stat(s.memoryPath); err == nil {
		s.lastMemoryModTime = info.ModTime()
	}
	return nil
}

func (s *Session) maybeAutoWIP() {
	gitDir := filepath.Join(s.workspaceDir, ".git")
	if _, err := os.Stat(gitDir); err != nil {
		return
	}
	statusCmd := exec.Command("git", "-C", s.workspaceDir, "status", "--porcelain")
	out, err := statusCmd.Output()
	if err != nil || len(bytes.TrimSpace(out)) == 0 {
		return
	}
	_ = exec.Command("git", "-C", s.workspaceDir, "add", "-A").Run()
	_ = exec.Command(
		"git",
		"-C",
		s.workspaceDir,
		"stash",
		"push",
		"--include-untracked",
		"-m",
		"checkpoint:"+time.Now().UTC().Format(time.RFC3339Nano),
	).Run()
}

func (s *Session) switchToAdapter(adapter agents.Adapter) error {
	if err := s.Checkpoint("switch"); err != nil {
		return err
	}
	s.mu.Lock()
	s.swapping = true
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		s.swapping = false
		s.mu.Unlock()
	}()
	_ = os.Remove(s.handoffOutPath)
	s.signalHandoff()
	if htmlOut, err := s.waitForHandoff(); err == nil && strings.TrimSpace(htmlOut) != "" {
		s.handoffHTML = htmlOut
	}
	if err := s.runHook(s.hooks.OnSwap, map[string]string{
		"FROM_AGENT": s.Assistant,
		"TO_AGENT":   adapter.Name,
	}); err != nil {
		return err
	}
	fromAgent := s.Assistant
	s.Assistant = adapter.Name
	s.adapter = adapter
	s.hooks = adapter.Hooks
	if err := s.renderHandoffFile(); err != nil {
		return err
	}
	cmd := exec.Command(adapter.Command[0], append(adapter.Command[1:], adapter.Args...)...)
	cmd.Dir = s.workspaceDir
	cmd.Env = s.commandEnv(map[string]string{
		"FROM_AGENT": fromAgent,
		"TO_AGENT":   adapter.Name,
	})
	f, err := pty.Start(cmd)
	if err != nil {
		return err
	}
	_ = pty.Setsize(f, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	s.mu.Lock()
	oldPTY := s.pty
	oldCmd := s.cmd
	s.pty = f
	s.cmd = cmd
	s.phase = "running"
	s.health = "healthy"
	s.reasonCode = "agent_switched"
	s.mu.Unlock()
	if oldPTY != nil {
		_ = oldPTY.Close()
	}
	if oldCmd != nil && oldCmd.Process != nil {
		_ = oldCmd.Process.Kill()
		_, _ = oldCmd.Process.Wait()
	}
	if err := s.persistMetadata(); err != nil {
		return err
	}
	go s.drain(f)
	return nil
}

func (s *Session) signalHandoff() {
	s.mu.Lock()
	cmd := s.cmd
	s.mu.Unlock()
	if cmd == nil || cmd.Process == nil {
		return
	}
	_ = cmd.Process.Signal(syscall.SIGUSR1)
}

func (s *Session) waitForHandoff() (string, error) {
	deadline := time.Now().Add(s.handoffTimeout)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(s.handoffOutPath)
		if err == nil {
			section, extractErr := extractHandoffSection(data)
			if extractErr == nil {
				_ = s.mergeHandoff(section)
				return section, nil
			}
		}
		time.Sleep(10 * time.Millisecond)
	}
	return "", fmt.Errorf("handoff timeout")
}

func (s *Session) mergeHandoff(section string) error {
	s.handoffHTML = section
	return s.writeMemoryHTML(s.Snapshot())
}

func (s *Session) renderHandoffFile() error {
	return atomicWriteFile(s.handoffPath, []byte("<!doctype html><html><body><section data-section=\"handoff\">"+s.handoffHTML+"</section></body></html>\n"))
}

func (s *Session) runHook(script string, extraEnv map[string]string) error {
	if strings.TrimSpace(script) == "" {
		return nil
	}
	cmd := exec.Command("sh", "-lc", script)
	cmd.Dir = s.workspaceDir
	cmd.Env = s.commandEnv(extraEnv)
	return cmd.Run()
}

func (s *Session) loadHandoffHTML() string {
	data, err := os.ReadFile(s.memoryPath)
	if err != nil {
		return ""
	}
	section, err := extractHandoffSection(data)
	if err != nil {
		return ""
	}
	return section
}

func extractHandoffSection(data []byte) (string, error) {
	matches := handoffSectionPattern.FindSubmatch(data)
	if len(matches) != 2 {
		return "", fmt.Errorf("handoff section missing")
	}
	return strings.TrimSpace(string(matches[1])), nil
}

func (s *Session) restoreSnapshot(snapshot []byte) {
	if len(snapshot) > ringSize {
		snapshot = snapshot[len(snapshot)-ringSize:]
	}
	copy(s.ring, snapshot)
	s.ringPos = len(snapshot)
	if len(snapshot) == ringSize {
		s.ringPos = 0
		s.ringFull = true
	}
}
