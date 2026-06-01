package session

import "testing"

func TestStripTerminalReports(t *testing.T) {
	cases := []struct {
		name string
		in   string
		want string
	}{
		{
			name: "plain text untouched (no escape)",
			in:   "root@nikhil:/root/developer# ls\nprojects\n",
			want: "root@nikhil:/root/developer# ls\nprojects\n",
		},
		{
			name: "DA1 reply stripped",
			in:   "before\x1b[?64;1;2;6;9;15;18;21;22cafter",
			want: "beforeafter",
		},
		{
			name: "DA2 reply stripped",
			in:   "x\x1b[>41;320;0cy",
			want: "xy",
		},
		{
			name: "OSC 10/11 color replies (ST-terminated) stripped",
			in:   "a\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:0000/0000/0000\x1b\\b",
			want: "ab",
		},
		{
			name: "OSC color reply (BEL-terminated) stripped",
			in:   "a\x1b]11;rgb:1234/5678/9abc\x07b",
			want: "ab",
		},
		{
			name: "the exact reported garbage burst",
			in:   "Termux Stage 2 mounted\r\n\x1b[?64;1;2;6;9;15;18;21;22c\x1b[>41;320;0c\x1b]10;rgb:ffff/ffff/ffff\x1b\\\x1b]11;rgb:0000/0000/0000\x1b\\",
			want: "Termux Stage 2 mounted\r\n",
		},
		{
			name: "legitimate color SET (not rgb: reply form) preserved",
			in:   "\x1b]10;#ffffff\x07hello",
			want: "\x1b]10;#ffffff\x07hello",
		},
		{
			name: "legitimate SGR / cursor moves preserved",
			in:   "\x1b[1;32mgreen\x1b[0m\x1b[2J\x1b[H",
			want: "\x1b[1;32mgreen\x1b[0m\x1b[2J\x1b[H",
		},
		{
			name: "DA *request* (no ?/>) preserved — only replies are stripped",
			in:   "\x1b[c\x1b[>c",
			want: "\x1b[c\x1b[>c",
		},
		{
			name: "SGR mouse press+release (echoed tap) stripped",
			in:   "root@nikhil:~# \x1b[<0;28;28M\x1b[<0;28;28m",
			want: "root@nikhil:~# ",
		},
		{
			name: "SGR mouse drag sequence stripped",
			in:   "\x1b[<32;10;5M\x1b[<35;11;6Mdone",
			want: "done",
		},
		{
			name: "DECSET bracketed-paste (?…h, not ?…c) preserved",
			in:   "\x1b[?2004h\x1b[?1049hvim",
			want: "\x1b[?2004h\x1b[?1049hvim",
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := string(stripTerminalReports([]byte(c.in)))
			if got != c.want {
				t.Fatalf("stripTerminalReports(%q)\n  got  %q\n  want %q", c.in, got, c.want)
			}
		})
	}
}

// A chunk with no strippable content must return the SAME backing slice (no
// allocation on the hot path).
func TestStripTerminalReportsNoAllocOnCleanInput(t *testing.T) {
	in := []byte("\x1b[1mbold\x1b[0m plain output line\n")
	out := stripTerminalReports(in)
	if &out[0] != &in[0] {
		t.Fatalf("expected the original slice back for clean input (no realloc)")
	}
}

// terminalFilter must remove a report even when it fragments across reads —
// the real-world failure mode for the startup DA/OSC burst over 8 KB reads.
func TestTerminalFilterFragmentedReports(t *testing.T) {
	// Feed the exact startup burst one byte at a time; the concatenation of all
	// emitted output must contain none of the report bytes.
	burst := "Termux Stage 2 mounted\r\n" +
		"\x1b[?64;1;2;6;9;15;18;21;22c" +
		"\x1b[>41;320;0c" +
		"\x1b]10;rgb:c5c5/c8c8/c6c6\x1b\\" +
		"\x1b]11;rgb:1d1d/1f1f/2121\x1b\\" +
		"root@nikhil:~# "
	var tf terminalFilter
	var out []byte
	for i := 0; i < len(burst); i++ {
		out = append(out, tf.filter([]byte{burst[i]})...)
	}
	out = append(out, tf.filter(nil)...) // flush is a no-op; nothing should be pending
	want := "Termux Stage 2 mounted\r\nroot@nikhil:~# "
	if string(out) != want {
		t.Fatalf("byte-fragmented filter\n  got  %q\n  want %q", string(out), want)
	}
	if len(tf.pending) != 0 {
		t.Fatalf("expected no pending bytes after a fully-terminated stream, got %q", tf.pending)
	}
}

// A report split into two arbitrary halves is still fully removed.
func TestTerminalFilterSplitInHalf(t *testing.T) {
	full := "ls\r\n\x1b]11;rgb:1d1d/1f1f/2121\x1b\\projects\r\n"
	for split := 1; split < len(full); split++ {
		var tf terminalFilter
		out := append([]byte{}, tf.filter([]byte(full[:split]))...)
		out = append(out, tf.filter([]byte(full[split:]))...)
		if got := string(out); got != "ls\r\nprojects\r\n" {
			t.Fatalf("split at %d:\n  got  %q\n  want %q", split, got, "ls\r\nprojects\r\n")
		}
	}
}

// A non-report escape sequence that merely *looks* like a prefix (DECSET ?…h)
// must pass through intact even when split, never be swallowed.
func TestTerminalFilterDoesNotEatDECSET(t *testing.T) {
	full := "\x1b[?2004h"
	for split := 1; split < len(full); split++ {
		var tf terminalFilter
		out := append([]byte{}, tf.filter([]byte(full[:split]))...)
		out = append(out, tf.filter([]byte(full[split:]))...)
		if got := string(out); got != full {
			t.Fatalf("DECSET split at %d should survive: got %q want %q", split, got, full)
		}
	}
}
