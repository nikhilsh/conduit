import Testing
import Foundation
@testable import SweKitty

/// Pure-data tests for the composer attach sheet's underlying model.
/// We pulled `AttachKind` and `ComposerAttachment` out as `Equatable`
/// structs precisely so the picker plumbing (UIKit representables)
/// doesn't need to be exercised from XCTest.
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
        // Both mention "0x01 binary frame" now that we're shipping raw
        // bytes via the upload tag (sweswe-parity #file-upload) instead
        // of inlining base64 in the chat message.
        #expect(AttachKind.image.subtitle != AttachKind.file.subtitle)
        #expect(AttachKind.image.subtitle.contains("0x01"))
        #expect(AttachKind.file.subtitle.contains("0x01"))
    }

    @Test func attachKindHasDistinctIcons() {
        #expect(AttachKind.image.iconName == "photo.on.rectangle.angled")
        #expect(AttachKind.file.iconName == "doc.badge.plus")
    }

    @Test func attachmentCarriesRawBytes() {
        // The attachment ships raw bytes (not base64). The Rust core
        // takes care of encoding the 0x01 frame; this layer just
        // forwards what the picker produced.
        let payload = Data([0x89, 0x50, 0x4E, 0x47]) // PNG magic
        let att = ComposerAttachment(
            kind: .image,
            filename: "IMG_0001.JPG",
            mimeType: "image/jpeg",
            bytes: payload
        )
        #expect(att.bytes == payload)
        #expect(att.filename == "IMG_0001.JPG")
        #expect(att.mimeType == "image/jpeg")
    }

    @Test func attachmentEquatableIgnoresIDFromCallerPerspective() {
        // The id is auto-generated per attachment; equality should
        // still detect "same payload, different id" as different
        // attachments. This is what `pendingAttachments` deduplication
        // would lean on if we ever added dedupe.
        let a = ComposerAttachment(kind: .image, filename: "a", mimeType: "image/jpeg", bytes: Data("A".utf8))
        let b = ComposerAttachment(kind: .image, filename: "a", mimeType: "image/jpeg", bytes: Data("A".utf8))
        // Different UUIDs → not equal.
        #expect(a != b)
        // Same UUID → equal.
        let copy = ComposerAttachment(id: a.id, kind: a.kind, filename: a.filename, mimeType: a.mimeType, bytes: a.bytes)
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

    // MARK: - dispatchUploads smoke test (sweswe-parity #file-upload)
    //
    // The composer's confirm action (ChatTab.dispatchSend) routes each
    // pending attachment through AttachmentDispatcher.dispatchUploads,
    // which in prod calls SessionStore.sendFile. We pass a recorder
    // closure here so the test pins the (session, filename, mime, bytes)
    // tuple ChatTab ships per attachment. If a future refactor drops
    // the call entirely or re-orders the arguments, this test fails
    // before it lands on a user's phone.

    @Test func dispatchUploadsFiresSendFileOncePerAttachment() {
        struct Captured: Equatable {
            let sessionID: String
            let filename: String
            let mime: String
            let bytes: Data
        }
        var captured: [Captured] = []

        let attachments: [ComposerAttachment] = [
            ComposerAttachment(
                kind: .image,
                filename: "photo.jpg",
                mimeType: "image/jpeg",
                bytes: Data([0xFF, 0xD8, 0xFF])
            ),
            ComposerAttachment(
                kind: .file,
                filename: "notes.txt",
                mimeType: "text/plain",
                bytes: Data("hello".utf8)
            ),
        ]

        AttachmentDispatcher.dispatchUploads(
            attachments,
            sessionID: "session-xyz"
        ) { session, name, mime, bytes in
            captured.append(Captured(sessionID: session, filename: name, mime: mime, bytes: bytes))
        }

        #expect(captured.count == 2)
        #expect(captured[0] == Captured(
            sessionID: "session-xyz",
            filename: "photo.jpg",
            mime: "image/jpeg",
            bytes: Data([0xFF, 0xD8, 0xFF])
        ))
        #expect(captured[1] == Captured(
            sessionID: "session-xyz",
            filename: "notes.txt",
            mime: "text/plain",
            bytes: Data("hello".utf8)
        ))
    }

    @Test func dispatchUploadsWithNoAttachmentsIsNoOp() {
        var calls = 0
        AttachmentDispatcher.dispatchUploads(
            [],
            sessionID: "session-xyz"
        ) { _, _, _, _ in
            calls += 1
        }
        #expect(calls == 0)
    }
}
