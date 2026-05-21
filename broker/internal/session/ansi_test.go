package session

import "testing"

func TestAnsiStripper(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{"plain ascii", "hello world\n", "hello world\n"},
		{"sgr color codes", "\x1b[31mred\x1b[0m text", "red text"},
		{"osc title", "\x1b]0;window title\x07visible", "visible"},
		{"osc st-terminated", "\x1b]0;t\x1b\\after", "after"},
		{"dcs ignored", "\x1bP1;0|payload\x1b\\seen", "seen"},
		{"cr overwrite", "abc\rXYZ", "XYZ"},
		{"backspace pops rune", "abc\b", "ab"},
		{"backspace utf-8 rune", "ab漢\b", "ab"},
		{"tab to spaces", "a\tb", "a    b"},
		{"bel dropped", "x\x07y", "xy"},
		{"cursor move dropped", "a\x1b[10;5Hb", "ab"},
		{"clear screen dropped", "\x1b[2Jhello", "hello"},
		{"ris esc-c resets", "before\x1bcafter", "after"},
		{"newlines preserved", "a\nb\nc", "a\nb\nc"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			var s ansiStripper
			got := string(s.Write([]byte(tc.in)))
			if got != tc.want {
				t.Errorf("got %q, want %q", got, tc.want)
			}
		})
	}
}

func TestAnsiStripperSplitChunks(t *testing.T) {
	// CSI sequence split across two Write calls — state machine must
	// carry across.
	var s ansiStripper
	first := string(s.Write([]byte("a\x1b[")))
	second := string(s.Write([]byte("31mred\x1b[0m")))
	if got := first + second; got != "ared" {
		t.Errorf("split-CSI got %q, want %q", got, "ared")
	}
}

func TestAnsiStripperSplitUTF8(t *testing.T) {
	// Multi-byte UTF-8 rune split across two chunks; nothing should
	// be corrupted.
	rune漢 := []byte("漢")
	var s ansiStripper
	first := string(s.Write([]byte{rune漢[0]}))
	second := string(s.Write([]byte{rune漢[1], rune漢[2]}))
	if got := first + second; got != "漢" {
		t.Errorf("split-utf8 got %q, want %q", got, "漢")
	}
}
