package session

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync"
	"time"
)

// agentInstallTimeout is the maximum time we'll wait for an agent CLI
// installer to complete. Installs can be slow (large binaries, slow links),
// so we give 300 s — well above the bootstrap 180 s cap to handle cold hosts.
const agentInstallTimeout = 300 * time.Second

// agentInstaller manages single-flight on-demand installs. One install per
// agent name runs at a time; concurrent sessions for the same agent share the
// in-flight install rather than racing with multiple simultaneous downloads.
var agentInstaller = &installFlight{inflight: make(map[string]*installResult)}

type installResult struct {
	done chan struct{} // closed when install finishes
	err  error         // populated before done is closed
}

type installFlight struct {
	mu       sync.Mutex
	inflight map[string]*installResult
}

// run executes installCmd for agentName (via `sh -c installCmd`) if not
// already in flight, returning the error from the run. A concurrent caller
// for the same agentName blocks until the in-flight run completes and then
// shares its outcome.
func (f *installFlight) run(ctx context.Context, agentName, installCmd string) error {
	f.mu.Lock()
	if r, ok := f.inflight[agentName]; ok {
		// Already installing — share the result.
		f.mu.Unlock()
		select {
		case <-r.done:
			return r.err
		case <-ctx.Done():
			return ctx.Err()
		}
	}
	r := &installResult{done: make(chan struct{})}
	f.inflight[agentName] = r
	f.mu.Unlock()

	go func() {
		defer func() {
			f.mu.Lock()
			delete(f.inflight, agentName)
			f.mu.Unlock()
			close(r.done)
		}()
		r.err = runInstallCmd(ctx, installCmd)
	}()

	select {
	case <-r.done:
		return r.err
	case <-ctx.Done():
		return ctx.Err()
	}
}

// runInstallCmd shells out to `sh -c installCmd` with a PATH that includes
// ~/.local/bin so freshly-installed binaries are immediately findable.
// stdout/stderr are forwarded to the broker's own stderr for on-box logging.
func runInstallCmd(ctx context.Context, installCmd string) error {
	home, _ := os.UserHomeDir()
	localBin := filepath.Join(home, ".local", "bin")

	// Build a PATH that includes ~/.local/bin (where claude/codex install to)
	// so the installer can self-verify and any post-install PATH checks work.
	envPath := os.Getenv("PATH")
	if envPath == "" {
		envPath = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
	}
	// Prepend localBin if not already present.
	fullPath := localBin + ":" + envPath

	cmd := exec.CommandContext(ctx, "sh", "-c", installCmd)
	cmd.Env = append(os.Environ(), "PATH="+fullPath)
	cmd.Stdout = os.Stderr // forward installer output to broker stderr
	cmd.Stderr = os.Stderr
	return cmd.Run()
}

// maybeInstallAgent checks whether the agent binary (adapter.Command[0]) is
// on PATH. If it is, it returns nil immediately. If it is missing AND the
// adapter has an InstallCmd, it:
//  1. publishes a "Installing…" system chat message,
//  2. runs the installer (single-flight per agent name),
//  3. re-checks the binary,
//  4. publishes "installed" or the failure reason.
//
// Returns nil when the binary is available (either pre-existing or after a
// successful install), or an error if the install was unavailable or failed.
// The publish func may be nil (no chat messages in that case).
func maybeInstallAgent(agentName, binary, installCmd string, publish func([]byte)) error {
	// Fast path: binary already present.
	if _, err := exec.LookPath(binary); err == nil {
		return nil
	}

	// Binary missing. If no install command is configured, report not-found.
	if installCmd == "" {
		return fmt.Errorf("exec: %q: executable file not found in $PATH", binary)
	}

	// Announce the install to the user.
	if publish != nil {
		publishChatSystem(publish, fmt.Sprintf("⏳ Installing %s on this box (one-time, ~a minute)…", agentName))
	}
	fmt.Fprintf(os.Stderr, "session: agent %q not found; running on-demand install\n", agentName)

	ctx, cancel := context.WithTimeout(context.Background(), agentInstallTimeout)
	defer cancel()

	if err := agentInstaller.run(ctx, agentName, installCmd); err != nil {
		msg := fmt.Sprintf("⚠️ couldn't install %s: %v", agentName, err)
		if publish != nil {
			publishChatSystem(publish, msg)
		}
		fmt.Fprintf(os.Stderr, "session: on-demand install %q: %v\n", agentName, err)
		return fmt.Errorf("on-demand install %q: %w", agentName, err)
	}

	// Re-verify the binary landed.
	if _, err := exec.LookPath(binary); err != nil {
		msg := fmt.Sprintf("⚠️ couldn't install %s: installer ran but binary not found at PATH", agentName)
		if publish != nil {
			publishChatSystem(publish, msg)
		}
		return fmt.Errorf("on-demand install %q: installer succeeded but binary still not found", agentName)
	}

	if publish != nil {
		publishChatSystem(publish, fmt.Sprintf("✅ %s installed", agentName))
	}
	fmt.Fprintf(os.Stderr, "session: on-demand install %q: succeeded\n", agentName)
	return nil
}
