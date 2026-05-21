import Testing
import Foundation
@testable import SweKitty

/// Pure-data tests for the composer attach sheet's underlying model.
/// We pulled `AttachKind` and `ComposerAttachment` out as `Equatable`
/// structs precisely so the picker plumbing (UIKit representables)
/// doesn't need to be exercised from XCTest. These tests pin the
/// row metadata + the inline-encoding format the broker downstream
/// will read.
@Suite("ComposerAttachSheet.model")
struct ComposerAttachModelTests {

    @Test func attachKindsAreImageAndFile() {
        // The sheet renders exactly two options in a stable order.
        // Snapshotting the order here so a future contributor doesn't
        // accidentally add ".camera" without updating the spec.
        #expect(AttachKind.allCases == [.image, .file])
    }

    @Test func attachKindTitlesAreUserFacing() {
        #expect(AttachKind.image.title == "Attach image")
        #expect(AttachKind.file.title == "Attach file")
    }

    @Test func attachKindHasDistinctSubtitles() {
        // Each row needs a one-liner explaining where the data ends up.
        #expect(AttachKind.image.subtitle != AttachKind.file.subtitle)
        #expect(AttachKind.image.subtitle.contains("base64"))
        #expect(AttachKind.file.subtitle.contains("base64"))
    }

    @Test func attachKindHasDistinctIcons() {
        #expect(AttachKind.image.iconName == "photo.on.rectangle.angled")
        #expect(AttachKind.file.iconName == "doc.badge.plus")
    }

    @Test func attachmentInlineBlockEmbedsBase64Payload() {
        // Format pinned: we ship a single-line header followed by the
        // base64 blob, separated by a newline. Brokers parse this
        // verbatim — changing the prefix is a wire break.
        let att = ComposerAttachment(
            kind: .image,
            filename: "IMG_0001.JPG",
            mimeType: "image/jpeg",
            base64: "QUJDRA=="
        )

        let block = att.inlineBlock
        #expect(block.hasPrefix("[attached image: IMG_0001.JPG; mime=image/jpeg; base64]"))
        #expect(block.contains("\nQUJDRA=="))
    }

    @Test func attachmentInlineBlockDistinguishesImageAndFile() {
        let image = ComposerAttachment(
            kind: .image, filename: "a.png", mimeType: "image/png", base64: "X"
        )
        let file = ComposerAttachment(
            kind: .file, filename: "a.txt", mimeType: "text/plain", base64: "X"
        )

        #expect(image.inlineBlock.contains("[attached image:"))
        #expect(file.inlineBlock.contains("[attached file:"))
    }

    @Test func attachmentEquatableIgnoresIDFromCallerPerspective() {
        // The id is auto-generated per attachment; equality should
        // still detect "same payload, different id" as different
        // attachments. This is what `pendingAttachments` deduplication
        // would lean on if we ever added dedupe.
        let a = ComposerAttachment(kind: .image, filename: "a", mimeType: "image/jpeg", base64: "A")
        let b = ComposerAttachment(kind: .image, filename: "a", mimeType: "image/jpeg", base64: "A")
        // Different UUIDs → not equal.
        #expect(a != b)
        // Same UUID → equal.
        let copy = ComposerAttachment(id: a.id, kind: a.kind, filename: a.filename, mimeType: a.mimeType, base64: a.base64)
        #expect(a == copy)
    }

    @Test func mimeTypeFallsBackToOctetStreamForUnknownExtensions() {
        let url = URL(fileURLWithPath: "/tmp/blob.xyzzz-unknown-ext-12345")
        #expect(ComposerAttachSheet.mimeType(for: url) == "application/octet-stream")
    }

    @Test func mimeTypeRecognisesCommonExtensions() {
        // UTType resolution is platform-dependent; if these ever start
        // returning octet-stream the runtime has regressed and we
        // want to know about it.
        let pngURL = URL(fileURLWithPath: "/tmp/icon.png")
        #expect(ComposerAttachSheet.mimeType(for: pngURL) == "image/png")
    }
}
