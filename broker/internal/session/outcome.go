package session

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// SessionOutcome is the per-session "outcome" snapshot surfaced in the status
// frame: the design's OutcomeChips on the session cards (lines added/removed,
// commit count, and the associated PR). Computed from the workspace git repo
// and `gh`, mirroring the SessionUsage / Usage() pattern in usage.go.
type SessionOutcome struct {
	LinesAdded   int
	LinesRemoved int
	Commits      int
	PRNumber     int
	PRState      string // "open" | "draft" | "merged" | "closed"
	HasGit       bool   // workspace is a git repo (diff/commits meaningful)
	HasPR        bool   // an associated PR was found
}

// How often the (cheap) git stats and the (network-bound) gh PR lookup are
// recomputed. Gated independently so a frequent watchdog tick doesn't shell
// out to GitHub on every pass.
const (
	outcomeGitEvery = 15 * time.Second
	outcomePREvery  = 60 * time.Second
)

// recordStartCommit captures the workspace git HEAD at session creation so a
// later `git diff` measures only what THIS session changed (not the repo's
// whole history). No-op — and HasGit stays false — when the workspace isn't a
// git repo.
func (s *Session) recordStartCommit() {
	if s.workspaceDir == "" {
		return
	}
	if _, err := os.Stat(filepath.Join(s.workspaceDir, ".git")); err != nil {
		return
	}
	out, err := runGit(s.workspaceDir, 2*time.Second, "rev-parse", "HEAD")
	if err != nil {
		// A brand-new repo with no commits has no HEAD; still a git repo,
		// so diffs against the empty tree are meaningful via commits later.
		s.mu.Lock()
		s.outcomeHasGit = true
		s.mu.Unlock()
		return
	}
	s.mu.Lock()
	s.startCommit = strings.TrimSpace(string(out))
	s.outcomeHasGit = true
	s.mu.Unlock()
}

// refreshOutcomeStats recomputes the session's git/PR outcome stats from the
// workspace and caches them on the session for Outcome() to read. The cheap
// git commands run on the git TTL; the network-bound `gh pr view` runs on the
// slower PR TTL. No-op when the workspace isn't a git repo.
func (s *Session) refreshOutcomeStats() {
	s.mu.Lock()
	wd := s.workspaceDir
	start := s.startCommit
	hasGit := s.outcomeHasGit
	lastGit := s.outcomeGitAt
	lastPR := s.outcomePRAt
	s.mu.Unlock()

	if !hasGit || wd == "" {
		return
	}
	now := time.Now()

	if lastGit.IsZero() || now.Sub(lastGit) >= outcomeGitEvery {
		added, removed := gitDiffShortstat(wd, start)
		commits := gitCommitCount(wd, start)
		s.mu.Lock()
		s.outcomeLinesAdded = added
		s.outcomeLinesRemoved = removed
		s.outcomeCommits = commits
		s.outcomeGitAt = time.Now()
		s.mu.Unlock()
	}

	if lastPR.IsZero() || now.Sub(lastPR) >= outcomePREvery {
		num, state := ghPRStatus(wd)
		s.mu.Lock()
		s.outcomePRNumber = num
		s.outcomePRState = state
		s.outcomePRAt = time.Now()
		s.mu.Unlock()
	}
}

// Outcome returns the cached outcome snapshot for the status frame.
func (s *Session) Outcome() SessionOutcome {
	s.mu.Lock()
	defer s.mu.Unlock()
	return SessionOutcome{
		LinesAdded:   s.outcomeLinesAdded,
		LinesRemoved: s.outcomeLinesRemoved,
		Commits:      s.outcomeCommits,
		PRNumber:     s.outcomePRNumber,
		PRState:      s.outcomePRState,
		HasGit:       s.outcomeHasGit,
		HasPR:        s.outcomePRNumber > 0,
	}
}

func runGit(dir string, timeout time.Duration, args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	return cmd.Output()
}

// gitDiffShortstat returns (added, removed) lines from `base` to the working
// tree (committed + tracked-uncommitted changes). base="" diffs the working
// tree against HEAD. Untracked files aren't counted until committed/added —
// an accepted v1 approximation. Returns (0, 0) on any error.
func gitDiffShortstat(dir, base string) (int, int) {
	args := []string{"diff", "--shortstat"}
	if base != "" {
		args = append(args, base)
	}
	out, err := runGit(dir, 3*time.Second, args...)
	if err != nil {
		return 0, 0
	}
	return parseShortstat(string(out))
}

// parseShortstat extracts insertions/deletions from a `git diff --shortstat`
// summary line: " 7 files changed, 24 insertions(+), 9 deletions(-)".
func parseShortstat(s string) (added, removed int) {
	for _, part := range strings.Split(s, ",") {
		fields := strings.Fields(strings.TrimSpace(part))
		if len(fields) < 2 {
			continue
		}
		n, err := strconv.Atoi(fields[0])
		if err != nil {
			continue
		}
		switch {
		case strings.HasPrefix(fields[1], "insertion"):
			added = n
		case strings.HasPrefix(fields[1], "deletion"):
			removed = n
		}
	}
	return added, removed
}

// gitCommitCount returns the number of commits made since session start
// (`base..HEAD`). Returns 0 when base is unknown or on any error.
func gitCommitCount(dir, base string) int {
	if base == "" {
		return 0
	}
	out, err := runGit(dir, 3*time.Second, "rev-list", "--count", base+"..HEAD")
	if err != nil {
		return 0
	}
	n, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return 0
	}
	return n
}

// ghPRStatus returns the (number, state) of the PR for the current branch via
// `gh pr view`, or (0, "") when there's no PR / gh is unavailable / it errors.
// State is normalized to "open" | "draft" | "merged" | "closed".
func ghPRStatus(dir string) (int, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "gh", "pr", "view", "--json", "number,state,isDraft")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return 0, ""
	}
	return parseGHPR(out)
}

// parseGHPR maps `gh pr view --json number,state,isDraft` output to a
// (number, normalized-state) pair. Split out for unit testing.
func parseGHPR(out []byte) (int, string) {
	var pr struct {
		Number  int    `json:"number"`
		State   string `json:"state"`
		IsDraft bool   `json:"isDraft"`
	}
	if err := json.Unmarshal(out, &pr); err != nil || pr.Number == 0 {
		return 0, ""
	}
	state := strings.ToLower(strings.TrimSpace(pr.State)) // OPEN/MERGED/CLOSED
	if state == "open" && pr.IsDraft {
		state = "draft"
	}
	return pr.Number, state
}
