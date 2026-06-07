package session

import (
	"path/filepath"
	"testing"
)

// Uploads must live outside the agent's git worktree (UploadBaseDir ==
// sessionDir), and the agent-facing copy of a composer message must point at
// that absolute path — otherwise a relative `uploads/...` resolves into the
// worktree where the bytes were deliberately not written (and where git
// hygiene would wipe them anyway). See the "uploaded image can't be read" bug.
func TestUploadBaseDirIsSessionDir(t *testing.T) {
	s := &Session{ID: "sid-1", sessionDir: "/root/.conduit/sessions/sid-1"}
	if got := s.UploadBaseDir(); got != "/root/.conduit/sessions/sid-1" {
		t.Fatalf("UploadBaseDir = %q, want session dir", got)
	}
	s2 := &Session{ID: "sid-2", workspaceDir: "/work"}
	if got := s2.UploadBaseDir(); got != "/work" {
		t.Fatalf("UploadBaseDir fallback = %q, want workspace", got)
	}
}

func TestRewriteUploadRefs(t *testing.T) {
	s := &Session{ID: "sid-1", sessionDir: "/root/.conduit/sessions/sid-1"}
	want := filepath.Join("/root/.conduit/sessions/sid-1", "uploads", "sid-1") + "/"
	cases := []struct {
		name string
		in   string
		out  string
	}{
		{"image reference line",
			"look at this [attached image: a.png — uploads/sid-1/a.png]",
			"look at this [attached image: a.png — " + want + "a.png]"},
		{"multiple refs in one message",
			"uploads/sid-1/a.png and uploads/sid-1/b.png",
			want + "a.png and " + want + "b.png"},
		{"no refs is untouched", "just a plain message", "just a plain message"},
		{"other session prefix not rewritten", "uploads/other/a.png", "uploads/other/a.png"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := s.RewriteUploadRefs(tc.in); got != tc.out {
				t.Fatalf("RewriteUploadRefs(%q) = %q, want %q", tc.in, got, tc.out)
			}
		})
	}
}
