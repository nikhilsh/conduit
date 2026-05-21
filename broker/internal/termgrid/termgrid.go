// Package termgrid manages a Node.js sidecar process that maintains a
// headless xterm.js Terminal per session. The harness mirrors PTY bytes
// into the sidecar so that on client attach it can reflow the grid to
// the client's viewport size and serialize it — fixing the cursor /
// wrap / alt-screen mismatch you get if you ship raw PTY bytes captured
// at a different size.
//
// The ring buffer in session.Session remains the streaming source of
// truth and the fallback for snapshots when the sidecar is unavailable.
package termgrid

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// ErrNoNode is returned by NewManager when the `node` binary isn't on
// PATH. Callers should treat this as a graceful fall-back to ring-only
// snapshots, not a fatal startup error.
var ErrNoNode = errors.New("termgrid: node binary not on PATH")

// ErrTimeout is returned when the sidecar doesn't respond within the
// per-call deadline (5s).
var ErrTimeout = errors.New("termgrid: sidecar request timed out")

// ErrClosed is returned when the Manager has been Close()'d.
var ErrClosed = errors.New("termgrid: manager closed")

const defaultTimeout = 5 * time.Second

// Manager owns the long-running sidecar subprocess. Safe for concurrent
// use.
type Manager struct {
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout io.ReadCloser

	writeMu sync.Mutex

	nextID atomic.Uint64

	mu      sync.Mutex
	pending map[uint64]chan response
	closed  bool
}

type request struct {
	ID   uint64 `json:"id"`
	Cmd  string `json:"cmd"`
	SID  string `json:"sid,omitempty"`
	Cols uint16 `json:"cols,omitempty"`
	Rows uint16 `json:"rows,omitempty"`
	B64  string `json:"b64,omitempty"`
}

type response struct {
	ID    uint64 `json:"id"`
	OK    bool   `json:"ok"`
	Error string `json:"error,omitempty"`
	Data  string `json:"data,omitempty"`
	Pong  int64  `json:"pong,omitempty"`
}

// NewManager spawns the sidecar process. The sidecar.js path is
// resolved in this order:
//
//  1. $SWE_KITTY_SIDECAR_PATH (full path to sidecar.js)
//  2. <dir-of-harness-binary>/sidecar/sidecar.js
//  3. <cwd>/harness/sidecar/sidecar.js (dev tree)
//
// If `node` is not on PATH, ErrNoNode is returned. If sidecar.js can't
// be located, a plain error is returned.
func NewManager() (*Manager, error) {
	if _, err := exec.LookPath("node"); err != nil {
		return nil, ErrNoNode
	}
	script, err := resolveSidecarPath()
	if err != nil {
		return nil, err
	}
	cmd := exec.Command("node", script)
	cmd.Stderr = os.Stderr
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("termgrid: start sidecar: %w", err)
	}
	m := &Manager{
		cmd:     cmd,
		stdin:   stdin,
		stdout:  stdout,
		pending: make(map[uint64]chan response),
	}
	go m.readLoop()
	return m, nil
}

func resolveSidecarPath() (string, error) {
	if p := strings.TrimSpace(os.Getenv("SWE_KITTY_SIDECAR_PATH")); p != "" {
		if _, err := os.Stat(p); err == nil {
			return p, nil
		}
	}
	if exe, err := os.Executable(); err == nil {
		candidate := filepath.Join(filepath.Dir(exe), "sidecar", "sidecar.js")
		if _, err := os.Stat(candidate); err == nil {
			return candidate, nil
		}
	}
	if wd, err := os.Getwd(); err == nil {
		// Walk up looking for harness/sidecar/sidecar.js — covers running
		// `go test` inside any harness subdir.
		cur := wd
		for i := 0; i < 6; i++ {
			candidate := filepath.Join(cur, "harness", "sidecar", "sidecar.js")
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
			candidate = filepath.Join(cur, "sidecar", "sidecar.js")
			if _, err := os.Stat(candidate); err == nil {
				return candidate, nil
			}
			next := filepath.Dir(cur)
			if next == cur {
				break
			}
			cur = next
		}
	}
	return "", errors.New("termgrid: sidecar.js not found (set SWE_KITTY_SIDECAR_PATH)")
}

func (m *Manager) readLoop() {
	scanner := bufio.NewScanner(m.stdout)
	// Allow up to 1 MB serialized payloads — big alt-screen TUIs can get
	// large. Default buf is only 64K.
	scanner.Buffer(make([]byte, 0, 4096), 1<<20)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var resp response
		if err := json.Unmarshal(line, &resp); err != nil {
			fmt.Fprintf(os.Stderr, "termgrid: bad sidecar line: %v\n", err)
			continue
		}
		m.mu.Lock()
		ch, ok := m.pending[resp.ID]
		if ok {
			delete(m.pending, resp.ID)
		}
		m.mu.Unlock()
		if ok {
			// Non-blocking send: channel is buffered with cap 1.
			select {
			case ch <- resp:
			default:
			}
		}
	}
	// Sidecar exited / stdout closed. Fail all pending.
	m.mu.Lock()
	for id, ch := range m.pending {
		close(ch)
		delete(m.pending, id)
	}
	m.closed = true
	m.mu.Unlock()
}

func (m *Manager) call(ctx context.Context, req request) (response, error) {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return response{}, ErrClosed
	}
	id := m.nextID.Add(1)
	req.ID = id
	ch := make(chan response, 1)
	m.pending[id] = ch
	m.mu.Unlock()

	encoded, err := json.Marshal(req)
	if err != nil {
		m.mu.Lock()
		delete(m.pending, id)
		m.mu.Unlock()
		return response{}, err
	}
	encoded = append(encoded, '\n')

	m.writeMu.Lock()
	_, werr := m.stdin.Write(encoded)
	m.writeMu.Unlock()
	if werr != nil {
		m.mu.Lock()
		delete(m.pending, id)
		m.mu.Unlock()
		return response{}, werr
	}

	select {
	case resp, ok := <-ch:
		if !ok {
			return response{}, ErrClosed
		}
		if !resp.OK {
			return resp, fmt.Errorf("termgrid: sidecar error: %s", resp.Error)
		}
		return resp, nil
	case <-ctx.Done():
		m.mu.Lock()
		delete(m.pending, id)
		m.mu.Unlock()
		return response{}, ErrTimeout
	}
}

func (m *Manager) callDefault(req request) (response, error) {
	ctx, cancel := context.WithTimeout(context.Background(), defaultTimeout)
	defer cancel()
	return m.call(ctx, req)
}

// Create starts a new headless terminal for sid at rows×cols.
func (m *Manager) Create(sid string, rows, cols uint16) error {
	_, err := m.callDefault(request{Cmd: "create", SID: sid, Rows: rows, Cols: cols})
	return err
}

// Write feeds bytes into the headless terminal's parser.
func (m *Manager) Write(sid string, p []byte) error {
	if len(p) == 0 {
		return nil
	}
	enc := base64.StdEncoding.EncodeToString(p)
	_, err := m.callDefault(request{Cmd: "write", SID: sid, B64: enc})
	return err
}

// Resize reflows the headless grid to the new dimensions.
func (m *Manager) Resize(sid string, rows, cols uint16) error {
	_, err := m.callDefault(request{Cmd: "resize", SID: sid, Rows: rows, Cols: cols})
	return err
}

// Serialize returns the ANSI-escape-encoded snapshot of the headless
// grid in its current state and size.
func (m *Manager) Serialize(sid string) (string, error) {
	resp, err := m.callDefault(request{Cmd: "serialize", SID: sid})
	if err != nil {
		return "", err
	}
	return resp.Data, nil
}

// Delete drops the headless terminal for sid.
func (m *Manager) Delete(sid string) error {
	_, err := m.callDefault(request{Cmd: "delete", SID: sid})
	return err
}

// Ping is a liveness probe. Returns the sidecar's epoch_ms.
func (m *Manager) Ping() (int64, error) {
	resp, err := m.callDefault(request{Cmd: "ping"})
	if err != nil {
		return 0, err
	}
	return resp.Pong, nil
}

// Close kills the sidecar subprocess. Idempotent.
func (m *Manager) Close() error {
	m.mu.Lock()
	if m.closed {
		m.mu.Unlock()
		return nil
	}
	m.closed = true
	m.mu.Unlock()
	_ = m.stdin.Close()
	// Give the sidecar a beat to exit cleanly before killing.
	done := make(chan error, 1)
	go func() { done <- m.cmd.Wait() }()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		_ = m.cmd.Process.Kill()
		<-done
	}
	return nil
}
