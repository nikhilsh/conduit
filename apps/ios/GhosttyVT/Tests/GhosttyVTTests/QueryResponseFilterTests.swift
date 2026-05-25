// Unit tests for `QueryResponseFilter` — the stripper that removes
// libghostty's duplicate terminal-query RESPONSES from the HOST_MANAGED
// `receive_buffer` stream (ghostty-ios-query-response-echo).
//
// These exercise the exact byte sequences seen echoing on-device
// (`^[[?62;22;52c`, `ESC P > | ghostty 1.3.1 ESC \\`) plus the real-input
// sequences that MUST survive (arrows, mouse, bracketed paste, function
// keys). No libghostty dependency — pure Swift, runs everywhere.

import XCTest
@testable import GhosttyVT

final class QueryResponseFilterTests: XCTestCase {
    private let ESC: UInt8 = 0x1B

    private func filtered(_ bytes: [UInt8]) -> [UInt8] {
        let f = QueryResponseFilter()
        return [UInt8](f.filter(Data(bytes)))
    }

    // MARK: - Responses that must be DROPPED

    func testDropsPrimaryDeviceAttributes() {
        // The literal `^[[?62;22;52c` from the bug report.
        let da1: [UInt8] = [ESC] + Array("[?62;22;52c".utf8)
        XCTAssertEqual(filtered(da1), [], "DA1 reply must be stripped")
    }

    func testDropsSecondaryDeviceAttributes() {
        let da2: [UInt8] = [ESC] + Array("[>1;95;0c".utf8)
        XCTAssertEqual(filtered(da2), [], "DA2 reply must be stripped")
    }

    func testDropsXTVersionDCS() {
        // `ESC P > | ghostty 1.3.1 ESC \` — the second bug-report literal.
        let xtversion: [UInt8] = [ESC] + Array("P>|ghostty 1.3.1".utf8) + [ESC, UInt8(ascii: "\\")]
        XCTAssertEqual(filtered(xtversion), [], "XTVERSION reply must be stripped")
    }

    func testDropsTertiaryDeviceAttributesDCS() {
        let da3: [UInt8] = [ESC] + Array("P!|00000000".utf8) + [ESC, UInt8(ascii: "\\")]
        XCTAssertEqual(filtered(da3), [], "DA3 reply must be stripped")
    }

    func testDropsCursorPositionReport() {
        let cpr: [UInt8] = [ESC] + Array("[24;80R".utf8)
        XCTAssertEqual(filtered(cpr), [], "CPR (cursor position) must be stripped")
    }

    func testDropsDeviceStatusReport() {
        let dsr: [UInt8] = [ESC] + Array("[0n".utf8)
        XCTAssertEqual(filtered(dsr), [], "DSR status must be stripped")
    }

    func testDropsDECRPM() {
        let decrpm: [UInt8] = [ESC] + Array("[?2026;2$y".utf8)
        XCTAssertEqual(filtered(decrpm), [], "DECRPM (DECRQM reply) must be stripped")
    }

    func testDropsXTGETTCAPReply() {
        let tcap: [UInt8] = [ESC] + Array("P1+r544e=787465726d2d323536636f6c6f72".utf8) + [ESC, UInt8(ascii: "\\")]
        XCTAssertEqual(filtered(tcap), [], "XTGETTCAP reply must be stripped")
    }

    func testDropsXTVersionTerminatedByBEL() {
        // BEL (0x07) is a valid DCS string terminator (xterm extension).
        let xtversion: [UInt8] = [ESC] + Array("P>|ghostty 1.3.1".utf8) + [0x07]
        XCTAssertEqual(filtered(xtversion), [], "BEL-terminated XTVERSION must be stripped")
    }

    // MARK: - Real input that must be PRESERVED

    func testKeepsArrowKeys() {
        let up: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "A")]
        XCTAssertEqual(filtered(up), up, "Up arrow (CSI A) must pass through")
        let right: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "C")]
        XCTAssertEqual(filtered(right), right, "Right arrow (CSI C) must pass through")
    }

    func testKeepsFunctionKeyTilde() {
        // F5 = CSI 15 ~ ; Home = CSI 1 ~ — `~`-terminated, NOT a response.
        let f5: [UInt8] = [ESC] + Array("[15~".utf8)
        XCTAssertEqual(filtered(f5), f5, "Function key (~ final) must pass through")
    }

    func testKeepsSGRMouseReport() {
        // SGR mouse: CSI < b ; x ; y M  — ends in `M`, real input.
        let mouse: [UInt8] = [ESC] + Array("[<0;10;5M".utf8)
        XCTAssertEqual(filtered(mouse), mouse, "SGR mouse report must pass through")
        let release: [UInt8] = [ESC] + Array("[<0;10;5m".utf8)
        XCTAssertEqual(filtered(release), release, "SGR mouse release (m) must pass through")
    }

    func testKeepsBracketedPasteFraming() {
        let start: [UInt8] = [ESC] + Array("[200~".utf8)
        let end: [UInt8] = [ESC] + Array("[201~".utf8)
        XCTAssertEqual(filtered(start), start, "Bracketed-paste start must pass through")
        XCTAssertEqual(filtered(end), end, "Bracketed-paste end must pass through")
    }

    func testKeepsFocusEvents() {
        let focusIn: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "I")]
        let focusOut: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "O")]
        XCTAssertEqual(filtered(focusIn), focusIn, "Focus-in (CSI I) must pass through")
        XCTAssertEqual(filtered(focusOut), focusOut, "Focus-out (CSI O) must pass through")
    }

    func testKeepsPlainText() {
        let text: [UInt8] = Array("hello world\r\n".utf8)
        XCTAssertEqual(filtered(text), text, "Plain text must pass through untouched")
    }

    func testKeepsBareEscAndSS3() {
        // A bare ESC, and SS3 function keys (ESC O P = F1).
        let bareEsc: [UInt8] = [ESC]
        XCTAssertEqual(filtered(bareEsc), bareEsc, "Bare ESC must pass through")
        let ss3F1: [UInt8] = [ESC, UInt8(ascii: "O"), UInt8(ascii: "P")]
        XCTAssertEqual(filtered(ss3F1), ss3F1, "SS3 F1 (ESC O P) must pass through")
    }

    // MARK: - Mixed / boundary-split streams

    func testStripsResponseFromMixedStream() {
        // Real keystroke + spurious DA1 reply + more real text. Only the
        // DA1 reply is removed; the surrounding input survives in order.
        let input: [UInt8] = Array("a".utf8)
            + [ESC] + Array("[?62;22;52c".utf8)
            + Array("b".utf8)
        XCTAssertEqual(filtered(input), Array("ab".utf8))
    }

    func testReassemblesResponseSplitAcrossChunks() {
        // libghostty can deliver a reply in two `receive_buffer` chunks.
        // The stateful filter must still classify + drop the whole thing.
        let f = QueryResponseFilter()
        let chunk1 = Data([ESC] + Array("[?62;".utf8))
        let chunk2 = Data(Array("22;52c".utf8))
        let out1 = [UInt8](f.filter(chunk1))
        let out2 = [UInt8](f.filter(chunk2))
        XCTAssertEqual(out1 + out2, [], "Split DA1 reply must be fully stripped")
    }

    func testReassemblesXTVersionSplitAtTerminator() {
        let f = QueryResponseFilter()
        let chunk1 = Data([ESC] + Array("P>|ghostty 1.3.1".utf8) + [ESC])
        let chunk2 = Data([UInt8(ascii: "\\")])
        let out1 = [UInt8](f.filter(chunk1))
        let out2 = [UInt8](f.filter(chunk2))
        XCTAssertEqual(out1 + out2, [], "XTVERSION split at ST must be fully stripped")
    }
}
