package session

import (
	"os"
	"path/filepath"
	"testing"
)

// TestDeleteSessionArchivesAndTerminates verifies the app-side delete
// path: a live session is dropped from the active map, its agent process
// is killed, and its on-disk dir is moved out of `sessions/` into
// `archived-sessions/` (transcript preserved, not hard-deleted).
func TestDeleteSessionArchivesAndTerminates(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("delete-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-delete", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}
	waitForOutput(t, sess, "delete-ready")

	// Seed a conversation log so we can assert it survives the archive.
	sess.convLog.appendUser("hello from the test")
	if err := sess.Checkpoint("pre-delete"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	sessionsDir := filepath.Join(root, ".swe-kitty", "sessions", sess.ID)
	if _, err := os.Stat(sessionsDir); err != nil {
		t.Fatalf("session dir should exist before delete: %v", err)
	}

	if err := m.DeleteSession(sess.ID); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}

	// Dropped from the active map immediately.
	if _, ok := m.Get(sess.ID); ok {
		t.Fatal("session still in active map after delete")
	}
	// Process killed (Done channel closed by Close()).
	select {
	case <-sess.Done():
	default:
		t.Fatal("session not terminated after delete")
	}
	// Active dir gone; archived dir present.
	if _, err := os.Stat(sessionsDir); !os.IsNotExist(err) {
		t.Fatalf("active session dir should be gone after delete, stat err=%v", err)
	}
	archivedDir := filepath.Join(root, ".swe-kitty", archivedSessionsDirName, sess.ID)
	if _, err := os.Stat(archivedDir); err != nil {
		t.Fatalf("archived session dir missing: %v", err)
	}
	if _, err := os.Stat(filepath.Join(archivedDir, "conversation.jsonl")); err != nil {
		t.Fatalf("archived conversation.jsonl missing: %v", err)
	}

	// Transcript still reachable through ConversationLog (the
	// GET /api/session/conversation/<id> backing call) via the archive
	// fallback.
	entries, err := m.ConversationLog(sess.ID)
	if err != nil {
		t.Fatalf("ConversationLog after delete: %v", err)
	}
	if len(entries) == 0 || entries[0].Content != "hello from the test" {
		t.Fatalf("unexpected archived transcript: %+v", entries)
	}
}

// TestDeleteSessionIdempotent verifies that deleting an unknown / already
// gone session is a no-op (no error), so the HTTP handler can answer 200
// for repeat deletes.
func TestDeleteSessionIdempotent(t *testing.T) {
	root := testRoot(t)
	_ = root
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("idem-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	if err := m.DeleteSession("never-existed"); err != nil {
		t.Fatalf("deleting unknown session should be a no-op, got: %v", err)
	}

	sess, _, err := m.GetOrCreate("session-idem", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "idem-ready")
	if err := m.DeleteSession(sess.ID); err != nil {
		t.Fatalf("first DeleteSession: %v", err)
	}
	if err := m.DeleteSession(sess.ID); err != nil {
		t.Fatalf("second DeleteSession should be a no-op, got: %v", err)
	}
}
