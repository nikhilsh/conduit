package session

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestConduitAwarenessEnabled pins the kill-switch semantics: default ON,
// falsey values OFF, anything else ON.
func TestConduitAwarenessEnabled(t *testing.T) {
	cases := []struct {
		val  string
		set  bool
		want bool
	}{
		{set: false, want: true}, // unset → default ON
		{val: "", set: true, want: true},
		{val: "1", set: true, want: true},
		{val: "on", set: true, want: true},
		{val: "true", set: true, want: true},
		{val: "anything", set: true, want: true},
		{val: "0", set: true, want: false},
		{val: "off", set: true, want: false},
		{val: "OFF", set: true, want: false},
		{val: "false", set: true, want: false},
		{val: "no", set: true, want: false},
		{val: "disabled", set: true, want: false},
		{val: " off ", set: true, want: false}, // trimmed
	}
	for _, c := range cases {
		if c.set {
			t.Setenv(conduitAwarenessEnv, c.val)
		} else {
			// t.Setenv can't unset; rely on the env being unset in CI. Guard so
			// a leaked value from the runner doesn't flake the default case.
			if _, ok := os.LookupEnv(conduitAwarenessEnv); ok {
				continue
			}
		}
		if got := conduitAwarenessEnabled(); got != c.want {
			t.Errorf("conduitAwarenessEnabled(val=%q set=%v) = %v, want %v", c.val, c.set, got, c.want)
		}
	}
}

// TestConduitAwarenessPromptContent asserts the prompt names every affordance
// and stays ASCII-only (it is passed verbatim on claude's command line).
func TestConduitAwarenessPromptContent(t *testing.T) {
	p := conduitAwarenessPrompt()
	for _, want := range []string{
		"Conduit",
		"$PORT",
		"$CONDUIT_PREVIEW_PORT",
		"uploads/<session>/",
		"AskUserQuestion",
		"Offering options is always a question", // numbered/bulleted choice -> tappable cards, not prose
		".conduit/memory/",
	} {
		if !strings.Contains(p, want) {
			t.Errorf("prompt missing %q\nprompt: %s", want, p)
		}
	}
	for i := 0; i < len(p); i++ {
		if p[i] > 127 {
			t.Fatalf("prompt has non-ASCII byte at %d (curly quote / em-dash?): %q", i, p)
		}
	}
}

// TestClaudeAppendSystemPrompt pins the on/off behavior of the merged
// --append-system-prompt value.
func TestClaudeAppendSystemPrompt(t *testing.T) {
	t.Run("off is legacy byte-identical", func(t *testing.T) {
		t.Setenv(conduitAwarenessEnv, "off")
		if got := claudeAppendSystemPrompt(); got != askUserQuestionNudge {
			t.Fatalf("off value = %q, want bare askUserQuestionNudge", got)
		}
	})
	t.Run("on merges both, nudge first", func(t *testing.T) {
		t.Setenv(conduitAwarenessEnv, "on")
		got := claudeAppendSystemPrompt()
		if !strings.HasPrefix(got, askUserQuestionNudge) {
			t.Fatalf("on value should start with the nudge; got %q", got)
		}
		if !strings.Contains(got, conduitAwarenessPrompt()) {
			t.Fatalf("on value should contain the awareness prompt; got %q", got)
		}
	})
}

// TestUpsertConduitAwarenessSection pins the AGENTS.md upsert: insert into
// empty/existing, replace-in-place (idempotent), and append below user content.
func TestUpsertConduitAwarenessSection(t *testing.T) {
	section := conduitAwarenessAgentsMDSection()

	t.Run("empty yields just the section", func(t *testing.T) {
		got := upsertConduitAwarenessSection("")
		if got != section+"\n" {
			t.Fatalf("empty upsert = %q", got)
		}
	})

	t.Run("appends below existing content", func(t *testing.T) {
		existing := "# My Project\n\nBuild with make.\n"
		got := upsertConduitAwarenessSection(existing)
		if !strings.HasPrefix(got, "# My Project") {
			t.Fatalf("user content not preserved: %q", got)
		}
		if !strings.Contains(got, agentsMDSectionBegin) || !strings.Contains(got, agentsMDSectionEnd) {
			t.Fatalf("section markers missing: %q", got)
		}
	})

	t.Run("idempotent: replace-in-place keeps one copy", func(t *testing.T) {
		once := upsertConduitAwarenessSection("# P\n\nhi\n")
		twice := upsertConduitAwarenessSection(once)
		if once != twice {
			t.Fatalf("not idempotent:\nonce:  %q\ntwice: %q", once, twice)
		}
		if strings.Count(twice, agentsMDSectionBegin) != 1 {
			t.Fatalf("expected exactly one managed block, got %d", strings.Count(twice, agentsMDSectionBegin))
		}
	})

	t.Run("replaces stale block content in place", func(t *testing.T) {
		stale := "# P\n\n" + agentsMDSectionBegin + "\n\nOLD TEXT\n\n" + agentsMDSectionEnd + "\n\ntrailer\n"
		got := upsertConduitAwarenessSection(stale)
		if strings.Contains(got, "OLD TEXT") {
			t.Fatalf("stale content not replaced: %q", got)
		}
		if !strings.Contains(got, "trailer") {
			t.Fatalf("trailing user content lost: %q", got)
		}
		if strings.Count(got, agentsMDSectionBegin) != 1 {
			t.Fatalf("expected one block after replace, got %d", strings.Count(got, agentsMDSectionBegin))
		}
	})
}

func TestIsCodexProtocol(t *testing.T) {
	for _, p := range []string{"codex-app-server", "codex-exec"} {
		if !isCodexProtocol(p) {
			t.Errorf("isCodexProtocol(%q) = false, want true", p)
		}
	}
	for _, p := range []string{"", "stream-json", "opencode-server", "codex"} {
		if isCodexProtocol(p) {
			t.Errorf("isCodexProtocol(%q) = true, want false", p)
		}
	}
}

// TestKBSectionGate verifies the self-gate: kbSection returns ("", false) when
// no knowledge/INDEX.md exists, and (section, true) when it does.
func TestKBSectionGate(t *testing.T) {
	// No knowledge directory at all.
	dir := t.TempDir()
	section, ok := kbSection(dir)
	if ok {
		t.Errorf("kbSection should be false when no knowledge/INDEX.md; got section: %q", section)
	}

	// Create knowledge/INDEX.md.
	kbDir := filepath.Join(dir, "knowledge")
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	indexContent := "# KB Index\n\nSome entries.\n"
	if err := os.WriteFile(filepath.Join(kbDir, "INDEX.md"), []byte(indexContent), 0o644); err != nil {
		t.Fatal(err)
	}

	section, ok = kbSection(dir)
	if !ok {
		t.Error("kbSection should be true when knowledge/INDEX.md exists")
	}
	if !strings.Contains(section, "Knowledge base") {
		t.Errorf("section missing 'Knowledge base' header; got: %q", section)
	}
	// The section contains the broker binary path + " kb search" — in tests
	// os.Executable() returns the test binary path, so check for "kb search".
	if !strings.Contains(section, "kb search") {
		t.Errorf("section missing search instruction; got: %q", section)
	}
	if !strings.Contains(section, "KB Index") {
		t.Errorf("section missing index content; got: %q", section)
	}
}

// TestConduitAwarenessPromptWithKBGate verifies that the KB section is absent
// when no knowledge/INDEX.md exists and present when it does.
func TestConduitAwarenessPromptWithKBGate(t *testing.T) {
	t.Setenv(conduitAwarenessEnv, "on")

	// No KB: should equal the base prompt.
	dir := t.TempDir()
	withKB := conduitAwarenessPromptWithKB(dir)
	base := conduitAwarenessPrompt()
	if withKB != base {
		t.Errorf("no-KB prompt should equal base prompt\nbase: %q\nwithKB: %q", base, withKB)
	}

	// With KB: should contain the base prompt AND the KB section.
	kbDir := filepath.Join(dir, "knowledge")
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(kbDir, "INDEX.md"), []byte("# KB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withKB2 := conduitAwarenessPromptWithKB(dir)
	if !strings.Contains(withKB2, "Knowledge base") {
		t.Errorf("with-KB prompt should contain 'Knowledge base'; got: %q", withKB2)
	}
	if !strings.Contains(withKB2, base) {
		t.Errorf("with-KB prompt should contain the base prompt")
	}
}

// TestClaudeAppendSystemPromptForWorkspaceKBGate verifies that the workspace
// param drives KB inclusion in the claude --append-system-prompt value.
func TestClaudeAppendSystemPromptForWorkspaceKBGate(t *testing.T) {
	t.Setenv(conduitAwarenessEnv, "on")

	dir := t.TempDir()
	// No KB: should equal the standard claudeAppendSystemPrompt().
	noKB := claudeAppendSystemPromptForWorkspace(dir)
	standard := claudeAppendSystemPrompt()
	if noKB != standard {
		t.Errorf("no-KB workspace prompt should equal standard prompt\nstandard: %q\nnoKB: %q", standard, noKB)
	}

	// With KB: should contain KB section.
	kbDir := filepath.Join(dir, "knowledge")
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(kbDir, "INDEX.md"), []byte("# KB\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	withKB := claudeAppendSystemPromptForWorkspace(dir)
	if !strings.Contains(withKB, "Knowledge base") {
		t.Errorf("with-KB prompt should contain 'Knowledge base'; got: %q", withKB)
	}
}

// TestUpsertConduitAwarenessSectionWithKBIdempotent verifies the KB-aware
// AGENTS.md upsert is idempotent when repeated with the same workspace.
func TestUpsertConduitAwarenessSectionWithKBIdempotent(t *testing.T) {
	dir := t.TempDir()
	kbDir := filepath.Join(dir, "knowledge")
	if err := os.MkdirAll(kbDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(kbDir, "INDEX.md"), []byte("# KB\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	once := upsertConduitAwarenessSectionWithKB("# P\n\nhi\n", dir)
	twice := upsertConduitAwarenessSectionWithKB(once, dir)
	if once != twice {
		t.Fatalf("not idempotent:\nonce:  %q\ntwice: %q", once, twice)
	}
	if strings.Count(twice, agentsMDSectionBegin) != 1 {
		t.Fatalf("expected exactly one managed block, got %d", strings.Count(twice, agentsMDSectionBegin))
	}
	if !strings.Contains(twice, "Knowledge base") {
		t.Error("KB section missing from AGENTS.md content")
	}
}
