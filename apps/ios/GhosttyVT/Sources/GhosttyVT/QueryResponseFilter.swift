// Terminal-query *response* stripper for the double-emulator topology
// (ghostty-ios-query-response-echo).
//
// Why this exists
// ===============
// swe-kitty's native terminal puts TWO VT emulators in series on the
// same byte stream:
//
//   1. The BROKER's real kernel PTY + tmux (`TERM=xterm-256color`,
//      `broker/internal/session/manager.go` → `pty.Start`). This is a
//      genuine terminal: when a program (or tmux at startup) emits a
//      Device-Attributes / XTVERSION / DSR *query*, the broker's real
//      PTY + tmux already answer it — the querying program reads the
//      reply right there, broker-side. The broker OWNS query/response.
//
//   2. libghostty on the iOS client, re-emulating the SAME raw stream
//      that the broker streams down (fed via `ghostty_surface_write_buffer`).
//      Because libghostty is a faithful emulator, it ALSO sees those
//      queries in the stream and AUTO-REPLIES — handing its duplicate
//      answer back to the host through the HOST_MANAGED `receive_buffer`
//      callback (the analog of clauntty's `set_pty_input_callback`).
//
// In the single-emulator reference apps this is correct: clauntty's host
// PTY is a remote SSH shell where libghostty is the ONLY emulator, so its
// reply is the reply; geistty drives tmux in CONTROL MODE (`-CC`, a DCS
// control protocol) so raw VT queries never reach libghostty as text. We
// have neither — we pass raw PTY bytes through a SECOND emulator, so
// libghostty's duplicate reply is spurious. It travels
// `receive_buffer` → `onInput` → broker PTY input and lands at the idle
// bash prompt (no program is reading), where the shell's line discipline
// echoes it as literal visible text:
//
//     ^[[?62;22;52c            (DA1 / primary Device Attributes)
//     :>|ghostty 1.3.1^[\\      (XTVERSION DCS: ESC P > | ghostty 1.3.1 ESC \\)
//
// The fix
// =======
// Strip libghostty's query-RESPONSE sequences out of the `receive_buffer`
// stream before forwarding to the broker PTY. The broker's real terminal
// already answered every query, so libghostty's copy is pure duplication
// and must never reach the PTY input.
//
// This filter removes ONLY sequences that are exclusively terminal
// *replies* — bytes a human keyboard / mouse never produces:
//
//   * Primary   DA  (DA1):  CSI ?  … c        e.g. ESC [ ? 6 2 ; 2 2 ; 5 2 c
//   * Secondary DA  (DA2):  CSI >  … c        e.g. ESC [ > 1 ; 9 5 ; 0 c
//   * Tertiary  DA  (DA3):  DCS !  | … ST
//   * XTVERSION      reply:  DCS >  | … ST     e.g. ESC P > | ghostty 1.3.1 ESC \\
//   * DECRPM (DECRQM reply): CSI ?  … $ y
//   * DSR status report:     CSI    … n  AND   CSI ? … n
//   * Cursor position (CPR): CSI    … R  AND   CSI ? … R  (DECXCPR)
//   * XTGETTCAP / other DCS replies of the form DCS 0|1 + r/+q … ST
//
// What it deliberately PRESERVES (these are real input and MUST pass):
//
//   * Cursor / nav keys:   CSI A/B/C/D/H/F, CSI 1~ … 24~ (function keys)
//   * SGR / X10 mouse:     CSI < … M/m,  CSI M …,  any CSI ending in M/m
//   * Focus in/out:        CSI I, CSI O
//   * Bracketed paste:     CSI 200~, CSI 201~
//   * Bare control bytes / UTF-8 text (anything not inside a CSI/DCS).
//
// The filter is a tiny, allocation-light state machine. It is pure Swift
// (no libghostty / UIKit types) so it lives in GhosttyVT and is exercised
// directly by `GhosttyVTTests` with no device round-trip.

import Foundation

/// Stateful stripper for terminal-query *response* escape sequences.
///
/// Stateful because libghostty may hand us a reply split across multiple
/// `receive_buffer` callbacks (e.g. the `ESC` in one chunk, the `[?62…c`
/// in the next). The instance carries partial-sequence state between
/// `filter(_:)` calls so a boundary split mid-sequence is still classified
/// correctly. One instance per `GhosttySurface`.
public final class QueryResponseFilter {
    public init() {}

    /// Parser state across chunk boundaries.
    private enum State: Equatable {
        /// Not inside an escape sequence. Bytes pass straight through.
        case ground
        /// Saw a lone ESC (0x1B); the next byte decides CSI vs DCS vs
        /// "ESC + something else" (which we pass through).
        case escape
        /// Inside a CSI sequence (`ESC [`). We buffer until the final
        /// byte (0x40–0x7E) and then decide pass vs drop.
        case csi
        /// Inside a DCS sequence (`ESC P`). We buffer until the ST
        /// terminator (`ESC \\` or BEL) and then decide pass vs drop.
        case dcs
        /// Inside a DCS body, having just seen an ESC — waiting to see if
        /// it's the `\\` that completes the `ESC \\` String Terminator.
        case dcsEscape
    }

    private var state: State = .ground
    /// Raw bytes of the in-flight escape sequence, INCLUDING the leading
    /// ESC, so we can re-emit verbatim if it turns out to be input we must
    /// preserve.
    private var pending: [UInt8] = []

    // Control bytes.
    private static let ESC: UInt8 = 0x1B
    private static let BEL: UInt8 = 0x07
    private static let CSI_INTRODUCER: UInt8 = 0x5B // '['
    private static let DCS_INTRODUCER: UInt8 = 0x50 // 'P'
    private static let BACKSLASH: UInt8 = 0x5C // '\\'

    /// Filter one chunk of `receive_buffer` bytes, returning only the
    /// bytes that should be forwarded to the broker PTY (query responses
    /// removed). Partial sequences are retained internally and resolved on
    /// a later call.
    public func filter(_ input: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(input.count)

        for byte in input {
            switch state {
            case .ground:
                if byte == Self.ESC {
                    state = .escape
                    pending = [byte]
                } else {
                    out.append(byte)
                }

            case .escape:
                pending.append(byte)
                switch byte {
                case Self.CSI_INTRODUCER:
                    state = .csi
                case Self.DCS_INTRODUCER:
                    state = .dcs
                default:
                    // `ESC` followed by anything else (e.g. `ESC O P` SS3
                    // function keys, or a bare `ESC` the user pressed) is
                    // not a query response we strip — flush verbatim.
                    out.append(contentsOf: pending)
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                }

            case .csi:
                pending.append(byte)
                // CSI final byte is in 0x40–0x7E. Parameter / intermediate
                // bytes (0x20–0x3F) keep us in the sequence.
                if byte >= 0x40 && byte <= 0x7E {
                    if !isCSIQueryResponse(pending) {
                        out.append(contentsOf: pending)
                    }
                    // else: drop the whole sequence (it was a reply).
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                }

            case .dcs:
                if byte == Self.ESC {
                    state = .dcsEscape
                    pending.append(byte)
                } else if byte == Self.BEL {
                    // BEL also terminates a DCS string (xterm extension).
                    pending.append(byte)
                    if !isDCSQueryResponse(pending) {
                        out.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else {
                    pending.append(byte)
                }

            case .dcsEscape:
                pending.append(byte)
                if byte == Self.BACKSLASH {
                    // Completed `ESC \\` String Terminator.
                    if !isDCSQueryResponse(pending) {
                        out.append(contentsOf: pending)
                    }
                    pending.removeAll(keepingCapacity: true)
                    state = .ground
                } else {
                    // Lone ESC inside the DCS body that wasn't ST — stay in
                    // DCS. (Unusual, but don't desync.) If it was itself an
                    // ESC starting a new ST attempt, fold back.
                    state = (byte == Self.ESC) ? .dcsEscape : .dcs
                }
            }
        }

        // A lone trailing ESC (state `.escape`, nothing after it in this
        // chunk) is NOT the start of a query response we can recognise —
        // every reply we strip continues with a `[` / `P` introducer in the
        // SAME byte run. Flush it so a bare ESC keypress survives instead of
        // being swallowed. Partial CSI/DCS sequences (`.csi`, `.dcs`,
        // `.dcsEscape`) stay buffered so a reply split across chunks is
        // still reassembled and dropped on the next `filter(_:)` call.
        if state == .escape {
            out.append(contentsOf: pending)
            pending.removeAll(keepingCapacity: true)
            state = .ground
        }

        return Data(out)
    }

    /// Classify a complete CSI sequence (leading `ESC [` … final byte) as
    /// a query *response* (true → drop) vs real input (false → keep).
    ///
    /// `seq` includes the leading `ESC` and `[`.
    private func isCSIQueryResponse(_ seq: [UInt8]) -> Bool {
        guard seq.count >= 3 else { return false } // ESC [ <final>
        let final = seq[seq.count - 1]
        // Bytes between the introducer and the final byte (params +
        // private-marker + intermediates).
        let body = seq[2..<(seq.count - 1)]
        let hasPrivateMarker = body.first == UInt8(ascii: "?")
            || body.first == UInt8(ascii: ">")
        let hasDollarIntermediate = body.contains(UInt8(ascii: "$"))

        switch final {
        case UInt8(ascii: "c"):
            // DA1 (CSI ? … c) and DA2 (CSI > … c) are replies. A bare
            // `CSI c` is itself the DA1 *request* — but a request never
            // arrives on the receive_buffer (input) path, and even if it
            // did, dropping a stray request is harmless. Drop on `c` only
            // when a private marker is present (the reply shape), so we
            // never eat a hypothetical user-typed `CSI c`.
            return hasPrivateMarker
        case UInt8(ascii: "R"):
            // CPR (cursor position report) and DECXCPR. Real input never
            // ends a CSI in `R`. Always a reply.
            return true
        case UInt8(ascii: "n"):
            // DSR status reports (CSI n / CSI ? n). Replies only.
            return true
        case UInt8(ascii: "y"):
            // DECRPM (DECRQM reply): CSI ? Ps ; Pm $ y. Reply only.
            return hasPrivateMarker && hasDollarIntermediate
        default:
            // Everything else ending a CSI — A/B/C/D/H/F nav keys, ~ for
            // function / paste-bracket keys, M/m mouse, I/O focus — is
            // real input. Keep it.
            return false
        }
    }

    /// Classify a complete DCS sequence (leading `ESC P` … ST) as a query
    /// *response* (true → drop) vs something to keep (false).
    ///
    /// `seq` includes the leading `ESC P` and the terminating `ESC \\`
    /// (or BEL).
    private func isDCSQueryResponse(_ seq: [UInt8]) -> Bool {
        guard seq.count >= 3 else { return false }
        // Byte right after `ESC P`.
        let marker = seq[2]
        switch marker {
        case UInt8(ascii: ">"):
            // XTVERSION reply: ESC P > | <name> ESC \\.
            return true
        case UInt8(ascii: "!"):
            // Tertiary DA (DA3): ESC P ! | <id> ESC \\.
            return true
        case UInt8(ascii: "0"), UInt8(ascii: "1"):
            // XTGETTCAP reply (`DCS 1 + r … ST` / `DCS 0 + r … ST`) and
            // request-status replies. The digit is the status flag; a
            // following `+r` / `+q` confirms the termcap reply shape.
            if seq.count >= 5 {
                let a = seq[3]
                let b = seq[4]
                if a == UInt8(ascii: "+") && (b == UInt8(ascii: "r") || b == UInt8(ascii: "q")) {
                    return true
                }
            }
            return false
        default:
            // Any other DCS (e.g. DECRQSS replies are `ESC P 1 $ r …` —
            // covered by the `1` case above; sixel image data `ESC P … q`
            // would be `q`-marked but libghostty never emits sixel on the
            // input path) — keep to be safe.
            return false
        }
    }
}
