package session

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// agentCWD resolves the current working directory of the process with the
// given PID by reading /proc/<pid>/cwd (Linux only). Returns "" when the pid
// is 0, the symlink cannot be read, or the resolved path does not exist — in
// all those cases the caller falls back to the session's static workspaceDir.
func agentCWD(pid int) string {
	if pid <= 0 {
		return ""
	}
	link := fmt.Sprintf("/proc/%d/cwd", pid)
	resolved, err := os.Readlink(link)
	if err != nil {
		return ""
	}
	// Verify the resolved path actually exists (handles stale symlinks).
	if _, err := os.Stat(resolved); err != nil {
		return ""
	}
	return resolved
}

// GitState holds the live git state for a session's worktree directory.
// All fields are zero/empty when the directory is not a git repo or any
// command fails — callers treat absence as "unknown", never as an error.
type GitState struct {
	// Branch is the current branch name, or the short SHA when HEAD is
	// detached. Empty when the directory is not a git repo.
	Branch string
	// Dirty is the number of lines from `git status --porcelain` (0 = clean).
	Dirty uint32
	// Ahead / Behind vs the base branch (origin/main if it exists, else main).
	Ahead  uint32
	Behind uint32
	// WorktreeName is the per-session worktree name, or empty when not
	// running in a dedicated worktree.
	WorktreeName string
}

// sessionGitCache guards a per-session cached GitState so the hot status-emit
// path doesn't shell out on every broadcast. A TTL of 2 s bounds staleness
// without saturating the machine with git processes.
type sessionGitCache struct {
	mu         sync.Mutex
	value      GitState
	computedAt time.Time
}

const gitStateCacheTTL = 2 * time.Second

// get returns the cached value and whether it is still valid.
func (c *sessionGitCache) get() (GitState, bool) {
	c.mu.Lock()
	defer c.mu.Unlock()
	if c.computedAt.IsZero() || time.Since(c.computedAt) > gitStateCacheTTL {
		return GitState{}, false
	}
	return c.value, true
}

// set stores a freshly-computed value.
func (c *sessionGitCache) set(gs GitState) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.value = gs
	c.computedAt = time.Now()
}

// computeGitState runs the git commands for dir and returns a GitState.
// Robust to non-git dirs / missing remotes — never returns an error; missing
// data is represented as zero values.
func computeGitState(dir, worktreeName string) GitState {
	if dir == "" || !isGitRepo(dir) {
		return GitState{}
	}

	gs := GitState{WorktreeName: worktreeName}

	// --- branch ---
	if out, err := runGit(dir, 3*time.Second, "rev-parse", "--abbrev-ref", "HEAD"); err == nil {
		b := strings.TrimSpace(string(out))
		if b == "HEAD" {
			// detached HEAD — use short SHA
			if sha, err2 := runGit(dir, 3*time.Second, "rev-parse", "--short", "HEAD"); err2 == nil {
				b = strings.TrimSpace(string(sha))
			} else {
				b = ""
			}
		}
		gs.Branch = b
	}

	// --- dirty count ---
	if out, err := runGit(dir, 3*time.Second, "status", "--porcelain"); err == nil {
		lines := 0
		for _, line := range strings.Split(string(out), "\n") {
			if strings.TrimSpace(line) != "" {
				lines++
			}
		}
		gs.Dirty = uint32(lines)
	}

	// --- ahead / behind ---
	// Try origin/main first, fall back to main.
	base := pickBase(dir)
	if base != "" {
		// `git rev-list --left-right --count <base>...HEAD`
		// output: "<behind>\t<ahead>"
		if out, err := runGit(dir, 3*time.Second,
			"rev-list", "--left-right", "--count", base+"...HEAD"); err == nil {
			behind, ahead := parseLeftRight(strings.TrimSpace(string(out)))
			gs.Behind = behind
			gs.Ahead = ahead
		}
	}

	return gs
}

// pickBase returns "origin/main" when that ref exists in dir, else "main"
// if it exists, else "". Returns "" on any error or if no suitable base is
// found (new repo, no commits, etc.).
func pickBase(dir string) string {
	for _, candidate := range []string{"origin/main", "main"} {
		if _, err := runGit(dir, 2*time.Second, "rev-parse", "--verify", candidate); err == nil {
			return candidate
		}
	}
	return ""
}

// parseLeftRight parses the `<behind>\t<ahead>` output from
// `git rev-list --left-right --count`. Returns (0,0) on any parse error.
func parseLeftRight(s string) (behind, ahead uint32) {
	parts := strings.SplitN(s, "\t", 2)
	if len(parts) != 2 {
		return 0, 0
	}
	var b, a uint64
	// simple uint parse — strconv not imported here, roll it inline
	for _, c := range parts[0] {
		if c < '0' || c > '9' {
			return 0, 0
		}
		b = b*10 + uint64(c-'0')
	}
	for _, c := range parts[1] {
		if c < '0' || c > '9' {
			return 0, 0
		}
		a = a*10 + uint64(c-'0')
	}
	return uint32(b), uint32(a)
}

// worktreeNameFor returns the worktree name to show for a session. When the
// session's workspaceDir is a per-session linked worktree (the sessionDir
// "worktree" path), the name is the per-session branch (conduit/session-<id>).
// For all other cases it returns "".
func worktreeNameFor(s *Session) string {
	wt := filepath.Join(s.sessionDir, "worktree")
	wd := s.WorkspaceDir()
	if wd == "" || s.sessionDir == "" {
		return ""
	}
	// Resolve symlinks / clean so we can compare robustly.
	if filepath.Clean(wd) == filepath.Clean(wt) {
		return sessionWorktreeBranchPrefix + s.ID
	}
	return ""
}
