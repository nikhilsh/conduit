package agents

import (
	"errors"
	"fmt"
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
	Name             string   `toml:"name"`
	Image            string   `toml:"image"`
	Command          []string `toml:"command"`
	Args             []string `toml:"args"`
	EnvPassthrough   []string `toml:"env_passthrough"`
	Workdir          string   `toml:"workdir"`
	ChatEventPortEnv string   `toml:"chat_event_port_env"`
	Hooks            Hooks    `toml:"hooks"`
}

func (a Adapter) Validate() error {
	switch {
	case strings.TrimSpace(a.Name) == "":
		return errors.New("adapter: name is required")
	case strings.TrimSpace(a.Image) == "":
		return fmt.Errorf("adapter %q: image is required", a.Name)
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
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	reg := &Registry{adapters: make(map[string]Adapter, len(entries))}
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".toml" {
			continue
		}
		path := filepath.Join(dir, entry.Name())
		var adapter Adapter
		if _, err := toml.DecodeFile(path, &adapter); err != nil {
			return nil, fmt.Errorf("decode %s: %w", path, err)
		}
		if err := adapter.Validate(); err != nil {
			return nil, fmt.Errorf("%s: %w", path, err)
		}
		if _, exists := reg.adapters[adapter.Name]; exists {
			return nil, fmt.Errorf("%s: duplicate adapter name %q", path, adapter.Name)
		}
		reg.adapters[adapter.Name] = adapter
	}
	if len(reg.adapters) == 0 {
		return nil, fmt.Errorf("no adapters found in %s", dir)
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
