package session

import (
	"testing"
)

// TestParseLeftRight covers the `git rev-list --left-right --count` parser.
func TestParseLeftRight(t *testing.T) {
	tests := []struct {
		input      string
		wantBehind uint32
		wantAhead  uint32
	}{
		{"3\t2", 3, 2},
		{"0\t0", 0, 0},
		{"1\t0", 1, 0},
		{"0\t5", 0, 5},
		{"10\t7", 10, 7},
		// malformed inputs must not panic
		{"", 0, 0},
		{"\t", 0, 0},
		{"abc\t2", 0, 0},
		{"3\tabc", 0, 0},
		{"3", 0, 0},
	}
	for _, tc := range tests {
		behind, ahead := parseLeftRight(tc.input)
		if behind != tc.wantBehind || ahead != tc.wantAhead {
			t.Errorf("parseLeftRight(%q) = (%d, %d), want (%d, %d)",
				tc.input, behind, ahead, tc.wantBehind, tc.wantAhead)
		}
	}
}

// TestPorcelainDirtyCount verifies that dirty count counts non-empty lines
// from `git status --porcelain` output.
func TestPorcelainDirtyCount(t *testing.T) {
	// Simulate what computeGitState does with the porcelain output.
	count := func(out string) uint32 {
		lines := 0
		for _, line := range splitLines(out) {
			if line != "" {
				lines++
			}
		}
		return uint32(lines)
	}
	// 3 modified lines
	porcelain := " M broker/foo.go\n M broker/bar.go\n?? broker/baz.go\n"
	if got := count(porcelain); got != 3 {
		t.Errorf("count(%q) = %d, want 3", porcelain, got)
	}
	// empty output = clean working tree
	if got := count(""); got != 0 {
		t.Errorf("count(\"\") = %d, want 0", got)
	}
	// trailing newline only
	if got := count("\n"); got != 0 {
		t.Errorf("count(\\n) = %d, want 0", got)
	}
}

// splitLines is the same logic used inside computeGitState.
func splitLines(s string) []string {
	var out []string
	for _, line := range splitNL(s) {
		out = append(out, trimSpace(line))
	}
	return out
}

func splitNL(s string) []string {
	var parts []string
	start := 0
	for i := 0; i < len(s); i++ {
		if s[i] == '\n' {
			parts = append(parts, s[start:i])
			start = i + 1
		}
	}
	parts = append(parts, s[start:])
	return parts
}

func trimSpace(s string) string {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r') {
		i++
	}
	j := len(s)
	for j > i && (s[j-1] == ' ' || s[j-1] == '\t' || s[j-1] == '\r') {
		j--
	}
	return s[i:j]
}

// TestComputeGitStateNonRepo verifies that a non-git directory returns zero
// values without panicking.
func TestComputeGitStateNonRepo(t *testing.T) {
	dir := t.TempDir() // plain dir, not a git repo
	gs := computeGitState(dir, "")
	if gs.Branch != "" || gs.Dirty != 0 || gs.Ahead != 0 || gs.Behind != 0 || gs.WorktreeName != "" {
		t.Errorf("non-git dir returned non-zero GitState: %+v", gs)
	}
}

// TestComputeGitStateEmptyDir verifies that an empty dir returns zero values.
func TestComputeGitStateEmptyDir(t *testing.T) {
	gs := computeGitState("", "")
	if gs.Branch != "" {
		t.Errorf("empty dir: expected empty Branch, got %q", gs.Branch)
	}
}

// TestComputeGitStateLiveRepo exercises computeGitState against a real local
// git repository so we know the branch + dirty round-trip end-to-end.
func TestComputeGitStateLiveRepo(t *testing.T) {
	repo := t.TempDir()
	initRepoWithCommit(t, repo) // helper from worktree_test.go (same package)

	gs := computeGitState(repo, "")
	if gs.Branch == "" {
		t.Error("expected a branch name, got empty string")
	}
	if gs.Dirty != 0 {
		t.Errorf("clean repo: expected Dirty=0, got %d", gs.Dirty)
	}

	// Introduce an uncommitted change and verify Dirty > 0.
	writeWIPFile(t, repo, "newfile.txt", "hello\n")
	gs2 := computeGitState(repo, "wt-test")
	if gs2.Dirty == 0 {
		t.Error("dirty repo: expected Dirty>0 after untracked file, got 0")
	}
	if gs2.WorktreeName != "wt-test" {
		t.Errorf("WorktreeName: got %q, want \"wt-test\"", gs2.WorktreeName)
	}
}
