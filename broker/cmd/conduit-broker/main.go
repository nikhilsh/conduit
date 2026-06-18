// Command conduit-broker is the harness server entry point.
//
// Usage:
//
//	conduit-broker up [--local] [--public-url URL] [--addr :1977]
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
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"github.com/mdp/qrterminal/v3"
	"golang.org/x/term"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/auth"
	"github.com/nikhilsh/conduit/broker/internal/credentials"
	"github.com/nikhilsh/conduit/broker/internal/discovery"
	"github.com/nikhilsh/conduit/broker/internal/kb"
	"github.com/nikhilsh/conduit/broker/internal/oauth"
	"github.com/nikhilsh/conduit/broker/internal/push"
	"github.com/nikhilsh/conduit/broker/internal/replay"
	"github.com/nikhilsh/conduit/broker/internal/session"
	"github.com/nikhilsh/conduit/broker/internal/ws"
)

// version is stamped at link time by the release workflow:
//
//	go build -ldflags "-X main.version=v0.1.2" ./cmd/conduit-broker
//
// Defaults to "dev" for local builds where no stamp is provided.
var version string

func main() {
	// Inject version into the ws package so /api/capabilities readiness
	// block reports the correct broker_version. Done before any command
	// dispatch so the value is present from the first request.
	ws.SetBrokerVersion(version)

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
	case "kb":
		os.Exit(runKB(os.Args[2:]))
	case "chat":
		os.Exit(runChat(os.Args[2:]))
	case "-h", "--help", "help":
		usage()
	default:
		fmt.Fprintf(os.Stderr, "unknown command: %s\n\n", cmd)
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, `conduit-broker — the conduit server

Commands:
  up        start the HTTP+WebSocket harness
  memory    (task 005) per-session memory CLI
  kb        knowledge-base CLI (list/get/search/add)
  chat      attach to a running session's chat channel

Run "conduit-broker up --help" for options.`)
}

func runUp(args []string) int {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	// Default to loopback. A bare ":1977" binds 0.0.0.0 (every
	// interface), exposing the broker to the whole network with only the
	// bearer token as a gate. The mobile SSH-bootstrap path always passes
	// an explicit "127.0.0.1:<port>" (scripts/remote-bootstrap.sh), and a
	// direct-connect box that *wants* a public bind passes an explicit
	// "--addr :1977" — both override this default verbatim, so the secure
	// default never breaks an intentional public bind.
	addr := fs.String("addr", "127.0.0.1:1977", "HTTP listen address")
	local := fs.Bool("local", false, "advertise on LAN via mDNS")
	publicURL := fs.String("public-url", "", "public-facing URL (for QR/UX hints)")
	agentsDir := fs.String("agents-dir", "", "directory of agent adapter TOMLs (defaults: $XDG_CONFIG_HOME/conduit/agents → ~/.conduit/agents → ./agents → embedded)")
	replayBase := fs.String("replay-base", defaultReplayBase(), "directory for per-session replay recordings; empty disables recording")
	credentialsDir := fs.String("credentials-dir", defaultCredentialsDir(), "directory for per-identity OAuth credential blobs (docs/PLAN-AGENT-OAUTH.md); empty disables per-user OAuth materialization")
	// Phase 3a debug flag, OFF by default. When set (or CONDUIT_KB_EXPERIMENTAL=1),
	// enables user-box KB behavior: registered-source ingest (pointers only),
	// box-local .conduit/knowledge/ as the default kb-add target, kb promote, and
	// injection/search spanning all three origins. OFF == byte-identical Phase 1/2
	// behavior (KB only via a tracked knowledge/INDEX.md). The flag and the env var
	// unify on a single source of truth: setting the flag sets the env, which the
	// kb + session layers read via kb.ExperimentalEnabled().
	kbExperimental := fs.Bool("kb-experimental", false, "enable experimental user-box knowledge base (ingest pointers + box-local .conduit/knowledge + promote); also CONDUIT_KB_EXPERIMENTAL=1")
	_ = fs.Parse(args)

	// Unify flag + env: an explicit --kb-experimental sets the env so every
	// reader (kb package, session package) keys off the single
	// kb.ExperimentalEnabled() truth. The env alone also works (systemd unit).
	if *kbExperimental {
		_ = os.Setenv(kb.ExperimentalEnv, "1")
	}
	if kb.ExperimentalEnabled() {
		log.Printf("kb: EXPERIMENTAL user-box mode ON (ingest pointers + box-local .conduit/knowledge + promote)")
	}

	// `--local` (no explicit --addr) means "expose me on the LAN so a
	// phone on the same network can reach me". The secure loopback default
	// would otherwise advertise a LAN URL the box can't actually serve, so
	// bind all interfaces in that case. An explicit --addr always wins.
	addrSet := false
	fs.Visit(func(f *flag.Flag) {
		if f.Name == "addr" {
			addrSet = true
		}
	})
	if *local && !addrSet {
		if port, err := parsePort(*addr); err == nil {
			*addr = fmt.Sprintf("0.0.0.0:%d", port)
		}
	}

	// Security: a non-loopback listen address means the broker is
	// reachable from the network, where the bearer token is the ONLY
	// access control. Warn loudly so an operator who didn't intend a
	// public bind notices. Explicit public binds (direct-connect boxes)
	// are legitimate and keep working — this only logs, never refuses.
	if isPublicBind(*addr) {
		log.Printf("WARNING: binding PUBLIC interface %q — the bearer token is the ONLY access control; ensure a firewall or SSH tunnel fronts this broker", *addr)
	}

	store := auth.NewStore()
	// CONDUIT_TOKEN lets the mobile-app SSH bootstrap (and any other
	// upstream orchestrator) pre-pick the bearer so the pairing flow
	// doesn't have to scrape `docker logs` after `docker run`. If the
	// env var is missing or too short, mint a fresh one as before.
	token := os.Getenv("CONDUIT_TOKEN")
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
	// Discover each agent's live model+effort catalog in the background
	// (served via /api/capabilities "models"; also widens effort
	// validation to whatever the agents actually advertise).
	mgr.EnableModelDiscovery()
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
		// Lazy recovery: these are enumerated but NOT spawned here; each
		// agent starts on demand when a client first opens the session.
		log.Printf("recoverable sessions (lazy, spawn on open): %d", len(recovered))
	}
	// Reap Terminal-tab tmux sessions left behind by sessions that were
	// archived/pruned or lost to a crash in a previous broker lifetime
	// (plus any pre-rebrand `kitty-` named ones). Detached + orphaned only;
	// attached and still-recoverable sessions are preserved. Runs after
	// Recover so the on-disk session set it checks against is settled.
	mgr.ReapOrphanTmuxSessions()
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
	// Package 5: push notification registry + senders + dispatcher.
	// The registry is persisted under ~/.conduit/push-tokens.json so
	// tokens survive broker restarts.
	conduitRoot := conduitRootDir()
	pushReg := push.NewRegistryWithPersistence(homeDir(".conduit", "push-tokens.json"))
	srv.WithPush(pushReg)

	pushSenders := map[push.Platform]push.Sender{}
	relayURL := strings.TrimSpace(os.Getenv("CONDUIT_PUSH_RELAY_URL"))
	if relayURL != "" {
		installCredFile := filepath.Join(conduitRoot, "push-install.json")
		relaySender, err := push.NewRelaySender(relayURL, installCredFile)
		if err != nil {
			log.Printf("push relay: init failed: %v (relay disabled)", err)
		} else if relaySender != nil {
			pushSenders[push.PlatformAPNs] = relaySender
			pushSenders[push.PlatformFCM] = relaySender
			log.Printf("push relay: configured relay=%s", relayURL)
			// Wire Live Activity: use the same relay sender for LA content-state
			// pushes. LA tokens are session-scoped (LARegistry) and distinct from
			// the global alert registry.
			laReg := push.NewLARegistry()
			srv.WithLARegistry(laReg).WithLASender(relaySender)
		}
	}
	pushSenders[push.PlatformUnifiedPush] = push.NewUnifiedPushSender()
	dispatcher := push.NewDispatcher(pushReg, pushSenders)
	srv.WithDispatcher(dispatcher)
	srv.WithPushRelayConfigured(relayURL != "")
	// CONDUIT_NTFY_URL: base URL of a self-hosted ntfy instance
	// co-located with this broker, populated by
	// scripts/remote-bootstrap.sh --with-ntfy. Surfaced in
	// /api/capabilities features.ntfy_url so the Android app can
	// auto-configure UnifiedPush without a third-party distributor.
	ntfyURL := strings.TrimSpace(os.Getenv("CONDUIT_NTFY_URL"))
	if ntfyURL != "" {
		srv.WithNtfyURL(ntfyURL)
		log.Printf("push: ntfy distributor configured url=%s", ntfyURL)
	}
	log.Printf("push: registry loaded; relay=%v; unifiedpush=always; ntfy=%v", relayURL != "", ntfyURL != "")
	// Replay HTTP surface lives on the same mux as the WS server.
	// Secret = bearer token: anyone who can already attach to the WS
	// can mint a replay URL, but external observers cannot enumerate.
	replaySrv := replay.NewServer(mgr.ReplayBaseDir(), []byte(token))

	hostURL := resolveHostURL(*addr, *local, *publicURL)

	// Pairing URL consumed by the mobile QR scanner (apps/{ios,android}).
	// Format: conduit://<host>[:port]?token=<bearer>
	pairing := pairingURL(replaceScheme(hostURL), token)

	// Only print the FULL bearer token / pairing URL / QR when stdout is
	// an interactive terminal (the `up --local` operator flow). Under
	// systemd, stdout is routed into the journal, so printing the token
	// there permanently leaks the only access-control secret to anyone
	// who can read the journal. In that case emit a redacted fingerprint
	// only — enough to confirm WHICH token is live without revealing it.
	interactive := term.IsTerminal(int(os.Stdout.Fd()))
	if interactive {
		fmt.Printf("conduit-broker up\n  addr:    %s\n  url:     %s\n  token:   %s\n  pairing: %s\n",
			*addr, hostURL, token, pairing)
	} else {
		fmt.Printf("conduit-broker up\n  addr:    %s\n  url:     %s\n  token:   %s (redacted; stdout is not a TTY)\n",
			*addr, hostURL, redactToken(token))
	}
	if mgr.ReplayBaseDir() != "" && interactive {
		// Print a templated replay URL so the operator can plug in
		// any active session id without recomputing the HMAC. The sample
		// HMAC is token-derived, so only print it on an interactive TTY.
		sampleToken := replaySrv.Token("SESSION_ID")
		fmt.Printf("  replay:  %s/replay/<session-id>?t=<hmac>  (sample hmac for SESSION_ID: %s)\n", hostURL, sampleToken)
	}
	if interactive {
		fmt.Println()
		qrterminal.GenerateHalfBlock(pairing, qrterminal.L, os.Stdout)
		fmt.Printf("\nScan the QR above with the Conduit app, or:\n  wscat -c \"%s/ws/$(uuidgen)?assistant=claude&token=%s\"\n",
			replaceScheme(hostURL), token)
	}
	if interactive && strings.TrimSpace(*publicURL) == "" {
		// Without --public-url the pairing URL/QR can only encode localhost
		// or a LAN IP (resolveHostURL never emits a public address). A phone
		// on cellular scanning that QR saves a server it can never reach —
		// the #1 onboarding dead end for a remote/VPS broker. Make the
		// remedy loud so the operator doesn't ship an unreachable QR.
		fmt.Fprintf(os.Stderr,
			"\n⚠️  No --public-url set: the pairing URL/QR points at %q, reachable only on this machine/LAN.\n"+
				"    If this broker is remote (e.g. a VPS), restart with:  --public-url wss://<public-host>:<port>\n"+
				"    or pair the app manually with  ws://<public-ip>%s  + the token above.\n",
			hostURL, *addr)
	}

	var mdnsShutdown func()
	if *local {
		port, err := parsePort(*addr)
		lanIP := firstLANIPv4()
		switch {
		case err != nil:
			log.Printf("--local: cannot parse port from %q: %v (skipping mDNS)", *addr, err)
		case !isPrivateIPv4(lanIP):
			// The mDNS TXT record carries the bearer token so a phone on
			// the same LAN can auto-pair with zero typing. That is only
			// safe on a genuine private network: TXT records are cleartext
			// to the whole segment. If the box has no RFC1918/link-local
			// address (e.g. a public VPS whose only non-loopback IP is
			// public), broadcasting the token would hand it to hostile
			// same-segment neighbors (datacenter co-tenants). Refuse —
			// pair via QR / manual token entry instead.
			log.Printf("--local: no private LAN address (found %q) — NOT advertising the bearer token over mDNS; pair via the QR code / manual token entry. Running --local on a public/internet-facing box is unsupported.", lanIP)
		default:
			shutdown, err := discovery.Advertise(port, token)
			if err != nil {
				log.Printf("--local: mDNS advertise failed: %v", err)
			} else {
				log.Printf("--local: advertising %s on %s.local:%d (private LAN %s)", discovery.ServiceType, hostname(), port, lanIP)
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
		Addr:    *addr,
		Handler: rootMux,
		// Slowloris guards. ReadHeaderTimeout + ReadTimeout bound how
		// long a client may dribble the request line/headers/body, so a
		// stalled sender can't pin a connection open indefinitely.
		ReadHeaderTimeout: 10 * time.Second,
		ReadTimeout:       30 * time.Second,
		// WriteTimeout is deliberately left UNSET. This server's primary
		// surface is long-lived WebSockets (and streaming replay): a
		// WriteTimeout is an absolute deadline on the whole response, so
		// it would hard-close every WS the moment it elapsed regardless
		// of activity. WS liveness is instead enforced by the per-message
		// pong read-deadline (pongWait, see internal/ws/server.go) plus
		// the server heartbeat ping — a dead peer is reaped there without
		// killing healthy long-lived connections.
		IdleTimeout: 120 * time.Second,
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

	exitCode := 0
	select {
	case <-stop:
		log.Println("shutdown: signal received")
	case err := <-errCh:
		// A fatal server error (e.g. the port is already held by a
		// manually-launched broker) must exit NON-zero. Returning 0
		// here once made systemd's Restart=always spin a silent
		// ~3s crash-loop for a day (64k restarts) — an invisible
		// failure instead of a red `systemctl status`.
		log.Printf("shutdown: server error: %v", err)
		exitCode = 1
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
	return exitCode
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

// pairingURL builds the conduit:// deep link encoded into the QR.
// `wsURL` is expected to be of the form ws[s]://host[:port].
func pairingURL(wsURL, token string) string {
	host := wsURL
	host = strings.TrimPrefix(host, "ws://")
	host = strings.TrimPrefix(host, "wss://")
	return "conduit://" + host + "?token=" + token
}

// isPublicBind reports whether the listen address `addr` exposes the
// broker beyond loopback. A bare ":port" or "0.0.0.0:port" / "[::]:port"
// binds every interface; an explicit loopback host (127.0.0.1, ::1,
// localhost) does not. Anything else (a concrete LAN/public IP or
// hostname) is treated as public. Used only to decide whether to warn.
func isPublicBind(addr string) bool {
	host, _, err := net.SplitHostPort(addr)
	if err != nil {
		// Unparseable — be conservative and warn.
		return true
	}
	switch host {
	case "":
		// Bare ":port" binds all interfaces.
		return true
	case "localhost":
		return false
	}
	ip := net.ParseIP(host)
	if ip == nil {
		// A non-IP host (e.g. a public hostname) — treat as public.
		return true
	}
	if ip.IsUnspecified() {
		// 0.0.0.0 / :: bind all interfaces.
		return true
	}
	return !ip.IsLoopback()
}

// isPrivateIPv4 reports whether `s` parses to a private/trusted LAN IPv4
// address (RFC1918 10/8, 172.16/12, 192.168/16, or 169.254 link-local).
// Used to decide whether broadcasting the bearer token over mDNS is safe:
// only on a genuine private network, never on a public/datacenter wire.
func isPrivateIPv4(s string) bool {
	ip := net.ParseIP(s)
	if ip == nil {
		return false
	}
	return ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

// redactToken returns a non-reversible fingerprint of a bearer token
// safe to print to a non-TTY stdout (the systemd journal). Shows the
// first 6 chars plus the length so the operator can correlate WHICH
// token is live (e.g. against a CONDUIT_TOKEN they set) without exposing
// the secret. Short/empty tokens collapse to "<redacted>".
func redactToken(token string) string {
	if len(token) < 8 {
		return "<redacted>"
	}
	return token[:6] + "…(len=" + strconv.Itoa(len(token)) + ")"
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
		return "conduit"
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
// `~/.conduit/agents` location documented in SELF-HOST.md.
func userAgentsDir() string {
	for _, dir := range []string{
		envDir("XDG_CONFIG_HOME", "conduit", "agents"),
		homeDir(".conduit", "agents"),
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

// conduitRootDir returns the ~/.conduit directory (creating it with mode
// 0700 if needed). Falls back to os.TempDir() if the home directory
// cannot be resolved — that case only happens in tests/containers without
// a real home.
func conduitRootDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return os.TempDir()
	}
	dir := filepath.Join(home, ".conduit")
	_ = os.MkdirAll(dir, 0o700)
	return dir
}

// defaultReplayBase returns the documented default replay directory
// (`~/.conduit/sessions/`). Returns an empty string when the home
// directory can't be resolved — recording then defaults to disabled
// rather than dumping into the cwd.
func defaultReplayBase() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return home + string(os.PathSeparator) + ".conduit" + string(os.PathSeparator) + "sessions"
}

// defaultCredentialsDir returns the documented default per-identity
// OAuth credential store root (`~/.conduit/credentials/`, see
// docs/PLAN-AGENT-OAUTH.md §D.2). Returns an empty string when the
// home directory can't be resolved so the broker boots without the
// per-user OAuth path rather than dumping `.enc` files into the cwd.
func defaultCredentialsDir() string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return ""
	}
	return home + string(os.PathSeparator) + ".conduit" + string(os.PathSeparator) + "credentials"
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
