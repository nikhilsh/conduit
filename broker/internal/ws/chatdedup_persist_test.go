package ws

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// TestChatDedupPersistRoundTrip verifies that a client_msg_id accepted by one
// chatDedup instance is persisted to disk and then recognised as a duplicate by
// a fresh chatDedup instance that loads from the same directory.
// This is the broker-restart scenario: accept → persist → reload → duplicate rejected.
func TestChatDedupPersistRoundTrip(t *testing.T) {
	dir := t.TempDir()
	const (
		sessionID = "sess-persist-test"
		msgID     = "msg-abc-123"
	)

	// Simulate the first broker process: accept the message and persist.
	d1 := newChatDedup()
	dup := d1.markSeen(sessionID, msgID)
	if dup {
		t.Fatal("first markSeen must return false (new)")
	}
	d1.persistSession(dir, sessionID)

	// Verify the file was written.
	if _, err := os.Stat(filepath.Join(dir, "dedup.json")); err != nil {
		t.Fatalf("dedup.json not written: %v", err)
	}

	// Simulate the second broker process (restart): load from disk, then check.
	d2 := newChatDedup()
	d2.loadSession(dir, sessionID)

	dup2 := d2.markSeen(sessionID, msgID)
	if !dup2 {
		t.Fatal("after reload, same client_msg_id must be recognised as duplicate")
	}
}

// TestChatDedupPersistExpiredNotLoaded asserts that entries older than the TTL
// are not loaded back (they have expired and should be treated as new).
func TestChatDedupPersistExpiredNotLoaded(t *testing.T) {
	dir := t.TempDir()
	const (
		sessionID = "sess-expire-test"
		msgID     = "msg-expired-xyz"
	)

	d1 := newChatDedup()
	_ = d1.markSeen(sessionID, msgID)
	// Backdate the entry past the TTL so it is expired when persisted.
	d1.mu.Lock()
	d1.seen[sessionID][msgID] = time.Now().Add(-2 * chatDedupTTL)
	d1.mu.Unlock()
	d1.persistSession(dir, sessionID)
	// persistSession skips expired entries, so the file should be absent or empty.

	d2 := newChatDedup()
	d2.loadSession(dir, sessionID)
	dup := d2.markSeen(sessionID, msgID)
	if dup {
		t.Fatal("expired id must not be loaded; re-sight must be treated as new")
	}
}

// TestChatDedupPersistMaxEntries verifies that persistSession caps the file at
// dedupMaxPersist entries, keeping the newest.
func TestChatDedupPersistMaxEntries(t *testing.T) {
	dir := t.TempDir()
	const sessionID = "sess-cap-test"

	d1 := newChatDedup()
	// Insert dedupMaxPersist+50 fresh entries with distinct timestamps.
	// Use now-based timestamps so none expire before reload.
	base := time.Now().Add(-time.Minute)
	d1.mu.Lock()
	bySession := make(map[string]time.Time, dedupMaxPersist+50)
	for i := 0; i < dedupMaxPersist+50; i++ {
		id := string(rune('a'+i%26)) + string(rune('0'+i/26)) // unique across 260 values
		bySession[id] = base.Add(time.Duration(i) * time.Millisecond)
	}
	d1.seen[sessionID] = bySession
	d1.mu.Unlock()

	d1.persistSession(dir, sessionID)

	d2 := newChatDedup()
	d2.loadSession(dir, sessionID)
	d2.mu.Lock()
	count := len(d2.seen[sessionID])
	d2.mu.Unlock()
	if count > dedupMaxPersist {
		t.Fatalf("loaded %d entries, want at most %d", count, dedupMaxPersist)
	}
	if count == 0 {
		t.Fatal("expected non-zero entries after reload")
	}
}

// TestChatDedupLoadMissingFileIsNoop asserts that loadSession on a directory
// with no dedup.json is a no-op (does not panic or error).
func TestChatDedupLoadMissingFileIsNoop(t *testing.T) {
	dir := t.TempDir()
	d := newChatDedup()
	d.loadSession(dir, "no-such-session") // must not panic
}

// TestChatDedupLoadCorruptFileIsNoop asserts that a corrupt dedup.json is
// silently ignored so a bad file never kills the broker on reconnect.
func TestChatDedupLoadCorruptFileIsNoop(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "dedup.json"), []byte("not json"), 0o644); err != nil {
		t.Fatal(err)
	}
	d := newChatDedup()
	d.loadSession(dir, "sess") // must not panic or error
	d.mu.Lock()
	count := len(d.seen["sess"])
	d.mu.Unlock()
	if count != 0 {
		t.Fatalf("corrupt file must load 0 entries, got %d", count)
	}
}
