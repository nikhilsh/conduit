package session

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// lookupEnvCompat reads a CONDUIT_-prefixed environment variable, falling
// back to the legacy KITTY_-prefixed spelling (pre-rebrand) so existing
// deployments and systemd unit files that still set the old names keep
// working. `name` is always the new CONDUIT_ form. An explicitly-set
// CONDUIT_ value wins even if empty; only an unset CONDUIT_ name consults
// the legacy alias.
func lookupEnvCompat(name string) string {
	if v, ok := os.LookupEnv(name); ok {
		return v
	}
	if rest, found := strings.CutPrefix(name, "CONDUIT_"); found {
		return os.Getenv("KITTY_" + rest)
	}
	return ""
}

func durationFromEnv(name string, fallback time.Duration) time.Duration {
	raw := strings.TrimSpace(lookupEnvCompat(name))
	if raw == "" {
		return fallback
	}
	ms, err := strconv.Atoi(raw)
	if err != nil || ms <= 0 {
		return fallback
	}
	return time.Duration(ms) * time.Millisecond
}

func atomicWriteFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	if err := os.Rename(tmp, path); err != nil {
		return err
	}
	return syncDir(filepath.Dir(path))
}

func syncDir(path string) error {
	dir, err := os.Open(path)
	if err != nil {
		return err
	}
	defer dir.Close()
	return dir.Sync()
}
