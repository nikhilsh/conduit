package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatPage(store: SessionStore, session: ProjectSession) {
    val log by store.chatLog.collectAsState()
    val events = log[session.id] ?: emptyList()
    var draft by remember { mutableStateOf("") }

    Column(modifier = Modifier.fillMaxSize()) {
        LazyColumn(modifier = Modifier.weight(1f).fillMaxWidth().padding(8.dp)) {
            items(events) { ev ->
                Column(modifier = Modifier.padding(vertical = 4.dp)) {
                    Text(
                        ev.role.uppercase(),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(ev.content, style = MaterialTheme.typography.bodyMedium)
                }
            }
        }
        HorizontalDivider()
        Row(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text("Message agent…") },
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = {
                val msg = draft.trim()
                if (msg.isNotEmpty()) {
                    store.sendChat(session.id, msg)
                    draft = ""
                }
            }) { Icon(Icons.Default.Send, contentDescription = "Send") }
        }
    }
}
