import AVFoundation
import Foundation
import Speech

/// On-device speech transcription via Apple `Speech.framework`.
///
/// Mirrors the rail-A "Whisper-style" surface from `docs/PLAN-2026-05-19.md`
/// §2.3: push-to-talk, one-shot transcription, no realtime WebRTC dependency,
/// no protocol change. The transcribed text is intended to be fed into
/// `SessionStore.sendChat`.
///
/// Permissions:
/// - `NSSpeechRecognitionUsageDescription`
/// - `NSMicrophoneUsageDescription`
///
/// On-device support is best-effort: SFSpeechRecognizer falls back to
/// server-side when an on-device model isn't available for the user's
/// locale. We prefer on-device but do not require it.
@MainActor
final class VoiceTranscriber: ObservableObject {
    enum State: Equatable {
        case idle
        case requestingPermissions
        case listening
        case finalizing
        case error(message: String)

        var isActive: Bool {
            switch self {
            case .listening, .finalizing, .requestingPermissions:
                return true
            default:
                return false
            }
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var partialTranscript: String = ""

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Begin a new transcription session. `onFinal` is called once with the
    /// final transcript when the user stops dictation (or with the best
    /// partial result if SFSpeechRecognizer never produces a `isFinal` event).
    func start(locale: Locale = .current, onFinal: @escaping (String) -> Void) {
        guard !state.isActive else { return }
        state = .requestingPermissions
        partialTranscript = ""

        Task { @MainActor in
            do {
                try await requestPermissions()
                try startEngine(locale: locale, onFinal: onFinal)
            } catch let error as TranscriberError {
                state = .error(message: error.message)
            } catch {
                state = .error(message: error.localizedDescription)
            }
        }
    }

    /// User released the mic — flush the recognizer and emit the final
    /// transcript.
    func stop() {
        guard state.isActive else { return }
        state = .finalizing
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        // SFSpeechRecognitionTask will call its handler one final time with
        // isFinal == true; that path also resets state to .idle.
    }

    /// Abandon the current session and drop the partial transcript.
    func cancel() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        request = nil
        task = nil
        partialTranscript = ""
        state = .idle
    }

    // MARK: - Internals

    private func requestPermissions() async throws {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus =
            await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        guard speechStatus == .authorized else {
            throw TranscriberError(message: "Speech recognition permission denied")
        }

        let micGranted: Bool = await withCheckedContinuation { continuation in
            if #available(iOS 17.0, *) {
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            } else {
                AVAudioSession.sharedInstance().requestRecordPermission {
                    continuation.resume(returning: $0)
                }
            }
        }
        guard micGranted else {
            throw TranscriberError(message: "Microphone permission denied")
        }
    }

    private func startEngine(locale: Locale, onFinal: @escaping (String) -> Void) throws {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw TranscriberError(message: "Speech recognizer unavailable for \(locale.identifier)")
        }
        self.recognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.partialTranscript = result.bestTranscription.formattedString
                    if result.isFinal {
                        let final = result.bestTranscription.formattedString
                        self.tearDown()
                        if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onFinal(final)
                        }
                    }
                }
                if let error {
                    // If we already stopped the engine, .canceled / .noMatch are
                    // expected — surface only unrecognized error codes.
                    let nsError = error as NSError
                    if nsError.domain == "kAFAssistantErrorDomain"
                        || nsError.code == 203 // no match
                        || nsError.code == 209 // canceled
                    {
                        // Emit the best partial we collected, if any.
                        let final = self.partialTranscript
                        self.tearDown()
                        if !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            onFinal(final)
                        }
                        return
                    }
                    self.state = .error(message: nsError.localizedDescription)
                    self.tearDown()
                }
            }
        }

        state = .listening
    }

    private func tearDown() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request = nil
        task = nil
        state = .idle
    }
}

private struct TranscriberError: Error {
    let message: String
}
