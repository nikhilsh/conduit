package sh.nikhil.conduit.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import sh.nikhil.conduit.Telemetry
import java.util.Locale

/**
 * On-device speech transcription via Android `SpeechRecognizer`.
 *
 * Mirrors the rail-A "Whisper-style" surface from `docs/PLAN-2026-05-19.md`
 * §2.3: push-to-talk, one-shot transcription, prefers offline recognition
 * when supported (API 31+ via `EXTRA_PREFER_OFFLINE`). Output is intended
 * to be fed to `SessionStore.sendChat`.
 *
 * **Continuous across pauses.** Android's `SpeechRecognizer` is one-shot: it
 * delivers `onResults` (or `onError(NO_MATCH/SPEECH_TIMEOUT)`) the moment it
 * detects end-of-speech — i.e. a natural pause — and then stops. Treating that
 * first result as "the user is done" was the cause of the device-reported "we
 * lose what was spoken when the user pauses": everything after the first pause
 * was dropped. We instead *commit* each segment to an accumulated buffer and
 * immediately `startListening` again, so a single dictation spans any number of
 * pauses. We only emit the final transcript when the user explicitly stops
 * (`stop()`), e.g. taps send or releases the mic.
 *
 * Permissions:
 * - `android.permission.RECORD_AUDIO` (manifest + runtime).
 * - `<queries><intent>android.speech.RecognitionService</intent></queries>`
 *   in the manifest so the recognizer service is discoverable on Android 11+.
 */
class VoiceTranscriber(private val context: Context) {

    sealed class State {
        data object Idle : State()
        data object Listening : State()
        data object Finalizing : State()
        data class Error(val message: String) : State()
    }

    private val _state = MutableStateFlow<State>(State.Idle)
    val state: StateFlow<State> = _state.asStateFlow()

    /**
     * Everything recognized so far this session: the committed transcript of
     * past (paused) segments plus the live partial of the current segment.
     */
    private val _partial = MutableStateFlow("")
    val partial: StateFlow<String> = _partial.asStateFlow()

    /**
     * Smoothed input level (0..1), derived from the recognizer's
     * `onRmsChanged` callback (RMS in dB). Drives the voice-sheet
     * waveform so the bars track the user's actual voice. Resets to 0 on
     * teardown.
     */
    private val _level = MutableStateFlow(0f)
    val level: StateFlow<Float> = _level.asStateFlow()

    private var recognizer: SpeechRecognizer? = null
    private var onFinal: ((String) -> Unit)? = null
    private val mainHandler = Handler(Looper.getMainLooper())

    /** Recognizer intent, retained so segment restarts reuse the same config. */
    private var intent: Intent? = null

    /** Committed transcript of finalized (paused) segments. */
    private var accumulated = ""

    /** The current segment's latest partial, folded into [accumulated] on end. */
    private var segmentPartial = ""

    /** Set by [stop]/[cancel]. While false, a segment end restarts listening. */
    private var manualStop = false

    /** Guards against double-emitting the final transcript. */
    private var finished = false

    /** True while a `startListening` session is in flight (between start and
     *  the next onResults/onError). Lets [stop] know whether to wait for a
     *  callback or finalize immediately (e.g. in the restart gap). */
    private var recognizing = false

    /** Consecutive empty restarts, reset whenever real text arrives. Bounds a
     *  pathological hot-restart loop (e.g. recognizer errors out instantly). */
    private var restartCount = 0

    fun start(locale: Locale = Locale.getDefault(), onFinal: (String) -> Unit) {
        if (_state.value is State.Listening || _state.value is State.Finalizing) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            _state.value = State.Error("Speech recognition unavailable on this device")
            return
        }
        this.onFinal = onFinal
        manualStop = false
        finished = false
        accumulated = ""
        segmentPartial = ""
        restartCount = 0
        _partial.value = ""

        intent = buildIntent(locale)
        Telemetry.breadcrumb("voice", "start", mapOf("locale" to locale.toLanguageTag()))

        val sr = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = sr
        sr.setRecognitionListener(listener)
        startSegment()
    }

    fun stop() {
        if (_state.value !is State.Listening) return
        manualStop = true
        _state.value = State.Finalizing
        if (recognizing) {
            // A session is in flight — stopListening triggers onResults/onError,
            // which commits the segment and finalizes (manualStop is set).
            recognizer?.stopListening()
            // Safety net: some recognizer implementations don't reliably call
            // back from stopListening. Finalize anyway if nothing fires.
            mainHandler.postDelayed({ if (!finished) finalizeSuccess() }, 1_500)
        } else {
            // In the gap between segment restarts — nothing in flight.
            finalizeSuccess()
        }
    }

    fun cancel() {
        manualStop = true
        finished = true
        mainHandler.removeCallbacksAndMessages(null)
        recognizer?.cancel()
        tearDown()
        accumulated = ""
        segmentPartial = ""
        _partial.value = ""
        onFinal = null
        _state.value = State.Idle
    }

    private fun buildIntent(locale: Locale): Intent =
        Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
        }

    /** Begin (or resume after a pause) a single recognition session. */
    private fun startSegment() {
        val sr = recognizer ?: return
        val i = intent ?: return
        try {
            sr.startListening(i)
            recognizing = true
            _state.value = State.Listening
        } catch (e: SecurityException) {
            _state.value = State.Error(e.message ?: "Microphone permission denied")
            tearDown()
        }
    }

    /** Fold the current segment's text into the accumulated transcript. */
    private fun commitSegment() {
        val seg = segmentPartial.trim()
        if (seg.isNotEmpty()) accumulated = combine(accumulated, seg)
        segmentPartial = ""
        _partial.value = accumulated
    }

    /** A segment ended (pause or manual stop): restart to keep listening, or
     *  finalize if the user asked to stop. */
    private fun onSegmentEnded() {
        recognizing = false
        if (manualStop) {
            finalizeSuccess()
            return
        }
        if (restartCount++ > MAX_RESTARTS) {
            Telemetry.breadcrumb("voice", "restart cap", mapOf("chars" to accumulated.length.toString()))
            finalizeSuccess()
            return
        }
        // Reuse the same recognizer; post (with a small delay) so we're outside
        // the callback before re-arming — calling startListening synchronously
        // from within onResults/onError trips ERROR_RECOGNIZER_BUSY on some
        // OEMs. State stays Listening across the gap so the UI doesn't flash.
        mainHandler.postDelayed({
            if (!manualStop && !finished) startSegment()
        }, RESTART_DELAY_MS)
    }

    private fun finalizeSuccess() {
        if (finished) return
        finished = true
        mainHandler.removeCallbacksAndMessages(null)
        val final = accumulated.trim()
        tearDown()
        _state.value = State.Idle
        Telemetry.breadcrumb("voice", "finalize", mapOf("chars" to final.length.toString()))
        val cb = onFinal
        onFinal = null
        accumulated = ""
        segmentPartial = ""
        if (final.isNotEmpty()) cb?.invoke(final)
    }

    private fun tearDown() {
        recognizing = false
        recognizer?.destroy()
        recognizer = null
        _level.value = 0f
    }

    /** Join two transcript fragments with a single separating space. */
    private fun combine(head: String, tail: String): String {
        val h = head.trim()
        val t = tail.trim()
        return when {
            h.isEmpty() -> t
            t.isEmpty() -> h
            else -> "$h $t"
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}

        override fun onRmsChanged(rmsdB: Float) {
            // SpeechRecognizer reports RMS roughly in -2..10 dB; map that
            // range to 0..1 and lightly smooth so the waveform tracks the
            // voice without strobing.
            val norm = ((rmsdB + 2f) / 12f).coerceIn(0f, 1f)
            _level.value = _level.value * 0.6f + norm * 0.4f
        }

        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val txt = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?: return
            if (txt.isNotBlank()) restartCount = 0
            segmentPartial = txt
            _partial.value = combine(accumulated, segmentPartial)
        }

        override fun onResults(results: Bundle?) {
            val txt = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            if (txt.isNotEmpty()) {
                restartCount = 0
                segmentPartial = txt
            }
            commitSegment()
            onSegmentEnded()
        }

        override fun onError(error: Int) {
            when (error) {
                // End of a quiet segment / brief client hiccup — commit what we
                // have and keep listening (unless the user asked to stop). These
                // fire on every natural pause, so ending here is exactly the
                // lost-speech bug we're fixing.
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT,
                SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
                SpeechRecognizer.ERROR_CLIENT -> {
                    commitSegment()
                    onSegmentEnded()
                }
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ->
                    failWith("Microphone permission denied", error)
                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> {
                    // Offline model unavailable for this locale. Keep whatever
                    // we already captured rather than dropping it.
                    commitSegment()
                    if (accumulated.isNotBlank()) finalizeSuccess()
                    else failWith("Speech recognition needs network for this locale", error)
                }
                else -> {
                    commitSegment()
                    if (accumulated.isNotBlank()) finalizeSuccess()
                    else failWith("Speech recognition failed (code $error)", error)
                }
            }
        }

        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }

    private fun failWith(message: String, code: Int) {
        if (finished) return
        finished = true
        mainHandler.removeCallbacksAndMessages(null)
        Telemetry.breadcrumb("voice", "error", mapOf("code" to code.toString(), "chars" to accumulated.length.toString()))
        tearDown()
        _state.value = State.Error(message)
        onFinal = null
        accumulated = ""
        segmentPartial = ""
    }

    private companion object {
        /** Small delay before re-arming so we're outside the recognizer callback. */
        const val RESTART_DELAY_MS = 120L
        /** Cap on consecutive empty restarts (resets on any recognized text). */
        const val MAX_RESTARTS = 40
    }
}
