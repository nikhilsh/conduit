package session

import "regexp"

// terminalReportRe matches terminal capability *responses* that should never
// appear in a program's OUTPUT stream — they only ever flow terminal→program
// (the answer to a query). Under our headless tmux/PTY setup nothing on the
// broker side consumes these answers, so they get echoed into the pane and
// shipped to clients as visible garbage like:
//
//	^[[?64;1;2;6;9;15;18;21;22c   (DA1, Primary Device Attributes reply)
//	^[[>41;320;0c                 (DA2, Secondary Device Attributes reply)
//	^[]10;rgb:ffff/ffff/ffff^[\   (OSC 10, foreground-color query reply)
//	^[]11;rgb:0000/0000/0000^[\   (OSC 11, background-color query reply)
//
// This reproduces on every client renderer (xterm.js / Termux / Ghostty)
// because the offending bytes are in the broker's stream, not the renderer.
// Stripping them here fixes all clients at once. We match only the
// unambiguous *reply* shapes (the `?`/`>` private-DA forms and the OSC
// color-query `rgb:` reply form), never a request or a legitimate
// color-*set* (`OSC 10;#rrggbb`), so real program output is untouched.
var terminalReportRe = regexp.MustCompile(
	"\x1b\\[\\?[0-9;]*c" + // DA1 reply:  ESC [ ? … c   (request is ESC [ c — no `?`)
		"|\x1b\\[>[0-9]+;[0-9;]*c" + // DA2 reply:  ESC [ > n ; … c  (request is ESC [ > c / ESC [ > 0 c — no `;`)
		"|\x1b\\](?:10|11);rgb:[0-9A-Fa-f/]*(?:\x1b\\\\|\x07)") // OSC 10/11 reply: ESC ] 10|11 ; rgb:… ST

// stripTerminalReports removes spurious terminal capability-query replies from
// a chunk of PTY output. Returns the original slice unchanged when there's
// nothing to strip (the common case — no allocation). Stateless: it only
// removes *complete* reply sequences found within the chunk, so a sequence
// split across two reads is left intact (it renders rarely, but is never
// corrupted) rather than risking a half-stripped stream.
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
	for _, b := range p {
		if b == 0x1b {
			return true
		}
	}
	return false
}
