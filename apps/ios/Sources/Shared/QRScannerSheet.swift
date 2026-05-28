import SwiftUI
import AVFoundation
import AudioToolbox
import CoreImage
import PhotosUI
import UIKit

/// AVFoundation-backed QR scanner. Returns the raw scanned string via the
/// `onScan` closure (the caller parses `swekitty://…`).
struct QRScannerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onScan: (String) -> Void

    @State private var error: String?
    @State private var scanned: Bool = false
    @State private var selectedPhoto: PhotosPickerItem?
    private let detector = CIDetector(
        ofType: CIDetectorTypeQRCode,
        context: nil,
        options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]
    )

    var body: some View {
        NavigationStack {
            ZStack {
                ScannerRepresentable(scanned: $scanned) { code in
                    guard !scanned else { return }
                    scanned = true
                    onScan(code)
                    dismiss()
                }
                .ignoresSafeArea()

                VStack {
                    Spacer()
                    VStack(spacing: 12) {
                        Text("Point at a SweKitty pairing QR")
                            .font(.headline)
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("Choose From Photos", systemImage: "photo.on.rectangle")
                                .font(.headline)
                                .padding(.horizontal, 18)
                                .padding(.vertical, 12)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .padding(18)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 32)
                }

                if let error {
                    VStack {
                        Text(error)
                            .padding()
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    }
                }
            }
            .navigationTitle("Scan pairing QR")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .onChange(of: selectedPhoto) { _, item in
                guard let item else { return }
                importPhoto(item)
            }
        }
        .appearanceColorScheme()
    }

    private func importPhoto(_ item: PhotosPickerItem) {
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        error = "Couldn't read that photo."
                    }
                    return
                }
                let uiImage = UIImage(data: data)
                guard let image = CIImage(data: data) ?? uiImage.flatMap(CIImage.init(image:)) else {
                    await MainActor.run {
                        error = "Couldn't decode that image."
                    }
                    return
                }
                guard let code = qrString(from: image) else {
                    await MainActor.run {
                        error = "No QR code found in that photo."
                    }
                    return
                }
                await MainActor.run {
                    scanned = true
                    error = nil
                    onScan(code)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    self.error = "Photo import failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private func qrString(from image: CIImage) -> String? {
        guard let detector else { return nil }
        let features = detector.features(in: image)
        return features
            .compactMap { $0 as? CIQRCodeFeature }
            .compactMap(\.messageString)
            .first
    }
}

private struct ScannerRepresentable: UIViewControllerRepresentable {
    @Binding var scanned: Bool
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> ScannerViewController {
        let vc = ScannerViewController()
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: ScannerViewController, context: Context) {}

    final class Coordinator: NSObject, ScannerViewControllerDelegate {
        let onCode: (String) -> Void
        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }
        func scanner(_ vc: ScannerViewController, didScan code: String) { onCode(code) }
    }
}

protocol ScannerViewControllerDelegate: AnyObject {
    func scanner(_ vc: ScannerViewController, didScan code: String)
}

final class ScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: ScannerViewControllerDelegate?

    private let session = AVCaptureSession()
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        configureSession()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.layer.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.session.startRunning()
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if session.isRunning { session.stopRunning() }
    }

    private func configureSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return }
        session.addInput(input)

        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.layer.bounds
        view.layer.addSublayer(layer)
        previewLayer = layer
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let obj = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              obj.type == .qr,
              let code = obj.stringValue else { return }
        AudioServicesPlaySystemSound(1519) // soft tap
        delegate?.scanner(self, didScan: code)
    }
}
