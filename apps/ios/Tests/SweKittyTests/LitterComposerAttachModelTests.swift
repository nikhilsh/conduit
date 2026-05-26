import Foundation
import Testing
@testable import SweKitty

/// Pure-data assertions for the LitterUI composer attach sheet. Mirror
/// of Android `ComposerAttachModelTest` (PR #240) — same kind order,
/// titles, reference tokens, MIME fallback, size limits, the
/// cross-surface reference-line convention, and `composeOutgoingMessage`
/// folding. Runs without a SwiftUI host.
@Suite("LitterUI.ComposerAttachment")
struct LitterComposerAttachModelTests {

    @Test func attachKinds_orderedImageThenFile() {
        // The "+" menu renders one row per AttachKind in declaration
        // order — iOS leads with image, Android matches. Locking the
        // order prevents an accidental swap that would silently change
        // the default attach affordance.
        #expect(LitterUI.AttachKind.allCases == [.image, .file])
    }

    @Test func titles_matchAndroidCopy() {
        #expect(LitterUI.AttachKind.image.title == "Attach image")
        #expect(LitterUI.AttachKind.file.title == "Attach file")
    }

    @Test func referenceTokens_lowercaseImageAndFile() {
        // The reference line embeds this token so the agent knows how
        // to treat the path. Android mirrors the same two tokens.
        #expect(LitterUI.AttachKind.image.referenceToken == "image")
        #expect(LitterUI.AttachKind.file.referenceToken == "file")
    }

    @Test func mimeFallback_emptyExtension() {
        // The pure variant doesn't touch UTType. Empty extension →
        // octet-stream, matching Android.
        #expect(LitterUI.ComposerMime.fromExtensionOrDefault(nil) { _ in nil } == "application/octet-stream")
        #expect(LitterUI.ComposerMime.fromExtensionOrDefault("") { _ in nil } == "application/octet-stream")
    }

    @Test func mimeFallback_unknownExtension() {
        // Unknown extension the map can't classify → octet-stream.
        // Lookup is case-folded so HEIC and heic resolve identically.
        #expect(
            LitterUI.ComposerMime.fromExtensionOrDefault("xyzunknown") { _ in nil }
            == "application/octet-stream"
        )
    }

    @Test func mimeFallback_knownExtension() {
        // When the underlying map returns something, surface it
        // unchanged; the closure receives the lowercased extension.
        let fake: (String) -> String? = { $0 == "pdf" ? "application/pdf" : nil }
        #expect(LitterUI.ComposerMime.fromExtensionOrDefault("PDF", fake) == "application/pdf")
        #expect(LitterUI.ComposerMime.fromExtensionOrDefault("pdf", fake) == "application/pdf")
    }

    @Test func referenceLine_imageMatchesCrossSurfaceConvention() {
        // The agent acts on this line: it points at the broker-written
        // upload path relative to the session workspace. Android mirrors
        // the identical "[attached <kind>: <filename> — uploads/<sid>/<name>]"
        // shape so one regex parses both surfaces.
        let line = LitterUI.attachmentReferenceLine(
            kind: .image,
            filename: "IMG_0123.HEIC",
            sessionID: "sess-42"
        )
        #expect(line == "[attached image: IMG_0123.HEIC — uploads/sess-42/IMG_0123.HEIC]")

        let regex = try! NSRegularExpression(pattern: "^\\[attached (image|file): (.+) — uploads/([^/]+)/(.+)]$")
        let range = NSRange(line.startIndex..., in: line)
        let match = regex.firstMatch(in: line, range: range)
        #expect(match != nil)
        if let match {
            #expect(group(match, 1, in: line) == "image")
            #expect(group(match, 2, in: line) == "IMG_0123.HEIC")
            #expect(group(match, 3, in: line) == "sess-42")
            #expect(group(match, 4, in: line) == "IMG_0123.HEIC")
        }
    }

    @Test func referenceLine_fileMatchesCrossSurfaceConvention() {
        let line = LitterUI.attachmentReferenceLine(
            kind: .file,
            filename: "spec.pdf",
            sessionID: "sess-7"
        )
        #expect(line == "[attached file: spec.pdf — uploads/sess-7/spec.pdf]")

        let regex = try! NSRegularExpression(pattern: "^\\[attached (image|file): (.+) — uploads/([^/]+)/(.+)]$")
        let range = NSRange(line.startIndex..., in: line)
        let match = regex.firstMatch(in: line, range: range)
        #expect(match != nil)
        if let match {
            #expect(group(match, 1, in: line) == "file")
            #expect(group(match, 4, in: line) == "spec.pdf")
        }
    }

    @Test func referenceLine_usesEmDashSeparator() {
        // The separator is U+2014 (em-dash) with surrounding spaces, not
        // a hyphen — Android pins the identical codepoint.
        let line = LitterUI.attachmentReferenceLine(kind: .image, filename: "a.png", sessionID: "s")
        #expect(line.contains(" \u{2014} "))
    }

    @Test func attachment_sizeReflectsBytes() {
        let att = LitterUI.ComposerAttachment(
            kind: .file,
            filename: "a.bin",
            mimeType: "application/octet-stream",
            bytes: Data(count: 123)
        )
        #expect(att.sizeBytes == 123)
    }

    @Test func attachment_structuralEquality() {
        let a = LitterUI.ComposerAttachment(id: "x", kind: .image, filename: "p.png", mimeType: "image/png", bytes: Data([1, 2, 3]))
        let b = LitterUI.ComposerAttachment(id: "x", kind: .image, filename: "p.png", mimeType: "image/png", bytes: Data([1, 2, 3]))
        let c = LitterUI.ComposerAttachment(id: "x", kind: .image, filename: "p.png", mimeType: "image/png", bytes: Data([9]))
        #expect(a == b)
        #expect(a != c)
    }

    @Test func sizeLimit_rejectsEmptyAndOversized() {
        #expect(!LitterUI.ComposerAttachmentLimits.isWithinLimit(0))
        #expect(LitterUI.ComposerAttachmentLimits.isWithinLimit(1))
        #expect(LitterUI.ComposerAttachmentLimits.isWithinLimit(LitterUI.ComposerAttachmentLimits.maxBytes))
        #expect(!LitterUI.ComposerAttachmentLimits.isWithinLimit(LitterUI.ComposerAttachmentLimits.maxBytes + 1))
    }

    @Test func sizeLimit_is20MB() {
        // Matches Android's ComposerAttachmentLimits.MAX_BYTES.
        #expect(LitterUI.ComposerAttachmentLimits.maxBytes == 20 * 1024 * 1024)
    }

    @Test func composeOutgoingMessage_attachmentReferenceAppendedAfterDraft() {
        let att = LitterUI.ComposerAttachment(
            id: "a",
            kind: .file,
            filename: "spec.pdf",
            mimeType: "application/pdf",
            bytes: Data([0])
        )
        let msg = LitterUI.composeOutgoingMessage(
            draft: "please review",
            pendingAttachments: [att],
            sessionID: "sess-1"
        )
        #expect(msg.hasPrefix("please review"))
        #expect(msg.contains("[attached file: spec.pdf — uploads/sess-1/spec.pdf]"))
        // The base64 payload is NOT inlined — bytes go over the upload
        // frame, only the path reference rides the message.
        #expect(!msg.contains("base64"))
    }

    @Test func composeOutgoingMessage_multipleAttachmentsEachReferenced() {
        let img = LitterUI.ComposerAttachment(id: "i", kind: .image, filename: "a.png", mimeType: "image/png", bytes: Data([1]))
        let pdf = LitterUI.ComposerAttachment(id: "p", kind: .file, filename: "b.pdf", mimeType: "application/pdf", bytes: Data([2]))
        let msg = LitterUI.composeOutgoingMessage(
            draft: "look",
            pendingAttachments: [img, pdf],
            sessionID: "S"
        )
        #expect(msg.contains("[attached image: a.png — uploads/S/a.png]"))
        #expect(msg.contains("[attached file: b.pdf — uploads/S/b.pdf]"))
    }

    @Test func composeOutgoingMessage_emptyDraftAndNothingPending_returnsEmpty() {
        let msg = LitterUI.composeOutgoingMessage(
            draft: "   ",
            pendingAttachments: [],
            sessionID: "sess-1"
        )
        #expect(msg == "")
    }

    @Test func composeOutgoingMessage_attachmentOnlyStillSends() {
        // An attachment with no typed draft must still produce a
        // non-empty message (the reference line), so the send path
        // isn't a no-op.
        let att = LitterUI.ComposerAttachment(kind: .image, filename: "a.png", mimeType: "image/png", bytes: Data([1]))
        let msg = LitterUI.composeOutgoingMessage(
            draft: "",
            pendingAttachments: [att],
            sessionID: "sess-9"
        )
        #expect(msg == "[attached image: a.png — uploads/sess-9/a.png]")
    }

    // MARK: Helpers

    private func group(_ match: NSTextCheckingResult, _ idx: Int, in string: String) -> String? {
        guard let range = Range(match.range(at: idx), in: string) else { return nil }
        return String(string[range])
    }
}
