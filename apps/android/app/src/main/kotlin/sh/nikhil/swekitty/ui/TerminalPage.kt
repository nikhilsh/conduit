package sh.nikhil.swekitty.ui

import androidx.compose.foundation.layout.*
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
 * Terminal tab. PTY scrollback is parsed by [renderAnsi] into a styled
 * [androidx.compose.ui.text.AnnotatedString] — colors, bold/italic,
 * cursor-overwrite via `\r`, and CSI sequences other than SGR are
 * stripped. Real cursor-positioning emulation is out of scope; that's
 * a follow-up task.
 *
 * The whole buffer is re-rendered on each PTY delta (keyed on the
 * ByteArray identity, which changes on append). Acceptable for the
 * v0.x sizes; can become incremental if scrollback gets long.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun TerminalPage(store: SessionStore, session: ProjectSession) {
    val buffers by store.terminalBuffer.collectAsState()
    val raw = buffers[session.id] ?: ByteArray(0)
    val rendered = remember(raw) { renderAnsi(raw) }
    val scroll = rememberScrollState()
    var draft by remember { mutableStateOf("") }
    // Stop yanking the view back to bottom on every PTY event when the
    // user has deliberately scrolled up to read history — matches the
    // iOS SwiftTerm parity work (commit 69c4d7c). The flag flips on
    // whenever the user lands back near the bottom, off when they drag
    // away. New content only auto-follows when they're at the tail.
    var followBottom by remember { mutableStateOf(true) }
    LaunchedEffect(scroll.value, scroll.maxValue) {
        followBottom = scroll.value >= scroll.maxValue - 1
    }

    LaunchedEffect(rendered) {
        if (followBottom) scroll.scrollTo(scroll.maxValue)
    }

    Column(modifier = Modifier.fillMaxSize()) {
        SelectionContainer(modifier = Modifier.weight(1f).fillMaxWidth()) {
            Text(
                text = rendered,
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
