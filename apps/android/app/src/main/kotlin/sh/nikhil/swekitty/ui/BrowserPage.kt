package sh.nikhil.swekitty.ui

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Public
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

enum class BrowserMode { Preview, Memory }

@Composable
fun BrowserPage(store: SessionStore, session: ProjectSession, mode: BrowserMode = BrowserMode.Preview) {
    val previews by store.previews.collectAsState()
    val endpoint by store.endpoint.collectAsState()
    val base = endpoint.httpBaseUrl
    val neon = LocalNeonTheme.current

    val resolved: String? = when (mode) {
        BrowserMode.Preview -> previews[session.id]?.url?.let { resolve(base, it) }
        BrowserMode.Memory  -> resolve(base, "/memory/sessions/${session.id}.html")
    }

    if (resolved == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                when (mode) {
                    BrowserMode.Preview -> "No preview yet"
                    BrowserMode.Memory  -> "No memory yet"
                },
                style = MaterialTheme.typography.bodyLarge,
                fontFamily = neon.sans,
                color = neon.textDim,
            )
        }
        return
    }

    Column(modifier = Modifier.fillMaxSize()) {
        // Neon URL bar: a mono pill showing the live address with a globe
        // glyph, sitting above the WebView as the browser chrome.
        val barShape = RoundedCornerShape(10.dp)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 10.dp, vertical = 6.dp)
                .clip(barShape)
                .background(neon.codeBg, barShape)
                .border(1.dp, neon.border, barShape)
                .padding(horizontal = 10.dp, vertical = 7.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Icon(
                Icons.Outlined.Public,
                contentDescription = null,
                tint = neon.accent,
                modifier = Modifier.size(15.dp),
            )
            Text(
                resolved,
                style = MaterialTheme.typography.labelMedium,
                fontFamily = neon.mono,
                color = neon.codeText,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }

        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    webViewClient = WebViewClient()
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    loadUrl(resolved)
                }
            },
            update = { view ->
                if (view.url != resolved) view.loadUrl(resolved)
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
}

private fun resolve(base: String?, pathOrUrl: String): String? {
    val lower = pathOrUrl.lowercase()
    if (lower.startsWith("http://") || lower.startsWith("https://")) return pathOrUrl
    if (base.isNullOrBlank()) return null
    val sep = if (pathOrUrl.startsWith("/")) "" else "/"
    return "$base$sep$pathOrUrl"
}
