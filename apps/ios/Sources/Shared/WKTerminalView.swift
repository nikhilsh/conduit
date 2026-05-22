import SwiftUI
import WebKit

/// SwiftUI shell that wires the session store into the xterm.js-backed
/// terminal view. Replaces the SwiftTerm-backed `TerminalTab` for the
/// `.terminal` project tab. Surface is intentionally the same: take a
/// `ProjectSession` and read/write via the shared `SessionStore`.
///
/// Snapshot lifecycle: when the SwiftUI view leaves the hierarchy
/// (tab switch, background, etc.), `WKTerminalView.dismantleUIView`
/// fires; the coordinator calls `window.serializeState()` and
/// forwards the result to `store.terminalSnapshot[sessionID]` via
/// `onSnapshotCapture`. On next attach, that snapshot is read by
/// `initialSnapshot` and fed into the fresh xterm.js before live
/// PTY bytes — so the user sees their previous screen state
/// instantly instead of an empty terminal waiting for replay.
struct TerminalTabXterm: View {
    @Environment(SessionStore.self) private var store
    let session: ProjectSession

    var body: some View {
        WKTerminalView(
            sessionID: session.id,
            bufferProvider: { store.terminalBuffer[session.id] ?? Data() },
            bufferRevision: store.terminalBuffer[session.id]?.count ?? 0,
            initialSnapshot: store.terminalSnapshot[session.id],
            onInput: { bytes in
                store.sendInput(sessionID: session.id, bytes: bytes)
            },
            onResize: { rows, cols in
                store.resize(sessionID: session.id, rows: UInt16(rows), cols: UInt16(cols))
            },
            onSnapshotCapture: { [sessionID = session.id] snapshot in
                store.terminalSnapshot[sessionID] = snapshot
            }
        )
        // Scope: `.container` lets us extend under the home-indicator
        // inset (so the terminal still draws full-bleed at rest) WITHOUT
        // ignoring the keyboard safe area. The previous `.ignoresSafeArea(
        // edges: .bottom)` form ignored everything including the soft
        // keyboard, so the bottom rows of PTY output were hidden under
        // the keyboard while typing. Available since iOS 14.
        .ignoresSafeArea(.container, edges: .bottom)
        // SwiftUI ancestor touch-pass guard. The LitterUI shell hosts
        // this view inside a `NavigationStack { … VStack { header;
        // tabStrip; content } }` push. While none of the visible
        // ancestors install a `.gesture` / `TabView` / `ScrollView`,
        // the `NavigationStack`'s implicit interactive-pop pan
        // recognizer can race the WKWebView's UIKit touch handlers
        // for the first 150ms after touchDown — long enough that
        // xterm.js's `touchstart` JS handler never fires for short
        // vertical drags and the user perceives the terminal as
        // un-scrollable in LitterUI even though PR #109's WKWebView
        // scrollView fix (delaysContentTouches=false,
        // panGestureRecognizer.cancelsTouchesInView=false) is
        // intact below. Installing a zero-distance simultaneous
        // DragGesture here forces SwiftUI to treat the underlying
        // WKWebView as a gesture participant from touchDown rather
        // than waiting on ancestor arbitration — touches reach
        // xterm.js immediately and the scrollback gesture works.
        // The `onChanged` is intentionally a no-op: we're not
        // interpreting the drag, just claiming it for the subtree.
        .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in })
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
    /// If non-nil, fed to xterm.js immediately after `ready` (before any
    /// `bufferProvider()` deltas). Used to restore the previous render
    /// state when the view is re-entered after a SwiftUI dismantle.
    var initialSnapshot: String?
    let onInput: (Data) -> Void
    let onResize: (Int, Int) -> Void
    /// Called during dismantleUIView with the result of
    /// `window.serializeState()`. Forwarded asynchronously because
    /// evaluateJavaScript is async; the closure is held by SwiftUI
    /// and survives the representable's own destruction.
    var onSnapshotCapture: ((String) -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(onInput: onInput, onResize: onResize, initialSnapshot: initialSnapshot)
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
        // The xterm.js viewport runs its own touchmove handler that
        // translates vertical drag into `term.scrollLines`. iOS UIKit
        // delays touches that enter a scrollview's content by ~150ms
        // while it sniffs for a pan — long enough that the JS
        // touchstart never fires for short drags, and the user
        // perceives the terminal as un-scrollable. Forward the
        // gesture immediately and don't cancel touches in the
        // WKWebView's content view so xterm.js sees the full touch
        // sequence (touchstart → touchmove → touchend).
        webView.scrollView.delaysContentTouches = false
        webView.scrollView.panGestureRecognizer.cancelsTouchesInView = false
        webView.scrollView.bounces = false
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
        // Refresh the capture closure on every update — the parent
        // struct may have rebuilt with a new SessionStore reference,
        // and we want dismantleUIView to use the latest binding.
        coordinator.onSnapshotCapture = onSnapshotCapture
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

    /// SwiftUI lifecycle hook fired when the view is removed from the
    /// hierarchy. Capture the xterm.js render state here so the next
    /// attach can replay it. evaluateJavaScript is async; the closure
    /// SwiftUI retains is alive for the duration of the call even
    /// though the representable struct is gone by then.
    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.captureSnapshotIfReady()
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let onInput: (Data) -> Void
        let onResize: (Int, Int) -> Void
        /// Refreshed from the representable on every updateUIView so
        /// the latest closure runs at dismantle time.
        var onSnapshotCapture: ((String) -> Void)?
        weak var webView: WKWebView?
        var lastFedByteCount: Int = 0
        var ready: Bool = false
        /// Base64 chunks queued before xterm.js posted "ready".
        var pendingChunks: [String] = []
        /// If true, the next flush should reset the terminal first.
        var pendingReset: Bool = false
        /// Replay state from a prior dismantle. Fed into xterm.js
        /// right after `ready` posts, before live PTY bytes.
        let initialSnapshot: String?

        init(
            onInput: @escaping (Data) -> Void,
            onResize: @escaping (Int, Int) -> Void,
            initialSnapshot: String? = nil
        ) {
            self.onInput = onInput
            self.onResize = onResize
            self.initialSnapshot = initialSnapshot
        }

        /// Called from `WKTerminalView.dismantleUIView`. Asks xterm.js
        /// for its current serialized state via the SerializeAddon
        /// vendored in the JS bundle, then forwards the result to
        /// `onSnapshotCapture` so SessionStore can stash it for the
        /// next attach. Safe to call when not ready (no-op) or when
        /// onSnapshotCapture is nil (no-op).
        func captureSnapshotIfReady() {
            guard let webView, ready, let sink = onSnapshotCapture else { return }
            webView.evaluateJavaScript("window.serializeState()") { value, _ in
                guard let snapshot = value as? String, !snapshot.isEmpty else { return }
                sink(snapshot)
            }
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
                // Replay the prior snapshot first so the user sees
                // their last screen state instantly, then flush any
                // PTY bytes that arrived during the JS bootstrap.
                if let initial = initialSnapshot, !initial.isEmpty, let webView {
                    // Pass the snapshot as an argument to a function
                    // invoked via callAsyncJavaScript so we don't have
                    // to hand-escape every quote and newline in a
                    // serialized ANSI stream (which contains plenty of
                    // both). The function calls window.writeRaw added
                    // to terminal.js for this exact purpose.
                    webView.callAsyncJavaScript(
                        "window.reset(); window.writeRaw(s); return null;",
                        arguments: ["s": initial],
                        in: nil,
                        in: .page,
                        completionHandler: nil
                    )
                }
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
