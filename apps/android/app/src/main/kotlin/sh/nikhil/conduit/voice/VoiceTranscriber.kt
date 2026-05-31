package sh.nikhil.conduit.voice

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.speech.RecognitionListener
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.Locale

/**
 * On-device speech transcription via Android `SpeechRecognizer`.
 *
 * Mirrors the rail-A "Whisper-style" surface from `docs/PLAN-2026-05-19.md`
 * §2.3: push-to-talk, one-shot transcription, prefers offline recognition
 * when supported (API 31+ via `EXTRA_PREFER_OFFLINE`). Output is intended
 * to be fed to `SessionStore.sendChat`.
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

    private val _partial = MutableStateFlow("")
    val partial: StateFlow<String> = _partial.asStateFlow()

    private var recognizer: SpeechRecognizer? = null
    private var onFinal: ((String) -> Unit)? = null

    fun start(locale: Locale = Locale.getDefault(), onFinal: (String) -> Unit) {
        if (_state.value is State.Listening || _state.value is State.Finalizing) return
        if (!SpeechRecognizer.isRecognitionAvailable(context)) {
            _state.value = State.Error("Speech recognition unavailable on this device")
            return
        }
        this.onFinal = onFinal
        _partial.value = ""

        val sr = SpeechRecognizer.createSpeechRecognizer(context)
        recognizer = sr
        sr.setRecognitionListener(listener)

        val intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
            putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
            putExtra(RecognizerIntent.EXTRA_LANGUAGE, locale.toLanguageTag())
            putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
            putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
            }
        }
        try {
            sr.startListening(intent)
            _state.value = State.Listening
        } catch (e: SecurityException) {
            _state.value = State.Error(e.message ?: "Microphone permission denied")
            tearDown()
        }
    }

    fun stop() {
        if (_state.value !is State.Listening) return
        _state.value = State.Finalizing
        recognizer?.stopListening()
    }

    fun cancel() {
        recognizer?.cancel()
        tearDown()
        _partial.value = ""
        _state.value = State.Idle
    }

    private fun tearDown() {
        recognizer?.destroy()
        recognizer = null
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) {}
        override fun onBeginningOfSpeech() {}
        override fun onRmsChanged(rmsdB: Float) {}
        override fun onBufferReceived(buffer: ByteArray?) {}

        override fun onPartialResults(partialResults: Bundle?) {
            val txt = partialResults
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?: return
            _partial.value = txt
        }

        override fun onResults(results: Bundle?) {
            val txt = results
                ?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)
                ?.firstOrNull()
                ?.trim()
                .orEmpty()
            tearDown()
            _state.value = State.Idle
            if (txt.isNotEmpty()) {
                onFinal?.invoke(txt)
            }
            onFinal = null
        }

        override fun onError(error: Int) {
            // Some errors are expected when the user releases the mic with
            // no clear speech detected; emit the best partial we collected.
            val partial = _partial.value.trim()
            tearDown()
            if (partial.isNotEmpty()) {
                _state.value = State.Idle
                onFinal?.invoke(partial)
                onFinal = null
                return
            }
            _state.value = when (error) {
                SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS -> State.Error("Microphone permission denied")
                SpeechRecognizer.ERROR_NETWORK,
                SpeechRecognizer.ERROR_NETWORK_TIMEOUT -> State.Error("Speech recognition needs network for this locale")
                SpeechRecognizer.ERROR_NO_MATCH,
                SpeechRecognizer.ERROR_SPEECH_TIMEOUT -> State.Idle
                else -> State.Error("Speech recognition failed (code $error)")
            }
            onFinal = null
        }

        override fun onEndOfSpeech() {}
        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}
