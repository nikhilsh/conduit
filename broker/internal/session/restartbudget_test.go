package session

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestRecordAgentExitCounting(t *testing.T) {
	s := &Session{spawnedAt: time.Now()}

	s.recordAgentExit()
	s.recordAgentExit()
	if s.consecutiveFastExits != 2 {
		t.Fatalf("two fast exits: got %d, want 2", s.consecutiveFastExits)
	}

	// A run that outlived the window resets the budget.
	s.spawnedAt = time.Now().Add(-2 * fastExitWindow)
	s.recordAgentExit()
	if s.consecutiveFastExits != 0 {
		t.Fatalf("healthy run: got %d, want 0", s.consecutiveFastExits)
	}

	// Intentional teardown (Close set s.closing) never counts.
	s.spawnedAt = time.Now()
	s.closing = true
	s.recordAgentExit()
	if s.consecutiveFastExits != 0 {
		t.Fatalf("closing teardown: got %d, want 0", s.consecutiveFastExits)
	}
}

// waitReaped polls until the Done-watcher goroutine has dropped the
// session from the manager's live map, so the next GetOrCreate goes
// through disk recovery rather than returning the dead in-memory session.
func waitReaped(t *testing.T, m *Manager, id string) {
	t.Helper()
	deadline := time.After(3 * time.Second)
	for {
		if _, ok := m.Get(id); !ok {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("session %s never reaped from live map", id)
		case <-time.After(10 * time.Millisecond):
		}
	}
}

// TestSessionGivesUpAfterRepeatedFastExits is the end-to-end restart
// budget: an agent that dies instantly respawns on each reopen until
// maxConsecutiveFastExits, after which the open is refused with
// errSessionGaveUp and the session dir is archived out of the active set.
func TestSessionGivesUpAfterRepeatedFastExits(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": "echo crash-and-burn; exit 1",
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	const id = "session-giveup"
	for i := 1; i <= maxConsecutiveFastExits; i++ {
		sess, _, err := m.GetOrCreate(id, "claude")
		if err != nil {
			t.Fatalf("attempt %d: GetOrCreate: %v", i, err)
		}
		select {
		case <-sess.Done():
		case <-time.After(5 * time.Second):
			t.Fatalf("attempt %d: agent did not exit", i)
		}
		waitReaped(t, m, id)
	}

	_, _, err := m.GetOrCreate(id, "claude")
	if !errors.Is(err, errSessionGaveUp) {
		t.Fatalf("after %d fast exits: got err %v, want errSessionGaveUp", maxConsecutiveFastExits, err)
	}

	activeDir := filepath.Join(root, ".conduit", "sessions", id)
	if _, serr := os.Stat(activeDir); !os.IsNotExist(serr) {
		t.Fatalf("active session dir should be archived after give-up, stat err=%v", serr)
	}
	archivedDir := filepath.Join(root, ".conduit", archivedSessionsDirName, id)
	if _, serr := os.Stat(archivedDir); serr != nil {
		t.Fatalf("archived session dir missing after give-up: %v", serr)
	}

	// And the refusal is sticky: a re-open after the archive starts a
	// brand-new blank session rather than resurrecting the crash-looper
	// — acceptable; what must NOT happen is errSessionGaveUp again
	// blocking a genuinely new session the user creates under a new id.
	if _, _, err := m.GetOrCreate("session-fresh", "claude"); err != nil {
		t.Fatalf("fresh session under a new id should still create: %v", err)
	}
}
