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

  // Native code may seed an initial font size + theme before boot by
  // assigning window.CONDUIT_TERM_CONFIG = { fontSize, theme }. Falls
  // back to a dense 10pt Ghostty-Dark default (matches iOS) if absent.
  var seed = window.CONDUIT_TERM_CONFIG || {};
  var initialFontSize = typeof seed.fontSize === "number" ? seed.fontSize : 10;
  var initialTheme = seed.theme || { background: "#1d1f21", foreground: "#c5c8c6", cursor: "#c5c8c6" };

  var term = new Terminal({
    fontFamily: "Menlo, monospace",
    fontSize: initialFontSize,
    theme: initialTheme,
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

    // Touch scroll. Two regimes, mirroring the iOS native terminal fix:
    //
    //  1. The broker runs every session under tmux with `mouse on`, which
    //     makes tmux DECSET mouse tracking (1000/1002/1003 + SGR 1006).
    //     When that's on, xterm.js' OWN scrollback is empty — tmux owns
    //     the screen and scrolled-off lines never land in xterm's buffer,
    //     so `term.scrollLines()` does nothing. The only way to walk real
    //     history is to forward mouse-WHEEL reports to the PTY so tmux
    //     enters copy-mode and scrolls. We encode SGR (1006) wheel events
    //     ourselves (ESC [ < Cb ; Cx ; Cy M) and ship them via `onData`'s
    //     `input` bridge message — exactly what iOS does.
    //
    //  2. If mouse tracking is OFF (no tmux / a full-screen app that
    //     didn't enable it), fall back to scrolling xterm's local
    //     scrollback with `term.scrollLines` so the gesture still works.
    //
    // Direction: a finger dragging DOWN reveals OLDER content above →
    // wheel UP (button 64); finger UP → wheel DOWN (button 65).
    var termEl = document.getElementById("term");
    var lastTouchY = null;
    var wheelRemainder = 0;
    // Points of finger travel that equal one wheel "click". Matches the
    // iOS `scrollPointsPerWheel` so the feel is consistent across
    // platforms; the remainder is carried so slow drags still scroll.
    var POINTS_PER_WHEEL = 24;

    function cellHeightPx() {
      // xterm.js doesn't expose cell height as a public API; estimate
      // from fontSize. A small overshoot here just means scrolling feels
      // slightly less twitchy.
      return Math.max(12, Math.round((term.options.fontSize || 10) * 1.3));
    }

    // Is the foreground app (tmux) requesting mouse reports? xterm.js
    // tracks this in `term.modes.mouseTrackingMode` ("none" when off).
    function mouseTrackingOn() {
      try {
        var m = term.modes && term.modes.mouseTrackingMode;
        return !!m && m !== "none";
      } catch (e) {
        return false;
      }
    }

    function sendWheel(buttonCode) {
      // 1-based cell coords; tmux only needs them to be inside the pane,
      // so report the centre of the grid. Wheel events use the press
      // form `M` (no separate release).
      var cx = Math.max(1, Math.floor((term.cols || 80) / 2));
      var cy = Math.max(1, Math.floor((term.rows || 24) / 2));
      var seq = "\x1b[<" + buttonCode + ";" + cx + ";" + cy + "M";
      post({ type: "input", data: seq });
    }

    termEl.addEventListener("touchstart", function (e) {
      if (e.touches.length === 1) {
        lastTouchY = e.touches[0].clientY;
        wheelRemainder = 0;
      }
    }, { passive: true });
    termEl.addEventListener("touchmove", function (e) {
      if (e.touches.length !== 1 || lastTouchY === null) return;
      var y = e.touches[0].clientY;
      var dy = lastTouchY - y; // positive = content should scroll up (older)
      lastTouchY = y;
      if (dy === 0) return;

      if (mouseTrackingOn()) {
        // Forward discrete wheel clicks to the PTY for tmux copy-mode.
        // `dy > 0` (finger up) reveals NEWER content → wheel DOWN (65);
        // `dy < 0` (finger down) reveals OLDER content → wheel UP (64).
        wheelRemainder += dy;
        while (wheelRemainder >= POINTS_PER_WHEEL) {
          wheelRemainder -= POINTS_PER_WHEEL;
          sendWheel(65); // scroll toward newest output
        }
        while (wheelRemainder <= -POINTS_PER_WHEEL) {
          wheelRemainder += POINTS_PER_WHEEL;
          sendWheel(64); // scroll back into history
        }
        e.preventDefault();
      } else {
        // No mouse tracking: scroll xterm's own scrollback locally.
        var ch = cellHeightPx();
        var lines = (dy >= 0 ? Math.floor(dy / ch) : Math.ceil(dy / ch));
        if (lines !== 0) {
          term.scrollLines(lines);
          e.preventDefault();
        }
      }
    }, { passive: false });
    termEl.addEventListener("touchend", function () {
      lastTouchY = null;
      wheelRemainder = 0;
    }, { passive: true });

    window.feedBytes = function (b64) {
      var bin = atob(b64);
      var arr = new Uint8Array(bin.length);
      for (var i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
      term.write(arr);
    };

    window.serializeState = function () {
      return serializer.serialize();
    };

    window.reset = function () {
      term.reset();
    };

    // Live-update the cell font size. Re-fit afterwards so the grid
    // (cols/rows) reflows to the new cell metrics and the resize is
    // posted back to native → broker PTY. Mirrors iOS' font-size path.
    window.setFontSize = function (size) {
      var n = parseFloat(size);
      if (!isFinite(n) || n <= 0) return;
      term.options.fontSize = n;
      try { fit.fit(); } catch (e) { /* ignore */ }
    };

    // Live-update the color theme. `themeJson` is the xterm.js theme
    // object ({ background, foreground, cursor, + 16 ANSI names }) as a
    // JSON string built on the native side from TerminalPalette.
    window.setTheme = function (themeJson) {
      try {
        var t = typeof themeJson === "string" ? JSON.parse(themeJson) : themeJson;
        if (t) term.options.theme = t;
      } catch (e) { /* malformed theme — keep current */ }
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
