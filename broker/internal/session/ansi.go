package session

import "unicode/utf8"

// ansiStripper consumes raw PTY bytes and emits only the visible
// printable characters, dropping every escape sequence (CSI/OSC/DCS/
// APC/PM/SOS) and the bare control bytes a TUI uses to reposition the
// cursor. It is a state machine because PTY chunks routinely split an
// escape sequence in half, so a single regex over a buffered prefix
// would either under-strip or be quadratic.
//
// It is intentionally narrow: just enough to turn a Claude or Codex
// reply into something a chat bubble can render. Cursor positioning
// (J/H/K/f) is treated as "drop the control codes"; the surviving
// printable bytes still form a readable transcript because TUIs that
// repaint usually re-emit the same text on the new line.
type ansiStripper struct {
	state stripState
	// out holds the cleaned output of the current Write call. UTF-8
	// multi-byte runes are passed through byte-by-byte because the
	// state machine only branches on the C0/C1 control bytes, which
	// are all single-byte; continuation bytes 0x80-0xBF fall through
	// to feedNormal and append without reinterpretation.
	out []byte
}

type stripState int

const (
	stripNormal stripState = iota
	stripEsc               // saw 0x1B, deciding what kind of sequence
	stripCSI               // CSI parameters/intermediates, awaiting final byte
	stripOSC               // OSC string, awaits ST or BEL
	stripDCS               // DCS string, awaits ST
	stripStrTerm           // Saw ESC inside OSC/DCS, awaiting backslash (ST)
	stripCharset           // single-byte G0/G1 designator follows
)

// Write feeds a chunk of PTY bytes through the stripper and returns
// the visible bytes produced. The returned slice is owned by the
// caller and not retained across Write calls. State carries over
// between calls so split sequences are handled.
func (a *ansiStripper) Write(p []byte) []byte {
	// Reuse the same backing array across calls when possible; cap
	// growth to the input size so a single 256KB scrollback chunk
	// doesn't pin a much larger buffer forever.
	a.out = a.out[:0]
	if cap(a.out) < len(p) {
		a.out = make([]byte, 0, len(p))
	}

	for i := 0; i < len(p); i++ {
		b := p[i]
		switch a.state {
		case stripNormal:
			a.feedNormal(b)
		case stripEsc:
			a.feedEsc(b)
		case stripCSI:
			// Parameter (0x30–0x3F), intermediate (0x20–0x2F), then
			// final byte in 0x40–0x7E ends the sequence.
			if b >= 0x40 && b <= 0x7E {
				a.state = stripNormal
			}
			// All bytes inside CSI are dropped.
		case stripOSC, stripDCS:
			switch b {
			case 0x07: // BEL terminates an OSC string.
				a.state = stripNormal
			case 0x1B: // ESC starts ST (ESC \).
				a.state = stripStrTerm
			}
		case stripStrTerm:
			// We just saw ESC inside an OSC/DCS string; a `\` here
			// completes ST. Anything else: treat as a new escape and
			// keep going (rare, defensive).
			if b == '\\' {
				a.state = stripNormal
			} else {
				a.state = stripEsc
				// Reinterpret this byte under the Esc state by
				// stepping back one.
				i--
			}
		case stripCharset:
			// G0/G1 designators are single byte (B, 0, U, K, …).
			a.state = stripNormal
		}
	}

	return a.out
}

func (a *ansiStripper) feedNormal(b byte) {
	switch {
	case b == 0x1B: // ESC
		a.state = stripEsc
		return
	case b == '\n':
		a.out = append(a.out, '\n')
		return
	case b == '\r':
		// CR alone is a cursor-return — drop. Most TUIs follow it
		// with either \n (handled above) or overwriting prints.
		// Implement the overwrite trick by rewinding the current
		// line: walk back to the previous \n or start of buffer.
		for len(a.out) > 0 && a.out[len(a.out)-1] != '\n' {
			a.out = a.out[:len(a.out)-1]
		}
		return
	case b == '\b':
		// Backspace pops one rune (handling multi-byte runes).
		a.popRune()
		return
	case b == '\t':
		a.out = append(a.out, ' ', ' ', ' ', ' ')
		return
	case b == 0x07: // BEL outside of OSC — drop.
		return
	case b < 0x20:
		// Any other C0 control byte: drop.
		return
	case b == 0x7F: // DEL — drop.
		return
	}
	// Printable. UTF-8: simple byte-by-byte append works because the
	// state machine doesn't reinterpret continuation bytes.
	a.out = append(a.out, b)
}

func (a *ansiStripper) feedEsc(b byte) {
	switch b {
	case '[':
		a.state = stripCSI
	case ']':
		a.state = stripOSC
	case 'P':
		a.state = stripDCS
	case 'X', '^', '_':
		// SOS / PM / APC — same terminator rules as OSC.
		a.state = stripOSC
	case '(', ')', '*', '+':
		a.state = stripCharset
	case 'c':
		// ESC c (RIS) — full reset; treat as a clear.
		a.out = a.out[:0]
		a.state = stripNormal
	default:
		// Any other single-byte escape: drop it and return to normal.
		a.state = stripNormal
	}
}

// popRune removes the trailing UTF-8 codepoint from a.out, accounting
// for multi-byte sequences.
func (a *ansiStripper) popRune() {
	if len(a.out) == 0 {
		return
	}
	_, sz := utf8.DecodeLastRune(a.out)
	if sz == 0 {
		// Malformed tail; just drop one byte.
		sz = 1
	}
	a.out = a.out[:len(a.out)-sz]
}
