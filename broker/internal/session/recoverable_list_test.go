package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// writeRecoverableFixture lays down a minimal on-disk session that
// recoverSessionLocked would accept: meta.json + scrollback.bin + the
// memory snapshot. Individual checks are knocked out by the opts to prove
// RecoverableSessions mirrors each recovery precondition.
type fixtureOpts struct {
	assistant    string
	fastExits    int
	noScrollback bool
	noMemory     bool
}

func writeRecoverableFixture(t *testing.T, root, id string, o fixtureOpts) {
	t.Helper()
	sessDir := filepath.Join(root, "sessions", id)
	if err := os.MkdirAll(sessDir, 0o755); err != nil {
		t.Fatalf("mkdir session dir: %v", err)
	}
	meta := sessionMetadata{
		ID:                   id,
		Assistant:            o.assistant,
		Phase:                "exited",
		Health:               "warning",
		ConsecutiveFastExits: o.fastExits,
		AITitle:              "Fixture " + id,
		WorkspaceDir:         "/tmp/ws-" + id,
	}
	data, err := json.Marshal(meta)
	if err != nil {
		t.Fatalf("marshal meta: %v", err)
	}
	if err := os.WriteFile(filepath.Join(sessDir, "meta.json"), data, 0o644); err != nil {
		t.Fatalf("write meta: %v", err)
	}
	if !o.noScrollback {
		if err := os.WriteFile(filepath.Join(sessDir, "scrollback.bin"), []byte("hi"), 0o644); err != nil {
			t.Fatalf("write scrollback: %v", err)
		}
	}
	if !o.noMemory {
		memDir := filepath.Join(root, "memory", "sessions")
		if err := os.MkdirAll(memDir, 0o755); err != nil {
			t.Fatalf("mkdir memory: %v", err)
		}
		if err := os.WriteFile(filepath.Join(memDir, id+".html"), []byte("<html></html>"), 0o644); err != nil {
			t.Fatalf("write memory: %v", err)
		}
	}
}

func TestRecoverableSessionsAdvertisesOnlyResumable(t *testing.T) {
	root := t.TempDir()
	reg := testRegistry(t, root, map[string]string{"claude": "echo hi"})
	m := &Manager{
		sessions:  make(map[string]*Session),
		kittyRoot: root,
		registry:  reg,
		stopGC:    make(chan struct{}),
	}

	// Clean, recoverable session — should be advertised.
	writeRecoverableFixture(t, root, "ok-1", fixtureOpts{assistant: "claude"})
	// Missing scrollback — recovery would error on ReadFile.
	writeRecoverableFixture(t, root, "no-scroll", fixtureOpts{assistant: "claude", noScrollback: true})
	// Missing memory snapshot — recovery would error on Stat.
	writeRecoverableFixture(t, root, "no-mem", fixtureOpts{assistant: "claude", noMemory: true})
	// Restart budget exhausted — recovery refuses (errSessionGaveUp).
	writeRecoverableFixture(t, root, "gave-up", fixtureOpts{assistant: "claude", fastExits: maxConsecutiveFastExits})
	// Unknown adapter — registry.Get fails.
	writeRecoverableFixture(t, root, "bad-adapter", fixtureOpts{assistant: "nope"})
	// No assistant at all.
	writeRecoverableFixture(t, root, "no-assistant", fixtureOpts{assistant: ""})

	got := m.RecoverableSessions()
	if len(got) != 1 {
		t.Fatalf("expected exactly 1 recoverable session, got %d: %+v", len(got), got)
	}
	info := got[0]
	if info.ID != "ok-1" {
		t.Fatalf("expected ok-1, got %q", info.ID)
	}
	if !info.Recoverable {
		t.Errorf("recoverable row must carry Recoverable=true")
	}
	if info.Running {
		t.Errorf("a cold recoverable row must report Running=false, got true")
	}
	if info.Assistant != "claude" || info.Title != "Fixture ok-1" || info.CWD != "/tmp/ws-ok-1" {
		t.Errorf("metadata not carried through: %+v", info)
	}
}

func TestRecoverableSessionsExcludesLive(t *testing.T) {
	root := t.TempDir()
	reg := testRegistry(t, root, map[string]string{"claude": "echo hi"})
	m := &Manager{
		sessions:  make(map[string]*Session),
		kittyRoot: root,
		registry:  reg,
		stopGC:    make(chan struct{}),
	}
	writeRecoverableFixture(t, root, "live-1", fixtureOpts{assistant: "claude"})
	// Pretend it's already held in memory — RecoverableSessions must skip
	// it so a session is never listed in both Sessions and Recoverable.
	m.sessions["live-1"] = &Session{ID: "live-1"}

	if got := m.RecoverableSessions(); len(got) != 0 {
		t.Fatalf("a live session must not appear in the recoverable list, got %+v", got)
	}
}
