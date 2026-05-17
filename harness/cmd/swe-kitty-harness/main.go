// Command swe-kitty-harness is the harness server entry point.
//
// Usage:
//
//	swe-kitty-harness up [--local] [--public-url URL] [--addr :1977]
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
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/nikhilsh/swe-kitty/harness/internal/agents"
	"github.com/nikhilsh/swe-kitty/harness/internal/auth"
	"github.com/nikhilsh/swe-kitty/harness/internal/session"
	"github.com/nikhilsh/swe-kitty/harness/internal/ws"
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
	fmt.Fprintln(os.Stderr, `swe-kitty-harness — the swe-kitty server

Commands:
  up        start the HTTP+WebSocket harness
  memory    (task 005) per-session memory CLI

Run "swe-kitty-harness up --help" for options.`)
}

func runUp(args []string) int {
	fs := flag.NewFlagSet("up", flag.ExitOnError)
	addr := fs.String("addr", ":1977", "HTTP listen address")
	local := fs.Bool("local", false, "advertise on LAN via mDNS (stub in task 001)")
	publicURL := fs.String("public-url", "", "public-facing URL (for QR/UX hints)")
	_ = fs.Parse(args)

	if *local {
		log.Println("--local: mDNS advertisement is stubbed in task 001")
	}

	store := auth.NewStore()
	token := store.Mint()
	registry, err := agents.LoadDir("agents")
	if err != nil {
		log.Printf("load adapters: %v", err)
		return 1
	}
	mgr := session.NewManager(registry)
	if recovered, err := mgr.Recover(); err == nil && len(recovered) > 0 {
		log.Printf("recovered sessions: %v", recovered)
	}
	srv := ws.New(store, mgr)

	hostURL := *publicURL
	if hostURL == "" {
		hostURL = "http://localhost" + *addr
	}
	fmt.Printf("swe-kitty-harness up\n  addr:  %s\n  url:   %s\n  token: %s\n\nConnect:\n  wscat -c \"%s/ws/$(uuidgen)?assistant=claude&token=%s\"\n",
		*addr, hostURL, token, replaceScheme(hostURL), token)

	httpSrv := &http.Server{
		Addr:              *addr,
		Handler:           srv.Handler(),
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
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = httpSrv.Shutdown(ctx)
	mgr.Close()
	return 0
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
