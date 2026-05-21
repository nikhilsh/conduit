// Package session manages per-UUID sessions: a PTY-attached process,
// resize state, scrollback ring, and the channels that fan PTY output
// out to one or more attached WebSocket viewers.
//
// Task 001 scope: hardcoded `sh` as the "agent" — Docker-spawned agent
// containers land in task 006. Worktree creation / checkpoint / watchdog
// land in task 005. Everything in this file must be safe to extend
// behind the same public surface.
package session

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/creack/pty"
	"github.com/hinshun/vt10x"

	"github.com/nikhilsh/swe-kitty/harness/internal/agents"
)

const ringSize = 256 * 1024 // 256 KB scrollback per session

// Session is the per-UUID handle. Safe for concurrent use.
type Session struct {
	ID        string
	Assistant string

	pty       *os.File
	cmd       *exec.Cmd
	adapter   agents.Adapter
	rows      uint16
	cols      uint16
	closed    chan struct{}
	closeOnce sync.Once

	mu       sync.Mutex
	ring     []byte // circular scrollback (Phase 1: still authoritative)
	ringPos  int
	ringFull bool
	// term mirrors PTY output into a real VT100 cell grid so a future
	// Snapshot() can serialize a self-contained, replay-safe redraw
	// instead of raw bytes. See docs/PLAN-TERMINAL-CELLS.md. Phase 1
	// runs the emulator as a passive sink; Snapshot() does NOT yet
	// consult it.
	term     vt10x.Terminal
	subs     map[chan []byte]struct{}
	textSubs map[chan []byte]struct{}
	switchFn func(string) error

	repoRoot          string
	kittyRoot         string
	sessionDir        string
	worktreeDir       string
	scrollbackPath    string
	memoryPath        string
	metaPath          string
	handoffPath       string
	handoffOutPath    string
	checkpointEvery   time.Duration
	watchdogEvery     time.Duration
	stallAfter        time.Duration
	handoffTimeout    time.Duration
	workspaceDir      string
	requestedCWD      string
	reasonCode        string
	exitCode          int
	hooks             agents.Hooks
	phase             string
	health            string
	lastOutput        time.Time
	lastCheckpoint    time.Time
	handoffHTML       string
	checkpointMu      sync.Mutex
	lastMemoryModTime time.Time
	swapping          bool
}

func New(id string, adapter agents.Adapter) (*Session, error) {
	repoRoot, kittyRoot, err := resolveKittyRoots()
	if err != nil {
		return nil, err
	}
	return newSession(id, adapter, sessionOptions{
		repoRoot:  repoRoot,
		kittyRoot: kittyRoot,
	})
}

func newSession(id string, adapter agents.Adapter, opts sessionOptions) (*Session, error) {
	cmd := exec.Command(adapter.Command[0], append(adapter.Command[1:], adapter.Args...)...)
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "PS1=$ ")
	s := &Session{
		ID:           id,
		Assistant:    adapter.Name,
		adapter:      adapter,
		rows:         40,
		cols:         120,
		closed:       make(chan struct{}),
		ring:         make([]byte, ringSize),
		term:         vt10x.New(vt10x.WithSize(120, 40)),
		subs:         make(map[chan []byte]struct{}),
		textSubs:     make(map[chan []byte]struct{}),
		repoRoot:     opts.repoRoot,
		kittyRoot:    opts.kittyRoot,
		requestedCWD: strings.TrimSpace(opts.requestedCWD),
		checkpointEvery: durationFromEnv(
			"KITTY_SESSION_CHECKPOINT_INTERVAL_MS",
			60*time.Second,
		),
		watchdogEvery: durationFromEnv(
			"KITTY_SESSION_WATCHDOG_INTERVAL_MS",
			30*time.Second,
		),
		stallAfter: durationFromEnv(
			"KITTY_SESSION_STALL_AFTER_MS",
			5*time.Minute,
		),
		handoffTimeout: durationFromEnv(
			"KITTY_SESSION_HANDOFF_TIMEOUT_MS",
			250*time.Millisecond,
		),
		hooks:      adapter.Hooks,
		phase:      "running",
		health:     "healthy",
		reasonCode: "ok",
		lastOutput: time.Now().UTC(),
	}
	s.applyPaths()
	if err := s.prepareFilesystem(); err != nil {
		return nil, err
	}
	s.workspaceDir = s.commandDir(adapter)
	cmd.Dir = s.workspaceDir
	cmd.Env = s.commandEnv(nil)
	if len(opts.snapshot) > 0 {
		s.restoreSnapshot(opts.snapshot)
	}
	if !opts.lastCheckpoint.IsZero() {
		s.lastCheckpoint = opts.lastCheckpoint
	}
	if opts.handoffHTML != "" {
		s.handoffHTML = opts.handoffHTML
	} else {
		s.handoffHTML = s.loadHandoffHTML()
	}
	f, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	s.pty = f
	s.cmd = cmd
	_ = pty.Setsize(f, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	if err := s.persistMetadata(); err != nil {
		_ = f.Close()
		if s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
			_, _ = s.cmd.Process.Wait()
		}
		return nil, err
	}
	go s.drain(f)
	s.startBackgroundLoops()
	return s, nil
}

// Write sends bytes to the PTY input (terminal keystrokes).
func (s *Session) Write(p []byte) (int, error) {
	return s.pty.Write(p)
}

// Resize updates the PTY winsize. Both dimensions must be > 0.
func (s *Session) Resize(rows, cols uint16) error {
	if rows == 0 || cols == 0 {
		return errors.New("resize: rows and cols must be > 0")
	}
	s.mu.Lock()
	s.rows, s.cols = rows, cols
	term := s.term
	s.mu.Unlock()
	if term != nil {
		// vt10x.Resize takes (cols, rows) — opposite of pty.Setsize.
		term.Resize(int(cols), int(rows))
	}
	return pty.Setsize(s.pty, &pty.Winsize{Rows: rows, Cols: cols})
}

// Subscribe returns a channel that receives every subsequent PTY chunk
// until Unsubscribe is called or the session closes. The channel is
// closed when the session ends.
func (s *Session) Subscribe() chan []byte {
	ch := make(chan []byte, 64)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

func (s *Session) Unsubscribe(ch chan []byte) {
	s.mu.Lock()
	if _, ok := s.subs[ch]; ok {
		delete(s.subs, ch)
		close(ch)
	}
	s.mu.Unlock()
}

func (s *Session) SubscribeText() chan []byte {
	ch := make(chan []byte, 32)
	s.mu.Lock()
	s.textSubs[ch] = struct{}{}
	s.mu.Unlock()
	return ch
}

func (s *Session) UnsubscribeText(ch chan []byte) {
	s.mu.Lock()
	if _, ok := s.textSubs[ch]; ok {
		delete(s.textSubs, ch)
		close(ch)
	}
	s.mu.Unlock()
}

// Snapshot returns a copy of the current scrollback (oldest-first).
func (s *Session) Snapshot() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.ringFull {
		out := make([]byte, s.ringPos)
		copy(out, s.ring[:s.ringPos])
		return out
	}
	out := make([]byte, ringSize)
	copy(out, s.ring[s.ringPos:])
	copy(out[ringSize-s.ringPos:], s.ring[:s.ringPos])
	return out
}

func (s *Session) WorkspaceDir() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.workspaceDir
}

// Close terminates the session. Idempotent.
func (s *Session) Close() {
	s.closeOnce.Do(func() {
		_ = s.Checkpoint("exit")
		_ = s.pty.Close()
		exitCode := 0
		if s.cmd != nil && s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
		}
		if s.cmd != nil && s.cmd.Process != nil {
			state, _ := s.cmd.Process.Wait()
			if state != nil {
				exitCode = state.ExitCode()
			}
		}
		s.mu.Lock()
		s.exitCode = exitCode
		s.phase = "exited"
		s.reasonCode = "session_closed"
		s.mu.Unlock()
		_ = s.persistMetadata()
		_ = s.runHook(s.hooks.OnExit, map[string]string{
			"AGENT_NAME": s.Assistant,
			"EXIT_CODE":  fmt.Sprintf("%d", exitCode),
		})
		s.mu.Lock()
		for ch := range s.subs {
			close(ch)
		}
		for ch := range s.textSubs {
			close(ch)
		}
		s.subs = nil
		s.textSubs = nil
		s.mu.Unlock()
		close(s.closed)
	})
}

// Done returns a channel closed when the session ends.
func (s *Session) Done() <-chan struct{} { return s.closed }

func (s *Session) SwitchAdapter(assistant string) error {
	if s.switchFn == nil {
		return errors.New("switch_agent unavailable")
	}
	return s.switchFn(assistant)
}

func (s *Session) Switch(adapter agents.Adapter) error {
	return s.switchToAdapter(adapter)
}

func (s *Session) drain(f *os.File) {
	buf := make([]byte, 8192)
	for {
		n, err := f.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.append(chunk)
			s.fanout(chunk)
		}
		if err != nil {
			s.mu.Lock()
			stillCurrent := s.pty == f && !s.swapping
			s.mu.Unlock()
			if !stillCurrent {
				return
			}
			s.Close()
			return
		}
	}
}

func (s *Session) append(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.lastOutput = time.Now().UTC()
	for _, b := range p {
		s.ring[s.ringPos] = b
		s.ringPos++
		if s.ringPos == ringSize {
			s.ringPos = 0
			s.ringFull = true
		}
	}
	// Phase 1: mirror PTY output into the cell emulator alongside the
	// ring buffer. vt10x acquires its own internal lock and never blocks
	// on PTY/network IO, so this is safe to call under s.mu. Errors from
	// Write are not surfaced — the emulator is a best-effort sink and
	// the ring remains authoritative for Snapshot().
	if s.term != nil {
		_, _ = s.term.Write(p)
	}
}

func (s *Session) fanout(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for ch := range s.subs {
		select {
		case ch <- p:
		default:
			// slow subscriber; drop oldest by draining once
			select {
			case <-ch:
			default:
			}
			select {
			case ch <- p:
			default:
			}
		}
	}
}

// Manager owns the lookup table of sessions.
type Manager struct {
	mu             sync.RWMutex
	sessions       map[string]*Session
	recentProjects []RecentProject
	registry       *agents.Registry
	repoRoot       string
	kittyRoot      string
}

type CreateOptions struct {
	CWD string
}

func NewManager(registry *agents.Registry) *Manager {
	repoRoot, kittyRoot, _ := resolveKittyRoots()
	m := &Manager{
		sessions:  make(map[string]*Session),
		registry:  registry,
		repoRoot:  repoRoot,
		kittyRoot: kittyRoot,
	}
	m.loadRecentProjects()
	return m
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

func (m *Manager) AssistantNames() []string {
	return m.registry.Names()
}

// GetOrCreate returns the existing session for id, or starts a new one
// with the given assistant. assistant is honored only on creation.
func (m *Manager) GetOrCreate(id, assistant string) (*Session, bool, error) {
	return m.GetOrCreateWithOptions(id, assistant, CreateOptions{})
}

// GetOrCreateWithOptions is like GetOrCreate but accepts creation options.
// Options are honored only when a new session is created.
func (m *Manager) GetOrCreateWithOptions(id, assistant string, opts CreateOptions) (*Session, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.sessions[id]; ok {
		return s, false, nil
	}
	if m.sessionOnDisk(id) {
		s, err := m.recoverSessionLocked(id)
		if err == nil {
			return s, false, nil
		}
	}
	adapter, err := m.registry.Get(assistant)
	if err != nil {
		return nil, false, err
	}
	requestedCWD := strings.TrimSpace(opts.CWD)
	if requestedCWD != "" {
		if !filepath.IsAbs(requestedCWD) {
			return nil, false, fmt.Errorf("invalid cwd %q: must be an absolute path", requestedCWD)
		}
		if !dirExists(requestedCWD) {
			return nil, false, fmt.Errorf("invalid cwd %q: directory does not exist", requestedCWD)
		}
	}
	s, err := newSession(id, adapter, sessionOptions{
		repoRoot:     m.repoRoot,
		kittyRoot:    m.kittyRoot,
		requestedCWD: requestedCWD,
	})
	if err != nil {
		return nil, false, err
	}
	s.switchFn = func(next string) error {
		nextAdapter, err := m.registry.Get(next)
		if err != nil {
			return err
		}
		return s.Switch(nextAdapter)
	}
	m.sessions[id] = s
	m.recordRecentProjectLocked(s.WorkspaceDir(), s.Assistant, s.ID)
	go func() {
		<-s.Done()
		m.mu.Lock()
		delete(m.sessions, id)
		m.mu.Unlock()
	}()
	return s, true, nil
}

func (m *Manager) Recover() ([]string, error) {
	entries, err := os.ReadDir(filepath.Join(m.kittyRoot, "sessions"))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	m.mu.Lock()
	defer m.mu.Unlock()
	recovered := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		id := entry.Name()
		if _, ok := m.sessions[id]; ok {
			continue
		}
		s, err := m.recoverSessionLocked(id)
		if err != nil {
			continue
		}
		recovered = append(recovered, s.ID)
	}
	slices.Sort(recovered)
	return recovered, nil
}

func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		s.Close()
	}
}

func dirExists(path string) bool {
	info, err := os.Stat(path)
	return err == nil && info.IsDir()
}

type sessionOptions struct {
	repoRoot       string
	kittyRoot      string
	snapshot       []byte
	lastCheckpoint time.Time
	handoffHTML    string
	requestedCWD   string
}

type sessionMetadata struct {
	ID             string `json:"id"`
	Assistant      string `json:"assistant"`
	Rows           uint16 `json:"rows"`
	Cols           uint16 `json:"cols"`
	Phase          string `json:"phase"`
	Health         string `json:"health"`
	ReasonCode     string `json:"reason_code,omitempty"`
	ExitCode       int    `json:"exit_code,omitempty"`
	LastCheckpoint string `json:"last_checkpoint,omitempty"`
}

func (s *Session) applyPaths() {
	s.sessionDir = filepath.Join(s.kittyRoot, "sessions", s.ID)
	s.worktreeDir = filepath.Join(s.sessionDir, "work")
	s.scrollbackPath = filepath.Join(s.sessionDir, "scrollback.bin")
	s.metaPath = filepath.Join(s.sessionDir, "meta.json")
	s.memoryPath = filepath.Join(s.kittyRoot, "memory", "sessions", s.ID+".html")
	s.handoffPath = filepath.Join(s.worktreeDir, ".swe-kitty", "HANDOFF.html")
	s.handoffOutPath = filepath.Join(s.worktreeDir, ".swe-kitty", "HANDOFF-OUT.html")
}

func (s *Session) persistMetadata() error {
	s.mu.Lock()
	meta := sessionMetadata{
		ID:         s.ID,
		Assistant:  s.Assistant,
		Rows:       s.rows,
		Cols:       s.cols,
		Phase:      s.phase,
		Health:     s.health,
		ReasonCode: s.reasonCode,
		ExitCode:   s.exitCode,
	}
	if !s.lastCheckpoint.IsZero() {
		meta.LastCheckpoint = s.lastCheckpoint.UTC().Format(time.RFC3339Nano)
	}
	s.mu.Unlock()
	return atomicWriteJSON(s.metaPath, meta)
}

func atomicWriteJSON(path string, v any) error {
	data, err := json.MarshalIndent(v, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteFile(path, append(data, '\n'))
}

func resolveKittyRoots() (string, string, error) {
	if root := strings.TrimSpace(os.Getenv("SWE_KITTY_ROOT")); root != "" {
		abs, err := filepath.Abs(root)
		if err != nil {
			return "", "", err
		}
		return filepath.Dir(abs), abs, nil
	}
	wd, err := os.Getwd()
	if err != nil {
		return "", "", err
	}
	cur := wd
	for {
		if dirExists(filepath.Join(cur, ".git")) || dirExists(filepath.Join(cur, ".swe-kitty")) {
			return cur, filepath.Join(cur, ".swe-kitty"), nil
		}
		next := filepath.Dir(cur)
		if next == cur {
			return wd, filepath.Join(wd, ".swe-kitty"), nil
		}
		cur = next
	}
}
