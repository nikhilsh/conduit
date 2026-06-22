package session

import (
	"errors"
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

	sessionsDir := filepath.Join(root, ".conduit", "sessions", sess.ID)
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
	archivedDir := filepath.Join(root, ".conduit", archivedSessionsDirName, sess.ID)
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

// TestArchivedSessionRefusesReopen verifies the tombstone check: after a
// session is deleted (archived), any attempt to reopen it via
// GetOrCreateWithOptions returns errSessionArchived and does NOT create a
// fresh sessions/<id> directory or add the id to the live map.
func TestArchivedSessionRefusesReopen(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("tombstone-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	const id = "session-tombstone"
	sess, created, err := m.GetOrCreate(id, "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}
	waitForOutput(t, sess, "tombstone-ready")

	// Archive it via DeleteSession.
	if err := m.DeleteSession(id); err != nil {
		t.Fatalf("DeleteSession: %v", err)
	}

	// Canonical archived-sessions/<id> dir must exist.
	archivedDir := filepath.Join(root, ".conduit", archivedSessionsDirName, id)
	if _, err := os.Stat(archivedDir); err != nil {
		t.Fatalf("archived dir missing after delete: %v", err)
	}

	// Reopen attempt must be refused with errSessionArchived.
	_, _, err = m.GetOrCreate(id, "claude")
	if !errors.Is(err, errSessionArchived) {
		t.Fatalf("reopen archived session: got err %v, want errSessionArchived", err)
	}

	// sessions/<id> must NOT have been re-created.
	activeDir := filepath.Join(root, ".conduit", "sessions", id)
	if _, err := os.Stat(activeDir); !os.IsNotExist(err) {
		t.Fatalf("active session dir must not be re-created after archive refusal, stat err=%v", err)
	}

	// The session must NOT appear in the live map.
	if _, ok := m.Get(id); ok {
		t.Fatal("archived session must not be in live map after reopen refusal")
	}
}

// TestFreshSessionUnaffectedByTombstone verifies that a brand-new id
// (never seen before) still creates normally — the tombstone check must
// not block genuinely new sessions.
func TestFreshSessionUnaffectedByTombstone(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("fresh-ok"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	_, created, err := m.GetOrCreate("session-brand-new", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate brand-new: %v", err)
	}
	if !created {
		t.Fatal("expected brand-new session to be created")
	}
}

// TestOnDiskRecoverableSessionStillRecovers verifies that an on-disk
// recoverable session (in sessions/, not archived) still recovers via the
// normal path — the tombstone check must not fire for non-archived ids.
func TestOnDiskRecoverableSessionStillRecovers(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("recover-ok"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	const id = "session-recover"
	sess, _, err := m.GetOrCreate(id, "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "recover-ok")
	if err := sess.Checkpoint("before-recover"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	// Simulate a broker restart: close the manager without deleting the
	// session so the session dir stays in sessions/ (recoverable).
	m.Close()

	m2 := NewManager(reg)
	t.Cleanup(m2.Close)

	sess2, created, err := m2.GetOrCreate(id, "claude")
	if err != nil {
		t.Fatalf("GetOrCreate after restart: %v", err)
	}
	if created {
		t.Fatal("expected session to be recovered (not freshly created)")
	}
	if sess2 == nil {
		t.Fatal("recovered session is nil")
	}
}
