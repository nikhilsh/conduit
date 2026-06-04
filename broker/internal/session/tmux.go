package session

import "regexp"

// tmuxNameUnsafe matches every character that is NOT allowed in a tmux
// session name. tmux uses `.` and `:` as window/pane separators in target
// specs (e.g. `session:window.pane`), so a name containing either is
// ambiguous to `attach-session -t`. We also forbid whitespace and any
// other punctuation that the shell would have to quote, collapsing the
// safe set to ASCII letters, digits, underscore, and hyphen.
var tmuxNameUnsafe = regexp.MustCompile(`[^A-Za-z0-9_-]`)

// sanitizeTmuxName turns an arbitrary session UUID into a tmux-safe
// session name. Every unsafe character (notably `.` and `:`) is replaced
// with `_`, and the result is prefixed with `kitty-` so the broker's
// sessions are namespaced away from any tmux sessions the user started
// by hand. The transform is pure and deterministic: the same UUID always
// maps to the same tmux name, which is what lets a reconnect re-attach.
//
// An empty input still yields a usable name (`kitty-`), but in practice
// the caller always passes a non-empty UUID.
func sanitizeTmuxName(id string) string {
	return "kitty-" + tmuxNameUnsafe.ReplaceAllString(id, "_")
}

// terminalShellArgv builds the argv for the Terminal-tab PTY shell.
//
// When tmux is present it returns a login-shell invocation that attaches
// to an existing per-session tmux session or creates one if it doesn't
// exist yet (the `has-session && attach || new` idiom from MobileTerminal's
// ttyd-tmux.sh). This is what makes the terminal survive a disconnect or an
// app-background: the shell process the PTY hosts can die and re-spawn, but
// the tmux server keeps the real shell — and its scrollback — alive between
// attaches.
//
// When tmux is absent it returns a plain `bash` argv, preserving the
// pre-tmux behaviour exactly so hosts without tmux installed see no change.
//
// tmuxPath is the resolved absolute path to the tmux binary (from
// exec.LookPath); pass "" to signal tmux is unavailable.
func terminalShellArgv(tmuxPath, sessionName string) []string {
	if tmuxPath == "" {
		return []string{"bash"}
	}
	// `tmux new-session -A -s <name>` attaches if the session exists and
	// creates it otherwise — the single-command form of has/attach/new.
	// We wrap it in `bash -lc` so the PTY still owns a bash login shell
	// (matching the env we set: TERM, PS1) and so a clean tmux detach
	// (prefix-d) drops the user back to a usable shell rather than EOF.
	//
	// We `start-server` first, then set options, THEN attach via new-session —
	// so the options are in effect BEFORE the client attaches (some, notably
	// the alt-screen suppression below, only take hold if set pre-attach):
	//   - `terminal-overrides ',*:smcup@:rmcup@'` strips the outer terminal's
	//     smcup/rmcup so tmux does NOT switch the client to the *alternate*
	//     screen (no `ESC[?1049h`). It then runs on the MAIN screen, so the
	//     client terminal (libghostty / the Android emulator / xterm.js) keeps
	//     its OWN scrollback and finger-scroll is a passive view-move instead
	//     of being forwarded to tmux copy-mode.
	//   - `mouse off`           we want native client-side view scrolling, not
	//                          tmux copy-mode wheel forwarding (which also
	//                          caused the Android SGR mouse-report garbage).
	//   - `status off`          hides tmux's status bar so it can't land in the
	//                          client's scrollback now that we're on the main
	//                          screen.
	//   - `history-limit 50000` deep scrollback buffer.
	// The separator between tmux commands is tmux's own `;`, which must reach
	// tmux *literally* — so we escape it as `\;` in the shell string (bash
	// would otherwise eat a bare `;` as its own command separator). The final
	// `; exec bash -l` is intentionally a REAL (unescaped) bash separator so
	// bash exec's a login shell once tmux detaches/exits, exactly as before.
	cmd := tmuxPath + ` start-server \; set -ga terminal-overrides ',*:smcup@:rmcup@' \; set -g status off \; set -g mouse off \; set -g history-limit 50000 \; new-session -A -s ` + sessionName + `; exec bash -l`
	return []string{"bash", "-lc", cmd}
}
