package session

import (
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// TestDiffSummary inits a temp git repo, commits a file, then verifies
// DiffSummary returns non-zero counts when diffing against an earlier ref.
func TestDiffSummary(t *testing.T) {
	dir := t.TempDir()

	// Configure a minimal git identity so commits don't fail.
	run := func(name string, args ...string) {
		t.Helper()
		cmd := exec.Command(name, args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test",
			"GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test",
			"GIT_COMMITTER_EMAIL=test@test.com",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s %v: %v\n%s", name, args, err, out)
		}
	}

	run("git", "init", "-b", "main")
	run("git", "config", "user.email", "test@test.com")
	run("git", "config", "user.name", "test")

	// Initial commit on main (the base).
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("git", "add", ".")
	run("git", "commit", "-m", "init")

	// Create a branch and add more content.
	run("git", "checkout", "-b", "feature")
	if err := os.WriteFile(filepath.Join(dir, "b.txt"), []byte("line1\nline2\nline3\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("git", "add", ".")
	run("git", "commit", "-m", "add b")

	files, ins, del, stat, err := DiffSummary(dir, "main")
	if err != nil {
		t.Fatalf("DiffSummary: %v", err)
	}
	if files == 0 {
		t.Errorf("expected files_changed > 0, got %d (stat=%q)", files, stat)
	}
	if ins == 0 {
		t.Errorf("expected insertions > 0, got %d", ins)
	}
	_ = del // deletions may be 0 here — that's fine
	if stat == "" {
		t.Error("expected non-empty stat output")
	}
}

// TestDiffSummaryNoDiff verifies that an identical HEAD vs base returns zeros (no error).
func TestDiffSummaryNoDiff(t *testing.T) {
	dir := t.TempDir()

	run := func(name string, args ...string) {
		t.Helper()
		cmd := exec.Command(name, args...)
		cmd.Dir = dir
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=test",
			"GIT_AUTHOR_EMAIL=test@test.com",
			"GIT_COMMITTER_NAME=test",
			"GIT_COMMITTER_EMAIL=test@test.com",
		)
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("%s %v: %v\n%s", name, args, err, out)
		}
	}

	run("git", "init", "-b", "main")
	run("git", "config", "user.email", "test@test.com")
	run("git", "config", "user.name", "test")

	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("hello\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	run("git", "add", ".")
	run("git", "commit", "-m", "init")

	// HEAD is the same as main — no diff.
	files, ins, del, stat, err := DiffSummary(dir, "main")
	if err != nil {
		t.Fatalf("DiffSummary (no diff): %v", err)
	}
	if files != 0 || ins != 0 || del != 0 || stat != "" {
		t.Errorf("expected zeros for no-diff case, got files=%d ins=%d del=%d stat=%q", files, ins, del, stat)
	}
}

// TestDiffSummaryErrors covers the error paths.
func TestDiffSummaryErrors(t *testing.T) {
	t.Run("empty_workdir", func(t *testing.T) {
		_, _, _, _, err := DiffSummary("", "main")
		if err == nil {
			t.Error("expected error for empty workdir")
		}
	})
	t.Run("empty_base", func(t *testing.T) {
		_, _, _, _, err := DiffSummary("/tmp", "")
		if err == nil {
			t.Error("expected error for empty base")
		}
	})
}
