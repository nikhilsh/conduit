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
	PRURL        string // web URL of the PR/MR, e.g. https://github.com/org/repo/pull/123
	PRProvider   string // "github" | "gitlab" | ""
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
		num, state, prURL, prProvider := prStatus(wd)
		s.mu.Lock()
		s.outcomePRNumber = num
		s.outcomePRState = state
		s.outcomePRURL = prURL
		s.outcomePRProvider = prProvider
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
		PRURL:        s.outcomePRURL,
		PRProvider:   s.outcomePRProvider,
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

// providerForRemote maps a git remote URL to a provider string
// ("github" | "gitlab" | ""). Pure function — no I/O, testable.
func providerForRemote(remoteURL string) string {
	u := strings.ToLower(remoteURL)
	if strings.Contains(u, "github") {
		return "github"
	}
	if strings.Contains(u, "gitlab") {
		return "gitlab"
	}
	return ""
}

// repoOriginRemote returns the `origin` remote URL for the git repo at dir,
// or "" on any error (repo has no remote, git not found, etc.).
func repoOriginRemote(dir string) string {
	out, err := runGit(dir, 3*time.Second, "remote", "get-url", "origin")
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// prStatus returns (number, state, prURL, provider) for the current branch.
// It probes the git remote to pick the right provider and delegates to the
// appropriate CLI. Returns (0, "", "", "") on any error or absence of a PR.
func prStatus(dir string) (int, string, string, string) {
	remote := repoOriginRemote(dir)
	provider := providerForRemote(remote)
	switch provider {
	case "github":
		num, state, url := ghPRStatus(dir)
		return num, state, url, "github"
	case "gitlab":
		num, state, url := glabMRStatus(dir, remote)
		return num, state, url, "gitlab"
	default:
		// Unknown remote — try gh as a best-effort fallback (covers GitHub
		// Enterprise hosts not named "github.*").
		num, state, url := ghPRStatus(dir)
		return num, state, url, ""
	}
}

// ghPRStatus returns the (number, state, url) of the PR for the current
// branch via `gh pr view`, or (0, "", "") when there's no PR / gh is
// unavailable / it errors. State is normalized to "open" | "draft" |
// "merged" | "closed".
func ghPRStatus(dir string) (int, string, string) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "gh", "pr", "view", "--json", "number,state,isDraft,url")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return 0, "", ""
	}
	return parseGHPR(out)
}

// glabMRStatus returns the (number, state, url) of the MR for the current
// branch via `glab mr view --output json`, or falls back to constructing
// the URL from the remote when glab is unavailable. Returns (0, "", "") on
// any error or absence of an MR. Never fails the session — all errors are
// best-effort.
func glabMRStatus(dir, remoteURL string) (int, string, string) {
	glabPath, err := exec.LookPath("glab")
	if err == nil && glabPath != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, glabPath, "mr", "view", "--output", "json")
		cmd.Dir = dir
		out, cerr := cmd.Output()
		if cerr == nil {
			n, st, u := parseGlabMR(out)
			if n > 0 {
				return n, st, u
			}
		}
	}
	// glab unavailable or errored — can't get number/state without it.
	return 0, "", ""
}

// parseGHPR maps `gh pr view --json number,state,isDraft,url` output to a
// (number, normalized-state, url) triple. Split out for unit testing.
func parseGHPR(out []byte) (int, string, string) {
	var pr struct {
		Number  int    `json:"number"`
		State   string `json:"state"`
		IsDraft bool   `json:"isDraft"`
		URL     string `json:"url"`
	}
	if err := json.Unmarshal(out, &pr); err != nil || pr.Number == 0 {
		return 0, "", ""
	}
	state := strings.ToLower(strings.TrimSpace(pr.State)) // OPEN/MERGED/CLOSED
	if state == "open" && pr.IsDraft {
		state = "draft"
	}
	return pr.Number, state, pr.URL
}

// parseGlabMR maps `glab mr view --output json` output to a
// (number, normalized-state, web_url) triple. Split out for unit testing.
func parseGlabMR(out []byte) (int, string, string) {
	var mr struct {
		IID    int    `json:"iid"`
		State  string `json:"state"` // "opened" | "merged" | "closed"
		WebURL string `json:"web_url"`
	}
	if err := json.Unmarshal(out, &mr); err != nil || mr.IID == 0 {
		return 0, "", ""
	}
	state := strings.ToLower(strings.TrimSpace(mr.State))
	// glab uses "opened" for open MRs; normalize to match GitHub's vocabulary.
	if state == "opened" {
		state = "open"
	}
	return mr.IID, state, mr.WebURL
}
