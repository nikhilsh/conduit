package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.conduit.HostKeyPrompt

/**
 * TOFU dialog shown the first time we see a host's SSH fingerprint, or when
 * an already-trusted host's fingerprint changes. Persist the decision in
 * [sh.nikhil.conduit.SshHostKeyTrustStore] if the user accepts.
 *
 * The fingerprint card uses neon.surfaceSolid so it is fully opaque --
 * the previous surfaceVariant was translucent and let the scrim bleed through.
 */
@Composable
fun HostKeyPromptDialog(
    prompt: HostKeyPrompt,
    onAccept: () -> Unit,
    onReject: () -> Unit,
) {
    val neon = LocalNeonTheme.current
    AlertDialog(
        onDismissRequest = onReject,
        containerColor = neon.surfaceSolid,
        title = {
            Text(
                "Verify Host Key",
                fontFamily = neon.sans,
                color = neon.text,
            )
        },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "First time connecting to",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.sans,
                    color = neon.textDim,
                )
                Text(
                    "${prompt.host}:${prompt.port}",
                    fontFamily = neon.sans,
                    color = neon.text,
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    "Host Key Fingerprint",
                    fontFamily = neon.mono,
                    fontSize = 10.sp,
                    color = neon.textFaint,
                )
                Surface(
                    color = neon.surfaceSolid,
                    shape = RoundedCornerShape(8.dp),
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        prompt.fingerprint,
                        fontFamily = neon.mono,
                        fontSize = 11.sp,
                        color = neon.text,
                        modifier = Modifier.padding(12.dp),
                    )
                }
                Text(
                    "Verify this fingerprint against the server's ssh-keyscan output before trusting. If it doesn't match, something is intercepting your connection.",
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = neon.sans,
                    color = neon.textDim,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onAccept) {
                Text("Trust and Continue", fontFamily = neon.sans, color = neon.green)
            }
        },
        dismissButton = {
            TextButton(onClick = onReject) {
                Text("Reject", fontFamily = neon.sans, color = neon.textDim)
            }
        },
    )
}
