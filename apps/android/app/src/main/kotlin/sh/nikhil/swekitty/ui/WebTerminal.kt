package sh.nikhil.swekitty.ui

import android.annotation.SuppressLint
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import org.json.JSONObject
import sh.nikhil.swekitty.AppearanceStore
import sh.nikhil.swekitty.LocalAppearanceStore
import sh.nikhil.swekitty.SessionStore
import uniffi.swe_kitty_core.ProjectSession

/**
 * Compose entry point for the xterm.js-backed terminal tab. Ports the
 * iOS `TerminalTabXterm` / `WKTerminalView` surface to Android while
 * keeping the wire contract identical: pump PTY bytes in via
 * [SessionStore.terminalBuffer] and route keystrokes / resize events
 * back through [SessionStore.sendInput] / [SessionStore.resize].
 *
 * The native renderer (Compose `Text` with a hand-rolled ANSI parser)
 * has been retired in favour of xterm.js running inside a WebView —
 * this matches iOS and fixes the wrap/cursor parity bugs the parser
 * couldn't reasonably handle.
 */
@Composable
fun TerminalPage(store: SessionStore, session: ProjectSession) {
    val buffers by store.terminalBuffer.collectAsState()
    val raw = buffers[session.id] ?: ByteArray(0)
    // Appearance: font size + curated terminal theme are user-tunable
    // in Settings and live-update the visible terminal (matching the
    // iOS native terminal). Defaults are a dense 10pt + Ghostty Dark.
    val appearance = LocalAppearanceStore.current
    val fontSize by appearance.terminalFontSize.collectAsState()
    val terminalTheme by appearance.terminalTheme.collectAsState()
    WebTerminal(
        sessionID = session.id,
        buffer = raw,
        fontSize = fontSize,
        terminalTheme = terminalTheme,
        onInput = { bytes -> store.sendInput(session.id, bytes) },
        onResize = { rows, cols ->
            store.resize(session.id, rows.toUShort(), cols.toUShort())
        },
        modifier = Modifier,
    )
}

/**
 * Direct port of the iOS `WKTerminalView`. The buffer diff lives here
 * (we compare against `state.lastFedByteCount`) so that the caller can
 * pass the full buffer on every recomposition without re-rendering the
 * entire terminal — only the new tail goes across the JS bridge.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun WebTerminal(
    sessionID: String,
    buffer: ByteArray,
    fontSize: Float = AppearanceStore.DEFAULT_TERMINAL_FONT_SIZE,
    terminalTheme: AppearanceStore.TerminalTheme = AppearanceStore.TerminalTheme.GhosttyDark,
    onInput: (ByteArray) -> Unit,
    onResize: (Int, Int) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Per-session state survives recompositions; if the session id
    // changes we throw it away so a fresh attach doesn't try to diff
    // against a stale `lastFedByteCount`.
    val state = remember(sessionID) { WebTerminalState() }

    AndroidView(
        modifier = modifier,
        factory = { ctx ->
            val wv = WebView(ctx).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                setBackgroundColor(0xFF000000.toInt())
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                // xterm.js handles its own scrollback; we don't want the
                // WebView to fight it for pans (matches iOS where the
                // scrollView is disabled).
                isVerticalScrollBarEnabled = false
                isHorizontalScrollBarEnabled = false
                overScrollMode = WebView.OVER_SCROLL_NEVER
                setOnLongClickListener { false }
            }

            val bridge = TerminalBridge(
                state = state,
                webView = wv,
                onInput = onInput,
                onResize = onResize,
            )
            wv.addJavascriptInterface(bridge, "swekitty")

            state.webView = wv
            // Seed the appearance so the first paint (and the `ready`
            // flush) already use the user's font size + theme rather
            // than a brief flash of the JS defaults.
            state.fontSize = fontSize
            state.terminalTheme = terminalTheme
            wv.loadUrl("file:///android_asset/terminal/terminal.html")
            wv
        },
        update = { _ ->
            // Diff against the last byte count we forwarded to JS and
            // ship only the delta. If the buffer shrank (snapshot
            // replace), reset the terminal and replay from scratch.
            val last = state.lastFedByteCount
            when {
                buffer.size > last -> {
                    val slice = buffer.copyOfRange(last, buffer.size)
                    val b64 = Base64.encodeToString(slice, Base64.NO_WRAP)
                    state.feedOrQueue(b64)
                    state.lastFedByteCount = buffer.size
                }
                buffer.size < last -> {
                    val b64 = Base64.encodeToString(buffer, Base64.NO_WRAP)
                    state.resetAndFeed(b64)
                    state.lastFedByteCount = buffer.size
                }
            }
        },
    )

    // Live-apply font size + theme on every change. Idempotent on the
    // JS side; if the terminal isn't `ready` yet the value is stashed in
    // [WebTerminalState] and flushed by the `ready` handler.
    LaunchedEffect(sessionID, fontSize) {
        state.applyFontSize(fontSize)
    }
    LaunchedEffect(sessionID, terminalTheme) {
        state.applyTheme(terminalTheme)
    }

    DisposableEffect(sessionID) {
        onDispose {
            state.webView?.let { wv ->
                wv.removeJavascriptInterface("swekitty")
                wv.stopLoading()
                wv.destroy()
            }
            state.webView = null
        }
    }
}

/**
 * Mutable scratch space for [WebTerminal]. Holds the WebView handle,
 * the byte-count cursor used for diffing, and queued chunks waiting on
 * the JS `ready` post.
 */
internal class WebTerminalState {
    var webView: WebView? = null
    var lastFedByteCount: Int = 0

    @Volatile var ready: Boolean = false
    private val pendingChunks = ArrayDeque<String>()
    private var pendingReset: Boolean = false
    private val main = Handler(Looper.getMainLooper())

    // Current appearance, mirrored so we can re-apply on `ready` (the
    // first paint) and so a change while not-ready is not lost. Seeded
    // by the factory before the page loads.
    @Volatile var fontSize: Float = AppearanceStore.DEFAULT_TERMINAL_FONT_SIZE
    @Volatile var terminalTheme: AppearanceStore.TerminalTheme =
        AppearanceStore.TerminalTheme.GhosttyDark

    /** Push a new font size to the live terminal (re-fits the grid). */
    @Synchronized
    fun applyFontSize(size: Float) {
        fontSize = size
        if (ready) evalOnMain("window.setFontSize($size)")
    }

    /** Push a new color theme to the live terminal. */
    @Synchronized
    fun applyTheme(theme: AppearanceStore.TerminalTheme) {
        terminalTheme = theme
        if (ready) evalOnMain("window.setTheme('${TerminalPalette.xtermThemeJson(theme)}')")
    }

    @Synchronized
    fun feedOrQueue(b64: String) {
        if (b64.isEmpty()) return
        if (!ready || webView == null) {
            pendingChunks.addLast(b64)
            return
        }
        evalOnMain("window.feedBytes('$b64')")
    }

    @Synchronized
    fun resetAndFeed(b64: String) {
        if (!ready || webView == null) {
            pendingReset = true
            pendingChunks.clear()
            if (b64.isNotEmpty()) pendingChunks.addLast(b64)
            return
        }
        evalOnMain("window.reset(); window.feedBytes('$b64');")
    }

    @Synchronized
    fun flushPending() {
        // Apply the user's font size + theme first so the buffer we're
        // about to feed reflows / paints with the right metrics + colors.
        evalOnMain("window.setFontSize($fontSize)")
        evalOnMain("window.setTheme('${TerminalPalette.xtermThemeJson(terminalTheme)}')")
        if (pendingReset) {
            evalOnMain("window.reset()")
            pendingReset = false
        }
        while (pendingChunks.isNotEmpty()) {
            val chunk = pendingChunks.removeFirst()
            if (chunk.isNotEmpty()) {
                evalOnMain("window.feedBytes('$chunk')")
            }
        }
    }

    private fun evalOnMain(js: String) {
        val wv = webView ?: return
        if (Looper.myLooper() == Looper.getMainLooper()) {
            wv.evaluateJavascript(js, null)
        } else {
            main.post { wv.evaluateJavascript(js, null) }
        }
    }
}

/**
 * `@JavascriptInterface` shim wired up under `window.swekitty`. The JS
 * side posts JSON strings (see `terminal.js`'s `postBridge` helper);
 * this class parses them and translates into the same callbacks the
 * iOS coordinator dispatches.
 *
 * NB: methods annotated with `@JavascriptInterface` are invoked on an
 * arbitrary thread chosen by the WebView. Anything that touches the
 * WebView (evaluateJavascript) MUST hop back to the main thread — see
 * [WebTerminalState.evalOnMain].
 */
// `internal` (not `private`) so apps/android/app/src/test/... can
// drive postMessage with canned JSON. Keeps the parser exercised by
// a unit test instead of waiting for a real WebView to deliver bytes.
internal class TerminalBridge(
    private val state: WebTerminalState,
    @Suppress("unused") private val webView: WebView,
    private val onInput: (ByteArray) -> Unit,
    private val onResize: (Int, Int) -> Unit,
) {
    @JavascriptInterface
    fun postMessage(json: String) {
        val obj = try {
            JSONObject(json)
        } catch (e: Exception) {
            return
        }
        when (obj.optString("type")) {
            "ready" -> {
                state.ready = true
                state.flushPending()
            }
            "input" -> {
                val data = obj.optString("data", "")
                if (data.isNotEmpty()) {
                    onInput(data.toByteArray(Charsets.UTF_8))
                }
            }
            "resize" -> {
                // xterm.js posts integers but JSON-via-JS may surface
                // them as doubles; optInt handles both via floor().
                val cols = obj.optInt("cols", -1)
                val rows = obj.optInt("rows", -1)
                if (cols > 0 && rows > 0) {
                    onResize(rows, cols)
                }
            }
            else -> Unit
        }
    }
}
