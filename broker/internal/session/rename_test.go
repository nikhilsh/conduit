package session

import (
	"strings"
	"testing"
)

// TestDisplayNameRegex pins the §3.3 wire-validation contract: 1..32
// chars from `[A-Za-z0-9 _-]`. The regex by itself permits a single
// space — the additional "whitespace-only" carve-out is enforced in
// SetDisplayName (see TestSetDisplayNameRejectsWhitespaceOnly).
func TestDisplayNameRegex(t *testing.T) {
	cases := []struct {
		label string
		in    string
		ok    bool
	}{
		{"single-char", "x", true},
		{"max-len", "abcdefghijklmnopqrstuvwxyz012345", true}, // 32 chars
		{"with-space", "rust core", true},
		{"with-underscore", "feature_42", true},
		{"with-hyphen", "feature-42", true},
		{"empty", "", false},
		{"thirty-three", strings.Repeat("x", 33), false},
		{"slash", "feature/branch", false},
		{"newline", "feature\n", false},
		{"unicode", "naïve", false},
		{"tab", "a\tb", false},
	}
	for _, tc := range cases {
		t.Run(tc.label, func(t *testing.T) {
			if got := displayNameRegex.MatchString(tc.in); got != tc.ok {
				t.Fatalf("displayNameRegex(%q): want %v got %v", tc.in, tc.ok, got)
			}
		})
	}
}

// TestSetDisplayNameRejectsWhitespaceOnly covers the spec note that
// "whitespace-only strings ... are rejected silently". The regex alone
// would accept "   " because ASCII space is in the character class —
// SetDisplayName layers an explicit trim-and-reject on top.
func TestSetDisplayNameRejectsWhitespaceOnly(t *testing.T) {
	cases := []struct {
		label string
		in    string
		ok    bool
	}{
		{"valid-with-spaces", "rust core", true},
		{"single-space", " ", false},
		{"all-spaces", "      ", false},
	}
	for _, tc := range cases {
		t.Run(tc.label, func(t *testing.T) {
			s := &Session{}
			if got := s.SetDisplayName(tc.in); got != tc.ok {
				t.Fatalf("SetDisplayName(%q): want %v got %v", tc.in, tc.ok, got)
			}
			if tc.ok && s.DisplayName() != tc.in {
				t.Fatalf("DisplayName: want %q got %q", tc.in, s.DisplayName())
			}
			if !tc.ok && s.DisplayName() != "" {
				t.Fatalf("expected DisplayName to stay empty after reject; got %q", s.DisplayName())
			}
		})
	}
}
