package sh.nikhil.conduit.ui

import android.Manifest
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.GraphicEq
import androidx.compose.material.icons.outlined.Mic
import androidx.compose.material.icons.outlined.MoreHoriz
import androidx.compose.material.icons.outlined.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager
import sh.nikhil.conduit.voice.VoiceTranscriber

@Composable
fun InlineVoiceButton(onTranscript: (String) -> Unit) {
    val context = LocalContext.current
    val transcriber = remember { VoiceTranscriber(context) }
    val state by transcriber.state.collectAsState()
    val partial by transcriber.partial.collectAsState()

    var pendingStart by remember { mutableStateOf(false) }
    val micPermission = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission()
    ) { granted ->
        if (granted && pendingStart) {
            transcriber.start(onFinal = onTranscript)
        }
        pendingStart = false
    }

    fun beginIfPermitted() {
        val granted = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
        if (granted) {
            transcriber.start(onFinal = onTranscript)
        } else {
            pendingStart = true
            micPermission.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    Box(contentAlignment = Alignment.Center) {
        val bg = when (state) {
            is VoiceTranscriber.State.Listening -> MaterialTheme.colorScheme.primary
            is VoiceTranscriber.State.Error -> MaterialTheme.colorScheme.error
            else -> MaterialTheme.colorScheme.surfaceVariant
        }
        val tint = when (state) {
            is VoiceTranscriber.State.Listening -> MaterialTheme.colorScheme.onPrimary
            is VoiceTranscriber.State.Error -> MaterialTheme.colorScheme.onError
            else -> MaterialTheme.colorScheme.primary
        }
        Box(
            modifier = Modifier
                .size(42.dp)
                .clip(CircleShape)
                .background(bg)
                .pointerInput(Unit) {
                    detectTapGestures(
                        onPress = {
                            beginIfPermitted()
                            try {
                                awaitRelease()
                            } finally {
                                transcriber.stop()
                            }
                        }
                    )
                },
            contentAlignment = Alignment.Center,
        ) {
            val icon = when (state) {
                is VoiceTranscriber.State.Listening -> Icons.Outlined.GraphicEq
                is VoiceTranscriber.State.Finalizing -> Icons.Outlined.MoreHoriz
                is VoiceTranscriber.State.Error -> Icons.Outlined.Warning
                else -> Icons.Outlined.Mic
            }
            Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp))
        }
        if (state is VoiceTranscriber.State.Listening && partial.isNotBlank()) {
            Surface(
                shape = androidx.compose.foundation.shape.RoundedCornerShape(10.dp),
                color = MaterialTheme.colorScheme.surface,
                tonalElevation = 4.dp,
                modifier = Modifier.padding(top = 56.dp),
            ) {
                Text(
                    partial,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurface,
                    modifier = Modifier.padding(horizontal = 10.dp, vertical = 6.dp),
                    maxLines = 2,
                )
            }
        }
    }
}
