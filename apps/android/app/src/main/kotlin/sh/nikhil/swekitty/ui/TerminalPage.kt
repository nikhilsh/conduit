package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Send
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

/**
 * v1 stub terminal: shows raw PTY scrollback as monospace text and provides a
 * line-buffered input field. Real terminal emulation (termux/terminal-view)
 * lands in task 007 / v0.3 multi-view.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalPage(store: SessionStore, session: ProjectSession) {
    val buffers by store.terminalBuffer.collectAsState()
    val raw = buffers[session.id] ?: ByteArray(0)
    val text = remember(raw) { String(raw, Charsets.UTF_8) }
    val scroll = rememberScrollState()
    var draft by remember { mutableStateOf("") }

    LaunchedEffect(text) { scroll.scrollTo(scroll.maxValue) }

    Column(modifier = Modifier.fillMaxSize()) {
        SelectionContainer(modifier = Modifier.weight(1f).fillMaxWidth()) {
            Text(
                text = text,
                modifier = Modifier
                    .verticalScroll(scroll)
                    .padding(8.dp),
                fontFamily = FontFamily.Monospace,
                fontSize = 12.sp,
                overflow = TextOverflow.Clip,
            )
        }
        HorizontalDivider()
        Row(
            modifier = Modifier.fillMaxWidth().padding(8.dp),
            verticalAlignment = androidx.compose.ui.Alignment.CenterVertically,
        ) {
            OutlinedTextField(
                value = draft,
                onValueChange = { draft = it },
                placeholder = { Text("type and press send") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            IconButton(onClick = {
                if (draft.isNotEmpty()) {
                    // Append newline so shell sees a return; mirrors hitting Enter.
                    val payload = (draft + "\n").toByteArray(Charsets.UTF_8)
                    store.sendInput(session.id, payload)
                    draft = ""
                }
            }) { Icon(Icons.Default.Send, contentDescription = "Send") }
        }
    }
}
