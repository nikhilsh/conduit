package sh.nikhil.conduit.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import sh.nikhil.conduit.HostKeyPrompt

/**
 * TOFU dialog shown the first time we see a host's SSH fingerprint, or when
 * an already-trusted host's fingerprint changes. Persist the decision in
 * [sh.nikhil.conduit.SshHostKeyTrustStore] if the user accepts.
 */
@Composable
fun HostKeyPromptDialog(
    prompt: HostKeyPrompt,
    onAccept: () -> Unit,
    onReject: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onReject,
        title = { Text("Verify Host Key") },
        text = {
            Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(
                    "First time connecting to",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
                Text(
                    "${prompt.host}:${prompt.port}",
                    style = MaterialTheme.typography.titleMedium,
                )
                Text(
                    "Host Key Fingerprint",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                )
                Surface(
                    tonalElevation = 4.dp,
                    color = MaterialTheme.colorScheme.surfaceVariant,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Text(
                        prompt.fingerprint,
                        style = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace),
                        modifier = Modifier.padding(12.dp),
                    )
                }
                Text(
                    "Verify this fingerprint against the server's `ssh-keyscan` output before trusting. If it doesn't match, something is intercepting your connection.",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
        },
        confirmButton = {
            TextButton(onClick = onAccept) { Text("Trust and Continue") }
        },
        dismissButton = {
            TextButton(onClick = onReject) { Text("Reject") }
        },
    )
}
