package session

import (
	"os"
	"path/filepath"
	"testing"
)

// TestStageExternalTranscript_Claude verifies that stageExternalTranscriptInto
// copies the claude conversation file from the real home into agent-home
// at the expected path, preserving the slug directory name.
func TestStageExternalTranscript_Claude(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()

	// Create a fake claude transcript in the real home.
	sessionID := "abc123-def456-session"
	slug := "-root-developer-projects-myproject"
	srcDir := filepath.Join(realHome, ".claude", "projects", slug)
	if err := os.MkdirAll(srcDir, 0o700); err != nil {
		t.Fatalf("mkdir src: %v", err)
	}
	content := []byte(`{"type":"user","sessionId":"abc123-def456-session","message":{"role":"user","content":"hello"}}`)
	srcFile := filepath.Join(srcDir, sessionID+".jsonl")
	if err := os.WriteFile(srcFile, content, 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	stageExternalTranscriptInto(nil, agentHome, realHome, "claude", sessionID)

	dstFile := filepath.Join(agentHome, ".claude", "projects", slug, sessionID+".jsonl")
	got, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("staged file not found at %s: %v", dstFile, err)
	}
	if string(got) != string(content) {
		t.Fatalf("staged content mismatch:\n got %q\nwant %q", string(got), string(content))
	}
	st, err := os.Stat(dstFile)
	if err != nil {
		t.Fatalf("stat staged file: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Fatalf("staged file mode = %#o, want 0600", mode)
	}
}

// TestStageExternalTranscript_ClaudeIdempotent verifies that calling
// stageExternalTranscriptInto twice with the same session ID is harmless — the
// file is not overwritten when it already exists in agent-home.
func TestStageExternalTranscript_ClaudeIdempotent(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()

	sessionID := "idempotent-session-id"
	slug := "-root-project"
	srcDir := filepath.Join(realHome, ".claude", "projects", slug)
	if err := os.MkdirAll(srcDir, 0o700); err != nil {
		t.Fatalf("mkdir src: %v", err)
	}
	if err := os.WriteFile(filepath.Join(srcDir, sessionID+".jsonl"), []byte(`{"v":"1"}`), 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	// Pre-place a different version in agent-home.
	dstDir := filepath.Join(agentHome, ".claude", "projects", slug)
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		t.Fatalf("mkdir dst: %v", err)
	}
	preExisting := []byte(`{"v":"already-there"}`)
	dstFile := filepath.Join(dstDir, sessionID+".jsonl")
	if err := os.WriteFile(dstFile, preExisting, 0o600); err != nil {
		t.Fatalf("write pre-existing: %v", err)
	}

	stageExternalTranscriptInto(nil, agentHome, realHome, "claude", sessionID)

	got, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("read staged: %v", err)
	}
	if string(got) != string(preExisting) {
		t.Fatalf("idempotent: file was overwritten: got %q want %q", string(got), string(preExisting))
	}
}

// TestStageExternalTranscript_ClaudeNotFound verifies that a missing real-home
// transcript is handled gracefully (no panic, no error — just a log line).
func TestStageExternalTranscript_ClaudeNotFound(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()
	// No transcript in realHome. Should not panic.
	stageExternalTranscriptInto(nil, agentHome, realHome, "claude", "nonexistent-session-id")
	// No file should appear in agent-home.
	if _, err := os.Stat(filepath.Join(agentHome, ".claude")); !os.IsNotExist(err) {
		t.Fatalf("unexpected .claude dir in agent-home when transcript missing")
	}
}

// TestStageExternalTranscript_Codex verifies that the codex rollout file is
// copied from the real home's YYYY/MM/DD hierarchy into the agent-home
// preserving the same relative path.
func TestStageExternalTranscript_Codex(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()

	threadID := "thread-7890-abcd"
	relPath := filepath.Join("2025", "06", "15")
	filename := "rollout-xyz-" + threadID + "-001.jsonl"

	srcDir := filepath.Join(realHome, ".codex", "sessions", relPath)
	if err := os.MkdirAll(srcDir, 0o700); err != nil {
		t.Fatalf("mkdir src: %v", err)
	}
	content := []byte(`{"timestamp":"2025-06-15T10:00:00Z","type":"session_meta","payload":{"id":"thread-7890-abcd","cwd":"/workspace"}}`)
	srcFile := filepath.Join(srcDir, filename)
	if err := os.WriteFile(srcFile, content, 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	stageExternalTranscriptInto(nil, agentHome, realHome, "codex", threadID)

	dstFile := filepath.Join(agentHome, ".codex", "sessions", relPath, filename)
	got, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("staged codex file not found at %s: %v", dstFile, err)
	}
	if string(got) != string(content) {
		t.Fatalf("staged content mismatch:\n got %q\nwant %q", string(got), string(content))
	}
	st, err := os.Stat(dstFile)
	if err != nil {
		t.Fatalf("stat staged file: %v", err)
	}
	if mode := st.Mode().Perm(); mode != 0o600 {
		t.Fatalf("staged file mode = %#o, want 0600", mode)
	}
}

// TestStageExternalTranscript_CodexIdempotent verifies the codex staging is
// idempotent: a pre-existing destination is never overwritten.
func TestStageExternalTranscript_CodexIdempotent(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()

	threadID := "thread-idem-9999"
	relPath := filepath.Join("2025", "06", "16")
	filename := "rollout-" + threadID + ".jsonl"

	srcDir := filepath.Join(realHome, ".codex", "sessions", relPath)
	if err := os.MkdirAll(srcDir, 0o700); err != nil {
		t.Fatalf("mkdir src: %v", err)
	}
	if err := os.WriteFile(filepath.Join(srcDir, filename), []byte(`{"src":"real"}`), 0o600); err != nil {
		t.Fatalf("write src: %v", err)
	}

	// Pre-place a different version in agent-home.
	dstDir := filepath.Join(agentHome, ".codex", "sessions", relPath)
	if err := os.MkdirAll(dstDir, 0o700); err != nil {
		t.Fatalf("mkdir dst: %v", err)
	}
	preExisting := []byte(`{"src":"already-staged"}`)
	dstFile := filepath.Join(dstDir, filename)
	if err := os.WriteFile(dstFile, preExisting, 0o600); err != nil {
		t.Fatalf("write pre-existing: %v", err)
	}

	stageExternalTranscriptInto(nil, agentHome, realHome, "codex", threadID)

	got, err := os.ReadFile(dstFile)
	if err != nil {
		t.Fatalf("read staged: %v", err)
	}
	if string(got) != string(preExisting) {
		t.Fatalf("idempotent: file was overwritten: got %q want %q", string(got), string(preExisting))
	}
}

// TestStageExternalTranscript_CodexNotFound verifies graceful handling when
// the codex rollout file doesn't exist in the real home.
func TestStageExternalTranscript_CodexNotFound(t *testing.T) {
	t.Parallel()
	realHome := t.TempDir()
	agentHome := t.TempDir()
	stageExternalTranscriptInto(nil, agentHome, realHome, "codex", "nonexistent-thread-id")
	if _, err := os.Stat(filepath.Join(agentHome, ".codex")); !os.IsNotExist(err) {
		t.Fatalf("unexpected .codex dir in agent-home when transcript missing")
	}
}

// TestStageExternalTranscript_EmptyParams verifies no panic on empty inputs.
func TestStageExternalTranscript_EmptyParams(t *testing.T) {
	t.Parallel()
	stageExternalTranscriptInto(nil, "", "", "claude", "some-id")
	stageExternalTranscriptInto(nil, "/tmp/fake", "/tmp/real", "claude", "")
	stageExternalTranscriptInto(nil, "/tmp/fake", "", "codex", "some-id")
}
