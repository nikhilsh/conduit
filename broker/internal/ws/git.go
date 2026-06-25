package ws

// git.go — HTTP handlers for the DiffReview screen's git operations.
//
// Routes (dispatched from the /api/session/ prefix catch-all in api.go):
//
//	POST /api/session/{id}/git/commit  — stage all, commit, optional push
//	POST /api/session/{id}/git/pr      — gh pr create

import (
	"bytes"
	"context"
	"encoding/json"
	"log"
	"net/http"
	"os/exec"
	"regexp"
	"strings"
	"time"
)

// gitCommitRequest is the body for POST /api/session/{id}/git/commit.
type gitCommitRequest struct {
	Message string `json:"message"`
	Push    bool   `json:"push"`
}

// gitCommitResponse is the success/failure envelope for git/commit.
//
// Wire contract:
//
//	ok=true:  {"ok":true,"stdout":"...","stderr":"...","commit_sha":"abc123"}
//	ok=false: {"ok":false,"stdout":"...","stderr":"..."}
type gitCommitResponse struct {
	OK        bool   `json:"ok"`
	Stdout    string `json:"stdout"`
	Stderr    string `json:"stderr"`
	CommitSHA string `json:"commit_sha,omitempty"`
}

// gitPRRequest is the body for POST /api/session/{id}/git/pr.
type gitPRRequest struct {
	Title string `json:"title"`
	Body  string `json:"body"`
}

// gitPRResponse is the success/failure envelope for git/pr.
//
// Wire contract:
//
//	ok=true:  {"ok":true,"pr_url":"https://github.com/..."}
//	ok=false: {"ok":false,"stderr":"..."}
type gitPRResponse struct {
	OK     bool   `json:"ok"`
	PRURL  string `json:"pr_url,omitempty"`
	Stderr string `json:"stderr,omitempty"`
}

// reGitCommitLine matches the `git commit` summary line, e.g.:
//
//	[main abc1234] My commit message
var reGitCommitLine = regexp.MustCompile(`\[.*?([0-9a-f]{7,})\]`)

// serveSessionGitCommit handles POST /api/session/{id}/git/commit.
//
// Wire contract:
//
//	POST /api/session/{id}/git/commit
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"message":"commit message","push":true}
//
//	200 {"ok":true,"stdout":"...","stderr":"...","commit_sha":"abc123"}
//	200 {"ok":false,"stdout":"...","stderr":"..."}   — git failed (non-2xx would be confusing; callers key on ok)
//	400 {"error":"invalid_request","message":"…"}   — bad body / empty message
//	401 {"error":"auth_expired","message":"…"}
//	404 {"error":"session_not_found","message":"…"} — unknown session id
func (s *Server) serveSessionGitCommit(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req gitCommitRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Message = strings.TrimSpace(req.Message)
	if req.Message == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "message is required")
		return
	}

	sess, ok := s.Sessions.Get(sessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "session_not_found", "session not found: "+sessionID)
		return
	}
	workdir := sess.WorkspaceDir()
	if workdir == "" {
		log.Printf("git/commit: session %s has empty workdir", sessionID)
		writeAPIError(w, http.StatusBadRequest, "invalid_session", "session has no working directory")
		return
	}

	log.Printf("git/commit: session=%s workdir=%s push=%v", sessionID, workdir, req.Push)

	// Step 1: git add -A
	addOut, addErr, ok2 := runShellCmd(r.Context(), workdir, "git", "add", "-A")
	if !ok2 {
		log.Printf("git/commit: git add -A failed in %s: %s", workdir, addErr)
		writeJSON(w, http.StatusOK, gitCommitResponse{
			OK:     false,
			Stdout: addOut,
			Stderr: addErr,
		})
		return
	}

	// Step 2: git commit -m "$message"
	commitOut, commitErr, ok3 := runShellCmd(r.Context(), workdir, "git", "commit", "-m", req.Message)
	if !ok3 {
		log.Printf("git/commit: git commit failed in %s: %s", workdir, commitErr)
		writeJSON(w, http.StatusOK, gitCommitResponse{
			OK:     false,
			Stdout: addOut + commitOut,
			Stderr: commitErr,
		})
		return
	}

	// Extract the short commit SHA from the commit output line.
	sha := extractCommitSHA(commitOut)
	if sha == "" {
		// Fallback: ask git directly.
		if revOut, _, ok4 := runShellCmd(r.Context(), workdir, "git", "rev-parse", "--short", "HEAD"); ok4 {
			sha = strings.TrimSpace(revOut)
		}
	}

	combinedOut := addOut + commitOut
	combinedErr := commitErr

	// Step 3 (optional): git push
	if req.Push {
		pushOut, pushErr, ok5 := runShellCmd(r.Context(), workdir, "git", "push")
		combinedOut += pushOut
		combinedErr += pushErr
		if !ok5 {
			log.Printf("git/commit: git push failed in %s: %s", workdir, pushErr)
			writeJSON(w, http.StatusOK, gitCommitResponse{
				OK:        false,
				Stdout:    combinedOut,
				Stderr:    combinedErr,
				CommitSHA: sha, // commit succeeded even if push failed
			})
			return
		}
	}

	log.Printf("git/commit: success session=%s sha=%s push=%v", sessionID, sha, req.Push)
	writeJSON(w, http.StatusOK, gitCommitResponse{
		OK:        true,
		Stdout:    combinedOut,
		Stderr:    combinedErr,
		CommitSHA: sha,
	})
}

// serveSessionGitPR handles POST /api/session/{id}/git/pr.
//
// Wire contract:
//
//	POST /api/session/{id}/git/pr
//	Authorization: Bearer <token>   (or ?token=<token>)
//	{"title":"PR title","body":"optional description"}
//
//	200 {"ok":true,"pr_url":"https://github.com/…"}
//	200 {"ok":false,"stderr":"…"}                    — gh failed
//	400 {"error":"invalid_request","message":"…"}   — bad body / empty title
//	401 {"error":"auth_expired","message":"…"}
//	404 {"error":"session_not_found","message":"…"} — unknown session id
func (s *Server) serveSessionGitPR(w http.ResponseWriter, r *http.Request, sessionID string) {
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method_not_allowed", "POST required")
		return
	}
	var req gitPRRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "invalid JSON body")
		return
	}
	req.Title = strings.TrimSpace(req.Title)
	if req.Title == "" {
		writeAPIError(w, http.StatusBadRequest, "invalid_request", "title is required")
		return
	}

	sess, ok := s.Sessions.Get(sessionID)
	if !ok {
		writeAPIError(w, http.StatusNotFound, "session_not_found", "session not found: "+sessionID)
		return
	}
	workdir := sess.WorkspaceDir()
	if workdir == "" {
		log.Printf("git/pr: session %s has empty workdir", sessionID)
		writeAPIError(w, http.StatusBadRequest, "invalid_session", "session has no working directory")
		return
	}

	log.Printf("git/pr: session=%s workdir=%s title=%q", sessionID, workdir, req.Title)

	args := []string{"pr", "create", "--title", req.Title, "--body", req.Body}
	prOut, prErr, ok2 := runShellCmd(r.Context(), workdir, "gh", args...)
	if !ok2 {
		log.Printf("git/pr: gh pr create failed in %s: %s", workdir, prErr)
		writeJSON(w, http.StatusOK, gitPRResponse{
			OK:     false,
			Stderr: prErr,
		})
		return
	}

	// `gh pr create` prints the PR URL as the last line of stdout.
	prURL := extractPRURL(prOut)
	log.Printf("git/pr: success session=%s url=%s", sessionID, prURL)
	writeJSON(w, http.StatusOK, gitPRResponse{
		OK:    true,
		PRURL: prURL,
	})
}

// runShellCmd executes cmd with args in dir, capturing stdout and stderr
// separately. It returns (stdout, stderr, exitOK). A 30-second timeout
// is enforced; context cancellation is respected. The command never
// inherits the broker's stdin.
func runShellCmd(ctx context.Context, dir string, name string, args ...string) (stdout, stderr string, ok bool) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Dir = dir

	var outBuf, errBuf bytes.Buffer
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf

	err := cmd.Run()
	stdout = outBuf.String()
	stderr = errBuf.String()
	ok = err == nil
	return stdout, stderr, ok
}

// extractCommitSHA parses the short SHA out of a `git commit` output line
// like `[main abc1234] commit message`. Returns "" when no match.
func extractCommitSHA(out string) string {
	m := reGitCommitLine.FindStringSubmatch(out)
	if len(m) < 2 {
		return ""
	}
	return m[1]
}

// extractPRURL extracts the GitHub PR URL from `gh pr create` stdout.
// `gh pr create` outputs one line: the URL of the new PR.
// Returns the trimmed last non-empty line, which is the URL.
func extractPRURL(out string) string {
	lines := strings.Split(strings.TrimSpace(out), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		if l := strings.TrimSpace(lines[i]); l != "" {
			return l
		}
	}
	return strings.TrimSpace(out)
}
