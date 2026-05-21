import SwiftUI
import WebKit

/// SwiftUI shell that wires the session store into the xterm.js-backed
/// terminal view. Replaces the SwiftTerm-backed `TerminalTab` for the
/// `.terminal` project tab. Surface is intentionally the same: take a
/// `ProjectSession` and read/write via the shared `SessionStore`.
struct TerminalTabXterm: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    var body: some View {
        WKTerminalView(
            sessionID: session.id,
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            onInput: { bytes in
                store.sendInput(sessionID: session.id, bytes: bytes)
            },
            onResize: { rows, cols in
                store.resize(sessionID: session.id, rows: UInt16(rows), cols: UInt16(cols))
            }
        )
        .ignoresSafeArea(edges: .bottom)
    }
}

/// Terminal view backed by xterm.js inside a WKWebView. This replaces the
/// SwiftTerm-based `TerminalTab` for Stage F'. The contract on the wire
/// (input bytes, resize rows/cols) is unchanged — only the local renderer
/// differs.
///
/// Bytes from the harness ring buffer come in via `bufferProvider()`. We
/// diff against `lastFedByteCount` and forward only the new tail to
/// JS via `window.feedBytes(base64)`. On snapshot replacement (buf
/// shrank) we call `window.reset()` then re-feed the whole buffer — this
/// is the analog of the `ESC c` (RIS) workaround in the old SwiftTerm
/// path, but xterm.js handles mid-stream restarts gracefully so the
/// vertical-stripe bug should not return.
struct WKTerminalView: UIViewRepresentable {
    let sessionID: String
    let bufferProvider: () -> Data
    let bufferRevision: Int
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.add(context.coordinator, name: "term")

        // KeyableWKWebView injects our custom Esc/Tab/Arrows/Return
        // bar over the soft keyboard. The bar's onSend pipes back
        // through the same input callback as keystrokes from xterm.js,
        // so the harness can't tell them apart on the wire.
        let webView = KeyableWKWebView(frame: .zero, configuration: config)
        let bar = TerminalAccessoryBar()
        bar.onSend = { [weak coordinator = context.coordinator] bytes in
            coordinator?.onInput(bytes)
        }
        webView.terminalAccessoryView = bar
        webView.navigationDelegate = context.coordinator
        webView.scrollView.isScrollEnabled = false // xterm.js handles its own scrollback
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.backgroundColor = .black
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.webView = webView

        // The bundle layout depends on how XcodeGen registered the folder:
        // - `type: folder` keeps the subdirectory ("terminal/xterm.js")
        // - default flat copy drops it (just "xterm.js" at bundle root)
        // Try the subdirectory form first, then fall back to the flat
        // layout so we are robust to either packaging.
        let url: URL? = Bundle.main.url(
            forResource: "terminal",
            withExtension: "html",
            subdirectory: "terminal"
        ) ?? Bundle.main.url(forResource: "terminal", withExtension: "html")

        if let url {
            let readAccess = url.deletingLastPathComponent()
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        } else {
            assertionFailure("terminal.html missing from bundle")
        }

        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        let buf = bufferProvider()
        let last = coordinator.lastFedByteCount

        if buf.count > last {
            let slice = buf[last..<buf.count]
            let b64 = Data(slice).base64EncodedString()
            coordinator.feedOrQueue(b64: b64)
            coordinator.lastFedByteCount = buf.count
        } else if buf.count < last {
            // Snapshot replaced the buffer entirely. Reset xterm and
            // replay the new snapshot from scratch.
            let b64 = buf.base64EncodedString()
            coordinator.resetAndFeed(b64: b64)
            coordinator.lastFedByteCount = buf.count
        }
    }

    /// Convenience for callers that want to capture the rendered state
    /// before backgrounding. Today the snapshot is only logged — a
    /// future PR will persist it through SessionStore so the next
    /// attach can replay it locally.
    func teardown() {
        // Coordinator is not directly reachable from the representable
        // outside the SwiftUI update cycle; callers should hold the
        // view and trigger this via SessionStore in a follow-up PR.
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void
        weak var webView: WKWebView?
        var lastFedByteCount: Int = 0
        var ready: Bool = false
        /// Base64 chunks queued before xterm.js posted "ready".
        var pendingChunks: [String] = []
        /// If true, the next flush should reset the terminal first.
        var pendingReset: Bool = false

        init(onInput: @escaping (Data) -> Void, onResize: @escaping (Int, Int) -> Void) {
            self.onInput = onInput
            self.onResize = onResize
        }

        func feedOrQueue(b64: String) {
            guard !b64.isEmpty else { return }
            guard ready, let webView else {
                pendingChunks.append(b64)
                return
            }
            let js = "window.feedBytes('\(b64)')"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func resetAndFeed(b64: String) {
            guard let webView, ready else {
                pendingReset = true
                pendingChunks = [b64]
                return
            }
            let js = "window.reset(); window.feedBytes('\(b64)');"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func flushPending() {
            guard let webView else { return }
            if pendingReset {
                webView.evaluateJavaScript("window.reset()", completionHandler: nil)
                pendingReset = false
            }
            for chunk in pendingChunks where !chunk.isEmpty {
                webView.evaluateJavaScript("window.feedBytes('\(chunk)')", completionHandler: nil)
            }
            pendingChunks.removeAll(keepingCapacity: false)
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "term",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else {
                return
            }
            switch type {
            case "ready":
                ready = true
                flushPending()
            case "input":
                if let data = body["data"] as? String,
                   let bytes = data.data(using: .utf8) {
                    onInput(bytes)
                }
            case "resize":
                if let cols = body["cols"] as? Int, let rows = body["rows"] as? Int {
                    onResize(rows, cols)
                } else if let cols = (body["cols"] as? NSNumber)?.intValue,
                          let rows = (body["rows"] as? NSNumber)?.intValue {
                    onResize(rows, cols)
                }
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Page finished loading. JS will post `{ type: "ready" }`
            // once xterm.js has opened — we don't flush here, we wait
            // for that message so we know the renderer is mounted.
        }
    }
}

/// `WKWebView` subclass that exposes a custom `inputAccessoryView`.
/// WKWebView's default `inputAccessoryView` is `nil`; the soft keyboard
/// gets its own bar but there is no public hook to attach our toolbar
/// without subclassing. This is the documented workaround used by
/// every iOS terminal app on the App Store.
final class KeyableWKWebView: WKWebView {
    var terminalAccessoryView: UIView?

    override var inputAccessoryView: UIView? { terminalAccessoryView }

    // `canBecomeFirstResponder` defaults to whatever WKWebView's
    // hidden text-input internals say. Don't override — let the
    // existing first-responder choreography stand.
}
