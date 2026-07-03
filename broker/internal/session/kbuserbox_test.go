package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/nikhilsh/conduit/broker/internal/kb"
)

// TestKBSectionFlagOffUnchanged verifies that with the experimental flag OFF
// (the default), a workspace containing ONLY existing docs (README, no tracked
// knowledge/INDEX.md) produces NO KB section and NO .conduit/ writes — exactly
// Phase 1/2 behavior.
func TestKBSectionFlagOffUnchanged(t *testing.T) {
	t.Setenv(kb.ExperimentalEnv, "") // OFF

	ws := t.TempDir()
	if err := os.WriteFile(filepath.Join(ws, "README.md"), []byte("# Proj\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	section, ok := kbSection(ws)
	if ok {
		t.Errorf("flag OFF: kbSection should be false with no tracked knowledge/INDEX.md; got %q", section)
	}
	// No box-local writes, no ingest.
	if _, err := os.Stat(filepath.Join(ws, ".conduit")); err == nil {
		t.Error("flag OFF: .conduit/ must not be created")
	}
	idx, ok := kbWorkspaceIndex(ws)
	if ok {
		t.Errorf("flag OFF: kbWorkspaceIndex should be false; got %q", idx)
	}
}

// TestKBSectionFlagOnIngestsAndSpans verifies that with the flag ON, a repo
// with only existing docs (no tracked knowledge/) becomes KB-active: the
// section is injected, registered-source pointers appear, and the source bytes
// are untouched.
func TestKBSectionFlagOnIngestsAndSpans(t *testing.T) {
	t.Setenv(kb.ExperimentalEnv, "1") // ON

	ws := t.TempDir()
	readme := "# My App\n\nThe app.\n"
	if err := os.WriteFile(filepath.Join(ws, "README.md"), []byte(readme), 0o644); err != nil {
		t.Fatal(err)
	}

	section, ok := kbSection(ws)
	if !ok {
		t.Fatal("flag ON: kbSection should be active when an ingestable doc exists")
	}
	// The section is now pointer-only — it does NOT embed the merged index
	// content (which would have contained README.md). Verify the section
	// tells the agent to search/read, not that it contains the file name.
	if strings.Contains(section, "README.md") {
		t.Errorf("flag ON: section must NOT embed index content (pointer-only); got:\n%s", section)
	}
	if !strings.Contains(section, "kb search") {
		t.Errorf("flag ON: section should advertise kb search; got:\n%s", section)
	}
	if !strings.Contains(section, "source-pointer") {
		t.Errorf("flag ON: merged index should label origins; got:\n%s", section)
	}
	if !strings.Contains(section, "kb promote") {
		t.Errorf("flag ON: section should advertise kb promote; got:\n%s", section)
	}
	// Source untouched.
	got, _ := os.ReadFile(filepath.Join(ws, "README.md"))
	if string(got) != readme {
		t.Error("flag ON: README.md was modified by ingest")
	}
	// gitignore in place so box-local is never committed.
	if _, err := os.Stat(filepath.Join(ws, ".conduit", ".gitignore")); err != nil {
		t.Errorf("flag ON: expected .conduit/.gitignore: %v", err)
	}

	// Per-turn relevance hook also spans sources when ON.
	idx, ok := kbWorkspaceIndex(ws)
	if !ok || !strings.Contains(idx, "README.md") {
		t.Errorf("flag ON: kbWorkspaceIndex should include the pointer; ok=%v idx=%q", ok, idx)
	}
}
