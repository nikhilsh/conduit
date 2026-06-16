package session

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
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

// ---------------------------------------------------------------------------
// ExternalTranscriptSince tests (Build B — since_ts watch param)
// ---------------------------------------------------------------------------

func TestExternalTranscriptSince_FullWhenNoFilter(t *testing.T) {
	// Build a minimal claude transcript with two turns at different timestamps.
	sessionID := "watch-0000-1111-2222-333344445555"
	lines := []map[string]any{
		{
			"type": "user", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:00:00.000Z",
			"message":   map[string]any{"role": "user", "content": "first message"},
			"cwd":       "/tmp/proj",
		},
		{
			"type": "assistant", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:01:00.000Z",
			"message": map[string]any{
				"role": "assistant",
				"content": []map[string]any{
					{"type": "text", "text": "first reply"},
				},
			},
		},
		{
			"type": "user", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:02:00.000Z",
			"message":   map[string]any{"role": "user", "content": "second message"},
		},
		{
			"type": "assistant", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:03:00.000Z",
			"message": map[string]any{
				"role": "assistant",
				"content": []map[string]any{
					{"type": "text", "text": "second reply"},
				},
			},
		},
	}
	var raw string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		raw += string(b) + "\n"
	}
	// Write to a slug dir so claudeTranscript can find it.
	home := t.TempDir()
	projDir := filepath.Join(home, ".claude", "projects", "-tmp-proj")
	_ = os.MkdirAll(projDir, 0o755)
	_ = os.WriteFile(filepath.Join(projDir, sessionID+".jsonl"), []byte(raw), 0o644)
	t.Setenv("HOME", home)

	// sinceMs == 0: full transcript.
	result, err := ExternalTranscriptSince("claude", sessionID, 0)
	if err != nil {
		t.Fatalf("ExternalTranscriptSince full: %v", err)
	}
	if len(result.Items) != 4 {
		t.Errorf("full transcript: got %d items want 4", len(result.Items))
	}
	// latest_ts must be the max timestamp (10:03).
	ts10_03 := time.Date(2024, 12, 14, 10, 3, 0, 0, time.UTC).UnixMilli()
	if result.LatestTs != ts10_03 {
		t.Errorf("LatestTs=%d want %d (10:03)", result.LatestTs, ts10_03)
	}
}

func TestExternalTranscriptSince_FiltersBySinceTs(t *testing.T) {
	sessionID := "watch-aaaa-bbbb-cccc-ddddeeee0000"
	lines := []map[string]any{
		{
			"type": "user", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:00:00.000Z",
			"message":   map[string]any{"role": "user", "content": "old message"},
			"cwd":       "/tmp/proj2",
		},
		{
			"type": "assistant", "sessionId": sessionID,
			"timestamp": "2024-12-14T10:01:00.000Z",
			"message": map[string]any{
				"role": "assistant",
				"content": []map[string]any{
					{"type": "text", "text": "old reply"},
				},
			},
		},
		{
			"type": "user", "sessionId": sessionID,
			"timestamp": "2024-12-14T11:00:00.000Z",
			"message":   map[string]any{"role": "user", "content": "new message"},
		},
		{
			"type": "assistant", "sessionId": sessionID,
			"timestamp": "2024-12-14T11:01:00.000Z",
			"message": map[string]any{
				"role": "assistant",
				"content": []map[string]any{
					{"type": "text", "text": "new reply"},
				},
			},
		},
	}
	var raw string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		raw += string(b) + "\n"
	}
	home := t.TempDir()
	projDir := filepath.Join(home, ".claude", "projects", "-tmp-proj2")
	_ = os.MkdirAll(projDir, 0o755)
	_ = os.WriteFile(filepath.Join(projDir, sessionID+".jsonl"), []byte(raw), 0o644)
	t.Setenv("HOME", home)

	// Set since_ts to 10:01 (the old assistant reply's ts).
	// Only items STRICTLY AFTER 10:01 should be returned (the 11:xx items).
	ts10_01 := time.Date(2024, 12, 14, 10, 1, 0, 0, time.UTC).UnixMilli()
	result, err := ExternalTranscriptSince("claude", sessionID, ts10_01)
	if err != nil {
		t.Fatalf("ExternalTranscriptSince since: %v", err)
	}
	if len(result.Items) != 2 {
		t.Errorf("filtered transcript: got %d items want 2 (only the 11:xx items)", len(result.Items))
	}
	for _, item := range result.Items {
		ts := parseTimestamp(item.Ts)
		if !ts.IsZero() && ts.UnixMilli() <= ts10_01 {
			t.Errorf("item at ts=%s should be > since_ts 10:01", item.Ts)
		}
	}
	// LatestTs should be the max ts in the file (11:01), not the filtered set.
	ts11_01 := time.Date(2024, 12, 14, 11, 1, 0, 0, time.UTC).UnixMilli()
	if result.LatestTs != ts11_01 {
		t.Errorf("LatestTs=%d want %d (11:01 — max in file)", result.LatestTs, ts11_01)
	}
}

func TestExternalTranscriptSince_NoNewItemsStillReturnsLatestTs(t *testing.T) {
	// since_ts is past the newest item: no items returned but LatestTs is the max.
	sessionID := "watch-1111-2222-3333-444455556666"
	ts := "2024-12-14T10:00:00.000Z"
	lines := []map[string]any{
		{
			"type": "user", "sessionId": sessionID, "timestamp": ts,
			"message": map[string]any{"role": "user", "content": "only message"},
			"cwd":     "/tmp/proj3",
		},
	}
	var raw string
	for _, rec := range lines {
		b, _ := json.Marshal(rec)
		raw += string(b) + "\n"
	}
	home := t.TempDir()
	projDir := filepath.Join(home, ".claude", "projects", "-tmp-proj3")
	_ = os.MkdirAll(projDir, 0o755)
	_ = os.WriteFile(filepath.Join(projDir, sessionID+".jsonl"), []byte(raw), 0o644)
	t.Setenv("HOME", home)

	futureMs := time.Date(2025, 1, 1, 0, 0, 0, 0, time.UTC).UnixMilli()
	result, _ := ExternalTranscriptSince("claude", sessionID, futureMs)
	if len(result.Items) != 0 {
		t.Errorf("expected no items past since_ts, got %d", len(result.Items))
	}
	expectedLatest := time.Date(2024, 12, 14, 10, 0, 0, 0, time.UTC).UnixMilli()
	if result.LatestTs != expectedLatest {
		t.Errorf("LatestTs=%d want %d even when no new items", result.LatestTs, expectedLatest)
	}
}

// ---------------------------------------------------------------------------
// Fork worktree helper tests (Build A — FindGitRepoRoot + CreateForkWorktree)
// ---------------------------------------------------------------------------

func TestFindGitRepoRoot_InsideRepo(t *testing.T) {
	// This test runs inside the conduit repo itself — it should find a root.
	// We use the broker directory as the cwd since we know it's inside a git repo.
	root, ok := FindGitRepoRoot("/root/developer/projects/conduit")
	if !ok {
		t.Skip("not running inside a git repo (CI may not have one)")
	}
	if root == "" {
		t.Error("FindGitRepoRoot returned empty root inside a git repo")
	}
}

func TestFindGitRepoRoot_OutsideRepo(t *testing.T) {
	// A freshly created temp dir is NOT a git repo.
	tmp := t.TempDir()
	_, ok := FindGitRepoRoot(tmp)
	if ok {
		t.Errorf("FindGitRepoRoot(%q) returned ok=true for a non-git dir", tmp)
	}
}

func TestCreateForkWorktree_CreatesWorktreeAndLeavesSourceUnchanged(t *testing.T) {
	// Create a real temporary git repo, add a commit, then fork it.
	repoDir := t.TempDir()
	run := func(dir string, args ...string) {
		t.Helper()
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = dir
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("cmd %v: %v: %s", args, err, out)
		}
	}
	run(repoDir, "git", "init", "-b", "main")
	run(repoDir, "git", "config", "user.email", "test@test.com")
	run(repoDir, "git", "config", "user.name", "Test")
	// Write a file so HEAD exists (git won't add a worktree from an empty repo).
	_ = os.WriteFile(filepath.Join(repoDir, "README.md"), []byte("# Test\n"), 0o644)
	run(repoDir, "git", "add", ".")
	run(repoDir, "git", "commit", "-m", "init")

	// Record the original HEAD commit.
	origHEAD, err := exec.Command("git", "-C", repoDir, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatalf("git rev-parse HEAD: %v", err)
	}
	origHEAD = []byte(strings.TrimSpace(string(origHEAD)))

	// Create the fork worktree.
	wtDir := filepath.Join(t.TempDir(), "fork-worktree")
	sessID := "abcdef12-3456-7890-abcd-ef1234567890"
	branchName, err := CreateForkWorktree(repoDir, wtDir, sessID)
	if err != nil {
		t.Fatalf("CreateForkWorktree: %v", err)
	}
	if !strings.HasPrefix(branchName, "conduit/fork-") {
		t.Errorf("branchName=%q want prefix conduit/fork-", branchName)
	}

	// Worktree must exist and be a git repo.
	root, ok := FindGitRepoRoot(wtDir)
	if !ok || root == "" {
		t.Fatal("forked worktree is not inside a git repo")
	}

	// Source repo HEAD is unchanged (the fork operation never modifies origin).
	newHEAD, err := exec.Command("git", "-C", repoDir, "rev-parse", "HEAD").Output()
	if err != nil {
		t.Fatalf("git rev-parse HEAD after fork: %v", err)
	}
	newHEAD = []byte(strings.TrimSpace(string(newHEAD)))
	if string(origHEAD) != string(newHEAD) {
		t.Errorf("source HEAD changed after fork: %s → %s", origHEAD, newHEAD)
	}

	// The new worktree is on a different branch than the source.
	wtBranch, err := exec.Command("git", "-C", wtDir, "rev-parse", "--abbrev-ref", "HEAD").Output()
	if err != nil {
		t.Fatalf("git branch in worktree: %v", err)
	}
	if strings.TrimSpace(string(wtBranch)) == "main" {
		t.Error("worktree is on 'main'; expected a conduit/fork-... branch")
	}
}

// TestDiscoverExternalSessions_QualityFloorDropsOneShots verifies the
// discovery quality floor: trivial single-turn sessions are excluded so the
// list and TotalOnDisk reflect only sessions worth resuming.
func TestDiscoverExternalSessions_QualityFloorDropsOneShots(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".claude", "projects", "-home-user-proj")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}

	writeClaude := func(id string, pairs int) {
		lines := []map[string]any{
			{"type": "agent-setting", "agentSetting": "claude", "sessionId": id},
		}
		for i := 0; i < pairs; i++ {
			lines = append(lines,
				map[string]any{
					"type": "user", "sessionId": id,
					"timestamp": "2024-12-14T10:00:00.000Z",
					"message":   map[string]any{"role": "user", "content": "hi"},
					"cwd":       "/home/user/proj",
				},
				map[string]any{
					"type": "assistant", "sessionId": id,
					"timestamp": "2024-12-14T10:05:00.000Z",
					"message": map[string]any{
						"role":    "assistant",
						"content": []map[string]any{{"type": "text", "text": "ok"}},
					},
				},
			)
		}
		var content string
		for _, rec := range lines {
			b, _ := json.Marshal(rec)
			content += string(b) + "\n"
		}
		if err := os.WriteFile(filepath.Join(dir, id+".jsonl"), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	writeClaude("11111111-1111-1111-1111-111111111111", 1) // 1 pair  -> filtered out
	writeClaude("22222222-2222-2222-2222-222222222222", 3) // 3 pairs -> kept

	m := &Manager{conduitRoot: t.TempDir()}
	resp := m.DiscoverExternalSessions("", []string{"claude"})

	if resp.TotalOnDisk != 1 {
		t.Errorf("TotalOnDisk=%d want 1 (the one-shot must be filtered)", resp.TotalOnDisk)
	}
	if len(resp.Sessions) != 1 {
		t.Fatalf("got %d sessions, want 1", len(resp.Sessions))
	}
	if got := resp.Sessions[0].ExternalID; got != "22222222-2222-2222-2222-222222222222" {
		t.Errorf("kept the wrong session: %s", got)
	}
	if resp.Sessions[0].TurnCount < minMeaningfulTurns {
		t.Errorf("kept session TurnCount=%d below floor %d", resp.Sessions[0].TurnCount, minMeaningfulTurns)
	}
}
