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
