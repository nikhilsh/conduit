package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// newTestManager builds a Manager with only the fields RunGC touches.
// The full constructor expects an agents.Registry and tries to spawn a
// node sidecar — too much for a unit test that just exercises GC.
func newTestManager(t *testing.T) *Manager {
	t.Helper()
	root := t.TempDir()
	return &Manager{
		sessions:  make(map[string]*Session),
		kittyRoot: root,
		stopGC:    make(chan struct{}),
	}
}

// makeSession plants a fake session-on-disk: kittyRoot/sessions/<id>/
// with a meta.json whose mtime is `age` old.
func makeSession(t *testing.T, m *Manager, id string, age time.Duration) string {
	t.Helper()
	dir := filepath.Join(m.kittyRoot, "sessions", id)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	meta := filepath.Join(dir, "meta.json")
	if err := os.WriteFile(meta, []byte(`{}`), 0o644); err != nil {
		t.Fatalf("write meta: %v", err)
	}
	// Force both the file AND its parent dir back in time. os.Chtimes
	// only touches the file; parent dir mtime stays at "now", which
	// would defeat mostRecentTouch. Walk the dir tree to set them all.
	past := time.Now().Add(-age)
	if err := filepath.Walk(dir, func(path string, _ os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		return os.Chtimes(path, past, past)
	}); err != nil {
		t.Fatalf("chtimes walk: %v", err)
	}
	return dir
}

// memoryFile returns the snapshot path the GC pairs with a session id.
func memoryFile(m *Manager, id string) string {
	return filepath.Join(m.kittyRoot, "memory", "sessions", id+".html")
}

func TestRunGCPrunesStale(t *testing.T) {
	m := newTestManager(t)

	makeSession(t, m, "old", 30*24*time.Hour)   // 30d old → prune
	makeSession(t, m, "fresh", 1*time.Hour)     // 1h old  → keep
	makeSession(t, m, "edge", 6*24*time.Hour-1) // ~6d, just under 7d → keep
	makeSession(t, m, "live", 30*24*time.Hour)  // also stale, but live → keep
	m.sessions["live"] = &Session{ID: "live"}

	// Plant a pair memory HTML for "old" so we can prove it's cleaned.
	mDir := filepath.Join(m.kittyRoot, "memory", "sessions")
	if err := os.MkdirAll(mDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(memoryFile(m, "old"), []byte("snap"), 0o644); err != nil {
		t.Fatal(err)
	}

	pruned, err := m.RunGC(7*24*time.Hour, time.Now())
	if err != nil {
		t.Fatalf("RunGC: %v", err)
	}
	if got, want := strings.Join(pruned, ","), "old"; got != want {
		t.Errorf("pruned = %q, want %q", got, want)
	}
	// "old" gone, others present.
	for _, id := range []string{"fresh", "edge", "live"} {
		if _, err := os.Stat(filepath.Join(m.kittyRoot, "sessions", id)); err != nil {
			t.Errorf("expected session %q to be kept, got: %v", id, err)
		}
	}
	if _, err := os.Stat(filepath.Join(m.kittyRoot, "sessions", "old")); !os.IsNotExist(err) {
		t.Errorf("expected sessions/old to be gone, err = %v", err)
	}
	if _, err := os.Stat(memoryFile(m, "old")); !os.IsNotExist(err) {
		t.Errorf("expected memory/sessions/old.html to be gone, err = %v", err)
	}
}

func TestRunGCDisabledWithZeroAge(t *testing.T) {
	m := newTestManager(t)
	makeSession(t, m, "ancient", 365*24*time.Hour)

	pruned, err := m.RunGC(0, time.Now())
	if err != nil {
		t.Fatalf("RunGC: %v", err)
	}
	if len(pruned) != 0 {
		t.Errorf("disabled GC should be a no-op, pruned: %v", pruned)
	}
	if _, err := os.Stat(filepath.Join(m.kittyRoot, "sessions", "ancient")); err != nil {
		t.Errorf("session should remain when GC disabled: %v", err)
	}
}

func TestRunGCMissingRootIsFine(t *testing.T) {
	m := newTestManager(t)
	// No sessions/ dir exists yet; first-boot before any session.
	pruned, err := m.RunGC(7*24*time.Hour, time.Now())
	if err != nil {
		t.Errorf("missing root should be a no-op, got err: %v", err)
	}
	if len(pruned) != 0 {
		t.Errorf("missing root should prune nothing, got: %v", pruned)
	}
}

func TestRunGCKeepsCheckpointedSession(t *testing.T) {
	// A session that recently checkpointed (meta.json fresh) but
	// whose dir mtime is older — mostRecentTouch must pick the
	// max so we don't reap an active recovered session.
	m := newTestManager(t)
	dir := filepath.Join(m.kittyRoot, "sessions", "recovered")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	past := time.Now().Add(-30 * 24 * time.Hour)
	// Old dir mtime…
	if err := os.Chtimes(dir, past, past); err != nil {
		t.Fatal(err)
	}
	// …but fresh meta.json.
	meta := filepath.Join(dir, "meta.json")
	if err := os.WriteFile(meta, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	pruned, err := m.RunGC(7*24*time.Hour, time.Now())
	if err != nil {
		t.Fatalf("RunGC: %v", err)
	}
	if len(pruned) != 0 {
		t.Errorf("recovered session with fresh meta.json should be kept, pruned: %v", pruned)
	}
}
