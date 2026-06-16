package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestMaybeInstallAgentBinaryPresent verifies that when the binary is already
// on PATH, maybeInstallAgent returns nil without touching the install command.
func TestMaybeInstallAgentBinaryPresent(t *testing.T) {
	// "sh" is always present; use it as a stand-in for "the agent binary".
	err := maybeInstallAgent("sh", "sh", "exit 1", nil)
	if err != nil {
		t.Fatalf("expected nil (binary present), got: %v", err)
	}
}

// TestMaybeInstallAgentNoInstallCmd verifies that when the binary is missing
// and no install_cmd is configured, maybeInstallAgent returns a not-found error.
func TestMaybeInstallAgentNoInstallCmd(t *testing.T) {
	err := maybeInstallAgent("notarealbin-x9z", "notarealbin-x9z", "", nil)
	if err == nil {
		t.Fatal("expected error (binary missing, no install_cmd), got nil")
	}
	if !strings.Contains(err.Error(), "executable file not found") {
		t.Errorf("unexpected error message: %v", err)
	}
}

// TestMaybeInstallAgentInstallFails verifies that when the install command
// exits non-zero, maybeInstallAgent returns an error and publishes a failure
// system message.
func TestMaybeInstallAgentInstallFails(t *testing.T) {
	var published []string
	pub := func(b []byte) { published = append(published, string(b)) }

	// Use "exit 1" as a definitely-failing install command.
	err := maybeInstallAgent("notarealbin-x9z", "notarealbin-x9z", "exit 1", pub)
	if err == nil {
		t.Fatal("expected error (install fails), got nil")
	}
	// Must have published both the "Installing..." and the error message.
	var sawInstalling, sawError bool
	for _, msg := range published {
		if strings.Contains(msg, "Installing") {
			sawInstalling = true
		}
		if strings.Contains(msg, "couldn't install") {
			sawError = true
		}
	}
	if !sawInstalling {
		t.Error("expected 'Installing' message in published output")
	}
	if !sawError {
		t.Errorf("expected error message in published output; got: %v", published)
	}
}

// TestMaybeInstallAgentInstallSucceeds verifies the happy path: the binary is
// missing, the install command creates it, and the retry finds it. Uses a
// temp dir + a shell script as a fake installer.
func TestMaybeInstallAgentInstallSucceeds(t *testing.T) {
	tmpDir := t.TempDir()
	fakeBin := filepath.Join(tmpDir, "fake-agent-x9z")

	// Install command: write a tiny executable to fakeBin.
	installCmd := "printf '#!/bin/sh\\necho ok\\n' > " + fakeBin + " && chmod +x " + fakeBin

	// Prepend tmpDir to PATH so LookPath finds the binary after install.
	origPath := os.Getenv("PATH")
	t.Setenv("PATH", tmpDir+":"+origPath)

	var published []string
	pub := func(b []byte) { published = append(published, string(b)) }

	err := maybeInstallAgent("fake-agent-x9z", "fake-agent-x9z", installCmd, pub)
	if err != nil {
		t.Fatalf("expected nil (install succeeds), got: %v", err)
	}

	// Must have published "Installing..." and "installed" messages.
	var sawInstalling, sawInstalled bool
	for _, msg := range published {
		if strings.Contains(msg, "Installing") {
			sawInstalling = true
		}
		if strings.Contains(msg, "installed") {
			sawInstalled = true
		}
	}
	if !sawInstalling {
		t.Error("expected 'Installing' message")
	}
	if !sawInstalled {
		t.Errorf("expected 'installed' message; got: %v", published)
	}
}

// TestMaybeInstallAgentSingleFlight verifies that two concurrent callers for
// the same agent share a single install run (the install command is only
// executed once). Uses a counter written to a temp file.
func TestMaybeInstallAgentSingleFlight(t *testing.T) {
	tmpDir := t.TempDir()
	fakeBin := filepath.Join(tmpDir, "sf-agent")
	counterFile := filepath.Join(tmpDir, "counter")
	startedFile := filepath.Join(tmpDir, "started") // installer touches this, then blocks
	goFile := filepath.Join(tmpDir, "go")           // test creates this to release the installer

	// Install command: signal it has started, BLOCK until the test releases it
	// (goFile appears), then append a line to counter and write the binary.
	// Blocking the first install deterministically parks the second caller on
	// the single-flight in-flight entry — instead of racing both installs
	// through together (which flaked under CI load: if the first finished and
	// cleared the flight before the second reached run(), the second installed
	// again → count 2).
	installCmd := "touch " + startedFile +
		" && while [ ! -f " + goFile + " ]; do sleep 0.01; done" +
		" && echo x >> " + counterFile +
		" && printf '#!/bin/sh\\necho ok\\n' > " + fakeBin +
		" && chmod +x " + fakeBin

	origPath := os.Getenv("PATH")
	t.Setenv("PATH", tmpDir+":"+origPath)

	// Reset the global installer state between test runs by using a fresh
	// installFlight for this test.
	orig := agentInstaller
	agentInstaller = &installFlight{inflight: make(map[string]*installResult)}
	defer func() { agentInstaller = orig }()

	type result struct{ err error }
	results := make(chan result, 2)

	// Caller A: acquires the flight and runs the (blocking) install.
	go func() {
		results <- result{maybeInstallAgent("sf-agent", "sf-agent", installCmd, nil)}
	}()

	// Wait until A is inside the install command and blocked (flight held).
	waitForFile(t, startedFile, 5*time.Second)

	// Caller B: the binary is still absent (A is blocked), so B passes the
	// fast-path and enters run(), finds the in-flight entry A holds, and parks
	// on it. A is deliberately blocked (not racing), so B has uncontended time
	// to park before we release A — no tight race window.
	go func() {
		results <- result{maybeInstallAgent("sf-agent", "sf-agent", installCmd, nil)}
	}()

	// Give B time to reach the in-flight wait (A is blocked, so this is a
	// generous safety margin, not a race window), then release A.
	time.Sleep(100 * time.Millisecond)
	if err := os.WriteFile(goFile, []byte("go"), 0o600); err != nil {
		t.Fatalf("write go file: %v", err)
	}

	var errs []error
	for i := 0; i < 2; i++ {
		r := <-results
		if r.err != nil {
			errs = append(errs, r.err)
		}
	}
	if len(errs) > 0 {
		t.Fatalf("install errors: %v", errs)
	}

	data, err := os.ReadFile(counterFile)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	lines := strings.Count(strings.TrimSpace(string(data)), "\n") + 1
	if strings.TrimSpace(string(data)) == "" {
		lines = 0
	}
	// Single-flight: the install command runs exactly once; B shares A's result.
	if lines != 1 {
		t.Errorf("install command ran %d times, want 1 (single-flight)", lines)
	}
}

// waitForFile blocks until path exists or the timeout elapses (then fails t).
func waitForFile(t *testing.T, path string, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		if _, err := os.Stat(path); err == nil {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for %s", path)
}
