package sh.nikhil.swekitty.ui

import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.*
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

@Composable
fun BrowserPage(store: SessionStore, session: ProjectSession) {
    val previews by store.previews.collectAsState()
    val url = previews[session.id]?.url

    if (url == null) {
        Box(modifier = Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
            Text(
                "No preview yet",
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    } else {
        AndroidView(
            factory = { ctx ->
                WebView(ctx).apply {
                    webViewClient = WebViewClient()
                    settings.javaScriptEnabled = true
                    settings.domStorageEnabled = true
                    loadUrl(url)
                }
            },
            update = { view ->
                if (view.url != url) view.loadUrl(url)
            },
            modifier = Modifier.fillMaxSize(),
        )
    }
}
