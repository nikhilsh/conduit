package sh.nikhil.conduit.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.outlined.WarningAmber
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import sh.nikhil.conduit.voice.VoiceTranscriber

/**
 * Global voice dictation modal — invoked from the home BottomActionBar
 * mic button. Reuses `VoiceTranscriber` (Android SpeechRecognizer
 * backend), same as `InlineVoiceButton`. Mirrors `VoiceDictationSheet.swift`.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun VoiceDictationScreen(onTranscript: (String) -> Unit, onDismiss: () -> Unit) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val context = LocalContext.current
    val transcriber = remember { VoiceTranscriber(context) }
    val state by transcriber.state.collectAsState()
    val partial by transcriber.partial.collectAsState()
    var captured by remember { mutableStateOf("") }
    var permissionDenied by remember { mutableStateOf(false) }

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

    ModalBottomSheet(onDismissRequest = {
        transcriber.stop()
        onDismiss()
    }, sheetState = sheetState) {
        Column(
            modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp, vertical = 12.dp),
            verticalArrangement = Arrangement.spacedBy(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Voice", style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.SemiBold)
            Spacer(Modifier.height(20.dp))

            if (permissionDenied) {
                Icon(
                    Icons.Outlined.WarningAmber,
                    null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(44.dp),
                )
                Text(
                    "Microphone access is required for voice dictation.",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.error,
                )
            } else {
                Box(contentAlignment = Alignment.Center) {
                    Box(
                        modifier = Modifier
                            .size(140.dp)
                            .background(LocalNeonTheme.current.accent.copy(alpha = 0.18f), CircleShape),
                    )
                    Box(
                        modifier = Modifier
                            .size(96.dp)
                            .background(LocalNeonTheme.current.accent.copy(alpha = 0.35f), CircleShape),
                    )
                    Box(
                        modifier = Modifier
                            .size(64.dp)
                            .background(LocalNeonTheme.current.accent, CircleShape),
                        contentAlignment = Alignment.Center,
                    ) {
                        Icon(
                            Icons.Filled.GraphicEq,
                            null,
                            tint = MaterialTheme.colorScheme.onPrimary,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                }
                Text(
                    if (displayTranscript.isBlank()) "Listening…" else displayTranscript,
                    style = MaterialTheme.typography.titleMedium,
                    color = MaterialTheme.colorScheme.onSurface,
                )
            }

            Spacer(Modifier.weight(1f))

            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Surface(
                    shape = RoundedCornerShape(24.dp),
                    color = MaterialTheme.colorScheme.surfaceVariant.copy(alpha = 0.6f),
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(24.dp)).clickable {
                        transcriber.stop()
                        onDismiss()
                    },
                ) {
                    Text(
                        "Cancel",
                        style = MaterialTheme.typography.titleMedium,
                        modifier = Modifier.padding(vertical = 14.dp).fillMaxWidth(),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
                val canSend = displayTranscript.isNotBlank()
                Surface(
                    shape = RoundedCornerShape(24.dp),
                    color = if (canSend) LocalNeonTheme.current.accent else LocalNeonTheme.current.accent.copy(alpha = 0.5f),
                    modifier = Modifier.weight(1f).clip(RoundedCornerShape(24.dp)).clickable(enabled = canSend) {
                        transcriber.stop()
                        onTranscript(displayTranscript)
                        onDismiss()
                    },
                ) {
                    Text(
                        "Send",
                        style = MaterialTheme.typography.titleMedium,
                        color = MaterialTheme.colorScheme.onPrimary,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.padding(vertical = 14.dp).fillMaxWidth(),
                        textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                    )
                }
            }
        }
    }
}
