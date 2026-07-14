package main

import (
	"bytes"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// captureStdout redirects os.Stdout for the duration of fn and returns
// everything written to it. Used to assert on runKB's CLI output without
// threading a writer through the whole subcommand tree.
func captureStdout(t *testing.T, fn func()) string {
	t.Helper()
	orig := os.Stdout
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatalf("os.Pipe: %v", err)
	}
	os.Stdout = w
	defer func() { os.Stdout = orig }()

	fn()

	if err := w.Close(); err != nil {
		t.Fatalf("close pipe writer: %v", err)
	}
	var buf bytes.Buffer
	if _, err := io.Copy(&buf, r); err != nil {
		t.Fatalf("read pipe: %v", err)
	}
	return buf.String()
}

// --- splitFlagsAndPositionals unit tests -----------------------------------

func TestSplitFlagsAndPositionals_FlagAfterPositional(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")

	flagArgs, positional := splitFlagsAndPositionals(fs, []string{"query", "--dir", "/x"})
	if got, want := strings.Join(flagArgs, " "), "--dir /x"; got != want {
		t.Errorf("flagArgs = %q, want %q", got, want)
	}
	if got, want := strings.Join(positional, " "), "query"; got != want {
		t.Errorf("positional = %q, want %q", got, want)
	}
}

func TestSplitFlagsAndPositionals_FlagBeforePositional(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")

	flagArgs, positional := splitFlagsAndPositionals(fs, []string{"--dir", "/x", "query"})
	if got, want := strings.Join(flagArgs, " "), "--dir /x"; got != want {
		t.Errorf("flagArgs = %q, want %q", got, want)
	}
	if got, want := strings.Join(positional, " "), "query"; got != want {
		t.Errorf("positional = %q, want %q", got, want)
	}
}

func TestSplitFlagsAndPositionals_MultiplePositionalsAndFlags(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")
	fs.String("title", "", "")

	flagArgs, positional := splitFlagsAndPositionals(fs, []string{
		"extra1", "--title", "T", "extra2", "--dir", "/x",
	})
	if got, want := strings.Join(flagArgs, " "), "--title T --dir /x"; got != want {
		t.Errorf("flagArgs = %q, want %q", got, want)
	}
	if got, want := strings.Join(positional, " "), "extra1 extra2"; got != want {
		t.Errorf("positional = %q, want %q", got, want)
	}
}

func TestSplitFlagsAndPositionals_EqualsForm(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")

	flagArgs, positional := splitFlagsAndPositionals(fs, []string{"query", "--dir=/x"})
	if got, want := strings.Join(flagArgs, " "), "--dir=/x"; got != want {
		t.Errorf("flagArgs = %q, want %q", got, want)
	}
	if got, want := strings.Join(positional, " "), "query"; got != want {
		t.Errorf("positional = %q, want %q", got, want)
	}
}

func TestSplitFlagsAndPositionals_DoubleDashStopsParsing(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")

	flagArgs, positional := splitFlagsAndPositionals(fs, []string{"--dir", "/x", "--", "--not-a-flag"})
	if got, want := strings.Join(flagArgs, " "), "--dir /x"; got != want {
		t.Errorf("flagArgs = %q, want %q", got, want)
	}
	if got, want := strings.Join(positional, " "), "--not-a-flag"; got != want {
		t.Errorf("positional = %q, want %q", got, want)
	}
}

func TestSplitFlagsAndPositionals_UnknownFlagForwarded(t *testing.T) {
	fs := flag.NewFlagSet("test", flag.ContinueOnError)
	fs.String("dir", "", "")

	// Unknown flags are forwarded into flagArgs unchanged so fs.Parse can
	// report its normal "flag provided but not defined" error.
	flagArgs, _ := splitFlagsAndPositionals(fs, []string{"--bogus", "val"})
	if len(flagArgs) == 0 || flagArgs[0] != "--bogus" {
		t.Errorf("expected --bogus forwarded into flagArgs, got %v", flagArgs)
	}
}

// --- runKB CLI-level flag-position tests ------------------------------------

func writeKBFixture(t *testing.T, dir string) {
	t.Helper()
	if code := runKB([]string{"add", "--title", "Fixture Entry", "--tags", "broker", "--dir", dir, "--body", "hello fixture body"}); code != 0 {
		t.Fatalf("fixture add failed: exit %d", code)
	}
}

func TestRunKB_SearchHonorsDirAfterPositionalQuery(t *testing.T) {
	dir := t.TempDir()
	writeKBFixture(t, dir)

	out := captureStdout(t, func() {
		if code := runKB([]string{"search", "fixture", "--dir", dir}); code != 0 {
			t.Errorf("search exit = %d, want 0", code)
		}
	})
	if !strings.Contains(out, "fixture-entry") {
		t.Errorf("search output missing entry, got: %q", out)
	}
}

func TestRunKB_GetHonorsDirAfterPositionalSlug(t *testing.T) {
	dir := t.TempDir()
	writeKBFixture(t, dir)

	out := captureStdout(t, func() {
		if code := runKB([]string{"get", "fixture-entry", "--dir", dir}); code != 0 {
			t.Errorf("get exit = %d, want 0", code)
		}
	})
	if !strings.Contains(out, "hello fixture body") {
		t.Errorf("get output missing body, got: %q", out)
	}
}

func TestRunKB_AddHonorsDirAfterStrayPositional(t *testing.T) {
	dir := t.TempDir()
	// A stray leading positional token (e.g. a typo) must not swallow the
	// following flags -- title/tags/dir must still parse.
	code := runKB([]string{"add", "extra", "--title", "Stray", "--tags", "broker", "--dir", dir, "--body", "b"})
	if code != 0 {
		t.Fatalf("add exit = %d, want 0", code)
	}
	if _, err := os.Stat(filepath.Join(dir, "knowledge", "stray.md")); err != nil {
		t.Errorf("entry not written to expected --dir: %v", err)
	}
}

// --- kb add fresh-repo init --------------------------------------------------

func TestRunKB_AddCreatesKnowledgeDirAndIndexInFreshRepo(t *testing.T) {
	dir := t.TempDir()
	kbDir := filepath.Join(dir, "knowledge")
	if _, err := os.Stat(kbDir); !os.IsNotExist(err) {
		t.Fatalf("precondition: knowledge/ should not exist yet")
	}

	code := runKB([]string{"add", "--title", "First Entry", "--tags", "broker", "--dir", dir, "--body", "first body"})
	if code != 0 {
		t.Fatalf("add exit = %d, want 0", code)
	}

	// knowledge/ and INDEX.md must now exist -- this is also what flips
	// awareness-injection ON for the workspace (self-gated on
	// knowledge/INDEX.md existing; see conduitprompt.go).
	if _, err := os.Stat(kbDir); err != nil {
		t.Errorf("knowledge dir was not created: %v", err)
	}
	indexPath := filepath.Join(kbDir, "INDEX.md")
	idx, err := os.ReadFile(indexPath)
	if err != nil {
		t.Fatalf("INDEX.md was not created: %v", err)
	}
	if !strings.Contains(string(idx), "FIRST-ENTRY") {
		t.Errorf("INDEX.md missing new entry, got: %q", string(idx))
	}
}

func TestRunKB_AddInExistingRepoUnchanged(t *testing.T) {
	dir := t.TempDir()
	writeKBFixture(t, dir)

	code := runKB([]string{"add", "--title", "Second Entry", "--tags", "broker", "--dir", dir, "--body", "second body"})
	if code != 0 {
		t.Fatalf("add exit = %d, want 0", code)
	}
	idx, err := os.ReadFile(filepath.Join(dir, "knowledge", "INDEX.md"))
	if err != nil {
		t.Fatalf("read INDEX.md: %v", err)
	}
	if !strings.Contains(string(idx), "FIXTURE-ENTRY") || !strings.Contains(string(idx), "SECOND-ENTRY") {
		t.Errorf("INDEX.md missing expected entries, got: %q", string(idx))
	}
}
