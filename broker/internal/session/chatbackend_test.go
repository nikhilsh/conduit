package session

import (
	"errors"
	"testing"
)

// Compile-time proof all structured backends satisfy chatBackend.
var (
	_ chatBackend = (*chatProcess)(nil)
	_ chatBackend = (*codexChatProcess)(nil)
	_ chatBackend = (*codexAppServerProcess)(nil)
)

// TestBackendForResolution pins the protocol→backend registry routing that
// replaced the structuredChatBackend name shim: the three shipped protocols
// resolve to a backend; an empty protocol (legacy TUI-scrape) and an unknown
// protocol resolve to errNoBackend so the caller falls back to the scraper.
func TestBackendForResolution(t *testing.T) {
	resolved := map[string]bool{
		"stream-json":      true,
		"codex-exec":       true,
		"codex-app-server": true,
		"":                 false, // legacy TUI-scrape path
		"bogus":            false, // unknown protocol → clean error
		"STREAM-JSON":      false, // case-sensitive: only the exact key routes
	}
	for proto, wantOK := range resolved {
		b, err := backendFor(proto)
		if wantOK {
			if err != nil || b == nil {
				t.Fatalf("backendFor(%q): got err=%v backend=%v, want a backend", proto, err, b)
			}
			continue
		}
		if err == nil {
			t.Fatalf("backendFor(%q): got nil error, want errNoBackend", proto)
		}
		if !errors.Is(err, errNoBackend) {
			t.Fatalf("backendFor(%q): err=%v, want errNoBackend", proto, err)
		}
	}
}
