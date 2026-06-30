package session

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// Per-session git worktrees. When enabled, a coding session whose workspace is
// a git repo runs in its OWN linked worktree (on a per-session branch) instead
// of the shared checkout. That isolates concurrent sessions and the checkpoint
// loop from each other, so one session's in-progress edits never appear in (or
// get clobbered by) another's working tree.
//
// OFF by default: it changes where every session's code lives and which branch
// the work lands on, so it needs on-device verification before becoming the
// default. Enable with CONDUIT_SESSION_WORKTREE=1 (e.g. in the systemd unit).
// Every failure path falls back to the original directory — a worktree problem
// must never stop a session from starting.

const sessionWorktreeBranchPrefix = "conduit/session-"

func sessionWorktreeEnabled() bool {
	switch os.Getenv("CONDUIT_SESSION_WORKTREE") {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// isGitRepo reports whether dir is inside a git working tree.
func isGitRepo(dir string) bool {
	if dir == "" {
		return false
	}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--is-inside-work-tree").Output()
	return err == nil && strings.TrimSpace(string(out)) == "true"
}

// maybeRemapToWorktree returns a per-session worktree path for baseDir when the
// feature is enabled and baseDir is a git repo; otherwise it returns baseDir
// unchanged. Idempotent across recovery: an already-created worktree is reused.
//
// When s.requestedBranch is non-empty it is used as the worktree branch name;
// otherwise the default "conduit/session-<id>" is used.
func (s *Session) maybeRemapToWorktree(baseDir string) string {
	if !sessionWorktreeEnabled() || baseDir == "" || !isGitRepo(baseDir) {
		return baseDir
	}
	wt := filepath.Join(s.sessionDir, "worktree")
	if isGitRepo(wt) {
		return wt // recovered/restarted session — reuse its worktree
	}
	if err := os.MkdirAll(s.sessionDir, 0o755); err != nil {
		return baseDir
	}
	branch := sessionWorktreeBranchPrefix + s.ID
	if s.requestedBranch != "" {
		branch = s.requestedBranch
	}
	// -B creates-or-resets the per-session branch at the repo's current HEAD;
	// a linked worktree can't share a branch with another worktree, so each
	// session owns its own. CombinedOutput so a failure is fully swallowed.
	if _, err := exec.Command(
		"git", "-C", baseDir, "worktree", "add", "-B", branch, wt, "HEAD",
	).CombinedOutput(); err != nil {
		return baseDir
	}
	return wt
}

// removeSessionWorktree deregisters and deletes the session's worktree (if it
// has one) from its parent repo. Best-effort: anything missing is a no-op so a
// session delete never fails on worktree teardown. Resolved via the shared
// common dir so it works without knowing the original repo path.
func removeSessionWorktree(worktreePath string) {
	if worktreePath == "" || !isGitRepo(worktreePath) {
		return
	}
	commonOut, err := exec.Command("git", "-C", worktreePath, "rev-parse", "--git-common-dir").Output()
	if err != nil {
		return
	}
	common := strings.TrimSpace(string(commonOut))
	if common == "" {
		return
	}
	if !filepath.IsAbs(common) {
		common = filepath.Join(worktreePath, common)
	}
	mainRepo := filepath.Dir(common) // parent of <repo>/.git
	_ = exec.Command("git", "-C", mainRepo, "worktree", "remove", "--force", worktreePath).Run()
	_ = exec.Command("git", "-C", mainRepo, "worktree", "prune").Run()
}
