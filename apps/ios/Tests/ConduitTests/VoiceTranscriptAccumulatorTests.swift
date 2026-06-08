import Testing

@testable import Conduit

/// Unit coverage for `VoiceTranscriber.longestSegment` — the guard that stops a
/// pause-time downward hypothesis revision from wiping the on-screen transcript.
///
/// The device-reported bug ("I pause and the text shrinks / starts over") was a
/// shorter, *non-blank* hypothesis overwriting a longer one. The fully-blank
/// case was already handled; the partial-shrink case was not. These tests pin
/// the invariant: the live segment never regresses within a single utterance,
/// while legitimate growth and same-length corrections still apply.
@Suite("VoiceTranscriber.longestSegment")
struct VoiceTranscriptAccumulatorTests {
    @Test("growth is accepted")
    func growthAccepted() {
        #expect(VoiceTranscriber.longestSegment(current: "the", next: "the quick") == "the quick")
    }

    @Test("a shorter non-blank revision is ignored — the wipe bug")
    func shorterRevisionIgnored() {
        // Recognizer regresses to a shorter prefix right before a pause.
        #expect(
            VoiceTranscriber.longestSegment(current: "fix the parser bug", next: "fix the")
                == "fix the parser bug"
        )
    }

    @Test("a blank or whitespace revision is ignored")
    func blankRevisionIgnored() {
        #expect(VoiceTranscriber.longestSegment(current: "hello world", next: "") == "hello world")
        #expect(VoiceTranscriber.longestSegment(current: "hello world", next: "   ") == "hello world")
    }

    @Test("the first words of a segment are accepted from empty")
    func acceptsFromEmpty() {
        #expect(VoiceTranscriber.longestSegment(current: "", next: "hello") == "hello")
    }

    @Test("an equal-length correction still applies")
    func equalLengthCorrectionApplies() {
        #expect(VoiceTranscriber.longestSegment(current: "their", next: "there") == "there")
    }

    @Test("the segment never regresses across a noisy partial stream")
    func monotonicAcrossSequence() {
        // The partial stream around a pause: build up, then the engine emits a
        // shorter prefix (and a blank) before recovering. The displayed segment
        // must never lose ground, and must land on the full final hypothesis.
        let stream = ["fix", "fix the", "fix the parser", "fix the", "", "fix the parser bug"]
        var segment = ""
        var longestLen = 0
        for partial in stream {
            segment = VoiceTranscriber.longestSegment(current: segment, next: partial)
            let len = segment.trimmingCharacters(in: .whitespacesAndNewlines).count
            #expect(len >= longestLen)
            longestLen = len
        }
        #expect(segment == "fix the parser bug")
    }
}
