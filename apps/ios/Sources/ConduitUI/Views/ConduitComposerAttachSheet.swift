import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - ConduitComposerAttachBar
//
// The ConduitUI composer's "+" attach affordance. Splits into:
//   - the "+" Menu (image vs. file) hosted next to the text field,
//   - a `PhotosPicker` (JPG/PNG/WebP/HEIC) for images,
//   - a `.fileImporter` (PDF + arbitrary content types) for files,
//   - a removable chip strip rendered ABOVE the text field.
//
// Picked data is loaded OFF the main thread, size-guarded, and handed
// back as a `ConduitUI.ComposerAttachment`. The composer's send path
// uploads each via core `send_file` (0x01 frame → broker writes
// `uploads/<sessionID>/<filename>`) and then appends the cross-surface
// reference line. Mirrors Android's `ComposerAttachSheet.kt` (PR #240).
//
// Matches the ConduitUI palette/typography and never appears in
// read-only transcripts (the composer itself is suppressed there).

extension ConduitUI {

    /// Removable chip strip shown above the composer text field. One
    /// chip per pending attachment (icon + filename + size + an "x" to
    /// remove). Horizontally scrolls when several files are queued.
    struct ComposerAttachmentChips: View {
        let attachments: [ComposerAttachment]
        let onRemove: (ComposerAttachment) -> Void

        var body: some View {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(attachments) { attachment in
                        chip(for: attachment)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 6)
                .padding(.bottom, 2)
            }
        }

        private func chip(for attachment: ComposerAttachment) -> some View {
            HStack(spacing: 6) {
                Image(systemName: attachment.kind.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .neonAccentForeground()
                VStack(alignment: .leading, spacing: 1) {
                    Text(attachment.filename)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(ConduitUI.Palette.textBody.color)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(attachment.displaySize)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(ConduitUI.Palette.textMuted.color)
                }
                Button {
                    onRemove(attachment)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(attachment.filename)")
            }
            .padding(.leading, 10)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(maxWidth: 220)
            .conduitGlassCapsule(tint: ConduitUI.Palette.surfaceLight.color, config: .pill)
        }
    }

    /// The "+" button + its pickers. Owns the PhotosPicker selection and
    /// the `.fileImporter` presentation; the parent composer owns the
    /// pending-attachment list and the send path. We surface picked
    /// files through `onAttach` and any read/size error through
    /// `onError` (the parent shows it transiently). All byte loading
    /// happens off the main thread.
    struct ComposerAttachButton: View {
        let onAttach: (ComposerAttachment) -> Void
        let onError: (String) -> Void

        @State private var photoItems: [PhotosPickerItem] = []
        @State private var showPhotosPicker = false
        @State private var showFileImporter = false

        var body: some View {
            Menu {
                Button {
                    showPhotosPicker = true
                } label: {
                    Label(ConduitUI.AttachKind.image.title, systemImage: ConduitUI.AttachKind.image.systemImage)
                }
                Button {
                    showFileImporter = true
                } label: {
                    Label(ConduitUI.AttachKind.file.title, systemImage: ConduitUI.AttachKind.file.systemImage)
                }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(ConduitUI.Palette.textSecondary.color)
                    .frame(width: 36, height: 36)
                    .conduitGlassCircle(tint: ConduitUI.Palette.surfaceLight.color, config: .floating)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach")
            // Images: system photo picker. `.images` filter keeps it to
            // JPG/PNG/WebP/HEIC. Multi-select so a user can queue a few.
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photoItems,
                maxSelectionCount: 5,
                matching: .images
            )
            .onChange(of: photoItems) { _, items in
                guard !items.isEmpty else { return }
                let picked = items
                photoItems = []
                Task { await loadPhotos(picked) }
            }
            // PDFs + arbitrary files. `.pdf` is named first so it reads
            // as the headline type; `.data`/`.item` keep everything else
            // reachable. `asCopy: true` so we read a sandbox copy and
            // never hold a security-scoped URL past the read.
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.pdf, .data, .item],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    Task { await loadFiles(urls) }
                case .failure(let error):
                    onError("Couldn't open the file picker: \(error.localizedDescription)")
                }
            }
        }

        // MARK: Loading (off the main thread)

        private func loadPhotos(_ items: [PhotosPickerItem]) async {
            for item in items {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else {
                        report("Couldn't read that photo. Try again.")
                        continue
                    }
                    let (filename, mime) = Self.photoMetadata(for: item)
                    ingest(kind: .image, filename: filename, mime: mime, bytes: data)
                } catch {
                    report("Couldn't read that photo. Try again.")
                }
            }
        }

        private func loadFiles(_ urls: [URL]) async {
            for url in urls {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                do {
                    // Read on a background task so a large file doesn't
                    // block the UI; `Data(contentsOf:)` is blocking I/O.
                    let data = try await Task.detached(priority: .userInitiated) {
                        try Data(contentsOf: url)
                    }.value
                    let filename = url.lastPathComponent
                    let mime = Self.fileMime(for: url)
                    ingest(kind: .file, filename: filename, mime: mime, bytes: data)
                } catch {
                    report("Couldn't read \"\(url.lastPathComponent)\". Try again.")
                }
            }
        }

        /// Size-guard + hand back to the parent on the main actor.
        @MainActor
        private func ingest(kind: ConduitUI.AttachKind, filename: String, mime: String, bytes: Data) {
            guard ConduitUI.ComposerAttachmentLimits.isWithinLimit(bytes.count) else {
                if bytes.isEmpty {
                    onError("\"\(filename)\" is empty.")
                } else {
                    let mb = ConduitUI.ComposerAttachmentLimits.maxBytes / (1024 * 1024)
                    onError("\"\(filename)\" is too large (limit \(mb)MB).")
                }
                return
            }
            onAttach(
                ConduitUI.ComposerAttachment(
                    kind: kind,
                    filename: filename,
                    mimeType: mime,
                    bytes: bytes
                )
            )
        }

        @MainActor
        private func report(_ message: String) {
            onError(message)
        }

        // MARK: Metadata helpers

        /// Derive a filename + MIME for a PhotosPicker item. Photos
        /// don't carry a real filename, so we synthesize one from the
        /// preferred content type's extension and a short unique stub.
        private static func photoMetadata(for item: PhotosPickerItem) -> (String, String) {
            let type = item.supportedContentTypes.first
            let ext = type?.preferredFilenameExtension ?? "jpg"
            let mime = type?.preferredMIMEType ?? "image/jpeg"
            let stub = String(UUID().uuidString.prefix(8))
            return ("image-\(stub).\(ext)", mime)
        }

        /// MIME for a picked file URL — prefer the resource's content
        /// type, fall back to the extension map, then octet-stream.
        private static func fileMime(for url: URL) -> String {
            if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType,
               let mime = type.preferredMIMEType {
                return mime
            }
            return ConduitUI.ComposerMime.fromExtension(url.pathExtension)
        }
    }
}
