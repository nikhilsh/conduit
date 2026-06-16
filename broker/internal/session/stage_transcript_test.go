package session

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// TestStageExternalTranscript_Claude verifies that stageExternalTranscript
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

	stageExternalTranscript(agentHome, realHome, "claude", sessionID)

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
// stageExternalTranscript twice with the same session ID is harmless — the
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

	stageExternalTranscript(agentHome, realHome, "claude", sessionID)

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
	stageExternalTranscript(agentHome, realHome, "claude", "nonexistent-session-id")
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

	stageExternalTranscript(agentHome, realHome, "codex", threadID)

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

	stageExternalTranscript(agentHome, realHome, "codex", threadID)

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
	stageExternalTranscript(agentHome, realHome, "codex", "nonexistent-thread-id")
	if _, err := os.Stat(filepath.Join(agentHome, ".codex")); !os.IsNotExist(err) {
		t.Fatalf("unexpected .codex dir in agent-home when transcript missing")
	}
}

// TestStageExternalTranscript_EmptyParams verifies no panic on empty inputs.
func TestStageExternalTranscript_EmptyParams(t *testing.T) {
	t.Parallel()
	stageExternalTranscript("", "", "claude", "some-id")
	stageExternalTranscript("/tmp/fake", "/tmp/real", "claude", "")
	stageExternalTranscript("/tmp/fake", "", "codex", "some-id")
}

// ---------------------------------------------------------------------------
// seedResumeExcerptFromEntries tests
// ---------------------------------------------------------------------------

// makeEntries builds a slice of alternating user/assistant ConvEntry values
// for testing. Each entry's content is "msg-N" and its Ts is a fixed
// RFC3339Nano string so tests can assert exact values.
func makeEntries(n int) []ConvEntry {
	entries := make([]ConvEntry, n)
	base := time.Date(2025, 6, 16, 0, 0, 0, 0, time.UTC)
	for i := range entries {
		role := "user"
		if i%2 == 1 {
			role = "assistant"
		}
		entries[i] = ConvEntry{
			Role:    role,
			Content: fmt.Sprintf("msg-%d", i),
			Ts:      base.Add(time.Duration(i) * time.Minute).UTC().Format(time.RFC3339Nano),
		}
	}
	return entries
}

// readAllConvEntries reads and parses every line of a conversation.jsonl file.
func readAllConvEntries(t *testing.T, path string) []ConvEntry {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("readAllConvEntries: %v", err)
	}
	var out []ConvEntry
	for _, line := range strings.Split(strings.TrimSpace(string(data)), "\n") {
		if line == "" {
			continue
		}
		var e ConvEntry
		if err := json.Unmarshal([]byte(line), &e); err != nil {
			t.Fatalf("readAllConvEntries: unmarshal %q: %v", line, err)
		}
		out = append(out, e)
	}
	return out
}

// TestSeedResumeExcerpt_TakesLastN verifies that a 25-entry transcript
// seeds the last resumeExcerptN (10) entries plus the trailing system note.
func TestSeedResumeExcerpt_TakesLastN(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	all := makeEntries(25)
	seedResumeExcerptFromEntries(convLogPath, all, "claude")

	got := readAllConvEntries(t, convLogPath)

	// Expect resumeExcerptN content entries + 1 system note.
	wantTotal := resumeExcerptN + 1
	if len(got) != wantTotal {
		t.Fatalf("got %d entries, want %d (excerpt=%d + system note)", len(got), wantTotal, resumeExcerptN)
	}

	// The first resumeExcerptN entries must be the LAST 10 of the input (indices 15..24).
	for i := 0; i < resumeExcerptN; i++ {
		want := all[25-resumeExcerptN+i]
		if got[i].Role != want.Role || got[i].Content != want.Content {
			t.Errorf("entry[%d]: got {%s %q} want {%s %q}", i, got[i].Role, got[i].Content, want.Role, want.Content)
		}
	}

	// The last entry must be the system note.
	last := got[len(got)-1]
	if last.Role != "system" {
		t.Errorf("last entry role=%q want 'system'", last.Role)
	}
	if !strings.Contains(last.Content, "25 earlier turns") {
		t.Errorf("system note missing total-turns count: %q", last.Content)
	}
	if !strings.Contains(last.Content, "claude") {
		t.Errorf("system note missing agent name: %q", last.Content)
	}
	if !strings.Contains(last.Content, "Resumed from") {
		t.Errorf("system note missing 'Resumed from': %q", last.Content)
	}
}

// TestSeedResumeExcerpt_ShortTranscript verifies that a transcript shorter than
// resumeExcerptN seeds ALL entries (not just the last N).
func TestSeedResumeExcerpt_ShortTranscript(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	all := makeEntries(4) // fewer than resumeExcerptN
	seedResumeExcerptFromEntries(convLogPath, all, "codex")

	got := readAllConvEntries(t, convLogPath)
	// 4 content entries + 1 system note
	if len(got) != 5 {
		t.Fatalf("got %d entries, want 5", len(got))
	}
	for i := 0; i < 4; i++ {
		if got[i].Content != all[i].Content {
			t.Errorf("entry[%d] content=%q want %q", i, got[i].Content, all[i].Content)
		}
	}
	if got[4].Role != "system" {
		t.Errorf("last entry role=%q want 'system'", got[4].Role)
	}
	if !strings.Contains(got[4].Content, "4 earlier turns") {
		t.Errorf("system note totalTurns: %q", got[4].Content)
	}
}

// TestSeedResumeExcerpt_Idempotent verifies that a second call to
// seedResumeExcerptFromEntries is a no-op when conversation.jsonl already
// contains data.
func TestSeedResumeExcerpt_Idempotent(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	all := makeEntries(25)

	// First call: seeds the log.
	seedResumeExcerptFromEntries(convLogPath, all, "claude")
	firstRead := readAllConvEntries(t, convLogPath)
	if len(firstRead) != resumeExcerptN+1 {
		t.Fatalf("after first seed: got %d entries, want %d", len(firstRead), resumeExcerptN+1)
	}

	// Second call with MORE entries: must be a no-op (idempotent).
	more := makeEntries(30)
	seedResumeExcerptFromEntries(convLogPath, more, "claude")
	secondRead := readAllConvEntries(t, convLogPath)
	if len(secondRead) != len(firstRead) {
		t.Fatalf("after second seed (idempotent): got %d entries, want %d (no change)", len(secondRead), len(firstRead))
	}
}

// TestSeedResumeExcerpt_EmptyTranscript verifies that an empty transcript
// slice is handled gracefully (no file written, no panic).
func TestSeedResumeExcerpt_EmptyTranscript(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedResumeExcerptFromEntries(convLogPath, nil, "claude")
	if _, err := os.Stat(convLogPath); !os.IsNotExist(err) {
		t.Fatalf("expected no conversation.jsonl for empty transcript, got err=%v", err)
	}
}

// TestSeedResumeExcerpt_EmptyParams verifies no panic on empty path.
func TestSeedResumeExcerpt_EmptyParams(t *testing.T) {
	t.Parallel()
	entries := makeEntries(5)
	// None of these should panic.
	seedResumeExcerptFromEntries("", entries, "claude")
	seedResumeExcerptFromEntries("", nil, "claude")
}
