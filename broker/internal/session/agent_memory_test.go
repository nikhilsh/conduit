package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestCwdToClaudeSlug_RoundTrip verifies that cwdToClaudeSlug and
// claudeSlugToCWD are mutual inverses for common absolute paths.
// The slug transformation is: strip leading '/', replace '/' with '-',
// prepend '-'. The inverse restores the slash-separated path. This test
// pins both functions to the same rule so they cannot drift independently.
func TestCwdToClaudeSlug_RoundTrip(t *testing.T) {
	cases := []struct {
		path string
		slug string
	}{
		{"/root/developer/projects/conduit", "-root-developer-projects-conduit"},
		{"/home/user/code/myapp", "-home-user-code-myapp"},
		{"/workspace", "-workspace"},
		{"/a/b/c/d", "-a-b-c-d"},
	}
	for _, tc := range cases {
		slug := cwdToClaudeSlug(tc.path)
		if slug != tc.slug {
			t.Errorf("cwdToClaudeSlug(%q) = %q, want %q", tc.path, slug, tc.slug)
		}
		back := claudeSlugToCWD(slug)
		if back != tc.path {
			t.Errorf("claudeSlugToCWD(%q) = %q, want %q", slug, back, tc.path)
		}
	}
}

// TestLinkPersistentAgentState_CreatesSymlink verifies that after calling
// linkPersistentAgentState the symlink at <ephemeral>/.claude/projects
// resolves OUTSIDE the sessions/ directory (i.e. into agent-state/).
func TestLinkPersistentAgentState_CreatesSymlink(t *testing.T) {
	root := t.TempDir()
	ephemeral := filepath.Join(root, "sessions", "test-session-id", "agent-home")
	if err := os.MkdirAll(ephemeral, 0o700); err != nil {
		t.Fatalf("mkdir ephemeral: %v", err)
	}
	workspaceDir := "/root/developer/projects/conduit"

	if err := linkPersistentAgentState(ephemeral, root, "anthropic", workspaceDir); err != nil {
		t.Fatalf("linkPersistentAgentState: %v", err)
	}

	linkPath := filepath.Join(ephemeral, ".claude", "projects")

	// The path must exist.
	info, err := os.Lstat(linkPath)
	if err != nil {
		t.Fatalf("lstat link: %v", err)
	}
	if info.Mode()&os.ModeSymlink == 0 {
		t.Fatalf("expected symlink at %s, got mode %v", linkPath, info.Mode())
	}

	// Resolve the symlink and confirm it points outside sessions/.
	target, err := os.Readlink(linkPath)
	if err != nil {
		t.Fatalf("readlink: %v", err)
	}
	sessionsPrefix := filepath.Join(root, "sessions")
	if strings.HasPrefix(target, sessionsPrefix) {
		t.Fatalf("symlink target %q is still under sessions/ — it must point to agent-state/", target)
	}

	// Must live under agent-state/.
	agentStatePrefix := filepath.Join(root, "agent-state")
	if !strings.HasPrefix(target, agentStatePrefix) {
		t.Fatalf("symlink target %q does not start with agent-state/ prefix %q", target, agentStatePrefix)
	}
}

// TestLinkPersistentAgentState_CredentialFileIsRealFile verifies the
// credential isolation invariant: after linkPersistentAgentState runs,
// writing .claude/.credentials.json into the ephemeral home produces a
// REAL file (not a symlink) whose realpath is still inside sessions/,
// NOT inside agent-state/.
func TestLinkPersistentAgentState_CredentialFileIsRealFile(t *testing.T) {
	root := t.TempDir()
	ephemeral := filepath.Join(root, "sessions", "cred-isolation-test", "agent-home")
	if err := os.MkdirAll(ephemeral, 0o700); err != nil {
		t.Fatalf("mkdir ephemeral: %v", err)
	}

	if err := linkPersistentAgentState(ephemeral, root, "anthropic", "/home/user/project"); err != nil {
		t.Fatalf("linkPersistentAgentState: %v", err)
	}

	// Write a credential file into the ephemeral home's .claude dir.
	credPath := filepath.Join(ephemeral, ".claude", ".credentials.json")
	credData := []byte(`{"oauth":{"access_token":"AT","refresh_token":"RT"}}`)
	if err := os.WriteFile(credPath, credData, 0o600); err != nil {
		t.Fatalf("write credentials: %v", err)
	}

	// Must be a regular file, not a symlink.
	info, err := os.Lstat(credPath)
	if err != nil {
		t.Fatalf("lstat credentials: %v", err)
	}
	if info.Mode()&os.ModeSymlink != 0 {
		t.Fatalf(".credentials.json is a symlink — it must be a real file (credential isolation broken)")
	}
	if !info.Mode().IsRegular() {
		t.Fatalf(".credentials.json mode %v is not a regular file", info.Mode())
	}

	// Resolved path must NOT be inside agent-state/.
	realPath, err := filepath.EvalSymlinks(credPath)
	if err != nil {
		t.Fatalf("EvalSymlinks on credentials: %v", err)
	}
	agentStateDir := filepath.Join(root, "agent-state")
	if strings.HasPrefix(realPath, agentStateDir) {
		t.Fatalf("credential realpath %q is inside agent-state/ — isolation broken", realPath)
	}

	// Must be inside sessions/.
	sessionsDir := filepath.Join(root, "sessions")
	if !strings.HasPrefix(realPath, sessionsDir) {
		t.Fatalf("credential realpath %q is not inside sessions/", realPath)
	}
}

// TestLinkPersistentAgentState_BestEffortFallback verifies that an error in
// linkPersistentAgentState does not propagate to the caller as a hard failure.
// This is enforced by the manager.go call site wrapping it in a non-fatal
// error log, but the function itself should also return a descriptive error
// rather than panicking, so the caller can log-and-continue.
func TestLinkPersistentAgentState_BestEffortFallback(t *testing.T) {
	// Pass an empty workspaceDir — the function must return nil (skip, not error)
	// because an empty workspace means the slug can't be computed.
	if err := linkPersistentAgentState("/tmp/eph", "/tmp/root", "anthropic", ""); err != nil {
		t.Fatalf("empty workspaceDir: expected nil (skip), got %v", err)
	}

	// Non-anthropic provider — skip gracefully.
	if err := linkPersistentAgentState("/tmp/eph", "/tmp/root", "openai", "/home/user/proj"); err != nil {
		t.Fatalf("openai provider: expected nil (skip for codex), got %v", err)
	}

	// Unwritable conduitRoot — should return an error (the manager call site
	// logs and continues; this test confirms the error surface is clean).
	if os.Getuid() == 0 {
		t.Skip("running as root: permission test not meaningful")
	}
	unwritable := t.TempDir()
	if err := os.Chmod(unwritable, 0o500); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(unwritable, 0o700) })
	err := linkPersistentAgentState(t.TempDir(), unwritable, "anthropic", "/home/user/proj")
	if err == nil {
		t.Fatal("expected error for unwritable conduitRoot, got nil")
	}
}

// TestLinkPersistentAgentState_SharedStoreAcrossSessions confirms that two
// different session agent-homes pointing at the same workspaceDir share the
// same stable projects dir. A file written through one symlink is readable
// through the other — that is the whole point.
func TestLinkPersistentAgentState_SharedStoreAcrossSessions(t *testing.T) {
	root := t.TempDir()
	workspaceDir := "/home/user/myproject"

	eph1 := filepath.Join(root, "sessions", "session-1", "agent-home")
	eph2 := filepath.Join(root, "sessions", "session-2", "agent-home")
	if err := os.MkdirAll(eph1, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(eph2, 0o700); err != nil {
		t.Fatal(err)
	}

	if err := linkPersistentAgentState(eph1, root, "anthropic", workspaceDir); err != nil {
		t.Fatalf("session 1: %v", err)
	}
	if err := linkPersistentAgentState(eph2, root, "anthropic", workspaceDir); err != nil {
		t.Fatalf("session 2: %v", err)
	}

	// Write a memory file through session 1's symlink.
	slug := cwdToClaudeSlug(workspaceDir)
	memDir := filepath.Join(eph1, ".claude", "projects", slug, "memory")
	if err := os.MkdirAll(memDir, 0o700); err != nil {
		t.Fatalf("mkdir memory: %v", err)
	}
	memFile := filepath.Join(memDir, "MEMORY.md")
	if err := os.WriteFile(memFile, []byte("session 1 memory"), 0o644); err != nil {
		t.Fatalf("write memory: %v", err)
	}

	// Read it back through session 2's symlink.
	readPath := filepath.Join(eph2, ".claude", "projects", slug, "memory", "MEMORY.md")
	data, err := os.ReadFile(readPath)
	if err != nil {
		t.Fatalf("read via session 2: %v", err)
	}
	if string(data) != "session 1 memory" {
		t.Fatalf("shared store mismatch: got %q", string(data))
	}
}
