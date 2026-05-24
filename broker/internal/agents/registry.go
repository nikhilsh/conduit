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
	// ReasoningEffort is a "low" / "medium" / "high" label surfaced
	// on the iOS / Android agent pill. Optional; PR #16 hardcoded
	// "medium" in the status frame as a placeholder, this carries
	// the per-agent override when set in the toml.
	ReasoningEffort string `toml:"reasoning_effort"`
	Hooks           Hooks  `toml:"hooks"`
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
	for name := range r.adapters {
		names = append(names, name)
	}
	slices.Sort(names)
	return names
}
