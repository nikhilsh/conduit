package session

import (
	"slices"
	"strings"
	"testing"
)

// TestSanitizeTmuxName pins the UUID -> tmux-name transform. tmux session
// names cannot contain `.` or `:` (target-spec separators); the helper must
// replace those (and any other unsafe char) and prefix `kitty-`. The
// transform is pure: the same UUID always maps to the same name, which is
// what lets a reconnect re-attach to the same tmux session.
func TestSanitizeTmuxName(t *testing.T) {
	cases := []struct {
		label string
		in    string
		want  string
	}{
		{"plain-uuid", "a94dfc72d609d57cd", "kitty-a94dfc72d609d57cd"},
		{"hyphenated-uuid", "550e8400-e29b-41d4-a716-446655440000", "kitty-550e8400-e29b-41d4-a716-446655440000"},
		{"dots-replaced", "1.2.3", "kitty-1_2_3"},
		{"colons-replaced", "host:1234", "kitty-host_1234"},
		{"slash-and-space", "foo/bar baz", "kitty-foo_bar_baz"},
		{"already-safe", "abc_DEF-123", "kitty-abc_DEF-123"},
		{"empty", "", "kitty-"},
	}
	for _, tc := range cases {
		t.Run(tc.label, func(t *testing.T) {
			got := sanitizeTmuxName(tc.in)
			if got != tc.want {
				t.Fatalf("sanitizeTmuxName(%q): want %q got %q", tc.in, tc.want, got)
			}
			// The result must never contain a tmux target-spec separator.
			if strings.ContainsAny(got, ".:") {
				t.Fatalf("sanitizeTmuxName(%q) = %q contains a tmux-unsafe char", tc.in, got)
			}
		})
	}
}

// TestSanitizeTmuxNameDeterministic guards the reconnect contract: two
// calls with the same id must produce byte-identical names.
func TestSanitizeTmuxNameDeterministic(t *testing.T) {
	id := "550e8400-e29b-41d4-a716-446655440000"
	if a, b := sanitizeTmuxName(id), sanitizeTmuxName(id); a != b {
		t.Fatalf("sanitizeTmuxName not deterministic: %q vs %q", a, b)
	}
}

// TestTerminalShellArgv covers both branches: tmux present yields a tmux
// attach-or-create argv carrying the sanitized session name; tmux absent
// falls back to plain bash with no behaviour change.
func TestTerminalShellArgv(t *testing.T) {
	t.Run("tmux-absent-falls-back-to-bash", func(t *testing.T) {
		got := terminalShellArgv("", "kitty-abc")
		want := []string{"bash"}
		if !slices.Equal(got, want) {
			t.Fatalf("terminalShellArgv(\"\", ...): want %v got %v", want, got)
		}
	})

	t.Run("tmux-present-yields-tmux-argv", func(t *testing.T) {
		got := terminalShellArgv("/usr/bin/tmux", "kitty-abc")
		if len(got) != 3 || got[0] != "bash" || got[1] != "-lc" {
			t.Fatalf("expected [bash -lc <script>], got %v", got)
		}
		script := got[2]
		if !strings.Contains(script, "/usr/bin/tmux") {
			t.Fatalf("script missing tmux path: %q", script)
		}
		// attach-or-create: `new-session -A` is the single-command idiom.
		if !strings.Contains(script, "new-session -A") {
			t.Fatalf("script missing attach-or-create form: %q", script)
		}
		if !strings.Contains(script, "kitty-abc") {
			t.Fatalf("script missing session name: %q", script)
		}
	})
}
