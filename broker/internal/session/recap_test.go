package session

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// makeEntries builds a slice of alternating user/assistant ConvEntry values for
// testing. Each entry's content is "msg-N" and its Ts is a fixed RFC3339Nano
// string so tests can assert exact values.
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

// withStubRecap swaps the package-level generateRecap seam for the duration of
// a test and restores it afterward.
func withStubRecap(t *testing.T, fn func(ctx context.Context, agent, externalID, agentHome, binary string) (string, error)) {
	t.Helper()
	prev := generateRecap
	generateRecap = fn
	t.Cleanup(func() { generateRecap = prev })
}

// TestSeedRecapEntry_WritesSingleSystemMessage verifies seedRecapEntry writes
// exactly one "system" entry whose content carries the framing + recap text.
func TestSeedRecapEntry_WritesSingleSystemMessage(t *testing.T) {
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedRecapEntry(convLogPath, "claude", "We were refactoring the auth module; left off mid-test.")

	got := readAllConvEntries(t, convLogPath)
	if len(got) != 1 {
		t.Fatalf("got %d entries, want exactly 1", len(got))
	}
	e := got[0]
	if e.Role != "system" {
		t.Errorf("role = %q, want 'system'", e.Role)
	}
	if !strings.Contains(e.Content, "Resumed from your terminal") {
		t.Errorf("content missing resume framing: %q", e.Content)
	}
	if !strings.Contains(e.Content, "refactoring the auth module") {
		t.Errorf("content missing recap text: %q", e.Content)
	}
	if !strings.Contains(e.Content, "claude's memory") {
		t.Errorf("content missing agent-memory note: %q", e.Content)
	}
}

// TestSeedRecapEntry_Idempotent verifies a second call is a no-op when the log
// already has content.
func TestSeedRecapEntry_Idempotent(t *testing.T) {
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedRecapEntry(convLogPath, "claude", "first recap")
	first := readAllConvEntries(t, convLogPath)
	if len(first) != 1 {
		t.Fatalf("after first seed: got %d entries, want 1", len(first))
	}

	seedRecapEntry(convLogPath, "claude", "second recap should be ignored")
	second := readAllConvEntries(t, convLogPath)
	if len(second) != 1 {
		t.Fatalf("after second seed (idempotent): got %d entries, want 1", len(second))
	}
	if !strings.Contains(second[0].Content, "first recap") {
		t.Errorf("idempotent seed overwrote content: %q", second[0].Content)
	}
}

// TestSeedRecapEntry_EmptyParams verifies no panic / no write on empty inputs.
func TestSeedRecapEntry_EmptyParams(t *testing.T) {
	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedRecapEntry("", "claude", "recap")            // empty path
	seedRecapEntry(convLogPath, "claude", "")        // empty recap
	seedRecapEntry(convLogPath, "claude", "   \n\t") // whitespace-only recap
	if _, err := os.Stat(convLogPath); !os.IsNotExist(err) {
		t.Fatalf("expected no conversation.jsonl for empty params, got err=%v", err)
	}
}

// TestSeedResumeRecap_UsesGeneratedRecap verifies the happy path: a stubbed
// generateRecap returns text, and that text is seeded into the log.
func TestSeedResumeRecap_UsesGeneratedRecap(t *testing.T) {
	withStubRecap(t, func(_ context.Context, agent, externalID, agentHome, binary string) (string, error) {
		return "Stubbed recap: building the recap feature.", nil
	})

	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedResumeRecap(convLogPath, "claude", "ext-123", "/tmp/agenthome", "/usr/bin/claude")

	got := readAllConvEntries(t, convLogPath)
	if len(got) != 1 {
		t.Fatalf("got %d entries, want 1", len(got))
	}
	if !strings.Contains(got[0].Content, "Stubbed recap: building the recap feature.") {
		t.Errorf("seeded content missing stubbed recap: %q", got[0].Content)
	}
	if got[0].Role != "system" {
		t.Errorf("role = %q, want 'system'", got[0].Role)
	}
}

// TestSeedResumeRecap_FallsBackOnError verifies that when generateRecap errors,
// seedResumeRecap falls back to the deterministic note (which it builds from
// the on-disk transcript — here the transcript read will itself fail for the
// bogus id, so the bare fallback line is used). Either way the log gets ONE
// system entry and the chat is never left empty.
func TestSeedResumeRecap_FallsBackOnError(t *testing.T) {
	withStubRecap(t, func(_ context.Context, agent, externalID, agentHome, binary string) (string, error) {
		return "", fmt.Errorf("simulated one-shot failure")
	})

	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")

	seedResumeRecap(convLogPath, "claude", "no-such-external-id", "/tmp/agenthome", "/usr/bin/claude")

	got := readAllConvEntries(t, convLogPath)
	if len(got) != 1 {
		t.Fatalf("got %d entries, want exactly 1 (deterministic fallback)", len(got))
	}
	if got[0].Role != "system" {
		t.Errorf("role = %q, want 'system'", got[0].Role)
	}
	if !strings.Contains(got[0].Content, "Resumed") {
		t.Errorf("fallback content missing resume framing: %q", got[0].Content)
	}
}

// TestSeedResumeRecap_Idempotent verifies the top-level seed is idempotent and
// does NOT invoke the (expensive) generateRecap seam when the log already has
// content.
func TestSeedResumeRecap_Idempotent(t *testing.T) {
	called := false
	withStubRecap(t, func(_ context.Context, agent, externalID, agentHome, binary string) (string, error) {
		called = true
		return "should not be used", nil
	})

	dir := t.TempDir()
	convLogPath := filepath.Join(dir, "conversation.jsonl")
	// Pre-seed the log with existing content.
	if err := os.WriteFile(convLogPath, []byte(`{"role":"user","content":"existing","ts":"t"}`+"\n"), 0o600); err != nil {
		t.Fatalf("pre-write: %v", err)
	}

	seedResumeRecap(convLogPath, "claude", "ext-123", "/tmp/agenthome", "/usr/bin/claude")

	if called {
		t.Errorf("generateRecap was invoked despite non-empty conversation.jsonl (not idempotent)")
	}
	got := readAllConvEntries(t, convLogPath)
	if len(got) != 1 || got[0].Content != "existing" {
		t.Fatalf("idempotent guard altered the log: %+v", got)
	}
}

// TestSeedResumeRecap_EmptyParams verifies empty agent/externalID/path short
// circuit without invoking the seam or writing.
func TestSeedResumeRecap_EmptyParams(t *testing.T) {
	called := false
	withStubRecap(t, func(_ context.Context, agent, externalID, agentHome, binary string) (string, error) {
		called = true
		return "x", nil
	})
	seedResumeRecap("", "claude", "ext", "/home", "/bin/claude")
	seedResumeRecap("/tmp/x.jsonl", "", "ext", "/home", "/bin/claude")
	seedResumeRecap("/tmp/x.jsonl", "claude", "", "/home", "/bin/claude")
	if called {
		t.Errorf("generateRecap invoked on empty params")
	}
}

// TestFormatRecapMessage verifies the framing wraps the recap as one message.
func TestFormatRecapMessage(t *testing.T) {
	msg := formatRecapMessage("codex", "  we were wiring the broker  ")
	if !strings.Contains(msg, "Resumed from your terminal") {
		t.Errorf("missing framing: %q", msg)
	}
	if !strings.Contains(msg, "we were wiring the broker") {
		t.Errorf("missing recap body: %q", msg)
	}
	if !strings.Contains(msg, "codex's memory") {
		t.Errorf("missing agent memory note: %q", msg)
	}
	// Single message — not a multi-entry dump: exactly the framing + body.
	if strings.Count(msg, "Resumed from your terminal") != 1 {
		t.Errorf("framing duplicated: %q", msg)
	}
}

// TestFirstUserPrompt verifies the deterministic-recap helper picks the first
// non-empty user message, collapses whitespace, and caps length.
func TestFirstUserPrompt(t *testing.T) {
	entries := []ConvEntry{
		{Role: "assistant", Content: "hi there"},
		{Role: "user", Content: "  \n\t "}, // empty after trim → skipped
		{Role: "user", Content: "fix the\n  login    bug"},
	}
	got := firstUserPrompt(entries)
	if got != "fix the login bug" {
		t.Errorf("firstUserPrompt = %q, want 'fix the login bug'", got)
	}

	long := strings.Repeat("x", 500)
	gotLong := firstUserPrompt([]ConvEntry{{Role: "user", Content: long}})
	if len([]rune(gotLong)) > 200 {
		t.Errorf("firstUserPrompt did not cap length: len=%d", len([]rune(gotLong)))
	}
	if !strings.HasSuffix(gotLong, "…") {
		t.Errorf("capped prompt missing ellipsis: %q", gotLong)
	}

	if firstUserPrompt(nil) != "" {
		t.Errorf("firstUserPrompt(nil) should be empty")
	}
}

// TestTranscriptDigest verifies the codex digest tags roles, caps message and
// total length, and keeps the tail of a long transcript.
func TestTranscriptDigest(t *testing.T) {
	d := transcriptDigest(makeEntries(4))
	if !strings.Contains(d, "[user] msg-0") || !strings.Contains(d, "[assistant] msg-3") {
		t.Errorf("digest missing role-tagged entries: %q", d)
	}

	// A very long transcript: digest must stay bounded and keep recent turns.
	big := makeEntries(100)
	dbig := transcriptDigest(big)
	if !strings.Contains(dbig, "msg-99") {
		t.Errorf("digest dropped the most recent turn: tail missing")
	}
	if strings.Contains(dbig, "msg-0") {
		t.Errorf("digest kept the oldest turn despite the message cap")
	}
}

// writeClaudeTranscriptFile creates a minimal claude JSONL transcript at the
// expected path under homeDir and returns the session ID used.
//
// claudeTranscript reads from $HOME/.claude/projects/<slug>/<id>.jsonl, so
// this creates a single slug dir with the given session ID.
func writeClaudeTranscriptFile(t *testing.T, homeDir, sessionID string, entries []ConvEntry) {
	t.Helper()
	slugDir := filepath.Join(homeDir, ".claude", "projects", "test-slug")
	if err := os.MkdirAll(slugDir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	fpath := filepath.Join(slugDir, sessionID+".jsonl")
	f, err := os.Create(fpath)
	if err != nil {
		t.Fatalf("create: %v", err)
	}
	defer f.Close()
	enc := json.NewEncoder(f)
	for _, e := range entries {
		// Write in the claude JSONL format claudeTranscript / parseClaudeTranscript expects.
		role := e.Role
		if role == "assistant" {
			// assistant entries need the claude envelope format
			line := map[string]any{
				"type":      "assistant",
				"timestamp": e.Ts,
				"message": map[string]any{
					"role": "assistant",
					"content": []map[string]any{
						{"type": "text", "text": e.Content},
					},
				},
			}
			if err := enc.Encode(line); err != nil {
				t.Fatalf("encode assistant: %v", err)
			}
		} else {
			line := map[string]any{
				"type":      "user",
				"timestamp": e.Ts,
				"message": map[string]any{
					"role":    "user",
					"content": e.Content,
				},
			}
			if err := enc.Encode(line); err != nil {
				t.Fatalf("encode user: %v", err)
			}
		}
	}
}

// TestClaudeRecap_NoResumeFlag verifies that claudeRecap does NOT pass
// --resume or --fork-session to the claude binary. It creates a fake claude
// binary that dumps its argv to a file and outputs a canned recap.
func TestClaudeRecap_NoResumeFlag(t *testing.T) {
	dir := t.TempDir()

	// Redirect $HOME so ExternalTranscript("claude", …) reads from our temp dir.
	t.Setenv("HOME", dir)

	sessionID := "test-session-" + fmt.Sprintf("%d", time.Now().UnixNano())
	entries := makeEntries(6)
	writeClaudeTranscriptFile(t, dir, sessionID, entries)

	// Fake claude binary: saves argv to a file, prints canned recap.
	argvFile := filepath.Join(dir, "argv.txt")
	fakeClaude := filepath.Join(dir, "claude")
	script := "#!/usr/bin/env bash\n" +
		`printf '%s\n' "$@" > ` + argvFile + "\n" +
		`echo "Working on the recap feature."` + "\n"
	if err := os.WriteFile(fakeClaude, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake claude: %v", err)
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	got, err := claudeRecap(ctx, fakeClaude, dir, sessionID)
	if err != nil {
		t.Fatalf("claudeRecap: %v", err)
	}
	if got != "Working on the recap feature." {
		t.Errorf("recap = %q, want canned text", got)
	}

	// Read the argv the fake binary received and assert no --resume.
	argvData, readErr := os.ReadFile(argvFile)
	if readErr != nil {
		t.Fatalf("read argv file: %v", readErr)
	}
	argvStr := string(argvData)
	if strings.Contains(argvStr, "--resume") {
		t.Errorf("claudeRecap passed --resume to binary (should use digest, not --resume): argv=%q", argvStr)
	}
	if strings.Contains(argvStr, "--fork-session") {
		t.Errorf("claudeRecap passed --fork-session to binary (should use digest): argv=%q", argvStr)
	}
	if !strings.Contains(argvStr, "--print") {
		t.Errorf("claudeRecap missing --print flag: argv=%q", argvStr)
	}
}

// TestClaudeRecap_EmptyTranscriptFallsBack verifies claudeRecap returns an
// error (not a binary-exec error) when the transcript doesn't exist on disk,
// proving it reads the transcript before attempting the exec.
func TestClaudeRecap_EmptyTranscriptFallsBack(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("HOME", dir)
	// No transcript file created — ExternalTranscript should fail.

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Use a non-existent binary — if claudeRecap tries to exec before reading
	// the transcript, we'd get "no such file" instead of the transcript error.
	_, err := claudeRecap(ctx, "/nonexistent/claude", dir, "no-such-id")
	if err == nil {
		t.Fatal("expected error for missing transcript, got nil")
	}
	// The error must mention ExternalTranscript, proving the transcript was read
	// BEFORE attempting any exec. A bare exec error would not contain this string.
	if !strings.Contains(err.Error(), "ExternalTranscript") && !strings.Contains(err.Error(), "empty transcript") {
		t.Errorf("expected transcript-read error (ExternalTranscript/empty transcript), got: %v", err)
	}
}
