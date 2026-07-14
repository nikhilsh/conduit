package ws

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// --- test repo helpers -----------------------------------------------------

// mustGit runs `git -C dir <args...>` and fails the test on error, returning
// combined stdout.
func mustGit(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v in %s: %v\n%s", args, dir, err, out)
	}
	return string(out)
}

// newGitRepo creates a temp dir, initializes a git repo on branch "main"
// with a local identity configured, and an initial commit so HEAD exists.
func newGitRepo(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	mustGit(t, dir, "init", "-q", "-b", "main")
	mustGit(t, dir, "config", "user.email", "test@example.com")
	mustGit(t, dir, "config", "user.name", "Test")
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\n"), 0o644); err != nil {
		t.Fatalf("seed README: %v", err)
	}
	mustGit(t, dir, "add", "-A")
	mustGit(t, dir, "commit", "-q", "-m", "initial commit")
	return dir
}

// newGitTestServer mirrors newTestServer but also returns the Manager so
// tests can create sessions rooted at a specific (git repo) directory. It
// isolates the session store under a per-test CONDUIT_ROOT so fixed literal
// session IDs (e.g. "sess-diff-endpoint") used across test runs never
// collide with a stale on-disk session dir from a prior `go test` run —
// without this, NewManager walks up from cwd to the repo's real .conduit/
// and recoverSessionLocked resurrects old state instead of creating fresh.
func newGitTestServer(t *testing.T) (*httptest.Server, string, *session.Manager) {
	t.Helper()
	root := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, ".conduit"), 0o755); err != nil {
		t.Fatalf("MkdirAll(.conduit): %v", err)
	}
	t.Setenv("CONDUIT_ROOT", filepath.Join(root, ".conduit"))
	a := auth.NewStore()
	tok := a.Mint()
	reg := newTestRegistry(t)
	m := session.NewManager(reg)
	srv := httptest.NewServer(New(a, m).Handler())
	t.Cleanup(func() { srv.Close(); m.Close() })
	return srv, tok, m
}

// newGitSession creates a live session (backed by the `cat` test adapter)
// rooted at dir, so sess.WorkspaceDir() / sess.LiveGitDir() resolve to dir.
func newGitSession(t *testing.T, m *session.Manager, id, dir string) *session.Session {
	t.Helper()
	sess, _, err := m.GetOrCreateWithOptions(id, "claude", session.CreateOptions{CWD: dir})
	if err != nil {
		t.Fatalf("GetOrCreateWithOptions(%s): %v", id, err)
	}
	return sess
}

func apiGet(t *testing.T, srv *httptest.Server, tok, path string) *http.Response {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, srv.URL+path+sep(path)+"token="+url.QueryEscape(tok), nil)
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET %s: %v", path, err)
	}
	return resp
}

func sep(path string) string {
	if strings.Contains(path, "?") {
		return "&"
	}
	return "?"
}

// --- parser tests ------------------------------------------------------

func TestParseUnifiedDiffModified(t *testing.T) {
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\nworld\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")

	files := parseUnifiedDiff(raw, map[string]bool{})
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(files), files)
	}
	f := files[0]
	if f.Path != "README.md" || f.Status != "modified" || f.Binary {
		t.Fatalf("unexpected file: %+v", f)
	}
	if f.Staged {
		t.Fatalf("unstaged change reported staged=true")
	}
	if f.Additions != 1 {
		t.Fatalf("additions = %d, want 1", f.Additions)
	}
	if len(f.Hunks) != 1 {
		t.Fatalf("expected 1 hunk, got %d", len(f.Hunks))
	}
}

func TestParseUnifiedDiffAdded(t *testing.T) {
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "new.txt"), []byte("brand new\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "new.txt")
	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")

	stagedSet := map[string]bool{"new.txt": true}
	files := parseUnifiedDiff(raw, stagedSet)
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(files), files)
	}
	f := files[0]
	if f.Status != "added" {
		t.Fatalf("status = %q, want added", f.Status)
	}
	if !f.Staged {
		t.Fatalf("staged add reported staged=false")
	}
	if f.Additions != 1 || f.Deletions != 0 {
		t.Fatalf("additions/deletions = %d/%d, want 1/0", f.Additions, f.Deletions)
	}
}

func TestParseUnifiedDiffDeleted(t *testing.T) {
	dir := newGitRepo(t)
	if err := os.Remove(filepath.Join(dir, "README.md")); err != nil {
		t.Fatalf("remove: %v", err)
	}
	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")

	files := parseUnifiedDiff(raw, map[string]bool{})
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(files), files)
	}
	f := files[0]
	if f.Status != "deleted" || f.Path != "README.md" {
		t.Fatalf("unexpected file: %+v", f)
	}
	if f.Deletions != 1 {
		t.Fatalf("deletions = %d, want 1", f.Deletions)
	}
}

func TestParseUnifiedDiffRenamed(t *testing.T) {
	dir := newGitRepo(t)
	mustGit(t, dir, "mv", "README.md", "RENAMED.md")
	// `git mv` stages the rename; git diff HEAD detects it by default (no -M
	// needed) — same command shape production uses for scope=uncommitted.
	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")

	files := parseUnifiedDiff(raw, map[string]bool{"RENAMED.md": true})
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(files), files)
	}
	f := files[0]
	if f.Status != "renamed" {
		t.Fatalf("status = %q, want renamed (%+v)", f.Status, f)
	}
	if f.OldPath != "README.md" || f.Path != "RENAMED.md" {
		t.Fatalf("old_path/path = %q/%q, want README.md/RENAMED.md", f.OldPath, f.Path)
	}
}

func TestParseUnifiedDiffBinary(t *testing.T) {
	dir := newGitRepo(t)
	blob := []byte{0x00, 0x01, 0x02, 0xff, 0xfe, 0x00, 0x10, 0x20}
	if err := os.WriteFile(filepath.Join(dir, "blob.bin"), blob, 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "blob.bin")
	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")

	files := parseUnifiedDiff(raw, map[string]bool{"blob.bin": true})
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d: %+v", len(files), files)
	}
	f := files[0]
	if !f.Binary {
		t.Fatalf("expected binary=true: %+v", f)
	}
	if len(f.Hunks) != 0 {
		t.Fatalf("binary file should have no hunks, got %d", len(f.Hunks))
	}
}

func TestUntrackedDiffFile(t *testing.T) {
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "scratch.txt"), []byte("line1\nline2\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	f := untrackedDiffFile(context.Background(), dir, "scratch.txt", 3)
	if f.Status != "untracked" || f.Path != "scratch.txt" {
		t.Fatalf("unexpected file: %+v", f)
	}
	if f.Additions != 2 || f.Deletions != 0 {
		t.Fatalf("additions/deletions = %d/%d, want 2/0", f.Additions, f.Deletions)
	}
	if f.Staged {
		t.Fatalf("untracked file must never report staged=true")
	}
}

// TestParseUnifiedDiffTruncation builds a file with many well-separated
// single-line edits (so each becomes its own hunk) whose cumulative line
// count exceeds maxDiffLinesPerFile, and asserts the per-file cap drops
// later hunks and sets truncated=true.
func TestParseUnifiedDiffTruncation(t *testing.T) {
	dir := newGitRepo(t)
	const blocks = 300
	const blockLines = 20
	var b strings.Builder
	for i := 0; i < blocks; i++ {
		for j := 0; j < blockLines; j++ {
			fmt.Fprintf(&b, "block%d-line%d\n", i, j)
		}
	}
	path := filepath.Join(dir, "big.txt")
	if err := os.WriteFile(path, []byte(b.String()), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "big.txt")
	mustGit(t, dir, "commit", "-q", "-m", "seed big file")

	// Modify the middle line of every block — far enough apart (given
	// context=3) that each edit stays its own hunk.
	lines := strings.Split(strings.TrimRight(b.String(), "\n"), "\n")
	for i := 0; i < blocks; i++ {
		idx := i*blockLines + blockLines/2
		lines[idx] = lines[idx] + "-EDITED"
	}
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatalf("rewrite: %v", err)
	}

	raw := mustGit(t, dir, "diff", "--no-color", "-U3", "HEAD")
	files := parseUnifiedDiff(raw, map[string]bool{})
	if len(files) != 1 {
		t.Fatalf("expected 1 file, got %d", len(files))
	}
	f := files[0]
	if !f.Truncated {
		t.Fatalf("expected truncated=true for a %d-block diff", blocks)
	}
	if len(f.Hunks) == 0 || len(f.Hunks) >= blocks {
		t.Fatalf("expected some but not all hunks kept, got %d of %d", len(f.Hunks), blocks)
	}
	totalKeptLines := 0
	for _, h := range f.Hunks {
		totalKeptLines += len(h.Lines)
	}
	if totalKeptLines > maxDiffLinesPerFile+50 { // small slack: cap breaks between whole hunks
		t.Fatalf("kept %d lines, want roughly <= %d (hunk-granular cap)", totalKeptLines, maxDiffLinesPerFile)
	}
}

// --- buildGitDiffResponse (both scopes) --------------------------------

func TestBuildGitDiffResponseUncommittedScope(t *testing.T) {
	dir := newGitRepo(t)
	// unstaged modification
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\nmodified\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	// staged addition
	if err := os.WriteFile(filepath.Join(dir, "staged.txt"), []byte("staged content\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "staged.txt")
	// untracked file
	if err := os.WriteFile(filepath.Join(dir, "untracked.txt"), []byte("untracked content\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}

	resp := buildGitDiffResponse(context.Background(), dir, "uncommitted", 3)
	if resp.Scope != "uncommitted" {
		t.Fatalf("scope = %q", resp.Scope)
	}
	if resp.Base != "" {
		t.Fatalf("base should be empty for uncommitted scope, got %q", resp.Base)
	}
	byPath := map[string]gitDiffFile{}
	for _, f := range resp.Files {
		byPath[f.Path] = f
	}
	if f, ok := byPath["README.md"]; !ok || f.Status != "modified" || f.Staged {
		t.Fatalf("README.md entry wrong: %+v (ok=%v)", f, ok)
	}
	if f, ok := byPath["staged.txt"]; !ok || f.Status != "added" || !f.Staged {
		t.Fatalf("staged.txt entry wrong: %+v (ok=%v)", f, ok)
	}
	if f, ok := byPath["untracked.txt"]; !ok || f.Status != "untracked" || f.Staged {
		t.Fatalf("untracked.txt entry wrong: %+v (ok=%v)", f, ok)
	}
	if resp.Diffstat.FilesChanged != 3 {
		t.Fatalf("diffstat.files_changed = %d, want 3", resp.Diffstat.FilesChanged)
	}
}

func TestBuildGitDiffResponseBranchScope(t *testing.T) {
	dir := newGitRepo(t)
	mustGit(t, dir, "checkout", "-q", "-b", "feature")
	if err := os.WriteFile(filepath.Join(dir, "feature.txt"), []byte("feature work\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	mustGit(t, dir, "add", "feature.txt")
	mustGit(t, dir, "commit", "-q", "-m", "feature commit")

	resp := buildGitDiffResponse(context.Background(), dir, "branch", 3)
	if resp.Scope != "branch" {
		t.Fatalf("scope = %q", resp.Scope)
	}
	if resp.Base != "main" {
		t.Fatalf("base = %q, want main (no origin remote configured)", resp.Base)
	}
	if resp.DefaultBranch != "main" {
		t.Fatalf("default_branch = %q, want main", resp.DefaultBranch)
	}
	found := false
	for _, f := range resp.Files {
		if f.Path == "feature.txt" && f.Status == "added" {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected feature.txt (added) in branch diff, got %+v", resp.Files)
	}
}

// --- HTTP endpoint tests -------------------------------------------------

func TestServeSessionGitDiffEndpoint(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	if err := os.WriteFile(filepath.Join(dir, "README.md"), []byte("hello\nendpoint test\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	newGitSession(t, m, "sess-diff-endpoint", dir)

	resp := apiGet(t, srv, tok, "/api/session/sess-diff-endpoint/git/diff")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body gitDiffResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body.Files) != 1 || body.Files[0].Path != "README.md" {
		t.Fatalf("unexpected files: %+v", body.Files)
	}

	// bad scope -> 400
	resp2 := apiGet(t, srv, tok, "/api/session/sess-diff-endpoint/git/diff?scope=bogus")
	defer resp2.Body.Close()
	if resp2.StatusCode != http.StatusBadRequest {
		t.Fatalf("bad scope status = %d, want 400", resp2.StatusCode)
	}

	// unknown session -> 404
	resp3 := apiGet(t, srv, tok, "/api/session/does-not-exist/git/diff")
	defer resp3.Body.Close()
	if resp3.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown session status = %d, want 404", resp3.StatusCode)
	}

	// non-git dir -> 409
	plainDir := t.TempDir()
	newGitSession(t, m, "sess-diff-nongit", plainDir)
	resp4 := apiGet(t, srv, tok, "/api/session/sess-diff-nongit/git/diff")
	defer resp4.Body.Close()
	if resp4.StatusCode != http.StatusConflict {
		t.Fatalf("non-git status = %d, want 409", resp4.StatusCode)
	}
}

func TestServeSessionGitStateEndpoint(t *testing.T) {
	srv, tok, m := newGitTestServer(t)
	dir := newGitRepo(t)
	newGitSession(t, m, "sess-state-git", dir)

	resp := apiGet(t, srv, tok, "/api/session/sess-state-git/git/state")
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("status = %d", resp.StatusCode)
	}
	var body gitStateResponse
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.IsGitRepo {
		t.Fatalf("is_git_repo = false, want true")
	}
	if body.Branch != "main" {
		t.Fatalf("branch = %q, want main", body.Branch)
	}
	if body.DefaultBranch != "main" {
		t.Fatalf("default_branch = %q, want main", body.DefaultBranch)
	}

	plainDir := t.TempDir()
	newGitSession(t, m, "sess-state-nongit", plainDir)
	resp2 := apiGet(t, srv, tok, "/api/session/sess-state-nongit/git/state")
	defer resp2.Body.Close()
	var body2 map[string]any
	if err := json.NewDecoder(resp2.Body).Decode(&body2); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if len(body2) != 1 || body2["is_git_repo"] != false {
		t.Fatalf("non-repo state = %+v, want exactly {is_git_repo:false}", body2)
	}
}

func TestCapabilitiesIncludesReviewShip(t *testing.T) {
	srv, tok := newTestServer(t)
	resp := apiGet(t, srv, tok, "/api/capabilities")
	defer resp.Body.Close()
	var body struct {
		Features struct {
			ReviewShip bool `json:"review_ship"`
		} `json:"features"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&body); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if !body.Features.ReviewShip {
		t.Fatalf("features.review_ship = false, want true")
	}
}
