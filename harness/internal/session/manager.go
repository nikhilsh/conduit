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
	"errors"
	"os"
	"os/exec"
	"sync"

	"github.com/creack/pty"
)

const ringSize = 256 * 1024 // 256 KB scrollback per session

// Session is the per-UUID handle. Safe for concurrent use.
type Session struct {
	ID        string
	Assistant string

	pty       *os.File
	cmd       *exec.Cmd
	rows      uint16
	cols      uint16
	closed    chan struct{}
	closeOnce sync.Once

	mu       sync.Mutex
	ring     []byte // circular scrollback
	ringPos  int
	ringFull bool
	subs     map[chan []byte]struct{}
}

// New starts a session backed by `sh`. The assistant string is recorded
// for future use (task 006 will use it to pick a Dockerized adapter);
// for now it's metadata only.
func New(id, assistant string) (*Session, error) {
	cmd := exec.Command("sh")
	cmd.Env = append(os.Environ(), "TERM=xterm-256color", "PS1=$ ")
	f, err := pty.Start(cmd)
	if err != nil {
		return nil, err
	}
	s := &Session{
		ID:        id,
		Assistant: assistant,
		pty:       f,
		cmd:       cmd,
		rows:      40,
		cols:      120,
		closed:    make(chan struct{}),
		ring:      make([]byte, ringSize),
		subs:      make(map[chan []byte]struct{}),
	}
	_ = pty.Setsize(f, &pty.Winsize{Rows: s.rows, Cols: s.cols})
	go s.drain()
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
	s.mu.Unlock()
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

// Close terminates the session. Idempotent.
func (s *Session) Close() {
	s.closeOnce.Do(func() {
		_ = s.pty.Close()
		if s.cmd.Process != nil {
			_ = s.cmd.Process.Kill()
		}
		_, _ = s.cmd.Process.Wait()
		s.mu.Lock()
		for ch := range s.subs {
			close(ch)
		}
		s.subs = nil
		s.mu.Unlock()
		close(s.closed)
	})
}

// Done returns a channel closed when the session ends.
func (s *Session) Done() <-chan struct{} { return s.closed }

func (s *Session) drain() {
	buf := make([]byte, 8192)
	for {
		n, err := s.pty.Read(buf)
		if n > 0 {
			chunk := make([]byte, n)
			copy(chunk, buf[:n])
			s.append(chunk)
			s.fanout(chunk)
		}
		if err != nil {
			// io.EOF or PTY-closed are both terminal — tear down the session.
			s.Close()
			return
		}
	}
}

func (s *Session) append(p []byte) {
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, b := range p {
		s.ring[s.ringPos] = b
		s.ringPos++
		if s.ringPos == ringSize {
			s.ringPos = 0
			s.ringFull = true
		}
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
	mu       sync.RWMutex
	sessions map[string]*Session
}

func NewManager() *Manager {
	return &Manager{sessions: make(map[string]*Session)}
}

func (m *Manager) Get(id string) (*Session, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	s, ok := m.sessions[id]
	return s, ok
}

// GetOrCreate returns the existing session for id, or starts a new one
// with the given assistant. assistant is honored only on creation.
func (m *Manager) GetOrCreate(id, assistant string) (*Session, bool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if s, ok := m.sessions[id]; ok {
		return s, false, nil
	}
	s, err := New(id, assistant)
	if err != nil {
		return nil, false, err
	}
	m.sessions[id] = s
	go func() {
		<-s.Done()
		m.mu.Lock()
		delete(m.sessions, id)
		m.mu.Unlock()
	}()
	return s, true, nil
}

func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for _, s := range m.sessions {
		s.Close()
	}
}
