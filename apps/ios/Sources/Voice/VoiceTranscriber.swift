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
/// **Continuous across pauses.** `SFSpeechRecognizer` finalizes a recognition
/// task as soon as it detects end-of-speech (a natural pause), and a finalized
/// task stops producing results. Treating that first `isFinal` as "the user is
/// done" was the cause of the device-reported "we lose what was spoken when the
/// user pauses": everything after the first pause was dropped because the
/// engine had already torn down. We instead *commit* each finalized segment to
/// an accumulated buffer and immediately start a fresh recognition task on the
/// still-running audio engine, so a single dictation can span any number of
/// pauses. We only emit the final transcript — and tear the engine down — when
/// the user explicitly stops (`stop()`), e.g. taps send or releases the mic.
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
    /// Everything recognized so far this session: the committed transcript of
    /// past (paused) segments plus the live partial of the current segment.
    @Published private(set) var partialTranscript: String = ""
    /// Smoothed input level (0…1), derived from the RMS of the same audio
    /// buffer that feeds the recognizer. Drives the voice-sheet waveform so
    /// the bars track the user's actual voice. Resets to 0 on teardown.
    @Published private(set) var level: Float = 0

    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    /// Committed transcript of finalized (paused) segments. The live segment's
    /// partial is appended on top to form `partialTranscript`.
    private var accumulated: String = ""
    /// The current segment's latest partial. Folded into `accumulated` when the
    /// segment finalizes.
    private var segmentPartial: String = ""
    /// Set by `stop()`/`cancel()`. While false, a finalized segment triggers a
    /// restart (keep listening across the pause); once true, the next segment
    /// end finalizes the whole session.
    private var manualStop = false
    /// Retained across segment restarts so we can rebuild the recognition task.
    private var onFinalHandler: ((String) -> Void)?
    private var currentLocale: Locale = .current
    /// Guards against double-emitting the final transcript.
    private var finished = false

    /// Begin a new transcription session. `onFinal` is called once with the
    /// full accumulated transcript when the user stops dictation (`stop()`).
    /// Pauses no longer end the session — recognition restarts automatically
    /// and keeps accumulating until `stop()`.
    func start(locale: Locale = .current, onFinal: @escaping (String) -> Void) {
        guard !state.isActive else { return }
        state = .requestingPermissions
        manualStop = false
        finished = false
        accumulated = ""
        segmentPartial = ""
        partialTranscript = ""
        onFinalHandler = onFinal
        currentLocale = locale
        Telemetry.breadcrumb("voice", "start", data: ["locale": locale.identifier])

        Task { @MainActor in
            do {
                try await requestPermissions()
                try startAudioEngine()
                try beginRecognition()
                state = .listening
            } catch let error as TranscriberError {
                Telemetry.capture(error: error, message: "voice start failed", tags: ["surface": "ios", "phase": "voice_start"], extras: ["detail": error.message])
                state = .error(message: error.message)
                stopAudioEngine()
            } catch {
                Telemetry.capture(error: error, message: "voice start failed", tags: ["surface": "ios", "phase": "voice_start"])
                state = .error(message: error.localizedDescription)
                stopAudioEngine()
            }
        }
    }

    /// User released the mic / tapped send — flush the in-flight segment and
    /// emit the full accumulated transcript.
    func stop() {
        guard state.isActive else { return }
        manualStop = true
        state = .finalizing
        if let request {
            // The recognition task fires once more (isFinal or an expected
            // end-of-speech error); `onSegmentEnded` sees `manualStop` and
            // finalizes with the full accumulated transcript.
            request.endAudio()
        } else {
            // No recognition in flight (still requesting permissions, or in the
            // brief gap between segment restarts): finalize immediately.
            finalizeSuccess()
        }
    }

    /// Abandon the current session and drop the transcript.
    func cancel() {
        manualStop = true
        finished = true
        stopAudioEngine()
        task?.cancel()
        request = nil
        task = nil
        accumulated = ""
        segmentPartial = ""
        partialTranscript = ""
        onFinalHandler = nil
        level = 0
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

    /// Configure the audio session + engine and install the input tap once.
    /// The engine keeps running across segment restarts; only the recognition
    /// request/task are recreated (see `beginRecognition`), so audio capture is
    /// continuous and pauses don't drop the engine.
    private func startAudioEngine() throws {
        guard let recognizer = SFSpeechRecognizer(locale: currentLocale), recognizer.isAvailable else {
            throw TranscriberError(message: "Speech recognizer unavailable for \(currentLocale.identifier)")
        }
        self.recognizer = recognizer

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.request?.append(buffer)
            self?.updateLevel(from: buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
    }

    /// Create a fresh recognition request + task for the next segment. Called
    /// at session start and after every pause-driven restart.
    private func beginRecognition() throws {
        guard let recognizer = self.recognizer else {
            throw TranscriberError(message: "Speech recognizer unavailable")
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        self.request = request

        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                self.handleRecognition(result: result, error: error)
            }
        }
    }

    private func handleRecognition(result: SFSpeechRecognitionResult?, error: Error?) {
        if let result {
            let next = result.bestTranscription.formattedString
            // SFSpeech revises its in-progress hypothesis as it listens, and right
            // before a pause it tends to regress that hypothesis — sometimes all the
            // way to blank, sometimes to a shorter prefix — before it fires the
            // `isFinal`/end-of-speech that commits the segment. Accepting that shorter
            // string verbatim is the device-reported wipe: "I pause and the text on
            // screen shrinks / starts over." Keep the LONGEST hypothesis we've shown
            // for this segment and ignore any regression; legitimate growth (and
            // same-length corrections) still apply, and the retained text commits when
            // the segment ends. A blank partial is just the extreme case of a regression.
            segmentPartial = Self.longestSegment(current: segmentPartial, next: next)
            partialTranscript = combine(accumulated, segmentPartial)
            if result.isFinal {
                commitSegment()
                onSegmentEnded()
                return
            }
        }
        if let error {
            // `.canceled` / `.noMatch` / the kAFAssistant family fire on a
            // natural end-of-speech (a pause) as well as on real failures. For
            // these we keep the session alive (commit + restart) rather than
            // treating the first pause as "done" — that was the lost-speech bug.
            let nsError = error as NSError
            let expected = nsError.domain == "kAFAssistantErrorDomain"
                || nsError.code == 203 // no match
                || nsError.code == 209 // canceled
            if expected {
                commitSegment()
                onSegmentEnded()
                return
            }
            // Genuine failure: surface it but keep whatever we accumulated so
            // the user doesn't lose what they already said.
            Telemetry.capture(error: nsError, message: "voice recognition error", tags: ["surface": "ios", "phase": "voice_recognize"], extras: ["code": "\(nsError.code)", "domain": nsError.domain])
            let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
            stopAudioEngine()
            request = nil
            task = nil
            level = 0
            state = .error(message: nsError.localizedDescription)
            if !finished {
                finished = true
                let handler = onFinalHandler
                onFinalHandler = nil
                if !final.isEmpty { handler?(final) }
            }
            accumulated = ""
            segmentPartial = ""
        }
    }

    /// Fold the current segment's text into the accumulated transcript.
    private func commitSegment() {
        let seg = segmentPartial.trimmingCharacters(in: .whitespacesAndNewlines)
        if !seg.isEmpty {
            accumulated = combine(accumulated, seg)
        }
        segmentPartial = ""
        partialTranscript = accumulated
    }

    /// A recognition task ended (pause or manual stop). Either restart to keep
    /// listening, or finalize if the user asked to stop.
    private func onSegmentEnded() {
        task = nil
        request = nil
        if manualStop {
            finalizeSuccess()
            return
        }
        do {
            try beginRecognition()
            // State stays `.listening` so the UI doesn't flash "PAUSED".
            Telemetry.breadcrumb("voice", "segment restart", data: ["chars": "\(accumulated.count)"])
        } catch {
            // Couldn't restart — finalize with what we have rather than hang.
            Telemetry.capture(error: error, message: "voice restart failed", tags: ["surface": "ios", "phase": "voice_restart"])
            finalizeSuccess()
        }
    }

    private func finalizeSuccess() {
        guard !finished else { return }
        finished = true
        stopAudioEngine()
        request = nil
        task = nil
        level = 0
        state = .idle
        let final = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        Telemetry.breadcrumb("voice", "finalize", data: ["chars": "\(final.count)"])
        let handler = onFinalHandler
        onFinalHandler = nil
        accumulated = ""
        segmentPartial = ""
        if !final.isEmpty { handler?(final) }
    }

    private func stopAudioEngine() {
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    /// Fold a freshly recognized partial into the live segment without ever
    /// regressing what's already on screen. SFSpeech revises its hypothesis
    /// downward (to a shorter prefix, or blank) right before a pause; returning
    /// the shorter string there is the "pausing wipes the transcript" bug. We
    /// keep whichever of `current`/`next` has more recognized characters, so the
    /// displayed segment is monotonic until it commits. Trade-off: a legitimate
    /// shortening correction is held at the longer form until segment end — a
    /// cosmetic redundancy we accept to never wipe mid-utterance. Pure +
    /// unit-tested (`VoiceTranscriptAccumulatorTests`).
    nonisolated static func longestSegment(current: String, next: String) -> String {
        let c = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let n = next.trimmingCharacters(in: .whitespacesAndNewlines)
        return n.count >= c.count ? next : current
    }

    /// Join two transcript fragments with a single separating space, tolerating
    /// empty fragments on either side.
    private func combine(_ head: String, _ tail: String) -> String {
        let h = head.trimmingCharacters(in: .whitespaces)
        let t = tail.trimmingCharacters(in: .whitespaces)
        if h.isEmpty { return t }
        if t.isEmpty { return h }
        return h + " " + t
    }

    /// Compute the RMS of the (mono / first-channel) PCM buffer, map it to
    /// a perceptual 0…1 range, and publish a smoothed value on the main
    /// actor. Called from the audio tap thread; the `nonisolated` shim lets
    /// it run off-actor and hop back to publish.
    nonisolated private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sumSquares: Float = 0
        for i in 0..<frames {
            let s = channel[i]
            sumSquares += s * s
        }
        let rms = (sumSquares / Float(frames)).squareRoot()
        // Map RMS (~0…0.3 for speech) to 0…1 with a gentle gain + clamp.
        let scaled = min(1.0, max(0.0, rms * 6.0))
        Task { @MainActor [weak self] in
            guard let self else { return }
            // Light exponential smoothing so the bars don't strobe.
            self.level = self.level * 0.6 + scaled * 0.4
        }
    }
}

private struct TranscriberError: Error {
    let message: String
}
