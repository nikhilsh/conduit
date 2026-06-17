package kb

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestExperimentalEnabled pins the flag's truthiness (default OFF).
func TestExperimentalEnabled(t *testing.T) {
	t.Setenv(ExperimentalEnv, "")
	if ExperimentalEnabled() {
		t.Fatal("empty env should be OFF")
	}
	for _, v := range []string{"0", "false", "no", "off", "nonsense"} {
		t.Setenv(ExperimentalEnv, v)
		if ExperimentalEnabled() {
			t.Errorf("%q should be OFF", v)
		}
	}
	for _, v := range []string{"1", "true", "yes", "on", "ENABLED"} {
		t.Setenv(ExperimentalEnv, v)
		if !ExperimentalEnabled() {
			t.Errorf("%q should be ON", v)
		}
	}
}

// TestSummarizeFirstLine pins the pure summary extractor.
func TestSummarizeFirstLine(t *testing.T) {
	cases := []struct{ in, want string }{
		{"# Title Here\n\nbody", "Title Here"},
		{"## Second level\n", "Second level"},
		{"no heading here\nmore", "no heading here"},
		{"\n\n   \n# After blanks", "After blanks"},
		{"---\ntitle: x\ntags: [a]\n---\n# Real Heading\n", "Real Heading"},
		{"---\ntitle: x\n---\nfirst body line", "first body line"},
		{"<!-- a comment -->\nactual line", "actual line"},
		{"", "(no summary)"},
		{"#\n#  \nplain", "plain"},
	}
	for _, c := range cases {
		if got := SummarizeFirstLine(c.in); got != c.want {
			t.Errorf("SummarizeFirstLine(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// TestMergeOrigins pins origin labeling and ordering.
func TestMergeOrigins(t *testing.T) {
	tracked := []IndexLine{{Slug: "t1", Summary: "tracked one"}}
	box := []IndexLine{{Slug: "b1", Summary: "box one"}}
	ptrs := []SourcePointer{{RelPath: "README.md", Summary: "readme"}}
	got := MergeOrigins(tracked, box, ptrs)
	if len(got) != 3 {
		t.Fatalf("expected 3 merged lines, got %d", len(got))
	}
	if got[0].Origin != OriginTracked || got[1].Origin != OriginBoxLocal || got[2].Origin != OriginSourcePointer {
		t.Errorf("origin ordering/labeling wrong: %+v", got)
	}
	if got[2].Slug != "README.md" {
		t.Errorf("pointer slug should be its relpath, got %q", got[2].Slug)
	}
}

// writeFile is a test helper that writes a file (creating parent dirs) and
// records its original bytes for an unchanged-assertion.
func writeFile(t *testing.T, path, content string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// TestScanSourcesPointersOnly verifies ingest registers pointers WITHOUT
// modifying the source files (privacy invariant 1).
func TestScanSourcesPointersOnly(t *testing.T) {
	ws := t.TempDir()
	readme := "# My Project\n\nDoes things."
	doc := "Architecture overview without a heading."
	claude := "# Project rules for Claude\n"
	writeFile(t, filepath.Join(ws, "README.md"), readme)
	writeFile(t, filepath.Join(ws, "docs", "architecture.md"), doc)
	writeFile(t, filepath.Join(ws, "CLAUDE.md"), claude)

	ptrs, err := ScanSources(ws)
	if err != nil {
		t.Fatal(err)
	}
	byPath := map[string]string{}
	for _, p := range ptrs {
		byPath[p.RelPath] = p.Summary
	}
	if byPath["README.md"] != "My Project" {
		t.Errorf("README summary = %q", byPath["README.md"])
	}
	if byPath["docs/architecture.md"] != "Architecture overview without a heading." {
		t.Errorf("docs summary = %q", byPath["docs/architecture.md"])
	}
	if _, ok := byPath["CLAUDE.md"]; !ok {
		t.Error("CLAUDE.md should be registered as a pointer")
	}

	// Source bytes MUST be unchanged.
	for path, want := range map[string]string{
		filepath.Join(ws, "README.md"):               readme,
		filepath.Join(ws, "docs", "architecture.md"): doc,
		filepath.Join(ws, "CLAUDE.md"):               claude,
	} {
		got, _ := os.ReadFile(path)
		if string(got) != want {
			t.Errorf("source %s was modified by ingest", path)
		}
	}
}

// TestIngestEnsuresGitignore verifies ingest creates the box-local gitignore
// (privacy invariant 2: never auto-committed).
func TestIngestEnsuresGitignore(t *testing.T) {
	ws := t.TempDir()
	writeFile(t, filepath.Join(ws, "README.md"), "# Hi\n")

	if _, err := Ingest(ws); err != nil {
		t.Fatal(err)
	}
	gi := filepath.Join(ws, ".conduit", ".gitignore")
	b, err := os.ReadFile(gi)
	if err != nil {
		t.Fatalf("expected .conduit/.gitignore: %v", err)
	}
	if !strings.Contains(string(b), "*") {
		t.Errorf(".conduit/.gitignore should ignore everything, got %q", string(b))
	}
	// Ingest writes SOURCES.md under the box-local store.
	if _, err := os.Stat(filepath.Join(ws, BoxLocalDir, SourcesFile)); err != nil {
		t.Errorf("expected SOURCES.md registry: %v", err)
	}
}

// TestScanExcludesManagedStores verifies ingest never points at conduit's own
// generated stores.
func TestScanExcludesManagedStores(t *testing.T) {
	ws := t.TempDir()
	writeFile(t, filepath.Join(ws, "README.md"), "# A\n")
	writeFile(t, filepath.Join(ws, "knowledge", "INDEX.md"), "# idx\n")
	writeFile(t, filepath.Join(ws, "knowledge", "foo.md"), "# foo\n")
	writeFile(t, filepath.Join(ws, BoxLocalDir, "bar.md"), "# bar\n")

	ptrs, err := ScanSources(ws)
	if err != nil {
		t.Fatal(err)
	}
	for _, p := range ptrs {
		if strings.HasPrefix(p.RelPath, "knowledge/") || strings.HasPrefix(p.RelPath, ".conduit/") {
			t.Errorf("ingest pointed at a managed store: %s", p.RelPath)
		}
	}
}

// TestBoxLocalAddAndPromote verifies box-local add targets .conduit/knowledge
// and promote moves it to tracked knowledge/ (regenerating both indexes).
func TestBoxLocalAddAndPromote(t *testing.T) {
	ws := t.TempDir()
	box := NewBoxLocalStore(ws)
	res, err := box.Add(AddRequest{
		Title: "Box Local Finding",
		Tags:  []string{"test"},
		Body:  "A discovery worth keeping on this box.",
	})
	if err != nil {
		t.Fatalf("box-local add: %v", err)
	}
	if !strings.Contains(res.Path, filepath.Join(".conduit", "knowledge")) {
		t.Errorf("box-local add wrote to %q, expected under .conduit/knowledge", res.Path)
	}
	// Tracked store must NOT have the entry yet.
	if _, err := os.Stat(NewStore(ws).EntryPath("box-local-finding")); err == nil {
		t.Error("entry leaked into tracked knowledge/ before promote")
	}

	pr, err := Promote(ws, "box-local-finding")
	if err != nil {
		t.Fatalf("promote: %v", err)
	}
	if _, err := os.Stat(pr.To); err != nil {
		t.Errorf("promoted entry missing at tracked path: %v", err)
	}
	if _, err := os.Stat(pr.From); err == nil {
		t.Error("box-local copy should be removed after promote")
	}
	// Tracked INDEX.md regenerated and references the slug.
	idx, err := NewStore(ws).ReadIndex()
	if err != nil {
		t.Fatalf("tracked index: %v", err)
	}
	if !strings.Contains(strings.ToLower(idx), "box-local-finding") {
		t.Errorf("tracked INDEX.md missing promoted slug:\n%s", idx)
	}
}

// TestPromoteRefusesClobber verifies promote won't overwrite a tracked entry.
func TestPromoteRefusesClobber(t *testing.T) {
	ws := t.TempDir()
	writeFile(t, filepath.Join(ws, "knowledge", "dup.md"), "---\ntitle: Dup\ntags: [x]\nstatus: active\n---\n\nbody\n")
	box := NewBoxLocalStore(ws)
	if _, err := box.Add(AddRequest{Title: "Dup", Tags: []string{"x"}, Body: "other body"}); err != nil {
		t.Fatal(err)
	}
	if _, err := Promote(ws, "dup"); err == nil {
		t.Error("promote should refuse to clobber an existing tracked entry")
	}
}

// TestBoxLocalSecretScrub verifies secret-scrub runs on the box-local write
// path too (privacy invariant 3).
func TestBoxLocalSecretScrub(t *testing.T) {
	ws := t.TempDir()
	box := NewBoxLocalStore(ws)
	_, err := box.Add(AddRequest{
		Title: "Has Secret",
		Tags:  []string{"test"},
		Body:  "the token is ghp_abcdefghijklmnopqrstuvwxyz0123",
	})
	if err == nil {
		t.Error("box-local add should refuse a body containing a secret")
	}
}

// TestSourceExistsGate verifies the experimental self-gate: active if ANY
// source exists.
func TestSourceExistsGate(t *testing.T) {
	// Empty workspace: no source.
	empty := t.TempDir()
	if SourceExists(empty) {
		t.Error("empty workspace should have no KB source")
	}
	// Just a README (ingestable doc) -> source exists.
	withDoc := t.TempDir()
	writeFile(t, filepath.Join(withDoc, "README.md"), "# Hi\n")
	if !SourceExists(withDoc) {
		t.Error("a workspace with an ingestable doc should have a KB source")
	}
}

// TestMergedIndexSpansOrigins verifies the merged view includes tracked,
// box-local, and pointer origins.
func TestMergedIndexSpansOrigins(t *testing.T) {
	ws := t.TempDir()
	writeFile(t, filepath.Join(ws, "README.md"), "# Readme summary\n")
	if _, err := NewStore(ws).Add(AddRequest{Title: "Tracked Entry", Tags: []string{"t"}, Body: "tracked body"}); err != nil {
		t.Fatal(err)
	}
	if _, err := NewBoxLocalStore(ws).Add(AddRequest{Title: "Box Entry", Tags: []string{"b"}, Body: "box body"}); err != nil {
		t.Fatal(err)
	}
	merged := MergedIndexForWorkspace(ws)
	origins := map[Origin]bool{}
	for _, l := range merged {
		origins[l.Origin] = true
	}
	for _, o := range []Origin{OriginTracked, OriginBoxLocal, OriginSourcePointer} {
		if !origins[o] {
			t.Errorf("merged index missing origin %q: %+v", o, merged)
		}
	}
}
