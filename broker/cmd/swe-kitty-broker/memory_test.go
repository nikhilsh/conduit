package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunMemoryCheckpointAndPromote(t *testing.T) {
	root := t.TempDir()
	tailPath := filepath.Join(root, "tail.txt")
	if err := os.WriteFile(tailPath, []byte("tail line\n"), 0o644); err != nil {
		t.Fatalf("WriteFile(tail): %v", err)
	}

	var stdout bytes.Buffer
	var stderr bytes.Buffer
	oldStdout, oldStderr := memoryStdout, memoryStderr
	memoryStdout, memoryStderr = &stdout, &stderr
	t.Cleanup(func() {
		memoryStdout, memoryStderr = oldStdout, oldStderr
	})

	code := runMemory([]string{
		"checkpoint",
		"--root", root,
		"--session", "abc",
		"--reason", "manual checkpoint",
		"--tail-file", tailPath,
		"--worktree", "/tmp/work",
		"--branch", "agent/codex-005-memory-checkpoint",
		"--task", "005",
		"--agent", "codex",
		"--created", "2026-05-17T12:00:00Z",
		"--at", "2026-05-17T12:05:00Z",
		"--task-brief", ".swe-kitty/tasks/005-memory-checkpoint.md",
		"--task-summary", "Implement memory CLI",
	})
	if code != 0 {
		t.Fatalf("runMemory checkpoint code=%d stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "manual checkpoint") {
		t.Fatalf("checkpoint output missing reason: %s", stdout.String())
	}

	stdout.Reset()
	stderr.Reset()
	code = runMemory([]string{"show", "--root", root, "--session", "abc"})
	if code != 0 {
		t.Fatalf("runMemory show code=%d stderr=%s", code, stderr.String())
	}
	if !strings.Contains(stdout.String(), "Implement memory CLI") {
		t.Fatalf("show output missing task summary: %s", stdout.String())
	}
}
