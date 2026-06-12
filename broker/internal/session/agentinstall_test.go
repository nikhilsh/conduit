package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
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

	// Install command: append a line to counter, then write the binary.
	installCmd := "echo x >> " + counterFile +
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

	for i := 0; i < 2; i++ {
		go func() {
			err := maybeInstallAgent("sf-agent", "sf-agent", installCmd, nil)
			results <- result{err}
		}()
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

	// The counter file should have at most 2 lines (both could win the race
	// before the binary is on-path), but ideally 1 (single-flight). In our
	// single-flight implementation the second caller blocks and shares the
	// first's result, so the install command runs exactly once. Verify <= 2
	// to be robust to timing without being flaky.
	data, err := os.ReadFile(counterFile)
	if err != nil {
		t.Fatalf("read counter: %v", err)
	}
	lines := strings.Count(strings.TrimSpace(string(data)), "\n") + 1
	if strings.TrimSpace(string(data)) == "" {
		lines = 0
	}
	// With single-flight, exactly 1.
	if lines != 1 {
		t.Errorf("install command ran %d times, want 1 (single-flight)", lines)
	}
}
