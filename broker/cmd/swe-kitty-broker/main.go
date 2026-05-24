// Command swe-kitty-broker is the harness server entry point.
//
// Usage:
//
//	swe-kitty-broker up [--local] [--public-url URL] [--addr :1977]
//
// On `up`, the harness mints a bearer token, starts the HTTP+WebSocket
// server, and prints a connection URL to stdout. Sessions are managed
// in-process; agent containers and worktree integration land in tasks
// 005 / 006.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"

	"github.com/nikhilsh/swe-kitty/broker/internal/agents"
	"github.com/nikhilsh/swe-kitty/broker/internal/auth"
	"github.com/nikhilsh/swe-kitty/broker/internal/credentials"
	"github.com/nikhilsh/swe-kitty/broker/internal/discovery"
	"github.com/nikhilsh/swe-kitty/broker/internal/oauth"
	"github.com/nikhilsh/swe-kitty/broker/internal/push"
	"github.com/nikhilsh/swe-kitty/broker/internal/replay"
	"github.com/nikhilsh/swe-kitty/broker/internal/session"
	"github.com/nikhilsh/swe-kitty/broker/internal/ws"
)

func main() {
	if len(os.Args) < 2 {
		usage()
		os.Exit(2)
	}
	cmd := os.Args[1]
	switch cmd {
	case "up":
		os.Exit(runUp(os.Args[2:]))
	case "memory":
		os.Exit(runMemory(os.Args[2:]))
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `swe-kitty-broker — the swe-kitty server

Commands:
  up        start the HTTP+WebSocket harness
  memory    (task 005) per-session memory CLI

Run "swe-kitty-broker up --help" for options.`)
}

func runUp(args []string) int {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	addr := fs.String("addr", ":1977", "HTTP listen address")
	local := fs.Bool("local", false, "advertise on LAN via mDNS")
	publicURL := fs.String("public-url", "", "public-facing URL (for QR/UX hints)")
	agentsDir := fs.String("agents-dir", "", "directory of agent adapter TOMLs (defaults: $XDG_CONFIG_HOME/swe-kitty/agents → ~/.swe-kitty/agents → ./agents → embedded)")
	replayBase := fs.String("replay-base", defaultReplayBase(), "directory for per-session replay recordings; empty disables recording")
	credentialsDir := fs.String("credentials-dir", defaultCredentialsDir(), "directory for per-identity OAuth credential blobs (docs/PLAN-AGENT-OAUTH.md); empty disables per-user OAuth materialization")
	_ = fs.Parse(args)

	store := auth.NewStore()
	// SWE_KITTY_TOKEN lets the mobile-app SSH bootstrap (and any other
	// upstream orchestrator) pre-pick the bearer so the pairing flow
	// doesn't have to scrape `docker logs` after `docker run`. If the
	// env var is missing or too short, mint a fresh one as before.
	token := os.Getenv("SWE_KITTY_TOKEN")
	if !store.Adopt(token) {
		token = store.Mint()
	}
	registry, regSource, err := loadAgentRegistry(*agentsDir)
	if err != nil {
		log.Printf("load adapters: %v", err)
		return 1
	}
	log.Printf("adapters: source=%s names=%v", regSource, registry.Names())
	mgr := session.NewManager(registry)
	// Enable replay recording before Recover() — recovered sessions
	// thus pick up the recorder on their drain loop too, so a
	// post-restart session continues writing to the same replay.json.
	if base := strings.TrimSpace(*replayBase); base != "" {
		if abs, err := expandHome(base); err == nil {
			mgr.SetReplayBaseDir(abs)
			log.Printf("replay: recording sessions to %s", abs)
		} else {
			log.Printf("replay: ignoring --replay-base %q: %v", base, err)
		}
	}
	if recovered, err := mgr.Recover(); err == nil && len(recovered) > 0 {
		log.Printf("recovered sessions: %v", recovered)
	}
	srv := ws.New(store, mgr)
	// Wire the per-identity OAuth credential store (Stage 1 of
	// docs/PLAN-AGENT-OAUTH.md). Empty --credentials-dir disables the
	// per-user OAuth materialization path; agents then fall back to
	// the legacy host-mirror $HOME exactly as before this PR.
	if credDir := strings.TrimSpace(*credentialsDir); credDir != "" {
		if abs, err := expandHome(credDir); err == nil {
			credStore := credentials.NewStore(abs, []byte(token))
			srv.WithCredentials(credStore)
			log.Printf("credentials: per-user OAuth store at %s", abs)
		} else {
			log.Printf("credentials: ignoring --credentials-dir %q: %v", credDir, err)
		}
	}
	// Wire the v2 server-side login manager (PLAN-AGENT-OAUTH.md
	// "Approach v2"). Always-on for now — the WS handlers nil-check
	// the field, but spawning a login subprocess is the broker's only
	// path to recover from a missing on-disk credential, so we never
	// want to ship without it. The manager itself is cheap: an empty
	// map; CLI subprocess spawn happens lazily on start_agent_login.
	oauthMgr := oauth.NewManager()
	srv.WithOAuth(oauthMgr)
	log.Printf("oauth: server-side login manager wired (providers: openai, anthropic)")
	// Package 5: device-token registry for push notifications. The
	// register_push_token WS handler fills it; the APNs/FCM senders +
	// event triggers land in follow-ups.
	srv.WithPush(push.NewRegistry())
	// Replay HTTP surface lives on the same mux as the WS server.
	// Secret = bearer token: anyone who can already attach to the WS
	// can mint a replay URL, but external observers cannot enumerate.
	replaySrv := replay.NewServer(mgr.ReplayBaseDir(), []byte(token))

	hostURL := resolveHostURL(*addr, *local, *publicURL)

	// Pairing URL consumed by the mobile QR scanner (apps/{ios,android}).
	// Format: swekitty://<host>[:port]?token=<bearer>
	pairing := pairingURL(replaceScheme(hostURL), token)

	fmt.Printf("swe-kitty-broker up\n  addr:    %s\n  url:     %s\n  token:   %s\n  pairing: %s\n",
		*addr, hostURL, token, pairing)
	if mgr.ReplayBaseDir() != "" {
		// Print a templated replay URL so the operator can plug in
		// any active session id without recomputing the HMAC.
		sampleToken := replaySrv.Token("SESSION_ID")
		fmt.Printf("  replay:  %s/replay/<session-id>?t=<hmac>  (sample hmac for SESSION_ID: %s)\n", hostURL, sampleToken)
	}
	fmt.Println()
	qrterminal.GenerateHalfBlock(pairing, qrterminal.L, os.Stdout)
	fmt.Printf("\nScan the QR above with the SweKitty app, or:\n  wscat -c \"%s/ws/$(uuidgen)?assistant=claude&token=%s\"\n",
		replaceScheme(hostURL), token)

	var mdnsShutdown func()
	if *local {
		port, err := parsePort(*addr)
		if err != nil {
			log.Printf("--local: cannot parse port from %q: %v (skipping mDNS)", *addr, err)
		} else {
			shutdown, err := discovery.Advertise(port, token)
			if err != nil {
				log.Printf("--local: mDNS advertise failed: %v", err)
			} else {
				log.Printf("--local: advertising %s on %s.local:%d", discovery.ServiceType, hostname(), port)
				mdnsShutdown = shutdown
			}
		}
	}

	// Combine the WS server's mux with the replay surface. The replay
	// handler owns the `/replay/` prefix; everything else falls
	// through to the existing WS handler. Done this way (rather than
	// passing the mux into ws.New) so the existing public surface
	// stays untouched.
	rootMux := http.NewServeMux()
	rootMux.Handle("/replay/", replaySrv.Handler())
	wsHandler := srv.Handler()
	rootMux.Handle("/", wsHandler)

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           rootMux,
		ReadHeaderTimeout: 10 * time.Second,
	}

	errCh := make(chan error, 1)
	go func() {
		err := httpSrv.ListenAndServe()
		if err != nil && err != http.ErrServerClosed {
			errCh <- err
		}
	}()

	stop := make(chan os.Signal, 1)
	signal.Notify(stop, os.Interrupt, syscall.SIGTERM)

	select {
	case <-stop:
		log.Println("shutdown: signal received")
	case err := <-errCh:
		log.Printf("shutdown: server error: %v", err)
	}
	if mdnsShutdown != nil {
		mdnsShutdown()
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(ctx)
	mgr.Close()
	// Kill any orphan login subprocesses (PLAN-AGENT-OAUTH.md v2 risk
	// register — never leave a CLI listening on a loopback port after
	// broker shutdown). No-op when no logins were ever started.
	oauthMgr.Close()
	return 0
}

func resolveHostURL(addr string, local bool, publicURL string) string {
	if strings.TrimSpace(publicURL) != "" {
		return publicURL
	}
	if local {
		if ip := firstLANIPv4(); ip != "" {
			return "http://" + ip + addr
		}
		if host := hostname(); host != "" {
			return "http://" + host + ".local" + addr
		}
	}
	return "http://localhost" + addr
}

func firstLANIPv4() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			var ip net.IP
			switch v := a.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil {
				continue
			}
			ip = ip.To4()
			if ip == nil || ip.IsLoopback() {
				continue
			}
			return ip.String()
		}
	}
	return ""
}

// pairingURL builds the swekitty:// deep link encoded into the QR.
// `wsURL` is expected to be of the form ws[s]://host[:port].
func pairingURL(wsURL, token string) string {
	host := wsURL
	host = strings.TrimPrefix(host, "ws://")
	host = strings.TrimPrefix(host, "wss://")
	return "swekitty://" + host + "?token=" + token
}

func parsePort(addr string) (int, error) {
	// addr is a Go listen string like ":1977" or "0.0.0.0:1977".
	idx := strings.LastIndex(addr, ":")
	if idx < 0 || idx == len(addr)-1 {
		return 0, fmt.Errorf("no port in %q", addr)
	}
	return strconv.Atoi(addr[idx+1:])
}

func hostname() string {
	h, err := os.Hostname()
	if err != nil || h == "" {
		return "swe-kitty"
	}
	return h
}

// loadAgentRegistry walks a small priority list so a freshly-installed
// binary works out of the box but is still trivially extensible. The
// first source that succeeds wins.
func loadAgentRegistry(explicit string) (*agents.Registry, string, error) {
	type candidate struct {
		label string
		load  func() (*agents.Registry, error)
	}
	var cands []candidate
	if explicit != "" {
		cands = append(cands, candidate{
			label: "--agents-dir " + explicit,
			load:  func() (*agents.Registry, error) { return agents.LoadDir(explicit) },
		})
	} else {
		if dir := userAgentsDir(); dir != "" {
			cands = append(cands, candidate{
				label: dir,
				load:  func() (*agents.Registry, error) { return agents.LoadDir(dir) },
			})
		}
		cands = append(cands, candidate{
			label: "./agents",
			load:  func() (*agents.Registry, error) { return agents.LoadDir("agents") },
		})
		cands = append(cands, candidate{
			label: "embedded",
			load: func() (*agents.Registry, error) {
				return agents.LoadFS(embeddedAgents, "embedded-agents", "embedded")
			},
		})
	}
	var firstErr error
	for _, c := range cands {
		reg, err := c.load()
		if err == nil {
			return reg, c.label, nil
		}
		if firstErr == nil {
			firstErr = err
		}
	}
	return nil, "", firstErr
}

// userAgentsDir returns the user-scoped override directory if it
// exists, else empty. Honours XDG_CONFIG_HOME but falls back to the
// `~/.swe-kitty/agents` location documented in SELF-HOST.md.
func userAgentsDir() string {
	for _, dir := range []string{
		envDir("XDG_CONFIG_HOME", "swe-kitty", "agents"),
		homeDir(".swe-kitty", "agents"),
	} {
		if dir == "" {
			continue
		}
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			return dir
		}
	}
	return ""
}

func envDir(envKey string, parts ...string) string {
	root := os.Getenv(envKey)
	if root == "" {
		return ""
	}
	return joinPath(append([]string{root}, parts...)...)
}

func homeDir(parts ...string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return joinPath(append([]string{home}, parts...)...)
}

func joinPath(parts ...string) string {
	out := ""
	for _, p := range parts {
		if out == "" {
			out = p
		} else {
			out += string(os.PathSeparator) + p
		}
	}
	return out
}

// defaultReplayBase returns the documented default replay directory
// (`~/.swe-kitty/sessions/`). Returns an empty string when the home
// directory can't be resolved — recording then defaults to disabled
// rather than dumping into the cwd.
func defaultReplayBase() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return home + string(os.PathSeparator) + ".swe-kitty" + string(os.PathSeparator) + "sessions"
}

// defaultCredentialsDir returns the documented default per-identity
// OAuth credential store root (`~/.swe-kitty/credentials/`, see
// docs/PLAN-AGENT-OAUTH.md §D.2). Returns an empty string when the
// home directory can't be resolved so the broker boots without the
// per-user OAuth path rather than dumping `.enc` files into the cwd.
func defaultCredentialsDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return home + string(os.PathSeparator) + ".swe-kitty" + string(os.PathSeparator) + "credentials"
}

// expandHome resolves a leading `~` in a path against the user's home
// directory. Returns the input unchanged when it doesn't start with
// `~/` so absolute paths pass through.
func expandHome(p string) (string, error) {
	if p == "~" || strings.HasPrefix(p, "~/") {
		home, err := os.UserHomeDir()
		if err != nil {
			return "", err
		}
		if p == "~" {
			return home, nil
		}
		return home + p[1:], nil
	}
	return p, nil
}

// replaceScheme returns hostURL with http(s) swapped for ws(s) for the
// hint printed to stdout.
func replaceScheme(s string) string {
	if len(s) >= 8 && s[:8] == "https://" {
		return "wss://" + s[8:]
	}
	if len(s) >= 7 && s[:7] == "http://" {
		return "ws://" + s[7:]
	}
	return s
}
