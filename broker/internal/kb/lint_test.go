package kb

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// helpers

func mkKBDir(t *testing.T) (wsDir, kbDir string) {
	t.Helper()
	wsDir = t.TempDir()
	kbDir = filepath.Join(wsDir, KnowledgeDir)
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	return
}

func writeEntry(t *testing.T, kbDir, slug, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(kbDir, slug+".md"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

func writeIndex(t *testing.T, kbDir, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(kbDir, IndexFile), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
}

// validEntry returns a well-formed entry markdown string.
func validEntry(title, tags string) string {
	return "---\ntitle: " + title + "\ntags: [" + tags + "]\nscope: repo\nsource: test\nstatus: active\n---\n\nBody content.\n"
}

// TestLintPassesOnSyncKB verifies that a properly structured KB passes clean.
func TestLintPassesOnSyncKB(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "alpha", validEntry("Alpha Entry", "broker, ops"))
	writeEntry(t, kbDir, "beta", validEntry("Beta Entry", "ios, swift"))
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [alpha](alpha.md) | Alpha. |\n"+
			"| [beta](beta.md) | Beta. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatalf("Lint returned error: %v", err)
	}
	if !res.OK() {
		t.Errorf("expected clean lint, got errors: %v", res.Errors)
	}
}

// TestLintMissingFromIndex fails when an entry file is not referenced in INDEX.md.
func TestLintMissingFromIndex(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "alpha", validEntry("Alpha Entry", "broker"))
	writeEntry(t, kbDir, "orphan-file", validEntry("Orphan File", "ops"))
	// INDEX only references alpha.
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [alpha](alpha.md) | Alpha. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected error for missing-from-index entry")
	}
	found := false
	for _, e := range res.Errors {
		if strings.Contains(e, "orphan-file") && strings.Contains(e, "not referenced in INDEX") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected missing-from-index error mentioning 'orphan-file'; got: %v", res.Errors)
	}
}

// TestLintOrphanIndexRef fails when INDEX.md references a slug with no file.
func TestLintOrphanIndexRef(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "alpha", validEntry("Alpha Entry", "broker"))
	// INDEX references "ghost" which doesn't exist.
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [alpha](alpha.md) | Alpha. |\n"+
			"| [ghost](ghost.md) | Ghost entry. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected error for orphan INDEX reference")
	}
	found := false
	for _, e := range res.Errors {
		if strings.Contains(e, "ghost") && strings.Contains(e, "does not exist") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected orphan-ref error mentioning 'ghost'; got: %v", res.Errors)
	}
}

// TestLintDuplicateSlug fails when two entries collide case-insensitively.
func TestLintDuplicateSlug(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "FOO-BAR", validEntry("Foo Bar", "broker"))
	writeEntry(t, kbDir, "foo-bar", validEntry("Foo Bar Lower", "broker"))
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [FOO-BAR](FOO-BAR.md) | Foo Bar. |\n"+
			"| [foo-bar](foo-bar.md) | Foo Bar lower. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected error for duplicate slug")
	}
	found := false
	for _, e := range res.Errors {
		if strings.Contains(e, "duplicate slug") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected duplicate-slug error; got: %v", res.Errors)
	}
}

// TestLintBadFrontmatter fails when frontmatter is missing required fields.
func TestLintBadFrontmatter(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	// Entry missing title and tags.
	writeEntry(t, kbDir, "bad", "---\nscope: repo\nsource: test\nstatus: active\n---\n\nBody.\n")
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n| [bad](bad.md) | Bad. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected errors for bad frontmatter")
	}
	hasTitle := false
	hasTags := false
	for _, e := range res.Errors {
		if strings.Contains(e, "title") {
			hasTitle = true
		}
		if strings.Contains(e, "tags") {
			hasTags = true
		}
	}
	if !hasTitle {
		t.Errorf("expected missing-title error; got: %v", res.Errors)
	}
	if !hasTags {
		t.Errorf("expected missing-tags error; got: %v", res.Errors)
	}
}

// TestLintMissingStatus fails when the 'status' field is absent.
func TestLintMissingStatus(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "no-status", "---\ntitle: No Status\ntags: [broker]\nscope: repo\n---\n\nBody.\n")
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n| [no-status](no-status.md) | No status. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected error for missing status")
	}
	found := false
	for _, e := range res.Errors {
		if strings.Contains(e, "status") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected missing-status error; got: %v", res.Errors)
	}
}

// TestLintBrokenCrossLink fails when an entry links to a nonexistent slug.
func TestLintBrokenCrossLink(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "alpha",
		"---\ntitle: Alpha\ntags: [broker]\nscope: repo\nsource: t\nstatus: active\n---\n\n"+
			"See [GHOST](GHOST.md) for more.\n")
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n| [alpha](alpha.md) | Alpha. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if res.OK() {
		t.Fatal("expected error for broken cross-link")
	}
	found := false
	for _, e := range res.Errors {
		if strings.Contains(e, "GHOST") && strings.Contains(e, "broken cross-link") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected broken-cross-link error mentioning GHOST; got: %v", res.Errors)
	}
}

// TestLintOverlapWarn verifies the overlap heuristic warns but doesn't hard-fail.
func TestLintOverlapWarn(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	// Two entries with ≥2 shared tags and one title being a substring of the other.
	writeEntry(t, kbDir, "broker-ops", validEntry("Broker ops", "broker, ops, deployment"))
	writeEntry(t, kbDir, "broker-ops-advanced", validEntry("Broker ops advanced", "broker, ops, systemd"))
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [broker-ops](broker-ops.md) | Broker ops. |\n"+
			"| [broker-ops-advanced](broker-ops-advanced.md) | Broker ops advanced. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	// Should be OK (no hard errors) but have warnings.
	if !res.OK() {
		t.Errorf("overlap should only warn, not error; errors: %v", res.Errors)
	}
	if len(res.Warnings) == 0 {
		t.Error("expected overlap warning, got none")
	}
	found := false
	for _, w := range res.Warnings {
		if strings.Contains(w, "broker-ops") && strings.Contains(w, "structural heuristic") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected overlap warning with heuristic note; got: %v", res.Warnings)
	}
}

// TestLintNoOverlapWithoutSharedTags verifies entries with different tags don't warn.
func TestLintNoOverlapWithoutSharedTags(t *testing.T) {
	wsDir, kbDir := mkKBDir(t)
	writeEntry(t, kbDir, "broker-ops", validEntry("Broker ops", "broker, ops"))
	writeEntry(t, kbDir, "ios-ops", validEntry("Broker ops", "ios, swift"))
	writeIndex(t, kbDir,
		"# Index\n\n| Entry | Summary |\n|-------|----------|\n"+
			"| [broker-ops](broker-ops.md) | Broker ops. |\n"+
			"| [ios-ops](ios-ops.md) | iOS ops. |\n")

	res, err := Lint(wsDir)
	if err != nil {
		t.Fatal(err)
	}
	if !res.OK() {
		t.Errorf("expected no errors; got: %v", res.Errors)
	}
	if len(res.Warnings) > 0 {
		t.Errorf("expected no warnings without shared tags; got: %v", res.Warnings)
	}
}
