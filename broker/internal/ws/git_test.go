package ws

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func apiPost(t *testing.T, srv *httptest.Server, tok, path, body string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodPost, srv.URL+path+sep(path)+"token="+url.QueryEscape(tok),
		strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("POST %s: %v", path, err)
	}
	return resp
}

func TestServeSessionGitStageUnstage(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\nstage me\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	newGitSession(t, m, "sess-stage", dir)

	resp := apiPost(t, srv, tok, "/api/session/sess-stage/git/stage", `{"paths":["README.md"]}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("stage status = %d", resp.StatusCode)
	}
	var body gitOKResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.OK {
		t.Fatalf("stage failed: %+v", body)
	}
	staged := strings.TrimSpace(mustGit(t, dir, "diff", "--cached", "--name-only"))
	if staged != "README.md" {
		t.Fatalf("staged files = %q, want README.md", staged)
	}

	resp2 := apiPost(t, srv, tok, "/api/session/sess-stage/git/unstage", `{"paths":["README.md"]}`)
	defer resp2.Body.Close()
	var body2 gitOKResponse
	if err := json.NewDecoder(resp2.Body).Decode(&body2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body2.OK {
		t.Fatalf("unstage failed: %+v", body2)
	}
	staged2 := strings.TrimSpace(mustGit(t, dir, "diff", "--cached", "--name-only"))
	if staged2 != "" {
		t.Fatalf("staged files after unstage = %q, want empty", staged2)
	}
}

func TestServeSessionGitStageValidation(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	newGitSession(t, m, "sess-stage-invalid", dir)

	// missing paths -> 400 invalid_request
	resp := apiPost(t, srv, tok, "/api/session/sess-stage-invalid/git/stage", `{"paths":[]}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("empty paths status = %d, want 400", resp.StatusCode)
	}

	// absolute path -> 400 invalid_path
	resp2 := apiPost(t, srv, tok, "/api/session/sess-stage-invalid/git/stage", `{"paths":["/etc/passwd"]}`)
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusBadRequest {
		t.Fatalf("absolute path status = %d, want 400", resp2.StatusCode)
	}
	var body2 apiErrorEnvelope
	if err := json.NewDecoder(resp2.Body).Decode(&body2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if body2.Error.Code != "invalid_path" {
		t.Fatalf("error code = %q, want invalid_path", body2.Error.Code)
	}

	// ..-escaping path -> 400 invalid_path
	resp3 := apiPost(t, srv, tok, "/api/session/sess-stage-invalid/git/stage", `{"paths":["../outside.txt"]}`)
	defer resp3.Body.Close()
	if resp3.StatusCode != http.StatusBadRequest {
		t.Fatalf("escaping path status = %d, want 400", resp3.StatusCode)
	}
}

func TestServeSessionGitCommitStagedOnly(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "staged.txt"), []byte("staged content\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "unstaged.txt"), []byte("unstaged content\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "staged.txt")
	newGitSession(t, m, "sess-commit-staged", dir)

	resp := apiPost(t, srv, tok, "/api/session/sess-commit-staged/git/commit",
		`{"message":"staged only","all":false}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body gitCommitResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.OK || body.CommitSHA == "" {
		t.Fatalf("commit failed: %+v", body)
	}

	// unstaged.txt must still be untracked (never added).
	status := mustGit(t, dir, "status", "--porcelain")
	if !strings.Contains(status, "?? unstaged.txt") {
		t.Fatalf("expected unstaged.txt to remain untracked, status:\n%s", status)
	}
	log := mustGit(t, dir, "show", "--stat", "HEAD")
	if !strings.Contains(log, "staged.txt") || strings.Contains(log, "unstaged.txt") {
		t.Fatalf("commit contents wrong, HEAD show --stat:\n%s", log)
	}
}

func TestServeSessionGitCommitAllDefault(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "everything.txt"), []byte("untracked\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	newGitSession(t, m, "sess-commit-all", dir)

	// `all` omitted entirely -> back-compat add -A + commit.
	resp := apiPost(t, srv, tok, "/api/session/sess-commit-all/git/commit", `{"message":"commit everything"}`)
	defer resp.Body.Close()
	var body gitCommitResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.OK {
		t.Fatalf("commit failed: %+v", body)
	}
	status := strings.TrimSpace(mustGit(t, dir, "status", "--porcelain"))
	if status != "" {
		t.Fatalf("expected clean tree after all:true commit, status:\n%s", status)
	}
}

func TestServeSessionGitPush(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)

	// Bare remote to push against.
	remoteDir := t.TempDir()
	mustGit(t, remoteDir, "init", "-q", "--bare")
	mustGit(t, dir, "remote", "add", "origin", remoteDir)

	newGitSession(t, m, "sess-push", dir)

	resp := apiPost(t, srv, tok, "/api/session/sess-push/git/push", `{}`)
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body gitPushResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.OK {
		t.Fatalf("push failed: %+v", body)
	}
	if !body.SetUpstream {
		t.Fatalf("expected set_upstream=true on first push, got %+v", body)
	}
	if body.Branch != "main" {
		t.Fatalf("branch = %q, want main", body.Branch)
	}

	// Second push: upstream now exists -> plain push, set_upstream=false.
	if err := os.WriteFile(filepath.Join(dir, "more.txt"), []byte("more\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "-A")
	mustGit(t, dir, "commit", "-q", "-m", "more")

	resp2 := apiPost(t, srv, tok, "/api/session/sess-push/git/push", `{}`)
	defer resp2.Body.Close()
	var body2 gitPushResponse
	if err := json.NewDecoder(resp2.Body).Decode(&body2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body2.OK {
		t.Fatalf("second push failed: %+v", body2)
	}
	if body2.SetUpstream {
		t.Fatalf("expected set_upstream=false on second push, got %+v", body2)
	}
}
