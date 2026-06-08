package session

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func gitWIP(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=test", "GIT_AUTHOR_EMAIL=test@test",
		"GIT_COMMITTER_NAME=test", "GIT_COMMITTER_EMAIL=test@test",
	)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %s: %v\n%s", strings.Join(args, " "), err, out)
	}
	return strings.TrimSpace(string(out))
}

func writeWIPFile(t *testing.T, dir, name, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

// The core guarantee: a checkpoint must NOT revert the live working tree (the
// bug that wiped in-progress agent edits every 60s), yet must still capture a
// recoverable snapshot of both tracked changes and untracked files.
func TestMaybeAutoWIPSnapshotsWithoutTouchingTree(t *testing.T) {
	repo := t.TempDir()
	gitWIP(t, repo, "init", "-q")
	writeWIPFile(t, repo, "tracked.txt", "original\n")
	gitWIP(t, repo, "add", "-A")
	gitWIP(t, repo, "commit", "-q", "-m", "base")

	// Make the tree dirty: edit a tracked file + add an untracked one.
	writeWIPFile(t, repo, "tracked.txt", "in-progress edit\n")
	writeWIPFile(t, repo, "untracked.txt", "brand new\n")

	s := &Session{workspaceDir: repo, ID: "sess-1"}
	s.maybeAutoWIP()

	// 1. Working tree is UNTOUCHED — edits still on disk.
	if got, _ := os.ReadFile(filepath.Join(repo, "tracked.txt")); string(got) != "in-progress edit\n" {
		t.Fatalf("tracked edit was reverted off disk: %q", string(got))
	}
	if _, err := os.Stat(filepath.Join(repo, "untracked.txt")); err != nil {
		t.Fatalf("untracked file was removed from disk: %v", err)
	}
	if status := gitWIP(t, repo, "status", "--porcelain"); status == "" {
		t.Fatalf("working tree was cleaned — checkpoint must leave it dirty")
	}

	// 2. The snapshot ref exists and captures both the edit and the new file.
	ref := wipCheckpointRefPrefix + "sess-1"
	if got := gitWIP(t, repo, "show", ref+":tracked.txt"); got != "in-progress edit" {
		t.Errorf("snapshot missing tracked edit, got %q", got)
	}
	if got := gitWIP(t, repo, "show", ref+":untracked.txt"); got != "brand new" {
		t.Errorf("snapshot missing untracked file, got %q", got)
	}

	// 3. No stash was created (the old, never-restored pile-up is gone).
	if out := gitWIP(t, repo, "stash", "list"); out != "" {
		t.Errorf("expected no stash entries, got: %s", out)
	}
}

// Deleting a session drops its WIP snapshot ref so refs don't outlive the
// sessions that created them.
func TestDeleteWIPCheckpointRef(t *testing.T) {
	repo := t.TempDir()
	gitWIP(t, repo, "init", "-q")
	writeWIPFile(t, repo, "f.txt", "v0\n")
	gitWIP(t, repo, "add", "-A")
	gitWIP(t, repo, "commit", "-q", "-m", "base")

	s := &Session{workspaceDir: repo, ID: "sess-del"}
	writeWIPFile(t, repo, "f.txt", "dirty\n")
	s.maybeAutoWIP()
	ref := wipCheckpointRefPrefix + "sess-del"
	if out := gitWIP(t, repo, "for-each-ref", "--format=%(refname)", ref); out == "" {
		t.Fatalf("precondition: checkpoint ref should exist")
	}

	deleteWIPCheckpointRef(repo, "sess-del")

	if out := gitWIP(t, repo, "for-each-ref", "--format=%(refname)", ref); out != "" {
		t.Errorf("checkpoint ref should be gone after delete, got %q", out)
	}
	// Idempotent / safe on non-repo + missing ref.
	deleteWIPCheckpointRef(repo, "sess-del")
	deleteWIPCheckpointRef(t.TempDir(), "never")
	deleteWIPCheckpointRef("", "never")
}

// A second checkpoint overwrites the per-session ref rather than accumulating,
// so snapshots are bounded at one-per-session.
func TestMaybeAutoWIPOverwritesRefBounded(t *testing.T) {
	repo := t.TempDir()
	gitWIP(t, repo, "init", "-q")
	writeWIPFile(t, repo, "f.txt", "v0\n")
	gitWIP(t, repo, "add", "-A")
	gitWIP(t, repo, "commit", "-q", "-m", "base")

	s := &Session{workspaceDir: repo, ID: "sess-2"}
	ref := wipCheckpointRefPrefix + "sess-2"

	writeWIPFile(t, repo, "f.txt", "v1\n")
	s.maybeAutoWIP()
	first := gitWIP(t, repo, "rev-parse", ref)

	writeWIPFile(t, repo, "f.txt", "v2\n")
	s.maybeAutoWIP()
	second := gitWIP(t, repo, "rev-parse", ref)

	if first == second {
		t.Fatalf("second checkpoint did not update the ref")
	}
	if got := gitWIP(t, repo, "show", ref+":f.txt"); got != "v2" {
		t.Errorf("ref should hold the latest snapshot, got %q", got)
	}
	// Exactly one ref under the namespace — no accumulation.
	refs := gitWIP(t, repo, "for-each-ref", "--format=%(refname)", "refs/conduit/checkpoints/")
	if lines := strings.Split(strings.TrimSpace(refs), "\n"); len(lines) != 1 {
		t.Errorf("expected exactly 1 checkpoint ref, got %d: %v", len(lines), lines)
	}
}
