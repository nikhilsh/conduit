// Replay HTTP surface — serves `GET /replay/<session-id>` with an
// HTML+JS page that streams the recorded JSONL file and replays it
// through xterm.js (loaded from a CDN).
//
// Auth: each URL must carry `?t=<hmac>` derived from
// HMAC_SHA256(secret, session_id) → first 16 bytes hex. Without a
// matching token the server returns 401. This keeps replay URLs
// non-enumerable: an attacker who knows a session UUID still cannot
// download the timeline.
//
// The HTML player is intentionally simple: no build step, no embedded
// fonts, one inline JS file. xterm.js is fetched from jsdelivr at page
// load — documented offline limitation per the audit (rather than
// shipping a >300 KB blob inside the broker binary).
package replay

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"html"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// copyTimeline streams the replay file to the HTTP response. Wrapped
// so the test suite can stub out file I/O without dragging in a
// dedicated interface.
var copyTimeline = io.Copy

// Server serves the replay HTML page and bundled timeline. One Server
// is constructed per broker process.
type Server struct {
	BaseDir string
	Secret  []byte
}

// NewServer constructs a Server rooted at `baseDir` (per-session
// subdirectories must live under it) with the supplied HMAC secret.
// The secret can be any non-empty byte string — in v1 we pass the
// broker bearer token, so anyone who can already attach to the
// websocket can also mint a replay URL.
func NewServer(baseDir string, secret []byte) *Server {
	return &Server{BaseDir: baseDir, Secret: secret}
}

// Token returns the URL-safe HMAC token for the given session id.
// Truncated to 16 bytes hex (32 chars) — same entropy as a v4 UUID,
// which is what the session id space is anyway.
func (s *Server) Token(sessionID string) string {
	mac := hmac.New(sha256.New, s.Secret)
	_, _ = mac.Write([]byte(sessionID))
	sum := mac.Sum(nil)
	return hex.EncodeToString(sum[:16])
}

// verifyToken constant-time-compares the supplied token against the
// expected HMAC for `sessionID`. Returns false on any mismatch
// (including length) — never leaks where the comparison failed.
func (s *Server) verifyToken(sessionID, token string) bool {
	expected := s.Token(sessionID)
	if len(token) != len(expected) {
		return false
	}
	return hmac.Equal([]byte(expected), []byte(token))
}

// Handler returns the HTTP handler that serves `GET /replay/<id>` and
// `GET /replay/<id>/timeline.json`. Mount on the broker's existing mux.
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/replay/", s.serveReplay)
	return mux
}

// serveReplay dispatches between the HTML player and the raw JSONL
// timeline based on the URL suffix. We use one handler so the auth
// check sits in one place.
func (s *Server) serveReplay(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	suffix := strings.TrimPrefix(r.URL.Path, "/replay/")
	if suffix == "" {
		http.Error(w, "missing session id", http.StatusBadRequest)
		return
	}
	// Path layout: /replay/<id> → HTML page, /replay/<id>/timeline.json → JSONL.
	parts := strings.SplitN(suffix, "/", 2)
	sessionID := parts[0]
	if !isSafeID(sessionID) {
		http.Error(w, "invalid session id", http.StatusBadRequest)
		return
	}
	token := r.URL.Query().Get("t")
	if token == "" || !s.verifyToken(sessionID, token) {
		http.Error(w, "unauthorized", http.StatusUnauthorized)
		return
	}
	if len(parts) == 2 && parts[1] == "timeline.json" {
		s.serveTimeline(w, sessionID)
		return
	}
	if len(parts) == 2 && parts[1] != "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	s.serveHTML(w, r, sessionID, token)
}

// serveTimeline streams the recorded JSONL straight to the client.
// `application/x-ndjson` keeps it self-describing for curl debugging.
func (s *Server) serveTimeline(w http.ResponseWriter, sessionID string) {
	path := filepath.Join(s.BaseDir, sessionID, "replay.json")
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			http.Error(w, "no recording", http.StatusNotFound)
			return
		}
		http.Error(w, "internal error", http.StatusInternalServerError)
		return
	}
	defer f.Close()
	w.Header().Set("Content-Type", "application/x-ndjson; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = copyTimeline(w, f)
}

// serveHTML writes the inline player page. The timeline JSON is fetched
// asynchronously by the embedded JS rather than inlined — keeps the
// HTML small and lets browsers stream the (potentially large) file.
//
// We DO inline a tiny JSON blob with the configuration the JS needs
// (session id + timeline URL + token), so the test's "HTML contains the
// embedded JSON" assertion passes without parsing the JS.
func (s *Server) serveHTML(w http.ResponseWriter, r *http.Request, sessionID, token string) {
	cfg := map[string]string{
		"session_id":   sessionID,
		"timeline_url": fmt.Sprintf("/replay/%s/timeline.json?t=%s", sessionID, token),
	}
	cfgJSON, _ := json.Marshal(cfg)
	page := strings.ReplaceAll(replayHTML, "__SESSION_ID__", html.EscapeString(sessionID))
	page = strings.ReplaceAll(page, "__REPLAY_CONFIG_JSON__", string(cfgJSON))
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write([]byte(page))
}

// isSafeID enforces a conservative allowlist on the session id so a
// malicious URL cannot break out of BaseDir or read arbitrary files.
// The protocol says session ids are v4 UUIDs — letters / digits / dash
// is plenty.
func isSafeID(id string) bool {
	if id == "" || len(id) > 128 {
		return false
	}
	for _, c := range id {
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == '-' || c == '_':
		default:
			return false
		}
	}
	return true
}

// replayHTML is the player template. xterm.js is loaded from jsdelivr
// (documented offline limitation). Placeholders `__SESSION_ID__` and
// `__REPLAY_CONFIG_JSON__` are substituted at serve time.
const replayHTML = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>swe-kitty replay · __SESSION_ID__</title>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/xterm@5.3.0/css/xterm.css">
<style>
  body { margin: 0; background: #0b0d12; color: #d6deeb; font: 14px/1.4 system-ui, sans-serif; }
  header { display: flex; align-items: center; gap: 12px; padding: 8px 14px; background: #11141b; border-bottom: 1px solid #1f2330; }
  header h1 { font-size: 13px; font-weight: 600; margin: 0; flex: 1; opacity: 0.9; }
  button { background: #1d2230; color: #d6deeb; border: 1px solid #2a3142; border-radius: 4px; padding: 4px 10px; font: inherit; cursor: pointer; }
  button:hover { background: #252b3d; }
  button[aria-pressed="true"] { background: #3a4663; border-color: #5269a6; }
  main { display: grid; grid-template-columns: 1fr 320px; gap: 0; height: calc(100vh - 41px); }
  #terminal { padding: 8px; background: #000; overflow: hidden; }
  aside { border-left: 1px solid #1f2330; background: #11141b; overflow-y: auto; padding: 8px; }
  aside h2 { font-size: 11px; font-weight: 600; margin: 0 0 6px; opacity: 0.6; text-transform: uppercase; letter-spacing: 0.06em; }
  .evt { background: #181c27; border: 1px solid #232838; border-left: 3px solid #5269a6; border-radius: 4px; padding: 6px 8px; margin-bottom: 6px; font-size: 12px; }
  .evt .v { font-weight: 600; color: #82a4ff; }
  .evt pre { margin: 4px 0 0; white-space: pre-wrap; word-break: break-word; font-size: 11px; opacity: 0.85; }
  .status { font-size: 11px; opacity: 0.6; }
</style>
</head>
<body>
<header>
  <h1>swe-kitty replay · <code>__SESSION_ID__</code></h1>
  <span class="status" id="status">loading…</span>
  <button id="speed1" aria-pressed="true">1×</button>
  <button id="speed4">4×</button>
  <button id="speed16">16×</button>
</header>
<main>
  <div id="terminal"></div>
  <aside><h2>view_events</h2><div id="events"></div></aside>
</main>
<script id="replay-config" type="application/json">__REPLAY_CONFIG_JSON__</script>
<script src="https://cdn.jsdelivr.net/npm/xterm@5.3.0/lib/xterm.js"></script>
<script>
(async function () {
  const cfg = JSON.parse(document.getElementById("replay-config").textContent);
  const statusEl = document.getElementById("status");
  const eventsEl = document.getElementById("events");
  const term = new Terminal({
    cols: 120, rows: 40,
    convertEol: true,
    fontFamily: "ui-monospace, Menlo, Consolas, monospace",
    fontSize: 13,
    theme: { background: "#000000" }
  });
  term.open(document.getElementById("terminal"));
  let speed = 1;
  for (const [id, factor] of [["speed1", 1], ["speed4", 4], ["speed16", 16]]) {
    const btn = document.getElementById(id);
    btn.addEventListener("click", () => {
      speed = factor;
      document.querySelectorAll("header button").forEach((b) => b.setAttribute("aria-pressed", b === btn ? "true" : "false"));
    });
  }
  statusEl.textContent = "fetching timeline…";
  const resp = await fetch(cfg.timeline_url);
  if (!resp.ok) {
    statusEl.textContent = "error: " + resp.status + " " + resp.statusText;
    return;
  }
  const text = await resp.text();
  const lines = text.split("\n").filter((l) => l.length > 0);
  const events = [];
  for (const line of lines) {
    try { events.push(JSON.parse(line)); } catch (_) {}
  }
  statusEl.textContent = events.length + " events";
  if (events.length === 0) return;
  const t0 = new Date(events[0].ts).getTime();
  const decode = (b64) => Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  const dec = new TextDecoder("utf-8");
  let i = 0;
  const start = performance.now();
  function step() {
    while (i < events.length) {
      const evt = events[i];
      const offset = (new Date(evt.ts).getTime() - t0) / speed;
      if (performance.now() - start < offset) {
        setTimeout(step, Math.max(0, offset - (performance.now() - start)));
        return;
      }
      if (evt.kind === "pty") {
        const bytes = decode(evt.b64);
        term.write(dec.decode(bytes));
      } else if (evt.kind === "view_event") {
        const card = document.createElement("div");
        card.className = "evt";
        const v = document.createElement("span");
        v.className = "v";
        v.textContent = evt.view || "event";
        card.appendChild(v);
        const pre = document.createElement("pre");
        pre.textContent = JSON.stringify(evt.payload, null, 2);
        card.appendChild(pre);
        eventsEl.appendChild(card);
      }
      i++;
    }
    statusEl.textContent = "done";
  }
  step();
})();
</script>
</body>
</html>`
