package session

import (
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// preview.go owns the per-session browser-preview surface: deciding which
// port/URL (if any) to advertise to the app's Browser tab, and proving a
// listener actually belongs to this session before claiming it.
//
// Two problems this guards against:
//
//  1. False positive ("phantom tab"). The preview port is drawn from a shared
//     pool (3000–3019) the broker hands to every session as $PORT. The old
//     "anything listening on the port ⇒ advertise it" rule meant a stranger
//     squatting that loopback port (a leftover dev server, an unrelated local
//     service) masqueraded as this session's site and pinned the Browser tab.
//     We now require the listener to belong to the session's own process tree
//     (see preview_owner_*.go).
//
//  2. False negative ("weird url"). Many projects ignore $PORT and bind their
//     own (Vite 5173, Astro 4321, a hand-rolled server on 8080, …), so the
//     pool port is never live and the tab never appears even though a real
//     site is up. A project can declare where it lives via a
//     `.conduit/preview.json` in the session's working directory.

// previewConfig is the optional `.conduit/preview.json` override a project
// drops in its working directory to tell Conduit where it's hosted:
//
//	{ "port": 5173 }                       // probe + reverse-proxy this port
//	{ "url": "https://my-tunnel.dev" }     // advertise this URL directly
//
// `url`, when set, wins: it's advertised verbatim (the app's WebView loads it
// directly, bypassing the broker's `/preview/<id>/` proxy), so it can point
// off-box. `port` overrides the pool $PORT for both the liveness probe and the
// reverse proxy, and — because it's an explicit declaration — skips the
// process-tree ownership check (the project told us this is its server).
type previewConfig struct {
	URL  string `json:"url"`
	Port int    `json:"port"`
}

// previewTarget is the resolved answer to "where does this session's preview
// live, if anywhere". port<=0 && url=="" means "no preview".
type previewTarget struct {
	url      string // absolute URL to advertise directly (proxy bypassed)
	port     int    // loopback port to probe + reverse-proxy
	declared bool   // came from .conduit/preview.json → trust on liveness alone
	detected bool   // auto-detected in the session's process tree → already live
}

// loadPreviewConfig reads (and mtime-caches) `.conduit/preview.json` from the
// session's working directory. A missing/unparseable file yields the zero
// config. The cache keys on path+modtime so the hot proxy path costs an
// os.Stat, not a full read+unmarshal, until the agent actually rewrites it.
func (s *Session) loadPreviewConfig() previewConfig {
	dir := s.WorkspaceDir()
	if dir == "" {
		return previewConfig{}
	}
	path := filepath.Join(dir, ".conduit", "preview.json")
	info, err := os.Stat(path)
	if err != nil {
		return previewConfig{} // no file (or unreadable) → no override
	}
	mod := info.ModTime()

	s.mu.Lock()
	if path == s.previewCfgPath && mod.Equal(s.previewCfgMod) {
		cfg := s.previewCfg
		s.mu.Unlock()
		return cfg
	}
	s.mu.Unlock()

	var cfg previewConfig
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, &cfg) // malformed → zero cfg, still cached below
		cfg.URL = strings.TrimSpace(cfg.URL)
	}

	s.mu.Lock()
	s.previewCfg, s.previewCfgMod, s.previewCfgPath = cfg, mod, path
	s.mu.Unlock()
	return cfg
}

// previewTarget resolves where this session's preview lives. Precedence:
// explicit `.conduit/preview.json` (url, then port), else auto-detection of
// whatever the session's own process tree is listening on.
func (s *Session) previewTarget() previewTarget {
	cfg := s.loadPreviewConfig()
	if cfg.URL != "" {
		return previewTarget{url: cfg.URL, declared: true}
	}
	if cfg.Port > 0 {
		return previewTarget{port: cfg.Port, declared: true}
	}
	// Auto-detect: surface whatever the session's OWN process tree is listening
	// on — no project cooperation, no "$PORT was honored" assumption. Scoping to
	// the tree is also the ownership guarantee: a stranger's loopback port is
	// never in our tree, so it can't pin a phantom Browser tab.
	if port := s.detectPreviewPort(); port > 0 {
		return previewTarget{port: port, detected: true}
	}
	return previewTarget{}
}

// detectPreviewPort returns the loopback port to surface for this session,
// chosen from the set its process tree is actually listening on, and caches it
// (previewDetectedPort) for the proxy hot path. 0 when the tree listens on
// nothing or the platform has no /proc-based detection.
func (s *Session) detectPreviewPort() int {
	port := 0
	if pid := s.agentPID(); pid > 0 {
		port = choosePreviewPort(listeningPortsForTree(pid), s.previewPort, s.previewPort+1000)
	}
	s.mu.Lock()
	s.previewDetectedPort = port
	s.mu.Unlock()
	return port
}

// choosePreviewPort applies the selection policy over a process tree's set of
// listening ports: prefer the pooled $PORT (the nudge target → a stable proxy
// URL), else the lowest port that isn't the $AGENT_CHAT_PORT MCP bridge. Split
// out as a pure function so the policy is unit-testable without /proc.
func choosePreviewPort(ports []int, preferred, chat int) int {
	best := 0
	for _, p := range ports {
		if preferred > 0 && p == preferred {
			return p // exact $PORT match — the stable target the agent was nudged to use
		}
		if p == chat {
			continue // the MCP view_event bridge, not a web server
		}
		if best == 0 || p < best {
			best = p
		}
	}
	return best
}

// previewPayload builds the status frame's `preview` object (WEBSOCKET-PROTOCOL
// §3.2), or nil when this session has no preview surface at all. The `url` is
// populated only when the preview is actually reachable — empty url is the
// signal the app reads as "no live site → withdraw the Browser tab".
//
// Probing liveness on every status frame keeps the tab tracking reality: it
// appears when the agent's server comes up and disappears when it stops, and
// (for the shared pool port) never latches onto a stranger's listener.
func (s *Session) previewPayload() map[string]any {
	tgt := s.previewTarget()

	// An explicitly declared absolute URL is advertised verbatim — we don't
	// own it, can't probe off-box hosts cheaply, and the app loads it directly.
	if tgt.url != "" {
		return map[string]any{"port": s.previewPort, "url": tgt.url}
	}

	// Report the resolved port, else the pooled allocation, so the wire shape
	// stays {port,url} even before a server is up. A detected port is live by
	// construction; a declared port still gets a liveness probe (the project
	// may have named a server that hasn't started yet).
	port := tgt.port
	if port <= 0 {
		port = s.previewPort
	}
	if port <= 0 {
		return nil // no allocation and nothing detected/declared
	}
	url := ""
	if tgt.detected || (tgt.declared && portListening(tgt.port)) {
		url = "/preview/" + s.ID + "/"
	}
	return map[string]any{"port": port, "url": url}
}

// EffectivePreviewPort is the loopback port the reverse proxy should target:
// the declared override, else the last auto-detected port, else the pooled
// $PORT. Returns 0 when the preview is an off-box absolute URL (the app loads
// that directly, so the proxy is never invoked for it). Reads the cached
// detected port rather than rescanning /proc, keeping the proxy path cheap.
func (s *Session) EffectivePreviewPort() int {
	cfg := s.loadPreviewConfig()
	if cfg.URL != "" {
		return 0
	}
	if cfg.Port > 0 {
		return cfg.Port
	}
	s.mu.Lock()
	detected := s.previewDetectedPort
	s.mu.Unlock()
	if detected > 0 {
		return detected
	}
	return s.previewPort
}

// agentPID returns the spawned agent's PID, or 0 if no process is running.
// Used to root the preview-port ownership walk at the session's own process.
func (s *Session) agentPID() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.cmd != nil && s.cmd.Process != nil {
		return s.cmd.Process.Pid
	}
	return 0
}

// PreviewDebugInfo is a snapshot of one session's preview resolution, surfaced
// by the broker's GET /debug/previews so phantom/missing-tab cases are
// self-diagnosing without a device: it shows the pooled $PORT we handed the
// agent, every port the session's process tree is actually listening on, what
// auto-detection chose, any `.conduit/preview.json` override, and the resulting
// proxy target.
type PreviewDebugInfo struct {
	SessionID      string `json:"session_id"`
	Assistant      string `json:"assistant"`
	Running        bool   `json:"running"`
	AgentPID       int    `json:"agent_pid"`
	PooledPort     int    `json:"pooled_port"`             // the $PORT we exported to the agent
	ListeningPorts []int  `json:"listening_ports"`         // all LISTEN ports in the session tree
	DetectedPort   int    `json:"detected_port,omitempty"` // auto-detect's pick
	DeclaredURL    string `json:"declared_url,omitempty"`  // from .conduit/preview.json
	DeclaredPort   int    `json:"declared_port,omitempty"` // from .conduit/preview.json
	EffectivePort  int    `json:"effective_port"`          // the port the proxy targets
	WorkspaceDir   string `json:"workspace_dir,omitempty"`
}

// PreviewDebug snapshots every live session's preview resolution. Mirrors the
// LiveSessions() pattern: copy the session set under the lock, then gather
// per-session (each gather does its own /proc scan and locking).
func (m *Manager) PreviewDebug() []PreviewDebugInfo {
	m.mu.RLock()
	live := make([]*Session, 0, len(m.sessions))
	for _, s := range m.sessions {
		live = append(live, s)
	}
	m.mu.RUnlock()

	out := make([]PreviewDebugInfo, 0, len(live))
	for _, s := range live {
		out = append(out, s.previewDebug())
	}
	return out
}

func (s *Session) previewDebug() PreviewDebugInfo {
	cfg := s.loadPreviewConfig()
	pid := s.agentPID()
	var listening []int
	if pid > 0 {
		listening = listeningPortsForTree(pid)
	}
	s.mu.Lock()
	detected := s.previewDetectedPort
	s.mu.Unlock()
	return PreviewDebugInfo{
		SessionID:      s.ID,
		Assistant:      s.Assistant,
		Running:        s.processAlive(),
		AgentPID:       pid,
		PooledPort:     s.previewPort,
		ListeningPorts: listening,
		DetectedPort:   detected,
		DeclaredURL:    cfg.URL,
		DeclaredPort:   cfg.Port,
		EffectivePort:  s.EffectivePreviewPort(),
		WorkspaceDir:   s.WorkspaceDir(),
	}
}

// portListening reports whether anything is accepting connections on the
// loopback port. A short timeout keeps the per-status-frame build cheap; the
// dial is to loopback so it resolves fast.
func portListening(port int) bool {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort("127.0.0.1", strconv.Itoa(port)), 150*time.Millisecond)
	if err != nil {
		return false
	}
	_ = conn.Close()
	return true
}
