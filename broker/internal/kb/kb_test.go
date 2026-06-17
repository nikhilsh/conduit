package kb

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestMakeSlug pins slug generation.
func TestMakeSlug(t *testing.T) {
	cases := []struct{ title, want string }{
		{"Hello World", "hello-world"},
		{"UniFFI Bindings Checksum Trap", "uniffi-bindings-checksum-trap"},
		{"  leading/trailing spaces  ", "leading-trailing-spaces"},
		{"already-kebab", "already-kebab"},
		{"with 123 numbers", "with-123-numbers"},
		{"multiple   spaces", "multiple-spaces"},
		{"punctuation! at@ end.", "punctuation-at-end"},
		{"", "untitled"},
		{"---", "untitled"},
	}
	for _, c := range cases {
		got := MakeSlug(c.title)
		if got != c.want {
			t.Errorf("MakeSlug(%q) = %q, want %q", c.title, got, c.want)
		}
	}
}

// TestScrubSecrets verifies that obvious secret patterns are caught.
func TestScrubSecrets(t *testing.T) {
	hits := []struct {
		name string
		body string
	}{
		{"AWS key", "export KEY=AKIAIOSFODNN7EXAMPLE00"},
		{"private key", "-----BEGIN RSA PRIVATE KEY-----\nMIIE..."},
		{"Slack token", "token = xoxb-111-222-abcdefghij"},
		{"GitHub token", "GITHUB_TOKEN=ghp_abcdefghijklmnopqrstu"},
		{"CONDUIT_TOKEN", "CONDUIT_TOKEN=supersecret123"},
		{"password", "password=hunter22"},
		{"secret", "secret=mypassword"},
		{"long hex", "deadbeefcafe0123456789abcdef01234567"},
		{"long base64", "dGhpcyBpcyBhIGxvbmcgYmFzZTY0IGVuY29kZWQgc3RyaW5nZm9yc2Ny"},
	}
	for _, c := range hits {
		name, matched := ScrubSecrets(c.body)
		if !matched {
			t.Errorf("%s: expected secret match, got none", c.name)
		} else if name == "" {
			t.Errorf("%s: matched but returned empty pattern name", c.name)
		}
	}

	// Clean body should not match.
	clean := "This is a normal knowledge entry about broker ops and how to redeploy."
	if name, matched := ScrubSecrets(clean); matched {
		t.Errorf("clean body incorrectly flagged as secret (pattern: %q)", name)
	}
}

// TestSchemaValidation checks required-field enforcement.
func TestSchemaValidation(t *testing.T) {
	valid := AddRequest{Title: "My Entry", Tags: []string{"broker"}, Body: "some content"}
	if err := validateSchema(valid); err != nil {
		t.Fatalf("valid request rejected: %v", err)
	}

	noTitle := AddRequest{Tags: []string{"broker"}, Body: "body"}
	if err := validateSchema(noTitle); err == nil {
		t.Error("missing title should have failed validation")
	}

	noTags := AddRequest{Title: "My Entry", Body: "body"}
	if err := validateSchema(noTags); err == nil {
		t.Error("missing tags should have failed validation")
	}

	noBody := AddRequest{Title: "My Entry", Tags: []string{"broker"}}
	if err := validateSchema(noBody); err == nil {
		t.Error("missing body should have failed validation")
	}
}

// TestDedupRefusal checks that adding an entry with an existing slug is refused.
func TestDedupRefusal(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	kbDir := filepath.Join(dir, KnowledgeDir)
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Write a pre-existing entry.
	existing := "---\ntitle: My Entry\ntags: [broker]\nscope: repo\nsource: human\nstatus: active\n---\n\nBody content.\n"
	if err := os.WriteFile(filepath.Join(kbDir, "my-entry.md"), []byte(existing), 0o644); err != nil {
		t.Fatal(err)
	}

	// Try to add an entry with the same slug title.
	_, err := store.Add(AddRequest{
		Title: "My Entry",
		Tags:  []string{"broker"},
		Body:  "New content",
	})
	if err == nil {
		t.Fatal("duplicate entry should have been refused")
	}
	if !strings.Contains(err.Error(), "duplicate entry") {
		t.Errorf("unexpected error message: %v", err)
	}
}

// TestSecretScrubRefusal checks that secret-containing bodies are refused.
func TestSecretScrubRefusal(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	if err := os.MkdirAll(filepath.Join(dir, KnowledgeDir), 0o755); err != nil {
		t.Fatal(err)
	}

	_, err := store.Add(AddRequest{
		Title: "Broker creds",
		Tags:  []string{"broker"},
		Body:  "The token is CONDUIT_TOKEN=secretvalue123 and must never be shared.",
	})
	if err == nil {
		t.Fatal("secret-containing body should have been refused")
	}
	if !strings.Contains(err.Error(), "secret detected") {
		t.Errorf("unexpected error message: %v", err)
	}
}

// TestAddWritesFileAndUpdatesIndex verifies the happy path: file written +
// INDEX.md regenerated.
func TestAddWritesFileAndUpdatesIndex(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	kbDir := filepath.Join(dir, KnowledgeDir)
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	// Pre-create a minimal INDEX.md so RegenerateIndex can preserve preamble.
	initialIndex := "# Knowledge base index\n\nTest preamble.\n"
	if err := os.WriteFile(store.IndexPath(), []byte(initialIndex), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := store.Add(AddRequest{
		Title: "Broker Ops Footguns",
		Tags:  []string{"broker", "ops"},
		Scope: "repo",
		Body:  "Never pkill the broker by name. Kill by PID only.",
	})
	if err != nil {
		t.Fatalf("Add failed: %v", err)
	}

	// Entry file should exist.
	entryPath := store.EntryPath(result.Slug)
	if _, err := os.Stat(entryPath); err != nil {
		t.Fatalf("entry file not written: %v", err)
	}

	// INDEX.md should have been regenerated and contain the new entry.
	idx, err := store.ReadIndex()
	if err != nil {
		t.Fatalf("INDEX.md read failed: %v", err)
	}
	if !strings.Contains(idx, result.Slug) {
		t.Errorf("INDEX.md does not contain new slug %q\nINDEX:\n%s", result.Slug, idx)
	}
	if !strings.Contains(result.Message, result.Slug) {
		t.Errorf("result message does not mention slug: %q", result.Message)
	}
	if result.Staged {
		t.Error("result.Staged should be false for a fresh add")
	}
}

// TestAddCreatesFreshKBDir verifies that Add creates knowledge/ when it does not
// exist yet (mkdir-p behavior) and that secret-scrub still fires before any
// write so the directory is NOT created on a rejected body.
func TestAddCreatesFreshKBDir(t *testing.T) {
	wsDir := t.TempDir()
	store := NewStore(wsDir)
	kbDir := filepath.Join(wsDir, KnowledgeDir)

	// Precondition: knowledge/ dir does not exist.
	if _, err := os.Stat(kbDir); !os.IsNotExist(err) {
		t.Fatal("precondition: knowledge dir should not exist yet")
	}

	// Secret body should be rejected and the dir should NOT be created.
	_, err := store.Add(AddRequest{
		Title: "Secret Entry",
		Tags:  []string{"broker"},
		Body:  "CONDUIT_TOKEN=supersecretvalue123",
	})
	if err == nil {
		t.Fatal("secret body should have been rejected")
	}
	if !strings.Contains(err.Error(), "secret detected") {
		t.Errorf("expected secret-detected error, got: %v", err)
	}
	if _, statErr := os.Stat(kbDir); !os.IsNotExist(statErr) {
		t.Error("knowledge dir must not be created when secret-scrub fires")
	}

	// A clean add should create the dir and write the entry.
	result, err := store.Add(AddRequest{
		Title: "Fresh Entry",
		Tags:  []string{"broker"},
		Body:  "Normal body content for a fresh KB.",
	})
	if err != nil {
		t.Fatalf("Add on fresh workspace failed: %v", err)
	}
	if _, statErr := os.Stat(kbDir); statErr != nil {
		t.Errorf("knowledge dir was not created: %v", statErr)
	}
	if _, statErr := os.Stat(result.Path); statErr != nil {
		t.Errorf("entry file was not written: %v", statErr)
	}
}

// TestSearchHitAndMiss checks that search returns matches and ignores non-matches.
func TestSearchHitAndMiss(t *testing.T) {
	dir := t.TempDir()
	store := NewStore(dir)
	kbDir := filepath.Join(dir, KnowledgeDir)
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Write two entries.
	entries := map[string]string{
		"broker-ops.md": "---\ntitle: Broker Ops\ntags: [broker]\nscope: repo\nsource: human\nstatus: active\n---\n\nThe broker runs under systemd. Never pkill.\n",
		"ios-bugs.md":   "---\ntitle: iOS HTTP footguns\ntags: [ios, http]\nscope: repo\nsource: human\nstatus: active\n---\n\nURLComponents.path encodes query strings incorrectly.\n",
	}
	for name, content := range entries {
		if err := os.WriteFile(filepath.Join(kbDir, name), []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	// Write a minimal INDEX.md.
	if err := os.WriteFile(store.IndexPath(), []byte("# Index\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	// Search that should hit broker-ops.
	hits, err := store.Search("systemd")
	if err != nil {
		t.Fatalf("Search failed: %v", err)
	}
	if len(hits) == 0 {
		t.Error("search for 'systemd' should match broker-ops")
	}
	found := false
	for _, h := range hits {
		if strings.Contains(h, "broker-ops") {
			found = true
		}
	}
	if !found {
		t.Errorf("expected broker-ops in hits, got: %v", hits)
	}

	// Search that should miss.
	misses, err := store.Search("xyzzy_no_match_12345")
	if err != nil {
		t.Fatalf("Search failed: %v", err)
	}
	if len(misses) != 0 {
		t.Errorf("expected no matches, got: %v", misses)
	}
}

// TestBuildIndexPure tests buildIndex as a pure function with a temp dir.
func TestBuildIndexPure(t *testing.T) {
	dir := t.TempDir()
	kbDir := filepath.Join(dir, KnowledgeDir)
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}

	// Write an entry.
	content := "---\ntitle: My Fact\ntags: [test]\nscope: repo\nsource: human\nstatus: active\n---\n\nThis is the body sentence.\n"
	if err := os.WriteFile(filepath.Join(kbDir, "my-fact.md"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := BuildIndex(kbDir, []string{"my-fact"})
	if err != nil {
		t.Fatalf("BuildIndex failed: %v", err)
	}
	if !strings.Contains(result, "MY-FACT") {
		t.Errorf("index missing MY-FACT; got:\n%s", result)
	}
	if !strings.Contains(result, "This is the body sentence.") {
		t.Errorf("index missing body summary; got:\n%s", result)
	}
	if !strings.Contains(result, "<!-- BEGIN KB ENTRIES") {
		t.Errorf("index missing managed block marker; got:\n%s", result)
	}
}

// TestTruncateForInjection checks that oversized index content is capped.
func TestTruncateForInjection(t *testing.T) {
	// Content under limits -- should pass through unchanged.
	short := "# Index\n\nShort content.\n"
	if got := TruncateForInjection(short); got != short {
		t.Errorf("short content modified: %q", got)
	}

	// Content over MaxIndexBytes.
	long := strings.Repeat("x", MaxIndexBytes+100)
	result := TruncateForInjection(long)
	if len(result) > MaxIndexBytes+200 { // allow for the truncation note
		t.Errorf("result too long: len=%d", len(result))
	}
	if !strings.Contains(result, "truncated") {
		t.Error("truncation note missing")
	}

	// Content over MaxIndexLines.
	lines := make([]string, MaxIndexLines+10)
	for i := range lines {
		lines[i] = "line"
	}
	manyLines := strings.Join(lines, "\n")
	result2 := TruncateForInjection(manyLines)
	if !strings.Contains(result2, "truncated") {
		t.Error("truncation note missing for too-many-lines case")
	}
}
