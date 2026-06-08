package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func initRepoWithCommit(t *testing.T, dir string) {
	t.Helper()
	gitWIP(t, dir, "init", "-q")
	writeWIPFile(t, dir, "README.md", "base\n")
	gitWIP(t, dir, "add", "-A")
	gitWIP(t, dir, "commit", "-q", "-m", "base")
}

func TestMaybeRemapToWorktreeDisabledByDefault(t *testing.T) {
	t.Setenv("CONDUIT_SESSION_WORKTREE", "")
	repo := t.TempDir()
	initRepoWithCommit(t, repo)
	s := &Session{ID: "off-1", sessionDir: t.TempDir()}
	if got := s.maybeRemapToWorktree(repo); got != repo {
		t.Fatalf("disabled: expected baseDir unchanged, got %q", got)
	}
}

func TestMaybeRemapToWorktreeCreatesAndReuses(t *testing.T) {
	t.Setenv("CONDUIT_SESSION_WORKTREE", "1")
	repo := t.TempDir()
	initRepoWithCommit(t, repo)
	sessDir := t.TempDir()
	s := &Session{ID: "wt-1", sessionDir: sessDir}

	wt := s.maybeRemapToWorktree(repo)
	if wt == repo {
		t.Fatalf("enabled: expected a worktree path, got the base repo")
	}
	if !isGitRepo(wt) {
		t.Fatalf("worktree path is not a git repo: %q", wt)
	}
	// It's a real linked worktree on the per-session branch.
	branch := gitWIP(t, wt, "rev-parse", "--abbrev-ref", "HEAD")
	if branch != sessionWorktreeBranchPrefix+"wt-1" {
		t.Errorf("worktree on wrong branch: %q", branch)
	}
	// Editing in the worktree does NOT dirty the base repo (isolation).
	writeWIPFile(t, wt, "README.md", "changed in session\n")
	if status := gitWIP(t, repo, "status", "--porcelain"); status != "" {
		t.Errorf("base repo should be untouched by worktree edits, got: %s", status)
	}
	// Recovery: a second call reuses the existing worktree, no error.
	if again := s.maybeRemapToWorktree(repo); again != wt {
		t.Errorf("expected reuse of existing worktree %q, got %q", wt, again)
	}
}

func TestMaybeRemapToWorktreeNonRepoFailsSafe(t *testing.T) {
	t.Setenv("CONDUIT_SESSION_WORKTREE", "1")
	plain := t.TempDir() // not a git repo
	s := &Session{ID: "plain-1", sessionDir: t.TempDir()}
	if got := s.maybeRemapToWorktree(plain); got != plain {
		t.Fatalf("non-repo base must be returned unchanged, got %q", got)
	}
}

func TestRemoveSessionWorktree(t *testing.T) {
	t.Setenv("CONDUIT_SESSION_WORKTREE", "1")
	repo := t.TempDir()
	initRepoWithCommit(t, repo)
	sessDir := t.TempDir()
	s := &Session{ID: "rm-1", sessionDir: sessDir}
	wt := s.maybeRemapToWorktree(repo)
	if wt == repo || !isGitRepo(wt) {
		t.Fatalf("setup: expected a worktree, got %q", wt)
	}

	removeSessionWorktree(wt)

	if _, err := os.Stat(wt); !os.IsNotExist(err) {
		t.Errorf("worktree dir should be gone, stat err=%v", err)
	}
	// Parent repo no longer lists the worktree.
	list := gitWIP(t, repo, "worktree", "list")
	if strings.Contains(list, sessDir) {
		t.Errorf("parent repo still registers the worktree:\n%s", list)
	}
	// Safe/no-op on a path that isn't a worktree.
	removeSessionWorktree(filepath.Join(t.TempDir(), "nope"))
	removeSessionWorktree("")
}
