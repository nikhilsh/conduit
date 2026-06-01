package session

import (
	"bytes"
	"regexp"
)

// terminalReportRe matches terminal capability *responses* and mouse *reports*
// that should never appear in a program's OUTPUT stream — they only ever flow
// terminal→program (the answer to a query, or a mouse event). Under our
// headless tmux/PTY setup nothing on the broker side consumes these, so they
// get echoed into the pane and shipped to clients as visible garbage like:
//
//	^[[?64;1;2;6;9;15;18;21;22c   (DA1, Primary Device Attributes reply)
//	^[[>41;320;0c                 (DA2, Secondary Device Attributes reply)
//	^[]10;rgb:ffff/ffff/ffff^[\   (OSC 10, foreground-color query reply)
//	^[]11;rgb:0000/0000/0000^[\   (OSC 11, background-color query reply)
//	^[[<0;28;28M ^[[<0;28;28m      (SGR mouse press/release report — a tap)
//
// This reproduces on every client renderer (xterm.js / Termux / Ghostty)
// because the offending bytes are in the broker's stream, not the renderer.
// Stripping them here fixes all clients at once. We match only the
// unambiguous *reply*/report shapes (the `?`/`>` private-DA forms, the OSC
// color-query `rgb:` reply form, and the SGR `<…M/m` mouse form), never a
// request or a legitimate color-*set* (`OSC 10;#rrggbb`), so real program
// output is untouched.
var terminalReportRe = regexp.MustCompile(
	"\x1b\\[\\?[0-9;]*c" + // DA1 reply:  ESC [ ? … c   (request is ESC [ c — no `?`)
		"|\x1b\\[>[0-9]+;[0-9;]*c" + // DA2 reply:  ESC [ > n ; … c  (request is ESC [ > c / ESC [ > 0 c — no `;`)
		"|\x1b\\](?:10|11);rgb:[0-9A-Fa-f/]*(?:\x1b\\\\|\x07)" + // OSC 10/11 reply: ESC ] 10|11 ; rgb:… ST
		"|\x1b\\[<[0-9;]+[Mm]") // SGR mouse report: ESC [ < btn ; col ; row M|m (a tap echoed by a non-mouse shell)

// stripTerminalReports removes spurious terminal capability-query replies and
// mouse reports from a chunk of PTY output. Returns the original slice
// unchanged when there's nothing to strip (the common case — no allocation).
// Stateless: it only removes *complete* sequences found within the chunk. A
// sequence split across two reads is handled by terminalFilter, which carries
// the trailing partial into the next chunk before calling this.
func stripTerminalReports(p []byte) []byte {
	// Fast path: ESC is required for any of the patterns. Skip the regexp
	// (and its allocation) entirely for the overwhelmingly common ESC-free
	// or plain-text chunk.
	if !hasEscape(p) {
		return p
	}
	if terminalReportRe.Find(p) == nil {
		return p
	}
	return terminalReportRe.ReplaceAll(p, nil)
}

func hasEscape(p []byte) bool {
	return bytes.IndexByte(p, 0x1b) >= 0
}

// terminalFilter is the stateful wrapper around stripTerminalReports owned by a
// single drain goroutine. It carries a trailing *partial* report (one split
// across PTY read boundaries) into the next chunk so fragmented reports are
// still removed instead of leaking. The startup DA/OSC burst routinely
// fragments across the 8 KB drain reads — that fragmentation, not a regex gap,
// is why reports were still reaching clients. Only drain touches a
// terminalFilter (it's a drain-local value), so no locking is needed.
type terminalFilter struct {
	pending []byte
}

// maxPendingReport caps how many bytes we hold waiting for a partial report to
// complete. Our longest report (an OSC color reply) is well under this; once
// the held run outgrows it, it is provably not one of our sequences, so we stop
// holding and release it intact.
const maxPendingReport = 64

// filter strips complete reports from chunk (after prepending any partial held
// from the previous call) and holds back a new trailing partial for next time.
// The returned slice is safe for the caller to retain: held bytes are copied
// into a fresh buffer, never aliased into the returned slice.
func (tf *terminalFilter) filter(chunk []byte) []byte {
	p := chunk
	if len(tf.pending) > 0 {
		p = append(tf.pending, chunk...)
		tf.pending = nil
	}
	p = stripTerminalReports(p)
	i := trailingPartialReport(p)
	if i < 0 {
		return p
	}
	if len(p)-i > maxPendingReport {
		// Held run outgrew any real report — it isn't one of ours; release it.
		return p
	}
	tf.pending = append([]byte(nil), p[i:]...)
	return p[:i]
}

// trailingPartialReport returns the index where a trailing, still-incomplete
// report sequence begins (one we should hold for the next read), or -1 if p
// does not end mid-report. p has already had all *complete* reports stripped,
// so any unterminated report prefix found here is genuinely a fragment.
//
// It scans ESC positions backward to the *earliest* ESC that still yields a
// partial-report prefix. This matters for OSC color replies: their ST
// terminator (ESC \) embeds an ESC, so a split right at the ST would otherwise
// latch onto that inner ESC and wrongly emit the OSC body. We only look back a
// bounded window — a real report is short, and anything longer is released by
// the maxPendingReport cap in filter() anyway.
func trailingPartialReport(p []byte) int {
	best := -1
	limit := len(p) - (maxPendingReport + 4)
	if limit < 0 {
		limit = 0
	}
	for i := len(p) - 1; i >= limit; i-- {
		if p[i] != 0x1b {
			continue
		}
		if isPartialReportPrefix(p[i:]) {
			best = i // an enclosing partial may start even earlier — keep going
			continue
		}
		break // this ESC began a complete / non-report sequence; boundary found
	}
	return best
}

// isPartialReportPrefix reports whether t (which begins with ESC) is the
// unterminated prefix of one of our report sequences. It is deliberately
// strict: a CSI that isn't a `?`/`>`/`<` private form, or an OSC that isn't a
// 10/11 color reply, returns false so we never delay ordinary escape sequences
// (SGR colors, DECSET like `?2004h`, window-title OSC, …) by a read.
func isPartialReportPrefix(t []byte) bool {
	if len(t) == 1 {
		return true // lone ESC — could begin any report
	}
	switch t[1] {
	case '[':
		if len(t) == 2 {
			return true // ESC[ — still ambiguous (next byte could be ? > <)
		}
		switch t[2] {
		case '?', '>', '<':
			// DA1 (?…c), DA2 (>…c), SGR mouse (<…M/m): params are digits and
			// ';' until a terminator. Complete forms were already stripped, so
			// a clean digit/';' run with no terminator is a held partial; any
			// other byte means it's terminated as something that isn't ours.
			for _, b := range t[3:] {
				if (b < '0' || b > '9') && b != ';' {
					return false
				}
			}
			return true
		default:
			return false
		}
	case ']':
		if len(t) == 2 {
			return true // ESC] — could begin OSC 10/11
		}
		return isOSCColorPartial(t[2:])
	default:
		return false
	}
}

// isOSCColorPartial reports whether body (the bytes after ESC]) is the
// unterminated prefix of an OSC 10/11 color reply (`10;rgb:<hex/>` or
// `11;rgb:<hex/>`, the ST terminator not yet seen).
func isOSCColorPartial(body []byte) bool {
	return oscColorBodyPartial(body, "10;rgb:") || oscColorBodyPartial(body, "11;rgb:")
}

func oscColorBodyPartial(body []byte, fixed string) bool {
	if len(body) <= len(fixed) {
		return string(body) == fixed[:len(body)]
	}
	if string(body[:len(fixed)]) != fixed {
		return false
	}
	rest := body[len(fixed):]
	// A trailing lone ESC is the start of an unterminated ST (ESC \) — still
	// part of this partial, so tolerate it as the final byte.
	if len(rest) > 0 && rest[len(rest)-1] == 0x1b {
		rest = rest[:len(rest)-1]
	}
	for _, b := range rest {
		if !isHexDigit(b) && b != '/' {
			return false
		}
	}
	return true
}

func isHexDigit(b byte) bool {
	return (b >= '0' && b <= '9') || (b >= 'a' && b <= 'f') || (b >= 'A' && b <= 'F')
}
