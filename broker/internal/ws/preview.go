package ws

import (
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// servePreview reverse-proxies `/preview/<session-id>/<rest...>` to the
// session's dev server on 127.0.0.1:<previewPort> — the port the broker
// exports to the agent as $PORT. This is the surface the in-app Browser tab
// loads (WEBSOCKET-PROTOCOL.md §3.2 `preview`, sweswe-parity).
//
// Left unauthenticated by design: the session id is an unguessable UUID
// (a capability URL), the proxy target is loopback-only, and the in-app
// WebView loads it with a plain document GET that cannot carry the bearer
// header the WS/API surfaces require. WebSocket upgrades are bridged raw so
// dev-server hot-module-reload keeps working.
func (s *Server) servePreview(w http.ResponseWriter, r *http.Request) {
	rest := strings.TrimPrefix(r.URL.Path, "/preview/")
	id, tail, _ := strings.Cut(rest, "/")
	if id == "" {
		http.NotFound(w, r)
		return
	}
	sess, ok := s.Sessions.Get(id)
	if !ok {
		http.Error(w, "unknown session", http.StatusNotFound)
		return
	}
	port := sess.PreviewPort()
	if port <= 0 {
		http.Error(w, "no preview port for session", http.StatusServiceUnavailable)
		return
	}
	backendHost := "127.0.0.1:" + strconv.Itoa(port)
	backendPath := "/" + tail

	if isWebSocketUpgrade(r) {
		proxyPreviewWebSocket(w, r, backendHost, backendPath)
		return
	}

	proxy := httputil.NewSingleHostReverseProxy(&url.URL{Scheme: "http", Host: backendHost})
	director := proxy.Director
	proxy.Director = func(req *http.Request) {
		director(req)
		// Strip the `/preview/<id>` prefix so the dev server sees a path
		// rooted at its own document root.
		req.URL.Path = backendPath
		req.Host = backendHost
	}
	proxy.ErrorHandler = func(rw http.ResponseWriter, _ *http.Request, err error) {
		http.Error(rw, "preview backend unavailable: "+err.Error(), http.StatusBadGateway)
	}
	proxy.ServeHTTP(w, r)
}

// isWebSocketUpgrade reports whether r is a WebSocket handshake request.
func isWebSocketUpgrade(r *http.Request) bool {
	return strings.EqualFold(r.Header.Get("Upgrade"), "websocket") &&
		strings.Contains(strings.ToLower(r.Header.Get("Connection")), "upgrade")
}

// proxyPreviewWebSocket bridges a hijacked client WebSocket to the dev server:
// it replays the upgrade request to the backend (with the prefix stripped) and
// pipes bytes both ways until either side closes. Used for dev-server HMR.
func proxyPreviewWebSocket(w http.ResponseWriter, r *http.Request, backendHost, backendPath string) {
	backendConn, err := net.DialTimeout("tcp", backendHost, 10*time.Second)
	if err != nil {
		http.Error(w, "preview ws backend unavailable: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer backendConn.Close()

	outReq := r.Clone(r.Context())
	outReq.URL.Path = backendPath
	outReq.Host = backendHost
	// RequestURI must be empty for the client-side Request.Write.
	outReq.RequestURI = ""
	if err := outReq.Write(backendConn); err != nil {
		http.Error(w, "preview ws handshake write failed", http.StatusBadGateway)
		return
	}

	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "preview ws: hijacking unsupported", http.StatusInternalServerError)
		return
	}
	clientConn, clientBuf, err := hj.Hijack()
	if err != nil {
		return
	}
	defer clientConn.Close()

	errc := make(chan error, 2)
	go func() { _, e := io.Copy(backendConn, clientBuf); errc <- e }()
	go func() { _, e := io.Copy(clientConn, backendConn); errc <- e }()
	<-errc
}
