package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// ---------------------------------------------------------------------------
// Claude parser tests
// ---------------------------------------------------------------------------

func TestParseClaudeJSONL_Basic(t *testing.T) {
	dir := t.TempDir()
	sessionID := "aaaabbbb-cccc-dddd-eeee-111122223333"

	lines := []map[string]any{
		{"type": "agent-setting", "agentSetting": "claude", "sessionId": sessionID},
		{
			"type":      "user",
			"sessionId": sessionID,
			"timestamp": "2024-12-14T10:00:00.000Z",
			"message": map[string]any{
				"role":    "user",
				"content": "Refactor the auth module",
			},
			"cwd":       "/home/user/myproject",
			"gitBranch": "fix/auth",
		},
		{
			"type":      "assistant",
			"sessionId": sessionID,
			"timestamp": "2024-12-14T10:05:00.000Z",
			"message": map[string]any{
				"role": "assistant",
				"content": []map[string]any{
					{"type": "text", "text": "I'll help refactor the auth module."},
				},
			},
		},
		{"type": "ai-title", "aiTitle": "Auth Refactor", "sessionId": sessionID},
	}

	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, sessionID+".jsonl")
	if err := os.WriteFile(fpath, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	s, ok := ParseClaudeJSONL(fpath, nil, nil)
	if !ok {
		t.Fatal("ParseClaudeJSONL returned false")
	}
	if s.Agent != "claude" {
		t.Errorf("agent=%q want 'claude'", s.Agent)
	}
	if s.ExternalID != sessionID {
		t.Errorf("external_id=%q want %q", s.ExternalID, sessionID)
	}
	if s.Title != "Auth Refactor" {
		t.Errorf("title=%q want 'Auth Refactor'", s.Title)
	}
	if s.CWD != "/home/user/myproject" {
		t.Errorf("cwd=%q want '/home/user/myproject'", s.CWD)
	}
	if s.GitBranch != "fix/auth" {
		t.Errorf("git_branch=%q want 'fix/auth'", s.GitBranch)
	}
	if s.TurnCount != 1 {
		t.Errorf("turn_count=%d want 1 (1 user+assistant pair)", s.TurnCount)
	}
	if s.IsRunning {
		t.Error("is_running should be false")
	}
	// Verify LastActivityAt is non-zero and reasonable.
	if s.LastActivityAt == 0 {
		t.Error("last_activity_at should be non-zero")
	}
	expectedTs := time.Date(2024, 12, 14, 10, 5, 0, 0, time.UTC).UnixMilli()
	if s.LastActivityAt != expectedTs {
		t.Errorf("last_activity_at=%d want %d", s.LastActivityAt, expectedTs)
	}
}

func TestParseClaudeJSONL_FallbackTitle(t *testing.T) {
	dir := t.TempDir()
	sessionID := "bbbbcccc-dddd-eeee-ffff-222233334444"

	lines := []map[string]any{
		{"type": "agent-setting", "sessionId": sessionID},
		{
			"type":      "user",
			"sessionId": sessionID,
			"timestamp": "2024-12-14T10:00:00.000Z",
			"message": map[string]any{
				"role":    "user",
				"content": "Write unit tests for the payment service",
			},
		},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	s, ok := ParseClaudeJSONL(fpath, nil, nil)
	if !ok {
		t.Fatal("ParseClaudeJSONL returned false")
	}
	// No ai-title: should fall back to first user message.
	if s.Title != "Write unit tests for the payment service" {
		t.Errorf("title=%q want first user prompt", s.Title)
	}
}

func TestParseClaudeJSONL_Dedup(t *testing.T) {
	dir := t.TempDir()
	sessionID := "ccccdddd-eeee-ffff-0000-333344445555"
	ownIDs := map[string]struct{}{sessionID: {}}

	lines := []map[string]any{
		{"type": "agent-setting", "sessionId": sessionID},
		{"type": "user", "sessionId": sessionID, "timestamp": "2024-12-14T10:00:00.000Z",
			"message": map[string]any{"role": "user", "content": "hello"}},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	_, ok := ParseClaudeJSONL(fpath, ownIDs, nil)
	if ok {
		t.Error("ParseClaudeJSONL should return false for a Conduit-owned session")
	}
}

func TestParseClaudeJSONL_TitleTruncation(t *testing.T) {
	dir := t.TempDir()
	sessionID := "ddddeeee-ffff-0000-1111-444455556666"

	// 150-rune title
	longMsg := "Implement a comprehensive refactoring of the entire authentication and authorization subsystem to support multi-tenant environments with per-tenant policies and roles"
	lines := []map[string]any{
		{"type": "agent-setting", "sessionId": sessionID},
		{"type": "user", "sessionId": sessionID, "timestamp": "2024-12-14T10:00:00.000Z",
			"message": map[string]any{"role": "user", "content": longMsg}},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	s, ok := ParseClaudeJSONL(fpath, nil, nil)
	if !ok {
		t.Fatal("ParseClaudeJSONL returned false")
	}
	runes := []rune(s.Title)
	if len(runes) > 120 {
		t.Errorf("title length=%d exceeds 120 runes", len(runes))
	}
}

func TestParseClaudeJSONL_CorruptLines(t *testing.T) {
	dir := t.TempDir()
	sessionID := "eeeeffff-0000-1111-2222-555566667777"
	content := `{"type":"agent-setting","sessionId":"` + sessionID + `"}
not-valid-json
{"type":"user","sessionId":"` + sessionID + `","timestamp":"2024-12-14T10:00:00.000Z","message":{"role":"user","content":"hello"}}
another invalid line
`
	fpath := filepath.Join(dir, sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	// Should not panic; should return a valid session despite corrupt lines.
	s, ok := ParseClaudeJSONL(fpath, nil, nil)
	if !ok {
		t.Fatal("ParseClaudeJSONL returned false despite having valid records")
	}
	if s.ExternalID != sessionID {
		t.Errorf("external_id=%q want %q", s.ExternalID, sessionID)
	}
}

// ---------------------------------------------------------------------------
// Codex parser tests
// ---------------------------------------------------------------------------

func TestParseCodexRollout_Basic(t *testing.T) {
	dir := t.TempDir()
	sessionID := "019ec925-677b-7dd1-ad7e-a92a06a39f8a"

	lines := []map[string]any{
		{
			"timestamp": "2026-06-15T02:38:52.417Z",
			"type":      "session_meta",
			"payload": map[string]any{
				"id":         sessionID,
				"cwd":        "/tmp/myproject",
				"originator": "cli",
				"source":     "cli",
			},
		},
		{
			"timestamp": "2026-06-15T02:38:53.000Z",
			"type":      "response_item",
			"payload": map[string]any{
				"type": "message",
				"role": "user",
				"content": []map[string]any{
					{"type": "input_text", "text": "Explain the architecture"},
				},
			},
		},
		{
			"timestamp": "2026-06-15T02:38:55.000Z",
			"type":      "response_item",
			"payload": map[string]any{
				"type": "message",
				"role": "assistant",
				"content": []map[string]any{
					{"type": "output_text", "text": "The architecture consists of..."},
				},
			},
		},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, "rollout-2026-06-15T02-38-52-"+sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	s, ok := ParseCodexRollout(fpath, nil)
	if !ok {
		t.Fatal("ParseCodexRollout returned false")
	}
	if s.Agent != "codex" {
		t.Errorf("agent=%q want 'codex'", s.Agent)
	}
	if s.ExternalID != sessionID {
		t.Errorf("external_id=%q want %q", s.ExternalID, sessionID)
	}
	if s.CWD != "/tmp/myproject" {
		t.Errorf("cwd=%q want '/tmp/myproject'", s.CWD)
	}
	if s.Title != "Explain the architecture" {
		t.Errorf("title=%q want 'Explain the architecture'", s.Title)
	}
	if s.TurnCount != 1 {
		t.Errorf("turn_count=%d want 1 (assistant messages)", s.TurnCount)
	}
	if s.IsRunning {
		t.Error("is_running should be false for codex (best-effort)")
	}
}

func TestParseCodexRollout_SkipsSystemContent(t *testing.T) {
	dir := t.TempDir()
	sessionID := "019aaaaa-0000-0000-0000-000000000001"
	lines := []map[string]any{
		{"timestamp": "2026-06-15T02:38:52.000Z", "type": "session_meta",
			"payload": map[string]any{"id": sessionID, "cwd": "/tmp"}},
		{
			"timestamp": "2026-06-15T02:38:52.100Z",
			"type":      "response_item",
			"payload": map[string]any{
				"type": "message", "role": "user",
				"content": []map[string]any{
					// System context XML — should be skipped as title
					{"type": "input_text", "text": "<environment_context>...</environment_context>"},
					// Real user text — should be used as title
					{"type": "input_text", "text": "Write a hello world program"},
				},
			},
		},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, "rollout-"+sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	s, ok := ParseCodexRollout(fpath, nil)
	if !ok {
		t.Fatal("ParseCodexRollout returned false")
	}
	if s.Title != "Write a hello world program" {
		t.Errorf("title=%q; should use real user text, not XML system context", s.Title)
	}
}

func TestParseCodexRollout_Dedup(t *testing.T) {
	dir := t.TempDir()
	sessionID := "019bbbbb-0000-0000-0000-000000000002"
	ownIDs := map[string]struct{}{sessionID: {}}

	lines := []map[string]any{
		{"timestamp": "2026-06-15T02:00:00.000Z", "type": "session_meta",
			"payload": map[string]any{"id": sessionID, "cwd": "/tmp"}},
	}
	var content string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		content += string(b) + "\n"
	}
	fpath := filepath.Join(dir, "rollout-"+sessionID+".jsonl")
	_ = os.WriteFile(fpath, []byte(content), 0o644)

	_, ok := ParseCodexRollout(fpath, ownIDs)
	if ok {
		t.Error("ParseCodexRollout should return false for Conduit-owned session")
	}
}

// ---------------------------------------------------------------------------
// claudeSlugToCWD tests
// ---------------------------------------------------------------------------

func TestClaudeSlugToCWD(t *testing.T) {
	tests := []struct {
		slug string
		want string
	}{
		{"-root", "/root"},
		{"-root-developer-projects-conduit", "/root/developer/projects/conduit"},
		{"nodash", "nodash"}, // no leading dash → return as-is
	}
	for _, tc := range tests {
		got := claudeSlugToCWD(tc.slug)
		if got != tc.want {
			t.Errorf("claudeSlugToCWD(%q)=%q want %q", tc.slug, got, tc.want)
		}
	}
}

// ---------------------------------------------------------------------------
// truncate tests
// ---------------------------------------------------------------------------

func TestTruncate(t *testing.T) {
	if got := truncate("hello", 120); got != "hello" {
		t.Errorf("truncate short string=%q", got)
	}
	long := make([]rune, 130)
	for i := range long {
		long[i] = 'a'
	}
	got := truncate(string(long), 120)
	if len([]rune(got)) != 120 {
		t.Errorf("truncate long string: got %d runes want 120", len([]rune(got)))
	}
	// Last rune should be ellipsis.
	runes := []rune(got)
	if runes[len(runes)-1] != '…' {
		t.Errorf("truncate: last rune should be '…'")
	}
}
