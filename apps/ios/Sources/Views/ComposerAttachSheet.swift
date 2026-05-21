import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Kinds of attachment the composer's "+" sheet offers. Pulled out
/// into a pure-data enum so unit tests can pin the option list
/// without spinning up SwiftUI.
enum AttachKind: String, CaseIterable, Identifiable, Equatable {
    case image
    case file

    var id: String { rawValue }

    /// User-facing row title in the attach sheet.
    var title: String {
        switch self {
        case .image: return "Attach image"
        case .file:  return "Attach file"
        }
    }

    /// One-line caption under the title.
    var subtitle: String {
        switch self {
        case .image: return "Pick from your photo library — encoded inline as base64."
        case .file:  return "Pick from Files — encoded inline as base64."
        }
    }

    /// SF Symbol drawn on the leading edge of the row.
    var iconName: String {
        switch self {
        case .image: return "photo.on.rectangle.angled"
        case .file:  return "doc.badge.plus"
        }
    }
}

/// Pure-data outcome of the picker step. Stash this so ChatTab can
/// observe and fold the encoded payload into the next outgoing chat
/// message. Kept Equatable so tests can assert state transitions.
struct ComposerAttachment: Equatable, Identifiable {
    let id: UUID
    let kind: AttachKind
    /// Short user-readable label, e.g. "IMG_0123.HEIC" or "spec.pdf".
    let filename: String
    /// MIME-ish hint used when formatting the wrapping payload.
    let mimeType: String
    /// Raw base64 bytes — what gets folded into the outgoing message.
    let base64: String

    init(id: UUID = UUID(), kind: AttachKind, filename: String, mimeType: String, base64: String) {
        self.id = id
        self.kind = kind
        self.filename = filename
        self.mimeType = mimeType
        self.base64 = base64
    }

    /// Renders the attachment as a self-describing inline block that
    /// the broker passes verbatim to the agent. Keeping the format
    /// pure-data + deterministic so tests don't need to compare
    /// against a SwiftUI view. Format mirrors what litter's web
    /// composer emits so brokers can reuse the same regex.
    var inlineBlock: String {
        let header: String
        switch kind {
        case .image: header = "[attached image: \(filename); mime=\(mimeType); base64]"
        case .file:  header = "[attached file: \(filename); mime=\(mimeType); base64]"
        }
        return "\(header)\n\(base64)"
    }
}

/// Modal sheet driven from ChatTab's "+" button. Offers two options
/// (image, file) then dismisses; the heavy lifting (PHPicker /
/// UIDocumentPicker) is delegated to the wrapped UIKit controllers
/// because PhotosUI's SwiftUI shim doesn't expose the raw URL.
struct ComposerAttachSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    /// Called when the user successfully picked an attachment.
    /// ChatTab routes this into the draft / next sendChat call.
    let onAttach: (ComposerAttachment) -> Void

    @State private var pendingKind: AttachKind?
    @State private var showImagePicker = false
    @State private var showFilePicker = false
    @State private var encodingError: String?

    var body: some View {
        NavigationStack {
            ZStack {
                SweKittyTheme.backgroundGradient(for: colorScheme).ignoresSafeArea()
                VStack(spacing: 14) {
                    ForEach(AttachKind.allCases) { kind in
                        attachRow(for: kind)
                    }
                    if let encodingError {
                        InlineErrorBanner(message: encodingError) {
                            self.encodingError = nil
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
            .navigationTitle("Attach")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showImagePicker) {
            PhotoPickerRepresentable { image, filename in
                handlePicked(image: image, filename: filename)
            }
        }
        .sheet(isPresented: $showFilePicker) {
            DocumentPickerRepresentable { url in
                handlePicked(fileURL: url)
            }
        }
    }

    private func attachRow(for kind: AttachKind) -> some View {
        Button {
            switch kind {
            case .image: showImagePicker = true
            case .file:  showFilePicker = true
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: kind.iconName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(SweKittyTheme.accent)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 3) {
                    Text(kind.title)
                        .font(.headline)
                        .foregroundStyle(SweKittyTheme.textPrimary)
                    Text(kind.subtitle)
                        .font(.footnote)
                        .foregroundStyle(SweKittyTheme.textSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "chevron.right")
                    .foregroundStyle(SweKittyTheme.textMuted)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .glassRoundedRect()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.title)
    }

    // MARK: - Encoding

    private func handlePicked(image: UIImage, filename: String) {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            encodingError = "Couldn't encode the selected image."
            return
        }
        let attachment = ComposerAttachment(
            kind: .image,
            filename: filename,
            mimeType: "image/jpeg",
            base64: data.base64EncodedString()
        )
        onAttach(attachment)
        dismiss()
    }

    private func handlePicked(fileURL: URL) {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: fileURL)
            let mime = Self.mimeType(for: fileURL)
            let attachment = ComposerAttachment(
                kind: .file,
                filename: fileURL.lastPathComponent,
                mimeType: mime,
                base64: data.base64EncodedString()
            )
            onAttach(attachment)
            dismiss()
        } catch {
            encodingError = "Couldn't read that file: \(error.localizedDescription)"
        }
    }

    /// Best-effort MIME inference from the picked URL. Falls back
    /// to application/octet-stream if UTType can't classify it.
    static func mimeType(for url: URL) -> String {
        guard let utType = UTType(filenameExtension: url.pathExtension) else {
            return "application/octet-stream"
        }
        return utType.preferredMIMEType ?? "application/octet-stream"
    }
}

// MARK: - UIKit pickers

/// Thin SwiftUI wrapper over PHPickerViewController. We use this
/// instead of PhotosUI's `PhotosPicker` view so we can recover the
/// source filename (PhotosPicker hands you a `Data` blob with no
/// metadata, which makes round-tripping a HEIC awkward).
struct PhotoPickerRepresentable: UIViewControllerRepresentable {
    let onPicked: (UIImage, String) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPicked: (UIImage, String) -> Void
        init(onPicked: @escaping (UIImage, String) -> Void) { self.onPicked = onPicked }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            picker.dismiss(animated: true)
            guard let result = results.first else { return }
            let provider = result.itemProvider
            let fallbackName = result.assetIdentifier.map { "photo-\($0).jpg" } ?? "photo.jpg"
            if provider.canLoadObject(ofClass: UIImage.self) {
                provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
                    guard let image = object as? UIImage else { return }
                    DispatchQueue.main.async {
                        self?.onPicked(image, provider.suggestedName.map { "\($0).jpg" } ?? fallbackName)
                    }
                }
            }
        }
    }
}

/// Thin SwiftUI wrapper over UIDocumentPickerViewController. Single-
/// select, copy-out semantics so we never touch the user's original
/// file in iCloud / Files.
struct DocumentPickerRepresentable: UIViewControllerRepresentable {
    let onPicked: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPicked: onPicked) }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPicked: (URL) -> Void
        init(onPicked: @escaping (URL) -> Void) { self.onPicked = onPicked }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPicked(url)
        }
    }
}
