package sh.nikhil.conduit.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Pure-data assertions for the composer attach sheet. Mirror of iOS
 * `ComposerAttachSheetModelTests`. Runs under plain JUnit — no
 * Robolectric, no Compose runtime, no Android framework.
 */
class ComposerAttachModelTest {

    @Test fun attachKinds_orderedImageThenFile() {
        // The bottom-sheet renders one row per AttachKind in declaration
        // order — iOS leads with image, Android matches. Locking the
        // order here prevents an accidental swap that would silently
        // change the default attach affordance.
        val kinds = AttachKind.values().toList()
        assertEquals(listOf(AttachKind.Image, AttachKind.File), kinds)
    }

    @Test fun titles_matchIOSCopy() {
        assertEquals("Attach image", AttachKind.Image.title)
        assertEquals("Attach file", AttachKind.File.title)
    }

    @Test fun referenceTokens_lowercaseImageAndFile() {
        // The reference line embeds this token so the agent knows how to
        // treat the path. iOS mirrors the same two tokens.
        assertEquals("image", AttachKind.Image.referenceToken)
        assertEquals("file", AttachKind.File.referenceToken)
    }

    @Test fun mimeFallback_emptyExtension() {
        // ComposerMime.fromExtensionOrDefault is the pure variant so we
        // don't have to spin up MimeTypeMap (which needs Android). Empty
        // extension → octet-stream, matching iOS UTType behaviour.
        assertEquals(
            "application/octet-stream",
            ComposerMime.fromExtensionOrDefault(null) { null },
        )
        assertEquals(
            "application/octet-stream",
            ComposerMime.fromExtensionOrDefault("") { null },
        )
    }

    @Test fun mimeFallback_unknownExtension() {
        // Unknown extension that the map can't classify → octet-stream.
        // The lookup is case-folded to lowercase so HEIC and heic both
        // resolve identically.
        assertEquals(
            "application/octet-stream",
            ComposerMime.fromExtensionOrDefault("xyzunknown") { null },
        )
    }

    @Test fun mimeFallback_knownExtension() {
        // When the underlying map returns something, we surface it
        // unchanged. The lambda receives the lowercased extension.
        val fake: (String) -> String? = { ext -> if (ext == "pdf") "application/pdf" else null }
        assertEquals("application/pdf", ComposerMime.fromExtensionOrDefault("PDF", fake))
        assertEquals("application/pdf", ComposerMime.fromExtensionOrDefault("pdf", fake))
    }

    @Test fun referenceLine_imageMatchesCrossSurfaceConvention() {
        // The agent acts on this line: it points at the broker-written
        // upload path relative to the session workspace. iOS mirrors the
        // identical "[attached <kind>: <filename> — uploads/<sid>/<name>]"
        // shape so one regex parses both surfaces.
        val line = attachmentReferenceLine(
            kind = AttachKind.Image,
            filename = "IMG_0123.HEIC",
            sessionId = "sess-42",
        )
        assertEquals(
            "[attached image: IMG_0123.HEIC — uploads/sess-42/IMG_0123.HEIC]",
            line,
        )
        val regex = Regex("^\\[attached (image|file): (.+) — uploads/([^/]+)/(.+)]\$")
        val match = regex.find(line)
        assertNotNull("reference line must match the cross-surface regex", match)
        assertEquals("image", match!!.groupValues[1])
        assertEquals("IMG_0123.HEIC", match.groupValues[2])
        assertEquals("sess-42", match.groupValues[3])
        assertEquals("IMG_0123.HEIC", match.groupValues[4])
    }

    @Test fun referenceLine_fileMatchesCrossSurfaceConvention() {
        val line = attachmentReferenceLine(
            kind = AttachKind.File,
            filename = "spec.pdf",
            sessionId = "sess-7",
        )
        assertEquals(
            "[attached file: spec.pdf — uploads/sess-7/spec.pdf]",
            line,
        )
        val regex = Regex("^\\[attached (image|file): (.+) — uploads/([^/]+)/(.+)]\$")
        val match = regex.find(line)
        assertNotNull(match)
        assertEquals("file", match!!.groupValues[1])
        assertEquals("spec.pdf", match.groupValues[4])
    }

    @Test fun attachment_sizeReflectsBytes() {
        val att = ComposerAttachment(
            kind = AttachKind.File,
            filename = "a.bin",
            mimeType = "application/octet-stream",
            bytes = ByteArray(123),
        )
        assertEquals(123, att.sizeBytes)
    }

    @Test fun attachment_structuralEquality() {
        // data class equality on a ByteArray field would compare by
        // reference; we override equals/hashCode to compare contents so
        // de-dupe + test assertions are honest.
        val a = ComposerAttachment(id = "x", kind = AttachKind.Image, filename = "p.png", mimeType = "image/png", bytes = byteArrayOf(1, 2, 3))
        val b = ComposerAttachment(id = "x", kind = AttachKind.Image, filename = "p.png", mimeType = "image/png", bytes = byteArrayOf(1, 2, 3))
        val c = ComposerAttachment(id = "x", kind = AttachKind.Image, filename = "p.png", mimeType = "image/png", bytes = byteArrayOf(9))
        assertEquals(a, b)
        assertEquals(a.hashCode(), b.hashCode())
        assertFalse(a == c)
    }

    @Test fun sizeLimit_rejectsEmptyAndOversized() {
        assertFalse(ComposerAttachmentLimits.isWithinLimit(0))
        assertTrue(ComposerAttachmentLimits.isWithinLimit(1))
        assertTrue(ComposerAttachmentLimits.isWithinLimit(ComposerAttachmentLimits.MAX_BYTES))
        assertFalse(ComposerAttachmentLimits.isWithinLimit(ComposerAttachmentLimits.MAX_BYTES + 1))
    }

    @Test fun composeOutgoingMessage_attachmentReferenceAppendedAfterDraft() {
        val att = ComposerAttachment(
            id = "a",
            kind = AttachKind.File,
            filename = "spec.pdf",
            mimeType = "application/pdf",
            bytes = byteArrayOf(0),
        )
        val msg = composeOutgoingMessage(
            draft = "please review",
            pinnedContexts = emptyList(),
            pendingAttachments = listOf(att),
            sessionId = "sess-1",
        )
        assertTrue(msg.startsWith("please review"))
        assertTrue(msg.contains("[attached file: spec.pdf — uploads/sess-1/spec.pdf]"))
        // The base64 payload is NOT inlined anymore — bytes go over the
        // upload frame, only the path reference rides the message.
        assertFalse(msg.contains("base64"))
    }

    @Test fun composeOutgoingMessage_multipleAttachmentsEachReferenced() {
        val img = ComposerAttachment(id = "i", kind = AttachKind.Image, filename = "a.png", mimeType = "image/png", bytes = byteArrayOf(1))
        val pdf = ComposerAttachment(id = "p", kind = AttachKind.File, filename = "b.pdf", mimeType = "application/pdf", bytes = byteArrayOf(2))
        val msg = composeOutgoingMessage(
            draft = "look",
            pinnedContexts = emptyList(),
            pendingAttachments = listOf(img, pdf),
            sessionId = "S",
        )
        assertTrue(msg.contains("[attached image: a.png — uploads/S/a.png]"))
        assertTrue(msg.contains("[attached file: b.pdf — uploads/S/b.pdf]"))
    }

    @Test fun composeOutgoingMessage_emptyDraftAndNothingPinned_returnsEmpty() {
        // Nothing pinned + empty draft + no attachments → empty string.
        // The composer's send path treats that as a no-op.
        val msg = composeOutgoingMessage(
            draft = "   ",
            pinnedContexts = emptyList(),
            pendingAttachments = emptyList(),
            sessionId = "sess-1",
        )
        assertEquals("", msg)
    }

    @Test fun composeOutgoingMessage_attachmentOnlyStillSends() {
        // An attachment with no typed draft must still produce a non-empty
        // message (the reference line), so the send path isn't a no-op.
        val att = ComposerAttachment(kind = AttachKind.Image, filename = "a.png", mimeType = "image/png", bytes = byteArrayOf(1))
        val msg = composeOutgoingMessage(
            draft = "",
            pinnedContexts = emptyList(),
            pendingAttachments = listOf(att),
            sessionId = "sess-9",
        )
        assertEquals("[attached image: a.png — uploads/sess-9/a.png]", msg)
    }
}
