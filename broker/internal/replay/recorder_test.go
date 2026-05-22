package replay

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestRecorderWritesValidJSONL covers the on-disk shape contract: every
// line is one JSON object with `ts` + `kind`, PTY bytes round-trip
// through base64, view_event payloads round-trip as nested objects.
func TestRecorderWritesValidJSONL(t *testing.T) {
	dir := t.TempDir()
	rec, err := NewRecorder("sess-1", dir)
	if err != nil {
		t.Fatalf("NewRecorder: %v", err)
	}
	ts1 := time.Date(2026, 5, 22, 7, 0, 0, 0, time.UTC)
	ts2 := ts1.Add(500 * time.Millisecond)
	ts3 := ts2.Add(time.Second)
	rec.RecordBytes([]byte{0x1b, '[', 'A'}, ts1) // ANSI escape: NOT line-safe
	rec.RecordEvent("chat", map[string]any{
		"role":    "assistant",
		"content": "hello",
	}, ts2)
	rec.RecordBytes([]byte("plain"), ts3)
	if err := rec.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	path := filepath.Join(dir, "sess-1", "replay.json")
	if got := rec.Path(); got != path {
		t.Fatalf("Path: got %s want %s", got, path)
	}
	f, err := os.Open(path)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()
	scanner := bufio.NewScanner(f)
	var lines [][]byte
	for scanner.Scan() {
		lines = append(lines, append([]byte{}, scanner.Bytes()...))
	}
	if err := scanner.Err(); err != nil {
		t.Fatalf("scan: %v", err)
	}
	if len(lines) != 3 {
		t.Fatalf("got %d lines, want 3 (lines=%q)", len(lines), lines)
	}

	// Line 1: pty event with the escape bytes intact via base64.
	var l1 struct {
		TS   string `json:"ts"`
		Kind string `json:"kind"`
		B64  string `json:"b64"`
	}
	if err := json.Unmarshal(lines[0], &l1); err != nil {
		t.Fatalf("unmarshal line1: %v (%q)", err, lines[0])
	}
	if l1.Kind != "pty" {
		t.Fatalf("line1.kind=%q want pty", l1.Kind)
	}
	decoded, err := base64.StdEncoding.DecodeString(l1.B64)
	if err != nil {
		t.Fatalf("base64: %v", err)
	}
	if string(decoded) != "\x1b[A" {
		t.Fatalf("decoded=%q want ESC[A", decoded)
	}

	// Line 2: view_event with nested payload preserved.
	var l2 struct {
		Kind    string         `json:"kind"`
		View    string         `json:"view"`
		Payload map[string]any `json:"payload"`
	}
	if err := json.Unmarshal(lines[1], &l2); err != nil {
		t.Fatalf("unmarshal line2: %v (%q)", err, lines[1])
	}
	if l2.Kind != "view_event" {
		t.Fatalf("line2.kind=%q want view_event", l2.Kind)
	}
	if l2.View != "chat" {
		t.Fatalf("line2.view=%q want chat", l2.View)
	}
	if l2.Payload["role"] != "assistant" || l2.Payload["content"] != "hello" {
		t.Fatalf("line2.payload mismatch: %+v", l2.Payload)
	}
}

// TestRecorderAppendsOnReopen ensures a recovered session continues
// writing the same timeline rather than truncating prior history.
// The session lifecycle re-instantiates a Recorder when a session is
// recovered from disk; the contract is "open with O_APPEND".
func TestRecorderAppendsOnReopen(t *testing.T) {
	dir := t.TempDir()
	rec1, err := NewRecorder("sess-app", dir)
	if err != nil {
		t.Fatalf("first NewRecorder: %v", err)
	}
	rec1.RecordBytes([]byte("one"), time.Unix(0, 0))
	if err := rec1.Close(); err != nil {
		t.Fatalf("Close 1: %v", err)
	}
	rec2, err := NewRecorder("sess-app", dir)
	if err != nil {
		t.Fatalf("second NewRecorder: %v", err)
	}
	rec2.RecordBytes([]byte("two"), time.Unix(1, 0))
	if err := rec2.Close(); err != nil {
		t.Fatalf("Close 2: %v", err)
	}
	data, err := os.ReadFile(filepath.Join(dir, "sess-app", "replay.json"))
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	// Two lines, both pty kind.
	count := 0
	for _, b := range data {
		if b == '\n' {
			count++
		}
	}
	if count != 2 {
		t.Fatalf("want 2 lines in file after reopen, got %d (data=%q)", count, data)
	}
}

// TestRecorderNilSafe codifies the contract that a nil receiver is a
// no-op — the drain / publish paths use a possibly-nil recorder and
// must never panic.
func TestRecorderNilSafe(t *testing.T) {
	var rec *Recorder
	rec.RecordBytes([]byte("x"), time.Now())
	rec.RecordEvent("chat", "y", time.Now())
	if err := rec.Close(); err != nil {
		t.Fatalf("Close on nil: %v", err)
	}
}
