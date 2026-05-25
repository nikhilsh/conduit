import Testing
import Foundation
import GhosttyVT

/// CI-exercised tests for `GhosttyVT.QueryResponseFilter`
/// (ghostty-ios-query-response-echo).
///
/// The native terminal puts TWO emulators in series: the broker's real
/// kernel PTY + tmux (which already answers DA/XTVERSION/DSR queries) and
/// libghostty re-emulating the same stream on-device. libghostty's
/// duplicate reply, handed back through the HOST_MANAGED `receive_buffer`
/// callback, would otherwise be routed to the broker PTY input and echo as
/// literal `^[[?62;22;52c` / `ghostty 1.3.1` text at the idle bash prompt.
/// This filter strips those duplicate RESPONSES while preserving genuine
/// input (arrows, mouse, paste framing, function keys).
///
/// Mirrors `apps/ios/GhosttyVT/Tests/GhosttyVTTests/QueryResponseFilterTests.swift`
/// so the behaviour is locked in BOTH the SPM package's `swift test` AND
/// the xcodebuild `SweKittyTests` run that CI actually executes.
@Suite("Ghostty query-response filter")
struct QueryResponseFilterSuite {
    private let ESC: UInt8 = 0x1B

    private func filtered(_ bytes: [UInt8]) -> [UInt8] {
        let f = QueryResponseFilter()
        return [UInt8](f.filter(Data(bytes)))
    }

    // MARK: - Responses that must be DROPPED

    @Test func dropsPrimaryDeviceAttributes() {
        let da1: [UInt8] = [ESC] + Array("[?62;22;52c".utf8)
        #expect(filtered(da1) == [])
    }

    @Test func dropsSecondaryDeviceAttributes() {
        let da2: [UInt8] = [ESC] + Array("[>1;95;0c".utf8)
        #expect(filtered(da2) == [])
    }

    @Test func dropsXTVersionDCS() {
        let xtversion: [UInt8] = [ESC] + Array("P>|ghostty 1.3.1".utf8) + [ESC, UInt8(ascii: "\\")]
        #expect(filtered(xtversion) == [])
    }

    @Test func dropsTertiaryDeviceAttributesDCS() {
        let da3: [UInt8] = [ESC] + Array("P!|00000000".utf8) + [ESC, UInt8(ascii: "\\")]
        #expect(filtered(da3) == [])
    }

    @Test func dropsCursorPositionReport() {
        let cpr: [UInt8] = [ESC] + Array("[24;80R".utf8)
        #expect(filtered(cpr) == [])
    }

    @Test func dropsDeviceStatusReport() {
        let dsr: [UInt8] = [ESC] + Array("[0n".utf8)
        #expect(filtered(dsr) == [])
    }

    @Test func dropsDECRPM() {
        let decrpm: [UInt8] = [ESC] + Array("[?2026;2$y".utf8)
        #expect(filtered(decrpm) == [])
    }

    @Test func dropsXTGETTCAPReply() {
        let tcap: [UInt8] = [ESC] + Array("P1+r544e=787465726d".utf8) + [ESC, UInt8(ascii: "\\")]
        #expect(filtered(tcap) == [])
    }

    @Test func dropsBELTerminatedXTVersion() {
        let xtversion: [UInt8] = [ESC] + Array("P>|ghostty 1.3.1".utf8) + [0x07]
        #expect(filtered(xtversion) == [])
    }

    // MARK: - Real input that must be PRESERVED

    @Test func keepsArrowKeys() {
        let up: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "A")]
        #expect(filtered(up) == up)
        let right: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "C")]
        #expect(filtered(right) == right)
    }

    @Test func keepsFunctionKeyTilde() {
        let f5: [UInt8] = [ESC] + Array("[15~".utf8)
        #expect(filtered(f5) == f5)
    }

    @Test func keepsSGRMouseReport() {
        let mouse: [UInt8] = [ESC] + Array("[<0;10;5M".utf8)
        #expect(filtered(mouse) == mouse)
        let release: [UInt8] = [ESC] + Array("[<0;10;5m".utf8)
        #expect(filtered(release) == release)
    }

    @Test func keepsBracketedPasteFraming() {
        let start: [UInt8] = [ESC] + Array("[200~".utf8)
        let end: [UInt8] = [ESC] + Array("[201~".utf8)
        #expect(filtered(start) == start)
        #expect(filtered(end) == end)
    }

    @Test func keepsFocusEvents() {
        let focusIn: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "I")]
        let focusOut: [UInt8] = [ESC, UInt8(ascii: "["), UInt8(ascii: "O")]
        #expect(filtered(focusIn) == focusIn)
        #expect(filtered(focusOut) == focusOut)
    }

    @Test func keepsPlainText() {
        let text: [UInt8] = Array("hello world\r\n".utf8)
        #expect(filtered(text) == text)
    }

    @Test func keepsBareEscAndSS3() {
        let bareEsc: [UInt8] = [ESC]
        #expect(filtered(bareEsc) == bareEsc)
        let ss3F1: [UInt8] = [ESC, UInt8(ascii: "O"), UInt8(ascii: "P")]
        #expect(filtered(ss3F1) == ss3F1)
    }

    // MARK: - Mixed / boundary-split streams

    @Test func stripsResponseFromMixedStream() {
        let input: [UInt8] = Array("a".utf8)
            + [ESC] + Array("[?62;22;52c".utf8)
            + Array("b".utf8)
        #expect(filtered(input) == Array("ab".utf8))
    }

    @Test func reassemblesResponseSplitAcrossChunks() {
        let f = QueryResponseFilter()
        let out1 = [UInt8](f.filter(Data([ESC] + Array("[?62;".utf8))))
        let out2 = [UInt8](f.filter(Data(Array("22;52c".utf8))))
        #expect(out1 + out2 == [])
    }

    @Test func reassemblesXTVersionSplitAtTerminator() {
        let f = QueryResponseFilter()
        let out1 = [UInt8](f.filter(Data([ESC] + Array("P>|ghostty 1.3.1".utf8) + [ESC])))
        let out2 = [UInt8](f.filter(Data([UInt8(ascii: "\\")])))
        #expect(out1 + out2 == [])
    }
}
