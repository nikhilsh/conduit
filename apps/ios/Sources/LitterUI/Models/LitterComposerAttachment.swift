import Foundation
import UniformTypeIdentifiers

// MARK: - LitterComposerAttachment
//
// Pure-data layer for the LitterUI composer's "+" attach affordance.
// Deliberately framework-light (no SwiftUI / no PhotosUI imports) so the
// model can be unit-tested under SweKittyTests without a view host. The
// SwiftUI sheet + chips (`LitterComposerAttachSheet.swift`) are the
// renderer; the send path uploads bytes via core `send_file` (0x01
// frame) and appends one reference line per file.
//
// Cross-surface parity: this mirrors Android's `ComposerAttachSheet.kt`
// / `ComposerAttachModelTest.kt` (PR #240) exactly — same two kinds,
// same lowercase reference tokens, same 20 MB cap, and the SAME
// `[attached <kind>: <filename> — uploads/<sessionID>/<filename>]`
// message-reference convention so one regex parses both platforms.

extension LitterUI {

    /// Kinds of attachment the composer's "+" menu offers. Two kinds
    /// drive the picker split: `.image` opens `PhotosPicker`
    /// (JPG/PNG/WebP/HEIC), `.file` opens the document picker (PDFs +
    /// arbitrary content types). The chosen kind also labels the
    /// outgoing message reference line so the agent knows whether to
    /// treat the path as an image or a generic file. Declaration order
    /// (image then file) is the menu render order and is pinned by
    /// `LitterComposerAttachModelTests` — Android matches.
    enum AttachKind: CaseIterable, Equatable, Sendable {
        case image
        case file

        var title: String {
            switch self {
            case .image: return "Attach image"
            case .file:  return "Attach file"
            }
        }

        var subtitle: String {
            switch self {
            case .image: return "Pick a photo (JPG/PNG/WebP) — uploaded to the session."
            case .file:  return "Pick a PDF or any file — uploaded to the session."
            }
        }

        /// SF Symbol shown leading the menu row.
        var systemImage: String {
            switch self {
            case .image: return "photo"
            case .file:  return "doc"
            }
        }

        /// Lowercase token embedded in the outgoing message reference
        /// line. Android mirrors the identical two tokens.
        var referenceToken: String {
            switch self {
            case .image: return "image"
            case .file:  return "file"
            }
        }
    }

    /// Pure-data outcome of the picker step. Carries the raw bytes so
    /// the send path can ship them over the 0x01 binary WS upload frame
    /// (core `send_file`); the broker lands them at
    /// `uploads/<sessionID>/<filename>`. Identifiable for the chip
    /// `ForEach`; Equatable so tests can assert state transitions.
    /// Mirrors Android `ComposerAttachment`.
    struct ComposerAttachment: Identifiable, Equatable, Sendable {
        let id: String
        let kind: AttachKind
        let filename: String
        let mimeType: String
        let bytes: Data

        init(
            id: String = UUID().uuidString,
            kind: AttachKind,
            filename: String,
            mimeType: String,
            bytes: Data
        ) {
            self.id = id
            self.kind = kind
            self.filename = filename
            self.mimeType = mimeType
            self.bytes = bytes
        }

        /// Byte length — surfaced in the chip + used for the size guard.
        var sizeBytes: Int { bytes.count }

        /// Human-readable size for the chip (e.g. "1.2 MB").
        var displaySize: String {
            ByteCountFormatter.string(fromByteCount: Int64(sizeBytes), countStyle: .file)
        }
    }

    /// Best-effort MIME inference. The pickers usually hand us a
    /// `UTType` / content type directly, but when they don't we fall
    /// back to the extension via `UTType(filenameExtension:)` and
    /// finally to `application/octet-stream`. Pulled out so tests can
    /// pin the fallback without a picker.
    enum ComposerMime {
        /// Resolve a MIME string from a filename extension. Case-folded
        /// to lowercase so `HEIC` and `heic` resolve identically.
        /// Returns `application/octet-stream` when the extension is
        /// empty or the type system can't classify it.
        static func fromExtension(_ ext: String?) -> String {
            guard let ext, !ext.isEmpty else { return "application/octet-stream" }
            if let type = UTType(filenameExtension: ext.lowercased()),
               let mime = type.preferredMIMEType {
                return mime
            }
            return "application/octet-stream"
        }

        /// Pure variant used by tests — no `UTType` lookup. `fromMap`
        /// stands in for the system type table.
        static func fromExtensionOrDefault(_ ext: String?, _ fromMap: (String) -> String?) -> String {
            guard let ext, !ext.isEmpty else { return "application/octet-stream" }
            return fromMap(ext.lowercased()) ?? "application/octet-stream"
        }
    }

    /// Size policy for composer attachments. Uploading multi-MB blobs
    /// over the WS control channel stalls the session, so we cap at a
    /// sane limit and let the UI warn/skip. Matches Android's
    /// `ComposerAttachmentLimits.MAX_BYTES` (20 MB).
    enum ComposerAttachmentLimits {
        /// Hard ceiling — anything larger is rejected with a warning.
        static let maxBytes: Int = 20 * 1024 * 1024

        /// Empty (0-byte) and oversized picks are rejected; the picker
        /// stays available so the user can retry with a smaller file.
        static func isWithinLimit(_ sizeBytes: Int) -> Bool {
            sizeBytes >= 1 && sizeBytes <= maxBytes
        }
    }

    /// Format the single-line reference the agent acts on once the
    /// bytes are uploaded. The broker writes uploads to
    /// `uploads/<sessionID>/<filename>` relative to the session
    /// workspace, and the agent runs in that workspace — so referencing
    /// the relative path lets Claude read the image/PDF/file directly.
    ///
    /// Shape (cross-surface; Android mirrors this byte-for-byte):
    ///
    ///     [attached <kind>: <filename> — uploads/<sessionID>/<filename>]
    ///
    /// The separator is an em-dash ` — ` (U+2014 with surrounding
    /// spaces). Cross-surface regex:
    /// `^\[attached (image|file): (.+) — uploads/([^/]+)/(.+)]$`
    static func attachmentReferenceLine(
        kind: AttachKind,
        filename: String,
        sessionID: String
    ) -> String {
        "[attached \(kind.referenceToken): \(filename) — uploads/\(sessionID)/\(filename)]"
    }

    /// Folds the draft text + any pending attachments into a single
    /// outgoing chat message. Mirror of Android `composeOutgoingMessage`
    /// (the iOS LitterUI surface has no pinned-context feature, so that
    /// parameter is omitted). Pieces are joined with a blank line so the
    /// draft and each reference line read as distinct paragraphs.
    ///
    /// Attachments are NOT inlined as base64: the bytes go over the
    /// 0x01 upload frame and the broker lands them at
    /// `uploads/<sessionID>/<filename>`; only the path reference rides
    /// the chat message. An attachment-only send (empty draft) still
    /// produces a non-empty message (just the reference lines), so the
    /// send path isn't a no-op; an empty draft with no attachments
    /// returns "" which the composer treats as a no-op.
    static func composeOutgoingMessage(
        draft: String,
        pendingAttachments: [ComposerAttachment],
        sessionID: String
    ) -> String {
        var pieces: [String] = []
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { pieces.append(trimmed) }
        for attachment in pendingAttachments {
            pieces.append(
                attachmentReferenceLine(
                    kind: attachment.kind,
                    filename: attachment.filename,
                    sessionID: sessionID
                )
            )
        }
        return pieces.joined(separator: "\n\n")
    }
}
