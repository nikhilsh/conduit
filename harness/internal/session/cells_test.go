// Package session — Stage F · Phase 1 sanity tests for the vt10x
// cell emulator scaffold. These tests pin down the bits of the upstream
// library we rely on (cell grid, cursor, alt-screen mode flag) so that
// future phases can build the cell-based Snapshot() serializer with
// confidence.
//
// Phase 1 does NOT change Snapshot() behaviour; these tests only exercise
// the emulator directly. See docs/PLAN-TERMINAL-CELLS.md.
package session

import (
	"testing"

	"github.com/hinshun/vt10x"
)

// TestEmulatorAcceptsBytes is the smoke test: a fresh emulator must not
// crash when fed a representative byte sequence — clear screen, alt
// screen enter, SGR set, a few glyphs, cursor home — and must end with
// the expected cell + cursor + mode state.
func TestEmulatorAcceptsBytes(t *testing.T) {
	term := vt10x.New(vt10x.WithSize(80, 24))

	// CSI 2 J        — clear screen
	// CSI ? 1049 h   — enter alt screen
	// CSI 1 m        — bold
	// CSI 31 m       — red fg
	// "hello"
	// CSI 2 ; 1 H    — cursor row 2, col 1
	// "world"
	payload := []byte(
		"\x1b[2J" +
			"\x1b[?1049h" +
			"\x1b[1m" +
			"\x1b[31m" +
			"hello" +
			"\x1b[2;1H" +
			"world",
	)
	n, err := term.Write(payload)
	if err != nil {
		t.Fatalf("term.Write: %v", err)
	}
	if n != len(payload) {
		t.Fatalf("short write: got %d, want %d", n, len(payload))
	}

	cols, rows := term.Size()
	if cols != 80 || rows != 24 {
		t.Fatalf("size: got (%d,%d), want (80,24)", cols, rows)
	}

	// Alt-screen mode must be active.
	if term.Mode()&vt10x.ModeAltScreen == 0 {
		t.Fatalf("expected ModeAltScreen to be set; got mode flags %x", uint32(term.Mode()))
	}

	// Row 0 should start with "hello".
	want := []rune{'h', 'e', 'l', 'l', 'o'}
	for i, r := range want {
		g := term.Cell(i, 0)
		if g.Char != r {
			t.Errorf("cell (%d,0): got %q, want %q", i, g.Char, r)
		}
	}

	// Row 1 should start with "world".
	want2 := []rune{'w', 'o', 'r', 'l', 'd'}
	for i, r := range want2 {
		g := term.Cell(i, 1)
		if g.Char != r {
			t.Errorf("cell (%d,1): got %q, want %q", i, g.Char, r)
		}
	}

	// Cursor should be at row 1 (0-indexed), col 5 (after "world").
	cur := term.Cursor()
	if cur.Y != 1 || cur.X != 5 {
		t.Errorf("cursor: got (x=%d,y=%d), want (x=5,y=1)", cur.X, cur.Y)
	}
}

// TestEmulatorResize verifies Resize takes (cols, rows) in that order —
// the inverse of pty.Setsize — so Session.Resize wires the arguments
// correctly.
func TestEmulatorResize(t *testing.T) {
	term := vt10x.New(vt10x.WithSize(80, 24))
	term.Resize(132, 50)
	cols, rows := term.Size()
	if cols != 132 || rows != 50 {
		t.Fatalf("after Resize(132,50): got (%d,%d), want (132,50)", cols, rows)
	}
}
