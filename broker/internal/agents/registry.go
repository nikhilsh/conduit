package agents

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"

	"github.com/BurntSushi/toml"
)

type Hooks struct {
	OnStart string `toml:"on_start"`
	OnExit  string `toml:"on_exit"`
	OnSwap  string `toml:"on_swap"`
}

// PermissionModeRule describes how to rewrite an argv for a named
// permission mode (e.g. "plan"). drop_args lists flag strings to
// remove; add_args lists flags to append. Both operate on the full
// argv (binary + args), so flags like "--dangerously-skip-permissions"
// can be stripped even when they came from the adapter's base args.
type PermissionModeRule struct {
	DropArgs []string `toml:"drop_args"`
	AddArgs  []string `toml:"add_args"`
}

type Adapter struct {
	Name string `toml:"name"`
	// Image is legacy/ignored: the broker runs agents as bare child
	// processes (pty.Start of Command), not Docker containers. Kept so
	// older TOMLs with an `image =` line still parse; no longer required
	// or used. See docs/AGENT-ADAPTERS.md.
	Image            string   `toml:"image"`
	Command          []string `toml:"command"`
	Args             []string `toml:"args"`
	EnvPassthrough   []string `toml:"env_passthrough"`
	Workdir          string   `toml:"workdir"`
	ChatEventPortEnv string   `toml:"chat_event_port_env"`
	// ChatMode selects how the Chat tab is sourced. "" (default) =
	// scrape the agent's TUI from the PTY (legacy). "stream-json" =
	// run the agent headless in stream-json as a structured chat
	// channel; the PTY then hosts a shell for the Terminal tab (B-i).
	// See docs/PLAN-CHAT-CHANNEL.md (task #24).
	ChatMode string `toml:"chat_mode"`
	// ReasoningEffort is a "low" / "medium" / "high" label surfaced
	// on the iOS / Android agent pill. Optional; PR #16 hardcoded
	// "medium" in the status frame as a placeholder, this carries
	// the per-agent override when set in the toml.
	ReasoningEffort string `toml:"reasoning_effort"`
	// Hidden keeps the adapter out of Names() (and so out of the app's
	// agent picker / capabilities assistants) while still resolvable by
	// Get(). Used by the built-in `shell` adapter, which is a Box-health
	// affordance rather than an agent.
	Hidden bool  `toml:"hidden"`
	Hooks  Hooks `toml:"hooks"`

	// --- Phase 1: manifest-driven fields (WS-1.1) ---
	// All fields are optional; absent fields are resolved by adapter Name
	// to today's hardcoded defaults in applyLegacyDefaults so third-party
	// adapter TOMLs that omit them preserve existing behavior.

	// Protocol is the chat-backend routing key for Phase 2.
	// Mirrors ChatMode for now; "stream-json" / "codex-app-server" / etc.
	Protocol string `toml:"protocol"`

	// ConfigDir is the agent's per-user config directory (e.g. ".claude",
	// ".codex"). Used by recovery.go to discover conversation files and
	// by lifecycle.go to derive credential paths.
	ConfigDir string `toml:"config_dir"`

	// DataDir is the agent's per-user data directory (relative to the
	// session's ephemeral $HOME, e.g. ".local/share/opencode"). Unlike
	// ConfigDir (config files), this holds the agent's session/conversation
	// STORE — for opencode a single global SQLite DB (opencode.db). It is the
	// resume hinge for server-backed agents that persist conversations in a
	// data store rather than per-session conversation files: recovery.go gates
	// the resume id on this dir's store existing. "" for agents (claude/codex)
	// that key resume off ConfigDir conversation files instead.
	DataDir string `toml:"data_dir"`

	// CredFiles lists the credential files the agent stores under its
	// config dir in the host HOME. Used by mirrorHostCredentials to copy
	// the right files into each session's ephemeral HOME.
	CredFiles []string `toml:"cred_files"`

	// ResumeArgs is the argv suffix to resume a previous session by ID.
	// The placeholder {session_id} is replaced with the actual ID.
	// Empty slice means the agent doesn't support CLI-level resume
	// (e.g. codex uses a protocol-level thread/resume instead).
	ResumeArgs []string `toml:"resume_args"`

	// ContinueArgs is the argv suffix to continue the most recent session
	// (no explicit ID). Used when conversation files exist but no session
	// ID was persisted.
	ContinueArgs []string `toml:"continue_args"`

	// ModelArgs is the argv template to pass a model override.
	// The placeholder {model} is replaced with the model name.
	ModelArgs []string `toml:"model_args"`

	// EffortArgs is the argv template to pass a reasoning-effort override.
	// The placeholder {effort} is replaced with the effort label.
	EffortArgs []string `toml:"effort_args"`

	// FastModeArgs is the argv template to pass a "fast mode" toggle
	// (claude-only). The placeholder {fast} is replaced with the literal
	// "true" or "false". Empty = the adapter has no fast-mode concept and
	// the toggle is a no-op (codex/opencode/gemini).
	FastModeArgs []string `toml:"fast_mode_args"`

	// LoginProvider is the OAuth provider key ("anthropic", "openai", …)
	// used by the credential store for this agent. "" means no OAuth flow.
	LoginProvider string `toml:"login_provider"`

	// PermissionModes maps mode name (e.g. "plan") → rewrite rule.
	// When a session is created with a named permission mode the rule's
	// drop_args are removed from the argv and add_args are appended.
	PermissionModes map[string]PermissionModeRule `toml:"permission_modes"`
}

func (a Adapter) Validate() error {
	switch {
	case strings.TrimSpace(a.Name) == "":
		return errors.New("adapter: name is required")
	case len(a.Command) == 0:
		return fmt.Errorf("adapter %q: command is required", a.Name)
	case strings.TrimSpace(a.Workdir) == "":
		return fmt.Errorf("adapter %q: workdir is required", a.Name)
	}
	return nil
}

// applyLegacyDefaults fills in any Phase-1 manifest fields that are absent
// from the TOML by resolving them from the adapter's Name. This preserves
// byte-identical behavior for third-party adapter TOMLs that predate the
// new fields, and also for the built-in claude/codex TOMLs until they are
// updated.
//
// The defaults mirror today's hardcoded switch sites exactly — the golden
// tests in manifest_golden_test.go pin this invariant.
func applyLegacyDefaults(a *Adapter) {
	// Protocol is the Phase-2 backend-routing key and a documented alias of
	// chat_mode. It is derived ONLY from chat_mode — never from the adapter
	// name — so routing matches the pre-Phase-2 chat_mode dispatch exactly: an
	// adapter with no chat_mode (e.g. the legacy TUI-scrape path, or a dummy
	// test adapter) gets protocol "" and routes to NO structured backend, just
	// as structuredChatBackend("") used to. The real claude/codex TOMLs set
	// chat_mode explicitly, so they get the right protocol; the name switch
	// below only backfills the OTHER manifest fields (config_dir, cred_files,
	// login_provider, arg templates, permission modes).
	if a.Protocol == "" && a.ChatMode != "" {
		a.Protocol = a.ChatMode
	}
	switch a.Name {
	case "claude":
		if a.ConfigDir == "" {
			a.ConfigDir = ".claude"
		}
		if len(a.CredFiles) == 0 {
			a.CredFiles = []string{".claude/.credentials.json", ".claude.json"}
		}
		if a.ResumeArgs == nil {
			a.ResumeArgs = []string{"--resume", "{session_id}"}
		}
		if a.ContinueArgs == nil {
			a.ContinueArgs = []string{"--continue"}
		}
		if len(a.ModelArgs) == 0 {
			a.ModelArgs = []string{"--model", "{model}"}
		}
		if len(a.EffortArgs) == 0 {
			a.EffortArgs = []string{"--effort", "{effort}"}
		}
		if len(a.FastModeArgs) == 0 {
			// claude fast mode is a boolean setting passed via
			// --settings '{"fastMode":true}' (verified; NOT an effort
			// level, NOT a model). {fast} expands to "true"/"false".
			a.FastModeArgs = []string{"--settings", `{"fastMode":{fast}}`}
		}
		if a.LoginProvider == "" {
			a.LoginProvider = "anthropic"
		}
		if a.PermissionModes == nil {
			a.PermissionModes = map[string]PermissionModeRule{
				"plan": {
					DropArgs: []string{"--dangerously-skip-permissions"},
					AddArgs:  []string{"--permission-mode", "plan"},
				},
			}
		}
	case "codex":
		if a.ConfigDir == "" {
			a.ConfigDir = ".codex"
		}
		if len(a.CredFiles) == 0 {
			a.CredFiles = []string{".codex/auth.json", ".codex/config.toml"}
		}
		if a.ResumeArgs == nil {
			// codex resumes via thread/resume (protocol level), not CLI args
			a.ResumeArgs = []string{}
		}
		if a.ContinueArgs == nil {
			a.ContinueArgs = []string{}
		}
		if len(a.ModelArgs) == 0 {
			a.ModelArgs = []string{"--model", "{model}"}
		}
		if len(a.EffortArgs) == 0 {
			a.EffortArgs = []string{"-c", "model_reasoning_effort={effort}"}
		}
		if a.LoginProvider == "" {
			a.LoginProvider = "openai"
		}
		if a.PermissionModes == nil {
			a.PermissionModes = map[string]PermissionModeRule{
				"plan": {
					DropArgs: []string{"--dangerously-bypass-approvals-and-sandbox"},
					AddArgs:  []string{"--sandbox", "read-only"},
				},
			}
		}
	}
}

type Registry struct {
	adapters map[string]Adapter
}

func LoadDir(dir string) (*Registry, error) {
	return LoadFS(os.DirFS(dir), ".", dir)
}

// LoadFS reads adapter TOMLs from any [fs.FS] rooted at `root`. The
// `displayDir` is used purely for error messages so callers can surface
// the underlying source (e.g. "embedded" vs an on-disk path).
func LoadFS(fsys fs.FS, root, displayDir string) (*Registry, error) {
	entries, err := fs.ReadDir(fsys, root)
	if err != nil {
		return nil, err
	}
	reg := &Registry{adapters: make(map[string]Adapter, len(entries))}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".toml" {
			continue
		}
		path := filepath.ToSlash(filepath.Join(root, entry.Name()))
		data, err := fs.ReadFile(fsys, path)
		if err != nil {
			return nil, fmt.Errorf("read %s/%s: %w", displayDir, entry.Name(), err)
		}
		var adapter Adapter
		if err := toml.Unmarshal(data, &adapter); err != nil {
			return nil, fmt.Errorf("decode %s/%s: %w", displayDir, entry.Name(), err)
		}
		if err := adapter.Validate(); err != nil {
			return nil, fmt.Errorf("%s/%s: %w", displayDir, entry.Name(), err)
		}
		applyLegacyDefaults(&adapter)
		if _, exists := reg.adapters[adapter.Name]; exists {
			return nil, fmt.Errorf("%s/%s: duplicate adapter name %q", displayDir, entry.Name(), adapter.Name)
		}
		reg.adapters[adapter.Name] = adapter
	}
	if len(reg.adapters) == 0 {
		return nil, fmt.Errorf("no adapters found in %s", displayDir)
	}
	return reg, nil
}

func (r *Registry) Get(name string) (Adapter, error) {
	adapter, ok := r.adapters[name]
	if !ok {
		return Adapter{}, fmt.Errorf("unknown assistant %q", name)
	}
	return adapter, nil
}

func (r *Registry) Names() []string {
	names := make([]string, 0, len(r.adapters))
	for name, adapter := range r.adapters {
		if adapter.Hidden {
			continue
		}
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}
