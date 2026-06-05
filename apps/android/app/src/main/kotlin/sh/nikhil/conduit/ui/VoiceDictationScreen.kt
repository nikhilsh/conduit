package sh.nikhil.conduit.ui

import android.Manifest
import android.content.pm.PackageManager
import android.speech.tts.TextToSpeech
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBars
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.ContextCompat
import sh.nikhil.conduit.voice.VoiceTranscriber
import java.util.Locale
import kotlin.math.PI
import kotlin.math.sin

/**
 * Global voice dictation modal — invoked from the home BottomActionBar
 * mic button (and the in-chat composer mic). Reuses `VoiceTranscriber`
 * (Android SpeechRecognizer backend). Mirrors `VoiceDictationSheet.swift`.
 *
 * Redesign (handoff §B.8 / `images/09-voice.png`): a live-transcript
 * surface with detected-intent chips, an amplitude-driven waveform, an
 * agent target chip, a "read replies aloud" TTS toggle, and a hands-free
 * hint. The recognized text still commits to the agent / composer exactly
 * as before — presentation + extension only.
 *
 * @param agent the agent the dictation routes to (drives the target chip
 *   + its tint). Defaults to `claude` (home seeds a new claude session;
 *   the in-chat path passes the session's agent).
 * @param sessionName display name of the routed session, shown after the
 *   agent in the target chip as `<agent> · <session>`. When dictation seeds
 *   a brand-new session (the Home flow) there is no session yet, so it
 *   falls back to `new session`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceDictationScreen(
    onTranscript: (String) -> Unit,
    onDismiss: () -> Unit,
    agent: String = "claude",
    sessionName: String = "new session",
) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val neon = LocalNeonTheme.current
    val transcriber = remember { VoiceTranscriber(context) }
    val state by transcriber.state.collectAsState()
    val partial by transcriber.partial.collectAsState()
    val level by transcriber.level.collectAsState()
    var captured by remember { mutableStateOf("") }
    var permissionDenied by remember { mutableStateOf(false) }
    var readAloud by remember { mutableStateOf(false) }

    // Read-replies-aloud TTS. No reply stream is wired into this modal, so
    // the only thing it speaks today is a send-confirmation in the Send
    // handler; the engine itself is real (not a no-op stub). Torn down with
    // the composable.
    val tts = remember {
        var engine: TextToSpeech? = null
        engine = TextToSpeech(context.applicationContext) { status ->
            if (status == TextToSpeech.SUCCESS) {
                engine?.language = Locale.getDefault()
            }
        }
        engine
    }
    DisposableEffect(Unit) {
        onDispose {
            tts.stop()
            tts.shutdown()
        }
    }

    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            transcriber.start(onFinal = { captured = it })
        } else {
            permissionDenied = true
        }
    }

    LaunchedEffect(Unit) {
        val granted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO,
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            transcriber.start(onFinal = { captured = it })
        } else {
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    val displayTranscript = if (captured.isNotEmpty()) captured else partial
    val isLive = state is VoiceTranscriber.State.Listening
    val tint = neonAgentColor(agent, neon)

    ModalBottomSheet(
        onDismissRequest = {
            transcriber.stop()
            onDismiss()
        },
        sheetState = sheetState,
        containerColor = neon.surfaceSolid,
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                // Honor the real bottom inset so the footer clears the
                // gesture pill / 3-button nav (handoff §C.1).
                .windowInsetsPadding(WindowInsets.navigationBars)
                .padding(horizontal = 16.dp, vertical = 12.dp),
        ) {
            // Agent target chip
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .neonCardSurface(neon = neon, shape = RoundedCornerShape(12.dp), fill = neon.surface, glowTint = tint)
                    .padding(horizontal = 12.dp, vertical = 9.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                ConduitMark(size = 18.dp, color = tint)
                Spacer(Modifier.width(8.dp))
                Text(agent.lowercase(), fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 12.sp, color = tint)
                Spacer(Modifier.width(8.dp))
                Text("·", fontFamily = neon.mono, fontSize = 11.sp, color = neon.textFaint)
                Spacer(Modifier.width(8.dp))
                Text(
                    sessionName,
                    fontFamily = neon.mono,
                    fontSize = 11.sp,
                    color = neon.textDim,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                )
            }

            if (permissionDenied) {
                Spacer(Modifier.height(40.dp))
                Column(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(Icons.Outlined.WarningAmber, null, tint = neon.red, modifier = Modifier.size(44.dp))
                    Spacer(Modifier.height(10.dp))
                    Text(
                        "Microphone access is required for voice dictation.",
                        style = MaterialTheme.typography.bodyMedium,
                        fontFamily = neon.sans,
                        color = neon.red,
                        textAlign = TextAlign.Center,
                    )
                }
                Spacer(Modifier.weight(1f))
            } else {
                Spacer(Modifier.height(18.dp))
                // LISTENING status
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(
                        modifier = Modifier
                            .size(7.dp)
                            .background(if (isLive) neon.green else neon.textFaint, CircleShape),
                    )
                    Spacer(Modifier.width(7.dp))
                    Text(
                        if (isLive) "LISTENING" else "PAUSED",
                        fontFamily = neon.mono,
                        fontWeight = FontWeight.SemiBold,
                        fontSize = 10.sp,
                        letterSpacing = 2.sp,
                        color = if (isLive) neon.green else neon.textFaint,
                    )
                }

                Spacer(Modifier.height(14.dp))
                // Live transcript — dim head, bright tail.
                Text(
                    text = transcriptAnnotated(displayTranscript, captured.isNotEmpty(), neon.text, neon.accent, neon.textFaint),
                    fontFamily = neon.sans,
                    fontWeight = FontWeight.Medium,
                    fontSize = 22.sp,
                    modifier = Modifier.fillMaxWidth().height(96.dp),
                )

                Spacer(Modifier.height(14.dp))
                // Detected-intent chips (heuristic)
                val chips = detectVoiceIntents(displayTranscript)
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    chips.forEach { chip ->
                        val chipTint = if (chip.kind == VoiceIntentKind.FILE) neon.blue else neon.accent
                        Row(
                            modifier = Modifier
                                .clip(RoundedCornerShape(50))
                                .background(neon.surface2)
                                .padding(horizontal = 9.dp, vertical = 4.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            chip.glyph?.let {
                                Text(it, fontFamily = neon.mono, fontWeight = FontWeight.Bold, fontSize = 11.sp, color = chipTint)
                                Spacer(Modifier.width(4.dp))
                            }
                            Text(chip.label, fontFamily = neon.mono, fontWeight = FontWeight.SemiBold, fontSize = 11.sp, color = chipTint)
                        }
                    }
                }

                Spacer(Modifier.weight(1f))
                Waveform(isLive = isLive, level = level, accent = neon.accent)
                Spacer(Modifier.weight(1f))
            }

            // Footer: toggle + send + hint
            Row(
                modifier = Modifier.fillMaxWidth().padding(top = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Switch(
                    checked = readAloud,
                    onCheckedChange = { readAloud = it },
                    colors = SwitchDefaults.colors(
                        checkedThumbColor = neon.accentText,
                        checkedTrackColor = neon.accent,
                    ),
                )
                Spacer(Modifier.width(10.dp))
                Text("read replies aloud", fontFamily = neon.mono, fontSize = 12.sp, color = neon.textDim)
                Spacer(Modifier.weight(1f))
                val canSend = displayTranscript.isNotBlank()
                Box(
                    modifier = Modifier
                        .size(48.dp)
                        .background(if (canSend) neon.accent else neon.accent.copy(alpha = 0.45f), CircleShape)
                        .clickable(enabled = canSend) {
                            transcriber.stop()
                            val text = displayTranscript.trim()
                            if (readAloud && text.isNotEmpty()) {
                                tts.speak("Sent to $agent. $text", TextToSpeech.QUEUE_FLUSH, null, "voice-send")
                            }
                            onTranscript(text)
                            onDismiss()
                        },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(Icons.Filled.ArrowUpward, contentDescription = "Send", tint = neon.accentText, modifier = Modifier.size(22.dp))
                }
            }
            Spacer(Modifier.height(10.dp))
            Text(
                "tap ↑ to send · hold to keep talking · \"hey conduit\" to start hands-free",
                fontFamily = neon.mono,
                fontSize = 10.sp,
                color = neon.textFaint,
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
        }
    }
}

/**
 * Amplitude-driven waveform: 28 capsule bars whose height tracks the live
 * mic [level] (from `VoiceTranscriber.onRmsChanged`), modulated by a
 * travelling sine so the row reads as a wave rather than a flat block.
 * When not [isLive] the bars fall to a resting line.
 */
@Composable
private fun Waveform(isLive: Boolean, level: Float, accent: Color) {
    val bars = 28
    val transition = rememberInfiniteTransition(label = "wave")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * PI).toFloat(),
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Restart,
        ),
        label = "wave-phase",
    )
    Row(
        modifier = Modifier.fillMaxWidth().height(92.dp).padding(horizontal = 24.dp),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        for (i in 0 until bars) {
            val barPhase = i * 0.5f
            val wobble = (sin(phase * 7f + barPhase) * 0.5f + 0.5f)
            val envelope = sin(i.toFloat() / (bars - 1).toFloat() * PI.toFloat())
            val amp = if (isLive) maxOf(0.06f, level) else 0.02f
            val h = (6f + wobble * envelope * amp * 78f).dp
            Box(
                modifier = Modifier
                    .weight(1f)
                    .height(h)
                    .clip(RoundedCornerShape(50))
                    .background(accent.copy(alpha = if (isLive) 0.95f else 0.4f)),
            )
        }
    }
}

/** Dim the settled head, brighten the last few words being recognized. */
private fun transcriptAnnotated(
    text: String,
    finalized: Boolean,
    headColor: Color,
    tailColor: Color,
    placeholderColor: Color,
): AnnotatedString {
    if (text.isBlank()) {
        return buildAnnotatedString {
            withStyle(SpanStyle(color = placeholderColor)) { append("Listening…") }
        }
    }
    if (finalized) {
        return buildAnnotatedString { withStyle(SpanStyle(color = headColor)) { append(text) } }
    }
    val words = text.split(" ")
    if (words.size <= 3) {
        return buildAnnotatedString { withStyle(SpanStyle(color = tailColor)) { append(text) } }
    }
    val head = words.dropLast(3).joinToString(" ")
    val tail = words.takeLast(3).joinToString(" ")
    return buildAnnotatedString {
        withStyle(SpanStyle(color = headColor)) { append("$head ") }
        withStyle(SpanStyle(color = tailColor, fontWeight = FontWeight.SemiBold)) { append(tail) }
    }
}

// MARK: - Detected-intent heuristic (mirrors iOS VoiceIntent)

internal enum class VoiceIntentKind { ACTION, TEST, FILE }

internal data class VoiceIntentChip(val label: String, val glyph: String?, val kind: VoiceIntentKind)

private val actionVerbs = listOf(
    "add", "fix", "refactor", "remove", "delete", "rename",
    "implement", "update", "build", "create", "write",
)
private val testRegex = Regex("\\btests?\\b|\\bspec\\b")
private val fileRegex = Regex("[A-Za-z0-9_./-]+\\.[A-Za-z]{1,4}\\b")

/**
 * Honest keyword heuristic, in priority order, deduped, capped at 4:
 *   - an action verb (add/fix/refactor/…) → a `task` chip
 *   - the word test/tests/spec            → a `+ test` chip
 *   - file-looking tokens (`name.ext`)    → one chip each
 * Returns empty when nothing is detected — we never fabricate.
 */
internal fun detectVoiceIntents(transcript: String): List<VoiceIntentChip> {
    val lower = transcript.lowercase().trim()
    if (lower.isEmpty()) return emptyList()
    val chips = mutableListOf<VoiceIntentChip>()
    if (actionVerbs.any { lower.contains(it) }) {
        chips += VoiceIntentChip("task", "•", VoiceIntentKind.ACTION)
    }
    if (testRegex.containsMatchIn(lower)) {
        chips += VoiceIntentChip("test", "+", VoiceIntentKind.TEST)
    }
    val seen = mutableSetOf<String>()
    for (m in fileRegex.findAll(transcript)) {
        val tok = m.value
        if (seen.add(tok.lowercase())) {
            chips += VoiceIntentChip(tok, null, VoiceIntentKind.FILE)
        }
    }
    return chips.take(4)
}
