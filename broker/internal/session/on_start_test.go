package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// testRegistryWithHooks builds a registry like testRegistry but appends
// extra TOML lines (e.g. a [hooks] section) to each adapter's TOML file.
func testRegistryWithHooks(t *testing.T, root string, scripts map[string]string, extraTOML map[string]string) *agents.Registry {
	t.Helper()
	dir := t.TempDir()
	workspace := filepath.Join(root, "workspace")
	if err := os.MkdirAll(workspace, 0o755); err != nil {
		t.Fatalf("MkdirAll(workspace): %v", err)
	}
	for name, script := range scripts {
		lines := []string{
			`name = "` + name + `"`,
			`image = "conduit/` + name + `:latest"`,
			`command = ["sh"]`,
			`args = ["-lc", ` + quoteTOML(script) + `]`,
			`workdir = ` + quoteTOML(workspace),
		}
		if extra, ok := extraTOML[name]; ok {
			lines = append(lines, extra)
		}
		body := strings.Join(lines, "\n")
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

// TestOnStartHookRunsAndCreatesFile verifies that an on_start hook is
// executed after the session spawns. The hook touches a sentinel file;
// after GetOrCreate + the session is ready the sentinel must exist.
func TestOnStartHookRunsAndCreatesFile(t *testing.T) {
	root := testRoot(t)
	sentinel := filepath.Join(root, "on_start_ran")
	hook := "touch " + sentinel

	reg := testRegistryWithHooks(t, root, map[string]string{
		"claude": idleScript("on-start-ready"),
	}, map[string]string{
		"claude": "[hooks]\non_start = " + quoteTOML(hook),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-on-start", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}
	waitForOutput(t, sess, "on-start-ready")

	// The on_start hook runs synchronously before drain starts, so the
	// sentinel must already exist once the session is ready.
	if _, err := os.Stat(sentinel); err != nil {
		t.Fatalf("on_start sentinel not found: %v (hook did not run)", err)
	}
}

// TestOnStartHookFailureDoesNotBlockSpawn verifies that a failing on_start
// hook (exit 1) never prevents the session from being created and used.
func TestOnStartHookFailureDoesNotBlockSpawn(t *testing.T) {
	root := testRoot(t)

	reg := testRegistryWithHooks(t, root, map[string]string{
		"claude": idleScript("on-start-fail-ready"),
	}, map[string]string{
		"claude": "[hooks]\non_start = " + quoteTOML("exit 1"),
	})
	m := NewManager(reg)
	t.Cleanup(m.Close)

	sess, created, err := m.GetOrCreate("session-on-start-fail", "claude")
	if err != nil {
		t.Fatalf("GetOrCreate must succeed even when on_start hook fails: %v", err)
	}
	if !created {
		t.Fatal("expected new session")
	}

	// Session must be functional despite the hook failure.
	waitForOutput(t, sess, "on-start-fail-ready")

	deadline := time.After(3 * time.Second)
	for {
		if sess.Status().Phase == "running" {
			return
		}
		select {
		case <-deadline:
			t.Fatalf("session phase = %q, want running", sess.Status().Phase)
		default:
			time.Sleep(10 * time.Millisecond)
		}
	}
}
