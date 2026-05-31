package session

import (
	"strings"
	"testing"
)

// TestCommandEnv_StripsEmptyAuthKeys verifies the broker does not
// forward an empty ANTHROPIC_API_KEY / OPENAI_API_KEY from its own
// environment to spawned agents. The legacy install ships an
// EnvironmentFile=/opt/conduit/.conduit/env with literal
// `ANTHROPIC_API_KEY=` placeholder lines; systemd exports those as
// "set to empty string", and the Claude CLI then prefers the empty
// env var over the OAuth credentials file, forcing the session to
// report logged-out despite a valid token on disk.
func TestCommandEnv_StripsEmptyAuthKeys(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "")
	t.Setenv("OPENAI_API_KEY", "")

	s := &Session{ID: "sess-strip", Assistant: "claude"}
	got := s.commandEnv(nil)

	for _, kv := range got {
		if kv == "ANTHROPIC_API_KEY=" {
			t.Fatalf("empty ANTHROPIC_API_KEY was forwarded to spawned agent")
		}
		if kv == "OPENAI_API_KEY=" {
			t.Fatalf("empty OPENAI_API_KEY was forwarded to spawned agent")
		}
	}
}

// TestCommandEnv_PreservesNonEmptyAuthKeys confirms a real API key
// still reaches the spawned agent, so deliberate env-file overrides
// keep working as before.
func TestCommandEnv_PreservesNonEmptyAuthKeys(t *testing.T) {
	t.Setenv("ANTHROPIC_API_KEY", "sk-test-anthropic")
	t.Setenv("OPENAI_API_KEY", "sk-test-openai")

	s := &Session{ID: "sess-preserve", Assistant: "claude"}
	got := s.commandEnv(nil)

	want := map[string]bool{
		"ANTHROPIC_API_KEY=sk-test-anthropic": false,
		"OPENAI_API_KEY=sk-test-openai":       false,
	}
	for _, kv := range got {
		if _, ok := want[kv]; ok {
			want[kv] = true
		}
	}
	for kv, seen := range want {
		if !seen {
			t.Fatalf("non-empty key dropped: %q not in commandEnv output", kv)
		}
	}
}

// TestCommandEnv_LeavesUnrelatedEmptyVarsAlone makes sure the filter
// is targeted — an unrelated empty variable in the broker's env (e.g.
// PS2=) must still pass through, since it does not interact with
// agent auth.
func TestCommandEnv_LeavesUnrelatedEmptyVarsAlone(t *testing.T) {
	t.Setenv("CONDUIT_TEST_EMPTY", "")

	s := &Session{ID: "sess-unrelated", Assistant: "claude"}
	got := s.commandEnv(nil)

	found := false
	for _, kv := range got {
		if strings.HasPrefix(kv, "CONDUIT_TEST_EMPTY=") {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("unrelated empty var was incorrectly stripped from commandEnv")
	}
}
