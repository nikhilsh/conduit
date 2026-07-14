package ws

// gitdiff.go — structured diff + git-state HTTP handlers for the "Review &
// Ship from phone" (Feature A) surface.
//
// Routes (dispatched from the /api/session/ prefix catch-all in api.go):
//
//	GET /api/session/{id}/git/diff?scope=uncommitted|branch&context=3
//	GET /api/session/{id}/git/state
//
// Both resolve their working directory via Session.LiveGitDir() (the
// agent's real cwd, not the static WorkspaceDir), so a worktree-remapped
// session reviews the tree the agent is actually standing in.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os/exec"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Caps on the diff payload — tune later. maxLinesPerFile bounds a single
// file's rendered hunks (remaining hunks dropped, file.truncated=true).
// maxFiles bounds the whole response (extra files omitted from `files` but
// still counted in `diffstat`, top-level truncated=true).
const (
	maxDiffLinesPerFile = 2000
	maxDiffFiles        = 300
)

// --- wire types ---------------------------------------------------------

type gitDiffLine struct {
	Kind string `json:"kind"` // context|add|del
	Old  int    `json:"old"`
	New  int    `json:"new"`
	Text string `json:"text"`
}

type gitDiffHunk struct {
	Header   string        `json:"header"`
	OldStart int           `json:"old_start"`
	OldLines int           `json:"old_lines"`
	NewStart int           `json:"new_start"`
	NewLines int           `json:"new_lines"`
	Lines    []gitDiffLine `json:"lines"`
}

type gitDiffFile struct {
	Path      string        `json:"path"`
	OldPath   string        `json:"old_path,omitempty"`
	Status    string        `json:"status"` // added|modified|deleted|renamed|copied|untracked
	Staged    bool          `json:"staged"`
	Binary    bool          `json:"binary"`
	Additions int           `json:"additions"`
	Deletions int           `json:"deletions"`
	Truncated bool          `json:"truncated"`
	Hunks     []gitDiffHunk `json:"hunks"`
}

type gitDiffStat struct {
	FilesChanged int `json:"files_changed"`
	Additions    int `json:"additions"`
	Deletions    int `json:"deletions"`
}

type gitDiffResponse struct {
	Scope         string        `json:"scope"`
	DefaultBranch string        `json:"default_branch"`
	Base          string        `json:"base,omitempty"`
	Files         []gitDiffFile `json:"files"`
	Diffstat      gitDiffStat   `json:"diffstat"`
	Truncated     bool          `json:"truncated"`
}

type gitPRInfo struct {
	URL    string `json:"url"`
	Number int    `json:"number"`
	State  string `json:"state"`
}

type gitStateResponse struct {
	IsGitRepo     bool       `json:"is_git_repo"`
	Branch        string     `json:"branch"`
	Detached      bool       `json:"detached"`
	DefaultBranch string     `json:"default_branch"`
	Upstream      string     `json:"upstream"`
	Ahead         int        `json:"ahead"`
	Behind        int        `json:"behind"`
	Staged        int        `json:"staged"`
	Unstaged      int        `json:"unstaged"`
	Untracked     int        `json:"untracked"`
	Dirty         int        `json:"dirty"`
	HasGh         bool       `json:"has_gh"`
	PR            *gitPRInfo `json:"pr,omitempty"`
}

// --- GET /api/session/{id}/git/diff -------------------------------------

// serveSessionGitDiff handles GET /api/session/{id}/git/diff.
//
// Wire contract:
//
//	GET /api/session/{id}/git/diff?scope=uncommitted|branch&context=3
//	Authorization: Bearer <token>   (or ?token=<token>)
//
//	200 {"scope":...,"default_branch":...,"files":[...],"diffstat":{...},"truncated":false}
//	409 {"error":"not_a_git_repo","message":"…"}
//	400 {"error":"invalid_request","message":"…"}   — bad scope
//	401 {"error":"auth_expired","message":"…"}
//	404 {"error":"session_not_found","message":"…"}
func (s *Server) serveSessionGitDiff(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET required")
		return
	}
	sess, ok := s.Sessions.Get(sessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "session_not_found", "session not found: "+sessionID)
		return
	}

	scope := strings.TrimSpace(r.URL.Query().Get("scope"))
	if scope == "" {
		scope = "uncommitted"
	}
	if scope != "uncommitted" && scope != "branch" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "scope must be uncommitted|branch")
		return
	}
	contextN := 3
	if cs := r.URL.Query().Get("context"); cs != "" {
		if n, err := strconv.Atoi(cs); err == nil && n >= 0 {
			contextN = n
		}
	}

	dir := sess.LiveGitDir()
	if !isGitRepoDir(dir) {
		writeAPIError(w, http.StatusConflict, "not_a_git_repo", "working directory is not a git repository")
		return
	}

	resp := buildGitDiffResponse(r.Context(), dir, scope, contextN)
	writeJSON(w, http.StatusOK, resp)
}

// buildGitDiffResponse runs the git commands for scope/contextN in dir and
// assembles the full diff response, applying the per-file and per-payload
// caps. Split out from the handler for direct unit testing against a temp
// git repo.
func buildGitDiffResponse(ctx context.Context, dir, scope string, contextN int) gitDiffResponse {
	resp := gitDiffResponse{
		Scope:         scope,
		DefaultBranch: defaultBranchName(ctx, dir),
	}

	stagedSet := stagedFileSet(ctx, dir)
	var raw string
	switch scope {
	case "branch":
		base := pickDiffBase(ctx, dir)
		resp.Base = base
		if base != "" {
			if mbOut, _, ok := runShellCmd(ctx, dir, "git", "merge-base", base, "HEAD"); ok {
				mb := strings.TrimSpace(mbOut)
				if mb != "" {
					if out, _, ok2 := runShellCmd(ctx, dir, "git", "diff", "--no-color",
						fmt.Sprintf("-U%d", contextN), mb+"...HEAD"); ok2 {
						raw = out
					}
				}
			}
		}
	default: // uncommitted
		if out, _, ok := runShellCmd(ctx, dir, "git", "diff", "--no-color",
			fmt.Sprintf("-U%d", contextN), "HEAD"); ok {
			raw = out
		}
	}

	files := parseUnifiedDiff(raw, stagedSet)

	if scope != "branch" {
		for _, p := range listUntrackedFiles(ctx, dir) {
			files = append(files, untrackedDiffFile(ctx, dir, p, contextN))
		}
	}

	sort.Slice(files, func(i, j int) bool { return files[i].Path < files[j].Path })

	// diffstat is computed over the FULL set, before the maxFiles cap trims
	// the `files` slice — extra files stay counted per the contract.
	stat := gitDiffStat{FilesChanged: len(files)}
	for _, f := range files {
		stat.Additions += f.Additions
		stat.Deletions += f.Deletions
	}
	resp.Diffstat = stat

	if len(files) > maxDiffFiles {
		resp.Truncated = true
		files = files[:maxDiffFiles]
	}
	resp.Files = files
	return resp
}

// --- GET /api/session/{id}/git/state ------------------------------------

// serveSessionGitState handles GET /api/session/{id}/git/state.
//
// Wire contract:
//
//	GET /api/session/{id}/git/state
//	Authorization: Bearer <token>   (or ?token=<token>)
//
//	200 {"is_git_repo":true,"branch":...,...,"pr":{...}}
//	200 {"is_git_repo":false}                          — not a repo, not an error
//	401 {"error":"auth_expired","message":"…"}
//	404 {"error":"session_not_found","message":"…"}
func (s *Server) serveSessionGitState(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "GET required")
		return
	}
	sess, ok := s.Sessions.Get(sessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "session_not_found", "session not found: "+sessionID)
		return
	}

	dir := sess.LiveGitDir()
	if !isGitRepoDir(dir) {
		writeJSON(w, http.StatusOK, map[string]any{"is_git_repo": false})
		return
	}

	ctx := r.Context()
	resp := gitStateResponse{IsGitRepo: true, DefaultBranch: defaultBranchName(ctx, dir)}

	if out, _, ok := runShellCmd(ctx, dir, "git", "rev-parse", "--abbrev-ref", "HEAD"); ok {
		branch := strings.TrimSpace(out)
		if branch == "HEAD" {
			resp.Detached = true
			if sha, _, ok2 := runShellCmd(ctx, dir, "git", "rev-parse", "--short", "HEAD"); ok2 {
				branch = strings.TrimSpace(sha)
			}
		}
		resp.Branch = branch
	}

	upstreamRef, hasUpstream := currentUpstreamRef(ctx, dir)
	if hasUpstream {
		resp.Upstream = upstreamRef
	}
	aheadBehindRef := upstreamRef
	if aheadBehindRef == "" {
		aheadBehindRef = pickDiffBase(ctx, dir)
	}
	if aheadBehindRef != "" {
		if out, _, ok := runShellCmd(ctx, dir, "git", "rev-list", "--left-right", "--count",
			aheadBehindRef+"...HEAD"); ok {
			behind, ahead := parseLeftRightCounts(out)
			resp.Ahead = ahead
			resp.Behind = behind
		}
	}

	resp.Staged = len(stagedFileSet(ctx, dir))
	if out, _, ok := runShellCmd(ctx, dir, "git", "diff", "--name-only"); ok {
		resp.Unstaged = countNonEmptyLines(out)
	}
	resp.Untracked = len(listUntrackedFiles(ctx, dir))
	resp.Dirty = resp.Staged + resp.Unstaged + resp.Untracked

	resp.HasGh = ghBinaryAvailable()
	if resp.HasGh {
		if pr, ok := ghPRLookup(ctx, dir); ok {
			resp.PR = &pr
		}
	}

	writeJSON(w, http.StatusOK, resp)
}

// --- git shell-out helpers ------------------------------------------------

// isGitRepoDir mirrors session.isGitRepo (unexported there) for the ws
// package's own use.
func isGitRepoDir(dir string) bool {
	if dir == "" {
		return false
	}
	out, _, ok := runShellCmd(context.Background(), dir, "git", "rev-parse", "--is-inside-work-tree")
	return ok && strings.TrimSpace(out) == "true"
}

// pickDiffBase returns the remote-tracking base ref ("origin/main") when it
// exists, else the local default branch, else "" if neither is resolvable.
func pickDiffBase(ctx context.Context, dir string) string {
	for _, candidate := range []string{"origin/main", "origin/master", "main", "master"} {
		if _, _, ok := runShellCmd(ctx, dir, "git", "rev-parse", "--verify", candidate); ok {
			return candidate
		}
	}
	return ""
}

// defaultBranchName returns the bare branch name (e.g. "main") backing
// pickDiffBase's ref (e.g. "origin/main"), or "" when no base is resolvable.
func defaultBranchName(ctx context.Context, dir string) string {
	base := pickDiffBase(ctx, dir)
	base = strings.TrimPrefix(base, "origin/")
	return base
}

// currentUpstreamRef returns ("origin/branch", true) when HEAD has an
// upstream tracking ref, else ("", false).
func currentUpstreamRef(ctx context.Context, dir string) (string, bool) {
	out, _, ok := runShellCmd(ctx, dir, "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}")
	if !ok {
		return "", false
	}
	ref := strings.TrimSpace(out)
	if ref == "" {
		return "", false
	}
	return ref, true
}

// stagedFileSet returns the set of paths present in the index diff
// (`git diff --cached --name-only`) — the best-effort whole-file `staged`
// flag source for the diff endpoint and the `staged` count for git/state.
func stagedFileSet(ctx context.Context, dir string) map[string]bool {
	set := map[string]bool{}
	out, _, ok := runShellCmd(ctx, dir, "git", "diff", "--cached", "--name-only")
	if !ok {
		return set
	}
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			set[l] = true
		}
	}
	return set
}

// listUntrackedFiles returns untracked files (respecting .gitignore) via
// `git ls-files --others --exclude-standard`.
func listUntrackedFiles(ctx context.Context, dir string) []string {
	out, _, ok := runShellCmd(ctx, dir, "git", "ls-files", "--others", "--exclude-standard")
	if !ok {
		return nil
	}
	var files []string
	for _, l := range strings.Split(out, "\n") {
		l = strings.TrimSpace(l)
		if l != "" {
			files = append(files, l)
		}
	}
	return files
}

func countNonEmptyLines(s string) int {
	n := 0
	for _, l := range strings.Split(s, "\n") {
		if strings.TrimSpace(l) != "" {
			n++
		}
	}
	return n
}

// untrackedDiffFile synthesizes an all-added diff for an untracked file via
// `git diff --no-index /dev/null <relPath>`. --no-index exits 1 when it
// finds differences (the expected/only case here), so exit status is
// ignored — stdout is parsed best-effort regardless. Path/status are forced
// to the caller-known relPath/"untracked" rather than trusting the
// /dev/null-side header parse.
func untrackedDiffFile(ctx context.Context, dir, relPath string, contextN int) gitDiffFile {
	raw := runGitCapture(ctx, dir, "diff", "--no-color", fmt.Sprintf("-U%d", contextN),
		"--no-index", "--", "/dev/null", relPath)
	f := gitDiffFile{Path: relPath, Status: "untracked"}
	parsed := parseUnifiedDiff(raw, nil)
	if len(parsed) > 0 {
		p := parsed[0]
		f.Binary = p.Binary
		f.Additions = p.Additions
		f.Deletions = p.Deletions
		f.Truncated = p.Truncated
		f.Hunks = p.Hunks
	}
	return f
}

// runGitCapture runs `git -C dir <args...>` and returns stdout regardless of
// exit status (some git subcommands, e.g. `diff --no-index`, use a nonzero
// exit code to mean "differences found", not "error").
func runGitCapture(ctx context.Context, dir string, args ...string) string {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "git", append([]string{"-C", dir}, args...)...)
	var out bytes.Buffer
	cmd.Stdout = &out
	_ = cmd.Run()
	return out.String()
}

// parseLeftRightCounts parses the `<behind>\t<ahead>` output of
// `git rev-list --left-right --count`. Returns (0,0) on any parse error.
func parseLeftRightCounts(s string) (behind, ahead int) {
	parts := strings.SplitN(strings.TrimSpace(s), "\t", 2)
	if len(parts) != 2 {
		return 0, 0
	}
	b, errB := strconv.Atoi(parts[0])
	a, errA := strconv.Atoi(parts[1])
	if errB != nil || errA != nil {
		return 0, 0
	}
	return b, a
}

// ghBinaryAvailable reports whether the `gh` CLI is on PATH.
func ghBinaryAvailable() bool {
	_, err := exec.LookPath("gh")
	return err == nil
}

// ghPRLookup returns the PR for the current branch via
// `gh pr view --json url,number,state`, best-effort with a short timeout.
// (false, zero value) on any error, no PR, or timeout — never fails the
// request.
func ghPRLookup(ctx context.Context, dir string) (gitPRInfo, bool) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "gh", "pr", "view", "--json", "url,number,state")
	cmd.Dir = dir
	out, err := cmd.Output()
	if err != nil {
		return gitPRInfo{}, false
	}
	var pr struct {
		URL    string `json:"url"`
		Number int    `json:"number"`
		State  string `json:"state"`
	}
	if err := json.Unmarshal(out, &pr); err != nil || pr.Number == 0 {
		return gitPRInfo{}, false
	}
	return gitPRInfo{URL: pr.URL, Number: pr.Number, State: strings.ToLower(strings.TrimSpace(pr.State))}, true
}

// --- unified diff parser --------------------------------------------------

var (
	reDiffGitStart = regexp.MustCompile(`^diff --git `)
	reHunkHeader   = regexp.MustCompile(`^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$`)
	reBinaryLine   = regexp.MustCompile(`^Binary files (.+) and (.+) differ$`)
)

// parseUnifiedDiff parses `git diff --no-color` output (possibly containing
// multiple files) into structured gitDiffFile entries. stagedSet may be nil
// (untracked-file single-shot parses never have a staged flag).
func parseUnifiedDiff(raw string, stagedSet map[string]bool) []gitDiffFile {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	lines := strings.Split(raw, "\n")
	n := len(lines)
	var files []gitDiffFile

	i := 0
	for i < n {
		if !reDiffGitStart.MatchString(lines[i]) {
			i++
			continue
		}
		i++ // consume "diff --git a/... b/..." — paths come from more specific lines below

		f := gitDiffFile{}
		var oldPathHdr, newPathHdr string

		for i < n && !strings.HasPrefix(lines[i], "@@ ") && !reDiffGitStart.MatchString(lines[i]) {
			l := lines[i]
			switch {
			case strings.HasPrefix(l, "new file mode"):
				f.Status = "added"
			case strings.HasPrefix(l, "deleted file mode"):
				f.Status = "deleted"
			case strings.HasPrefix(l, "rename from "):
				f.OldPath = strings.TrimPrefix(l, "rename from ")
				f.Status = "renamed"
			case strings.HasPrefix(l, "rename to "):
				f.Path = strings.TrimPrefix(l, "rename to ")
			case strings.HasPrefix(l, "copy from "):
				f.OldPath = strings.TrimPrefix(l, "copy from ")
				f.Status = "copied"
			case strings.HasPrefix(l, "copy to "):
				f.Path = strings.TrimPrefix(l, "copy to ")
			case strings.HasPrefix(l, "Binary files"):
				f.Binary = true
				if m := reBinaryLine.FindStringSubmatch(l); m != nil {
					a, b := m[1], m[2]
					if a != "/dev/null" {
						oldPathHdr = strings.TrimPrefix(a, "a/")
					}
					if b != "/dev/null" {
						newPathHdr = strings.TrimPrefix(b, "b/")
					}
				}
			case strings.HasPrefix(l, "--- "):
				p := strings.TrimPrefix(l, "--- ")
				if p != "/dev/null" {
					oldPathHdr = strings.TrimPrefix(p, "a/")
				}
			case strings.HasPrefix(l, "+++ "):
				p := strings.TrimPrefix(l, "+++ ")
				if p != "/dev/null" {
					newPathHdr = strings.TrimPrefix(p, "b/")
				}
			}
			i++
		}

		if f.Path == "" {
			switch {
			case newPathHdr != "":
				f.Path = newPathHdr
			case oldPathHdr != "":
				f.Path = oldPathHdr
			}
		}
		if f.Status == "" {
			f.Status = "modified"
		}

		var hunks []gitDiffHunk
		for i < n && strings.HasPrefix(lines[i], "@@ ") {
			hm := reHunkHeader.FindStringSubmatch(lines[i])
			if hm == nil {
				i++
				continue
			}
			oldStart := atoiSafe(hm[1])
			oldLines := 1
			if hm[2] != "" {
				oldLines = atoiSafe(hm[2])
			}
			newStart := atoiSafe(hm[3])
			newLines := 1
			if hm[4] != "" {
				newLines = atoiSafe(hm[4])
			}
			header := lines[i]
			i++

			oldLn, newLn := oldStart, newStart
			var hlines []gitDiffLine
			for i < n {
				l := lines[i]
				if strings.HasPrefix(l, "@@ ") || reDiffGitStart.MatchString(l) {
					break
				}
				if strings.HasPrefix(l, `\ No newline at end of file`) || l == "" {
					i++
					continue
				}
				switch l[0] {
				case ' ':
					hlines = append(hlines, gitDiffLine{Kind: "context", Old: oldLn, New: newLn, Text: l[1:]})
					oldLn++
					newLn++
				case '-':
					hlines = append(hlines, gitDiffLine{Kind: "del", Old: oldLn, New: 0, Text: l[1:]})
					oldLn++
				case '+':
					hlines = append(hlines, gitDiffLine{Kind: "add", Old: 0, New: newLn, Text: l[1:]})
					newLn++
				}
				i++
			}
			hunks = append(hunks, gitDiffHunk{
				Header: header, OldStart: oldStart, OldLines: oldLines,
				NewStart: newStart, NewLines: newLines, Lines: hlines,
			})
		}

		adds, dels := 0, 0
		for _, h := range hunks {
			for _, l := range h.Lines {
				switch l.Kind {
				case "add":
					adds++
				case "del":
					dels++
				}
			}
		}
		f.Additions = adds
		f.Deletions = dels

		var kept []gitDiffHunk
		running := 0
		for _, h := range hunks {
			if running >= maxDiffLinesPerFile {
				f.Truncated = true
				break
			}
			kept = append(kept, h)
			running += len(h.Lines)
		}
		f.Hunks = kept

		if stagedSet != nil && stagedSet[f.Path] {
			f.Staged = true
		}

		files = append(files, f)
	}
	return files
}

func atoiSafe(s string) int {
	n, _ := strconv.Atoi(s)
	return n
}
