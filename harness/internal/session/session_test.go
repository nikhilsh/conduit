package session

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nikhilsh/swe-kitty/harness/internal/agents"
)

func TestCheckpointPersistsSessionRails(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("checkpoint-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-checkpoint", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}

	waitForOutput(t, sess, "checkpoint-ready")
	if _, err := sess.Write([]byte("echo persisted\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "persisted")

	if err := sess.Checkpoint("manual"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	scrollback, err := os.ReadFile(filepath.Join(root, ".swe-kitty", "sessions", sess.ID, "scrollback.bin"))
	if err != nil {
		t.Fatalf("ReadFile(scrollback): %v", err)
	}
	if !bytes.Contains(scrollback, []byte("persisted")) {
		t.Fatalf("scrollback missing persisted output: %q", string(scrollback))
	}

	memoryDoc, err := os.ReadFile(filepath.Join(root, ".swe-kitty", "memory", "sessions", sess.ID+".html"))
	if err != nil {
		t.Fatalf("ReadFile(memory): %v", err)
	}
	if !bytes.Contains(memoryDoc, []byte("session-checkpoint")) {
		t.Fatalf("memory doc missing session id: %q", string(memoryDoc))
	}
}

func TestSwitchAdapterFallsBackToCheckpointAndKeepsSessionUsable(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": handoffTrapScript("claude-ready"),
		"codex":  idleScript("codex-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-switch", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "claude-ready")
	if err := sess.Checkpoint("before-switch"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}

	if err := sess.SwitchAdapter("codex"); err != nil {
		t.Fatalf("SwitchAdapter: %v", err)
	}
	waitForOutput(t, sess, "codex-ready")

	handoffDoc, err := os.ReadFile(filepath.Join(root, ".swe-kitty", "sessions", sess.ID, "work", ".swe-kitty", "HANDOFF.html"))
	if err != nil {
		t.Fatalf("ReadFile(HANDOFF): %v", err)
	}
	if !bytes.Contains(handoffDoc, []byte(`data-section="handoff"`)) {
		t.Fatalf("handoff file missing handoff section: %q", string(handoffDoc))
	}

	if _, err := sess.Write([]byte("echo switched\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "switched")
}

func TestWatchdogMarksWarningAndDead(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("watchdog-ready"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, _, err := m.GetOrCreate("session-watchdog", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "watchdog-ready")

	sess.mu.Lock()
	sess.lastOutput = time.Now().Add(-time.Second)
	sess.mu.Unlock()
	sess.stallAfter = 20 * time.Millisecond
	sess.runWatchdogChecks()
	if got := sess.Status().Health; got != "warning" {
		t.Fatalf("expected warning health, got %q", got)
	}

	if sess.cmd == nil || sess.cmd.Process == nil {
		t.Fatal("session process missing")
	}
	_ = sess.cmd.Process.Kill()
	_, _ = sess.cmd.Process.Wait()
	sess.runWatchdogChecks()
	if got := sess.Status().Health; got != "dead" {
		t.Fatalf("expected dead health, got %q", got)
	}
}

func TestManagerRecoverRestoresPersistedSnapshot(t *testing.T) {
	root := testRoot(t)
	reg := testRegistry(t, root, map[string]string{
		"claude": idleScript("recover-ready"),
	})

	m1 := NewManager(reg)
	sess, _, err := m1.GetOrCreate("session-recover", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	waitForOutput(t, sess, "recover-ready")
	if _, err := sess.Write([]byte("echo restore-me\n")); err != nil {
		t.Fatalf("Write: %v", err)
	}
	waitForOutput(t, sess, "restore-me")
	if err := sess.Checkpoint("recover"); err != nil {
		t.Fatalf("Checkpoint: %v", err)
	}
	m1.Close()

	m2 := NewManager(reg)
	t.Cleanup(m2.Close)
	recovered, err := m2.Recover()
	if err != nil {
		t.Fatalf("Recover: %v", err)
	}
	if len(recovered) != 1 || recovered[0] != "session-recover" {
		t.Fatalf("unexpected recovered ids: %v", recovered)
	}
	sess2, ok := m2.Get("session-recover")
	if !ok {
		t.Fatal("recovered session missing from manager")
	}
	if !bytes.Contains(sess2.Snapshot(), []byte("restore-me")) {
		t.Fatalf("snapshot missing restored output: %q", string(sess2.Snapshot()))
	}
}

func testRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".swe-kitty"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.swe-kitty): %v", err)
	}
	t.Setenv("SWE_KITTY_ROOT", filepath.Join(root, ".swe-kitty"))
	t.Setenv("KITTY_SESSION_CHECKPOINT_INTERVAL_MS", "1000")
	t.Setenv("KITTY_SESSION_WATCHDOG_INTERVAL_MS", "1000")
	t.Setenv("KITTY_SESSION_STALL_AFTER_MS", "1000")
	t.Setenv("KITTY_SESSION_HANDOFF_TIMEOUT_MS", "500")
	return root
}

func testRegistry(t *testing.T, root string, scripts map[string]string) *agents.Registry {
	t.Helper()
	dir := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatalf("MkdirAll(workspace): %v", err)
	}
	for name, script := range scripts {
		body := strings.Join([]string{
			`name = "` + name + `"`,
			`image = "swekitty/` + name + `:latest"`,
			`command = ["sh"]`,
			`args = ["-lc", ` + quoteTOML(script) + `]`,
			`workdir = ` + quoteTOML(workspace),
		}, "\n")
		path := filepath.Join(dir, name+".toml")
		if err := os.WriteFile(path, []byte(body+"\n"), 0o644); err != nil {
			t.Fatalf("WriteFile(%s): %v", path, err)
		}
	}
	reg, err := agents.LoadDir(dir)
	if err != nil {
		t.Fatalf("LoadDir: %v", err)
	}
	return reg
}

func waitForOutput(t *testing.T, sess *Session, want string) {
	t.Helper()
	sub := sess.Subscribe()
	defer sess.Unsubscribe(sub)

	deadline := time.After(3 * time.Second)
	var out bytes.Buffer
	for {
		select {
		case chunk := <-sub:
			out.Write(chunk)
			if strings.Contains(out.String(), want) {
				return
			}
		case <-deadline:
			t.Fatalf("timed out waiting for %q in %q", want, out.String())
		}
	}
}

func idleScript(ready string) string {
	return "echo " + ready + "; while :; do sleep 1; done"
}

func handoffTrapScript(ready string) string {
	return "trap 'cp \"$KITTY_HANDOFF_PATH\" \"$KITTY_HANDOFF_OUT_PATH\"; exit 0' USR1; echo " + ready + "; while :; do sleep 1; done"
}

func quoteTOML(v string) string {
	return `"` + strings.ReplaceAll(strings.ReplaceAll(v, `\`, `\\`), `"`, `\"`) + `"`
}
