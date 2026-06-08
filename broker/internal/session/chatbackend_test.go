package session

import "testing"

// Compile-time proof all structured backends satisfy chatBackend.
var (
	_ chatBackend = (*chatProcess)(nil)
	_ chatBackend = (*codexChatProcess)(nil)
	_ chatBackend = (*codexAppServerProcess)(nil)
)

func TestStructuredChatBackend(t *testing.T) {
	cases := map[string]string{
		"stream-json":      "claude",
		"codex-exec":       "codex",
		"codex-app-server": "codex",
		"":                 "",
		"bogus":            "",
		"STREAM-JSON":      "", // case-sensitive: only the exact token routes
	}
	for mode, want := range cases {
		if got := structuredChatBackend(mode); got != want {
			t.Fatalf("structuredChatBackend(%q) = %q, want %q", mode, got, want)
		}
	}
}
