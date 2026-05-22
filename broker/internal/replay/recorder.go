// Package replay records per-session PTY byte streams and structured
// view_events to a single newline-delimited JSON timeline on disk, and
// serves a shareable HTML player that replays the timeline through
// xterm.js.
//
// File shape (`<baseDir>/<sessionID>/replay.json`) is JSON Lines:
//
//	{"ts":"2026-05-22T07:00:00.000Z","kind":"pty","b64":"..."}
//	{"ts":"2026-05-22T07:00:01.234Z","kind":"view_event","view":"chat","payload":{...}}
//
// Append-only — each line is one event. The player streams the file and
// replays events at their original cadence (or 4×/16× via UI controls).
//
// Recorder is safe for concurrent use from the manager's drain
// goroutine plus the WS handler's `view_event` publish path. Errors
// after construction are best-effort: a failed write logs to stderr but
// must NEVER block PTY fan-out or close the session.
package replay

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"time"
)

// Recorder owns the replay.json file for a single session. Construct
// with NewRecorder; close on session teardown.
type Recorder struct {
	sessionID string
	dir       string
	path      string

	mu     sync.Mutex
	file   *os.File
	writer *json.Encoder
	closed bool
}

// ptyEvent / viewEvent are the on-disk record shapes. Kept as
// concrete structs (not map[string]any) so the JSONL output is
// schema-stable and easy to parse from the embedded JS player.
type ptyEvent struct {
	TS   string `json:"ts"`
	Kind string `json:"kind"`
	B64  string `json:"b64"`
}

type viewEventRecord struct {
	TS      string `json:"ts"`
	Kind    string `json:"kind"`
	View    string `json:"view"`
	Payload any    `json:"payload"`
}

// NewRecorder creates `<baseDir>/<sessionID>/replay.json`, opening it
// for append so a recovered session continues the same timeline rather
// than truncating prior history. Returns nil + error if the directory
// cannot be created or the file cannot be opened — callers should fall
// back to recording-disabled.
func NewRecorder(sessionID, baseDir string) (*Recorder, error) {
	if sessionID == "" {
		return nil, fmt.Errorf("replay: empty session id")
	}
	dir := filepath.Join(baseDir, sessionID)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return nil, fmt.Errorf("replay: mkdir %s: %w", dir, err)
	}
	path := filepath.Join(dir, "replay.json")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, fmt.Errorf("replay: open %s: %w", path, err)
	}
	return &Recorder{
		sessionID: sessionID,
		dir:       dir,
		path:      path,
		file:      f,
		writer:    json.NewEncoder(f),
	}, nil
}

// Path returns the absolute filesystem path of the replay JSONL file.
// Exposed so tests can inspect what landed without re-deriving the path
// from the session id.
func (r *Recorder) Path() string {
	if r == nil {
		return ""
	}
	return r.path
}

// Dir returns the per-session directory holding the replay file.
func (r *Recorder) Dir() string {
	if r == nil {
		return ""
	}
	return r.dir
}

// RecordBytes appends a `kind:"pty"` event. `b` is base64-encoded
// (StdEncoding) so the JSONL stays line-safe regardless of the raw byte
// values — PTY streams legitimately contain NUL, escape sequences, and
// other characters that would break naive text framing.
//
// Nil receiver is a no-op so callers don't need to guard on the
// "recording disabled" case.
func (r *Recorder) RecordBytes(b []byte, ts time.Time) {
	if r == nil || len(b) == 0 {
		return
	}
	encoded := base64.StdEncoding.EncodeToString(b)
	r.write(ptyEvent{
		TS:   ts.UTC().Format(time.RFC3339Nano),
		Kind: "pty",
		B64:  encoded,
	})
}

// RecordEvent appends a `kind:"view_event"` record. `payload` is the
// already-decoded `event` object from the WS frame (so the player can
// re-render it directly without re-parsing); `view` is the view tag
// from the same envelope (`chat`, `status`, etc).
func (r *Recorder) RecordEvent(view string, payload any, ts time.Time) {
	if r == nil {
		return
	}
	r.write(viewEventRecord{
		TS:      ts.UTC().Format(time.RFC3339Nano),
		Kind:    "view_event",
		View:    view,
		Payload: payload,
	})
}

// write serializes a record and appends it to the file under the
// mutex. Errors are logged once but never propagated — the contract is
// that recording is best-effort and must not perturb live streaming.
func (r *Recorder) write(v any) {
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed || r.writer == nil {
		return
	}
	if err := r.writer.Encode(v); err != nil {
		fmt.Fprintf(os.Stderr, "replay %s: write: %v\n", r.sessionID, err)
	}
}

// Close flushes the underlying file. Idempotent — calling twice is safe
// and returns the same nil result on the second call.
func (r *Recorder) Close() error {
	if r == nil {
		return nil
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	if r.closed {
		return nil
	}
	r.closed = true
	if r.file == nil {
		return nil
	}
	err := r.file.Close()
	r.file = nil
	r.writer = nil
	return err
}
