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
	for k, v := range extra {
		pairs[k] = v
	}
	for k, v := range pairs {
		env = append(env, k+"="+v)
	}
	return env
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
