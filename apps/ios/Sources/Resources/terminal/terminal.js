// terminal.js — xterm.js bootstrap for Conduit WKWebView / Android WebView host.
// Communicates with the native side via a platform-detected bridge:
//   iOS:     window.webkit.messageHandlers.term.postMessage(obj)
//   Android: window.conduit.postMessage(JSON.stringify(obj))
// Messages:
//   { type: "ready" }                    emitted once after term.open()
//   { type: "input", data: "<utf8>" }    keystroke from xterm.onData
//   { type: "resize", cols, rows }       fit/resize from xterm.onResize
// Native code drives the terminal via these globals:
//   window.feedBytes(b64)   — base64-decoded UTF-8 bytes are written into xterm
//   window.serializeState() — returns full ANSI snapshot via SerializeAddon
//   window.reset()          — clears terminal (used on snapshot replace)
(function () {
  "use strict";

  // Pick the right bridge at boot. Both paths receive the same object
  // shape: iOS gets it as a JS dict via WKScriptMessageHandler, Android
  // gets it as a JSON string via @JavascriptInterface and parses it.
  var postBridge = (function () {
    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.term) {
      return function (msg) {
        window.webkit.messageHandlers.term.postMessage(msg);
      };
    }
    if (window.conduit && typeof window.conduit.postMessage === "function") {
      return function (msg) {
        window.conduit.postMessage(JSON.stringify(msg));
      };
    }
    return function () {};
  })();

  function post(msg) {
    try {
      postBridge(msg);
    } catch (e) {
      // No bridge (e.g. opened outside WebView) — drop silently.
    }
  }

  var term = new Terminal({
    fontFamily: "Menlo, monospace",
    fontSize: 13,
    theme: { background: "#0c0c0c", foreground: "#e8e8e8" },
    allowProposedApi: true,
    convertEol: false,
    scrollback: 10000,
    cursorBlink: false,
  });

  var fit = new FitAddon.FitAddon();
  term.loadAddon(fit);

  var serializer = new SerializeAddon.SerializeAddon();
  term.loadAddon(serializer);

  try {
    term.loadAddon(new WebglAddon.WebglAddon());
  } catch (e) {
    // WebGL unavailable — xterm falls back to the DOM renderer silently.
  }

  // We defer term.open() until window.load so fit.fit() has accurate
  // layout dimensions. Posting the fitted size BEFORE we accept any
  // bytes from Swift means the harness can ship its first snapshot
  // reflowed to our real viewport — fixing the size-mismatched wrap
  // that plain xterm-on-the-client can't undo.
  function boot() {
    term.open(document.getElementById("term"));
    try { fit.fit(); } catch (e) { /* ignore */ }

    // Belt-and-braces: emit a resize event with the fitted dimensions
    // explicitly. xterm's own onResize fires when dimensions change
    // from the constructor defaults, but we want to be sure Swift sees
    // them even if fit happened to produce the same shape.
    try {
      var d = fit.proposeDimensions();
      if (d && d.cols && d.rows) {
        post({ type: "resize", cols: d.cols, rows: d.rows });
      } else {
        post({ type: "resize", cols: term.cols, rows: term.rows });
      }
    } catch (e) {
      post({ type: "resize", cols: term.cols, rows: term.rows });
    }

    term.onData(function (d) {
      // The iOS soft keyboard's Return key emits LF; TUI agents (Claude,
      // Codex) expect CR for Enter. Normalize so users don't need a
      // hardware-style workflow just to submit a prompt.
      if (d === "\n") d = "\r";
      else if (d === "\r\n") d = "\r";
      post({ type: "input", data: d });
    });

    term.onResize(function (sz) {
      post({ type: "resize", cols: sz.cols, rows: sz.rows });
    });

    window.addEventListener("resize", function () {
      try { fit.fit(); } catch (e) { /* ignore */ }
    });

    // Touch scroll. With the outer WKWebView scrollView disabled (so it
    // doesn't compete with xterm.js for pans), the inner .xterm-viewport
    // does NOT receive native momentum scrolling on iOS — touchmove
    // events fire but no scroll happens. Wire it manually: translate
    // vertical drag distance into term.scrollLines.
    var termEl = document.getElementById("term");
    var lastTouchY = null;
    // Accumulate sub-cell drag distance across touchmove events so a
    // slow scroll still produces motion. Without this, small dy
    // values floor to 0 and the terminal feels unresponsive until the
    // finger has moved an entire row's worth of pixels in one frame.
    var dragAccumPx = 0;
    function cellHeightPx() {
      // xterm.js doesn't expose cell height as a public API; estimate
      // from fontSize. Menlo 13pt at default lineHeight ≈ 17px. A small
      // overshoot here just means scrolling feels slightly less twitchy.
      return Math.max(12, Math.round((term.options.fontSize || 13) * 1.3));
    }
    termEl.addEventListener("touchstart", function (e) {
      if (e.touches.length === 1) {
        lastTouchY = e.touches[0].clientY;
        dragAccumPx = 0;
      }
    }, { passive: true });
    termEl.addEventListener("touchmove", function (e) {
      if (e.touches.length !== 1 || lastTouchY === null) return;
      var y = e.touches[0].clientY;
      dragAccumPx += (lastTouchY - y);
      lastTouchY = y;
      var ch = cellHeightPx();
      var lines = (dragAccumPx >= 0 ? Math.floor(dragAccumPx / ch) : Math.ceil(dragAccumPx / ch));
      if (lines !== 0) {
        term.scrollLines(lines);
        dragAccumPx -= lines * ch;
        e.preventDefault();
      }
    }, { passive: false });
    termEl.addEventListener("touchend", function () {
      lastTouchY = null;
      dragAccumPx = 0;
    }, { passive: true });

    window.feedBytes = function (b64) {
      var bin = atob(b64);
      var arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      term.write(arr);
    };

    // Write an already-ANSI-encoded string straight to xterm. Used by
    // the native side to replay the previous render state from a
    // serializeState() snapshot — strings round-trip cleanly through
    // evaluateJavaScript so no base64 is needed for this path.
    window.writeRaw = function (s) {
      term.write(s);
    };

    window.serializeState = function () {
      return serializer.serialize();
    };

    window.reset = function () {
      term.reset();
    };

    // Tell Swift we are ready to receive bytes.
    post({ type: "ready" });
  }

  if (document.readyState === "complete") {
    boot();
  } else {
    window.addEventListener("load", boot);
  }
})();
