package session

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
)

// This file implements dynamic model + effort discovery: at startup (and on a
// staleness TTL) the broker asks each agent CLI what models it actually
// serves, instead of trusting hardcoded lists that drift (gpt-5-codex shipped
// in the apps long after codex stopped serving it).
//
// Sources, both verified live:
//   - claude: a stream-json control_request {"subtype":"initialize"} returns
//     models[] with value/displayName/description/supportedEffortLevels.
//   - codex:  the app-server `model/list` JSON-RPC returns data[] with
//     id/displayName/description/supportedReasoningEfforts/isDefault.
//
// The catalog is served to the apps via /api/capabilities ("models") and
// also feeds effort validation: an effort the agent advertises is accepted
// even when the static fallback maps in override.go predate it.

// ModelInfo is one model in an assistant's catalog, normalized across
// agents. ID is what the app sends back as the session-create "model"
// override ("" = inherit the agent default; for claude the CLI's own
// "default" entry is normalized to "").
type ModelInfo struct {
	ID            string `json:"id"`
	DisplayName   string `json:"display_name"`
	Description   string `json:"description,omitempty"`
	IsDefault     bool   `json:"is_default,omitempty"`
	DefaultEffort string `json:"default_effort,omitempty"`
	// Efforts lists the reasoning-effort levels this model supports, in
	// the agent's own order. nil/empty = the model has no effort control
	// (e.g. claude haiku).
	Efforts []string `json:"efforts,omitempty"`
	// SupportsFastMode is true when the claude CLI advertises
	// supportsFastMode:true for this model in the initialize control
	// response. Only populated for claude; always false for codex.
	SupportsFastMode bool `json:"supports_fast_mode,omitempty"`
}

// catalogTTL is how long a fetched catalog is considered fresh. Model lists
// change on agent releases, not minute-to-minute.
const catalogTTL = 6 * time.Hour

// catalogRetry is the floor between probe attempts after a failure, so a
// missing/broken CLI doesn't get re-spawned on every capabilities poll.
const catalogRetry = 5 * time.Minute

// catalogProbeTimeout caps one CLI probe. claude's stream-json startup is the
// slow one (plugins + MCP init can take ~10s on the box).
const catalogProbeTimeout = 60 * time.Second

// dynamicEfforts is the package-level registry of agent-advertised effort
// levels, updated whenever a catalog probe succeeds. It backs
// effortSupported() — package-level (rather than threaded through
// SpawnOverride) because override validation runs in pure SpawnOverride
// methods and the broker has exactly one Manager.
var dynamicEfforts = struct {
	mu sync.RWMutex
	m  map[string]map[string]bool
}{m: map[string]map[string]bool{}}

func recordDynamicEfforts(assistant string, models []ModelInfo) {
	set := map[string]bool{}
	for _, mi := range models {
		for _, e := range mi.Efforts {
			if e = strings.TrimSpace(e); e != "" {
				set[e] = true
			}
		}
	}
	dynamicEfforts.mu.Lock()
	dynamicEfforts.m[assistant] = set
	dynamicEfforts.mu.Unlock()
}

// effortSupported reports whether an effort label may be forwarded to the
// assistant: either the static fallback map knows it (works with no catalog,
// e.g. broker just started) or the agent's own catalog advertises it (so new
// levels like codex "xhigh" work without a broker release).
func effortSupported(assistant, effort string) bool {
	switch assistant {
	case "claude":
		if claudeEfforts[effort] {
			return true
		}
	case "codex":
		if codexEfforts[effort] {
			return true
		}
	}
	dynamicEfforts.mu.RLock()
	defer dynamicEfforts.mu.RUnlock()
	return dynamicEfforts.m[assistant][effort]
}

// --- pure parsers (table-tested without spawning CLIs) ---

// claudeCatalogModel is the wire shape of one entry in the claude control
// protocol's initialize response models[] (claude-code 2.1.x, verified live).
type claudeCatalogModel struct {
	Value                 string   `json:"value"`
	DisplayName           string   `json:"displayName"`
	Description           string   `json:"description"`
	SupportsEffort        bool     `json:"supportsEffort"`
	SupportedEffortLevels []string `json:"supportedEffortLevels"`
	SupportsFastMode      bool     `json:"supportsFastMode"`
}

// parseClaudeCatalogLine inspects one stream-json stdout line. If it is the
// control_response for requestID, it returns the normalized catalog and
// ok=true; any other line (init, system, unrelated responses) returns
// ok=false.
func parseClaudeCatalogLine(line []byte, requestID string) ([]ModelInfo, bool) {
	var frame struct {
		Type     string `json:"type"`
		Response struct {
			Subtype   string `json:"subtype"`
			RequestID string `json:"request_id"`
			Response  struct {
				Models []claudeCatalogModel `json:"models"`
			} `json:"response"`
		} `json:"response"`
	}
	if err := json.Unmarshal(line, &frame); err != nil {
		return nil, false
	}
	if frame.Type != "control_response" || frame.Response.RequestID != requestID {
		return nil, false
	}
	out := make([]ModelInfo, 0, len(frame.Response.Response.Models))
	for _, m := range frame.Response.Response.Models {
		id := strings.TrimSpace(m.Value)
		if id == "" {
			continue
		}
		mi := ModelInfo{
			ID:               id,
			DisplayName:      strings.TrimSpace(m.DisplayName),
			Description:      strings.TrimSpace(m.Description),
			SupportsFastMode: m.SupportsFastMode,
		}
		if m.SupportsEffort {
			mi.Efforts = m.SupportedEffortLevels
		}
		// claude's own "use the default" entry — normalize to the broker's
		// inherit sentinel: the app omits the model override and the CLI
		// resolves its default, instead of us pinning today's default name.
		if id == "default" {
			mi.ID = ""
			mi.IsDefault = true
		}
		out = append(out, mi)
	}
	if len(out) == 0 {
		return nil, false
	}
	return out, true
}

// codexCatalogModel is the wire shape of one entry in the codex app-server
// model/list result data[] (codex-cli 0.13x, verified live).
type codexCatalogModel struct {
	ID          string `json:"id"`
	DisplayName string `json:"displayName"`
	Description string `json:"description"`
	Hidden      bool   `json:"hidden"`
	IsDefault   bool   `json:"isDefault"`
	Efforts     []struct {
		ReasoningEffort string `json:"reasoningEffort"`
	} `json:"supportedReasoningEfforts"`
	DefaultReasoningEffort string `json:"defaultReasoningEffort"`
}

// parseCodexModelList normalizes a model/list JSON-RPC result. Hidden models
// (internal slugs like codex-auto-review) are dropped.
func parseCodexModelList(result []byte) ([]ModelInfo, error) {
	var payload struct {
		Data []codexCatalogModel `json:"data"`
	}
	if err := json.Unmarshal(result, &payload); err != nil {
		return nil, err
	}
	out := make([]ModelInfo, 0, len(payload.Data))
	for _, m := range payload.Data {
		if m.Hidden || strings.TrimSpace(m.ID) == "" {
			continue
		}
		mi := ModelInfo{
			ID:            strings.TrimSpace(m.ID),
			DisplayName:   strings.TrimSpace(m.DisplayName),
			Description:   strings.TrimSpace(m.Description),
			IsDefault:     m.IsDefault,
			DefaultEffort: strings.TrimSpace(m.DefaultReasoningEffort),
		}
		for _, e := range m.Efforts {
			if v := strings.TrimSpace(e.ReasoningEffort); v != "" {
				mi.Efforts = append(mi.Efforts, v)
			}
		}
		out = append(out, mi)
	}
	if len(out) == 0 {
		return nil, errors.New("codex model/list: no visible models")
	}
	return out, nil
}

// --- process probes ---

// catalogScanBuf sizes the stdout line scanner. claude's init / control
// frames carry full command + agent inventories and run to hundreds of KB.
const catalogScanBuf = 4 << 20

// probeClaudeCatalog spawns the claude CLI headless and asks the stream-json
// control protocol for its model list. The probe never sends a user message,
// so no turn (and no token spend) happens; the process is killed as soon as
// the control_response arrives.
// extraEnv is appended to os.Environ() before the process is started; nil
// means inherit the broker's environment unchanged (flag-off / default).
func probeClaudeCatalog(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
	const reqID = "conduit-model-catalog"
	cmd := exec.CommandContext(ctx, bin,
		"-p", "--verbose",
		"--input-format", "stream-json",
		"--output-format", "stream-json")
	// Neutral cwd: don't pay for (or get confused by) some repo's project
	// config, MCP servers, or hooks.
	cmd.Dir = os.TempDir()
	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	req := fmt.Sprintf(`{"type":"control_request","request_id":%q,"request":{"subtype":"initialize"}}`+"\n", reqID)
	if _, err := stdin.Write([]byte(req)); err != nil {
		return nil, fmt.Errorf("claude catalog probe: write: %w", err)
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64*1024), catalogScanBuf)
	for sc.Scan() {
		if models, ok := parseClaudeCatalogLine(sc.Bytes(), reqID); ok {
			return models, nil
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("claude catalog probe: %w", err)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("claude catalog probe: read: %w", err)
	}
	return nil, errors.New("claude catalog probe: stream ended without control_response")
}

// probeCodexCatalog spawns a throwaway `codex app-server`, performs the
// initialize handshake, and calls model/list. Decoupled from the per-session
// app-server clients on purpose: the probe must work with zero sessions open.
// extraEnv is appended to os.Environ() before the process is started; nil
// means inherit the broker's environment unchanged (flag-off / default).
func probeCodexCatalog(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
	cmd := exec.CommandContext(ctx, bin, "app-server")
	cmd.Dir = os.TempDir()
	if len(extraEnv) > 0 {
		cmd.Env = append(os.Environ(), extraEnv...)
	}
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	if err := cmd.Start(); err != nil {
		return nil, err
	}
	defer func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	}()
	init, err := encodeCodexRequest(1, "initialize", map[string]any{
		"clientInfo": map[string]any{
			"name":    "conduit-broker",
			"title":   "conduit-broker model catalog probe",
			"version": "1.0.0",
		},
	})
	if err != nil {
		return nil, err
	}
	if _, err := stdin.Write(init); err != nil {
		return nil, fmt.Errorf("codex catalog probe: write initialize: %w", err)
	}
	sc := bufio.NewScanner(stdout)
	sc.Buffer(make([]byte, 64*1024), catalogScanBuf)
	sentList := false
	for sc.Scan() {
		var env codexRPCEnvelope
		if err := json.Unmarshal(sc.Bytes(), &env); err != nil || len(env.ID) == 0 {
			continue
		}
		id := strings.TrimSpace(string(env.ID))
		switch {
		case id == "1" && !sentList:
			list, err := encodeCodexRequest(2, "model/list", map[string]any{})
			if err != nil {
				return nil, err
			}
			if _, err := stdin.Write(list); err != nil {
				return nil, fmt.Errorf("codex catalog probe: write model/list: %w", err)
			}
			sentList = true
		case id == "2":
			if len(env.Error) > 0 {
				return nil, fmt.Errorf("codex catalog probe: model/list error: %s", env.Error)
			}
			return parseCodexModelList(env.Result)
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, fmt.Errorf("codex catalog probe: %w", err)
	}
	if err := sc.Err(); err != nil {
		return nil, fmt.Errorf("codex catalog probe: read: %w", err)
	}
	return nil, errors.New("codex catalog probe: stream ended without model/list response")
}

// catalogProbeFor resolves an assistant's catalog probe via the protocol
// backend registry (Phase 2): the assistant's adapter.Protocol selects the
// AgentBackend whose CatalogProbe does the live discovery. Returns nil for
// assistants with no registered backend (e.g. the hidden shell adapter, or a
// legacy TUI-scrape adapter), so maybeRefreshCatalog skips them. reg is the
// Manager's registry — needed to map assistant name → protocol.
func catalogProbeFor(reg *agents.Registry, assistant string) func(context.Context, string, []string) ([]ModelInfo, error) {
	backend, err := backendForAssistant(reg, assistant)
	if err != nil {
		return nil
	}
	return func(ctx context.Context, bin string, extraEnv []string) ([]ModelInfo, error) {
		return backend.CatalogProbe(ctx, bin, extraEnv)
	}
}

// binFingerprint returns a stable string identifying a CLI binary. It resolves
// symlinks (so ~/.local/bin/claude → .../versions/2.1.177/claude) and folds in
// file size + modtime so an in-place upgrade — same resolved path, different
// content — also forces a re-probe. Any stat/resolve error falls back to the
// raw bin path so a temporarily-missing CLI doesn't crash the cache.
func binFingerprint(bin string) string {
	resolved, err := filepath.EvalSymlinks(bin)
	if err != nil {
		return bin
	}
	fi, err := os.Stat(resolved)
	if err != nil {
		return resolved
	}
	return fmt.Sprintf("%s|%d|%d", resolved, fi.Size(), fi.ModTime().UnixNano())
}

// --- manager-side cache ---

// modelCatalogCache is the Manager-owned cache of discovered catalogs.
type modelCatalogCache struct {
	mu           sync.Mutex
	enabled      bool
	models       map[string][]ModelInfo
	attempted    map[string]time.Time // last probe start (success or not)
	fetched      map[string]time.Time // last probe success
	busy         map[string]bool
	fingerprints map[string]string // per-assistant binary fingerprint at last successful probe
	// probe is a test seam; nil = catalogProbeFor. The extraEnv slice is
	// forwarded from maybeRefreshCatalog (shared-agent-creds env or nil).
	probe func(ctx context.Context, assistant, bin string, extraEnv []string) ([]ModelInfo, error)
	// fingerprintFn is a test seam; nil = binFingerprint.
	fingerprintFn func(bin string) string
}

func (c *modelCatalogCache) init() {
	if c.models == nil {
		c.models = map[string][]ModelInfo{}
		c.attempted = map[string]time.Time{}
		c.fetched = map[string]time.Time{}
		c.busy = map[string]bool{}
		c.fingerprints = map[string]string{}
	}
}

// EnableModelDiscovery turns on background catalog probing and kicks the
// initial fetch for every discoverable assistant. Called once from
// cmd/conduit-broker — unit tests never enable it, so no CLI is spawned
// under `go test`.
func (m *Manager) EnableModelDiscovery() {
	m.catalog.mu.Lock()
	m.catalog.init()
	m.catalog.enabled = true
	m.catalog.mu.Unlock()
	for _, name := range m.registry.Names() {
		m.maybeRefreshCatalog(name)
	}
}

// SetModelCatalog injects a catalog directly (tests, or a future static
// config override). Also feeds effort validation.
func (m *Manager) SetModelCatalog(assistant string, models []ModelInfo) {
	m.catalog.mu.Lock()
	m.catalog.init()
	m.catalog.models[assistant] = models
	m.catalog.fetched[assistant] = time.Now()
	m.catalog.mu.Unlock()
	recordDynamicEfforts(assistant, models)
}

// ModelCatalog returns a snapshot of the discovered catalogs keyed by
// assistant (nil when nothing has been discovered yet — capabilities then
// omits "models" and the apps fall back to their built-in lists). Access
// also re-probes stale entries in the background.
func (m *Manager) ModelCatalog() map[string][]ModelInfo {
	m.catalog.mu.Lock()
	m.catalog.init()
	enabled := m.catalog.enabled
	var snap map[string][]ModelInfo
	if len(m.catalog.models) > 0 {
		snap = make(map[string][]ModelInfo, len(m.catalog.models))
		for k, v := range m.catalog.models {
			snap[k] = v
		}
	}
	m.catalog.mu.Unlock()
	if enabled {
		for _, name := range m.registry.Names() {
			m.maybeRefreshCatalog(name)
		}
	}
	return snap
}

// catalogExtraEnv computes the extra env vars to inject into a catalog probe
// when CONDUIT_SHARED_AGENT_CREDS is on. Under the flag the probe must query
// the same account that real sessions run under (the broker-owned agent-cred
// dir, not the host-login ~/.claude / ~/.codex). Returns nil when the flag is
// off — behavior is byte-identical to before this fix.
func (m *Manager) catalogExtraEnv() []string {
	if !sharedAgentCredsEnabled() {
		return nil
	}
	res := resolveSharedCred(m.conduitRoot, m.credStore)
	envMap, _ := sharedCredEnvFrom(res)
	if len(envMap) == 0 {
		return nil
	}
	// Flatten to sorted "K=V" strings for a deterministic, reproducible env.
	keys := make([]string, 0, len(envMap))
	for k := range envMap {
		keys = append(keys, k)
	}
	// Sort for determinism (order matters for test assertions).
	for i := 0; i < len(keys); i++ {
		for j := i + 1; j < len(keys); j++ {
			if keys[i] > keys[j] {
				keys[i], keys[j] = keys[j], keys[i]
			}
		}
	}
	out := make([]string, 0, len(keys))
	for _, k := range keys {
		out = append(out, k+"="+envMap[k])
	}
	return out
}

// maybeRefreshCatalog starts a background probe for the assistant when the
// cached entry is stale (or has never been fetched) and no probe is already
// running. A fingerprint change (e.g. the CLI symlink was upgraded in place)
// also forces an immediate re-probe even within the TTL, so stale models from
// a previous CLI version are evicted immediately. Failures keep the previous
// catalog and are retried no sooner than catalogRetry.
func (m *Manager) maybeRefreshCatalog(assistant string) {
	probe := m.catalog.probe
	if probe == nil {
		std := catalogProbeFor(m.registry, assistant)
		if std == nil {
			return
		}
		probe = func(ctx context.Context, _ string, bin string, extraEnv []string) ([]ModelInfo, error) {
			return std(ctx, bin, extraEnv)
		}
	}
	adapter, err := m.registry.Get(assistant)
	if err != nil || len(adapter.Command) == 0 {
		return
	}
	bin := adapter.Command[0]

	// Compute the shared-agent-creds env override BEFORE taking the catalog
	// lock; resolveSharedCred is pure (no writes) and cheap.
	extraEnv := m.catalogExtraEnv()

	// Resolve the current binary fingerprint before taking the lock so the
	// stat syscalls don't extend the critical section.
	fpFn := m.catalog.fingerprintFn
	if fpFn == nil {
		fpFn = binFingerprint
	}
	currentFP := fpFn(bin)

	m.catalog.mu.Lock()
	m.catalog.init()
	if !m.catalog.enabled || m.catalog.busy[assistant] {
		m.catalog.mu.Unlock()
		return
	}
	// A fingerprint change means the CLI binary was upgraded: force a re-probe
	// even if the TTL hasn't expired yet.
	fpChanged := currentFP != m.catalog.fingerprints[assistant]
	withinTTL := time.Since(m.catalog.fetched[assistant]) < catalogTTL
	// catalogRetry floors re-probe attempts after a FAILURE (fetched is zero
	// or behind attempted), preventing hot-loops on a broken/flapping binary.
	// After a successful probe the retry floor is skipped so a fingerprint
	// change (CLI upgrade) fires promptly rather than waiting up to 5 minutes.
	lastAttempt := m.catalog.attempted[assistant]
	lastFetch := m.catalog.fetched[assistant]
	withinRetryAfterFailure := !lastAttempt.IsZero() && lastFetch.Before(lastAttempt) &&
		time.Since(lastAttempt) < catalogRetry
	if (!fpChanged && withinTTL) || withinRetryAfterFailure {
		m.catalog.mu.Unlock()
		return
	}
	m.catalog.busy[assistant] = true
	m.catalog.attempted[assistant] = time.Now()
	m.catalog.mu.Unlock()

	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), catalogProbeTimeout)
		defer cancel()
		models, err := probe(ctx, assistant, bin, extraEnv)
		m.catalog.mu.Lock()
		m.catalog.busy[assistant] = false
		if err == nil && len(models) > 0 {
			m.catalog.models[assistant] = models
			m.catalog.fetched[assistant] = time.Now()
			m.catalog.fingerprints[assistant] = currentFP
		}
		m.catalog.mu.Unlock()
		if err != nil {
			fmt.Fprintf(os.Stderr, "session: model catalog probe (%s): %v\n", assistant, err)
			return
		}
		recordDynamicEfforts(assistant, models)
	}()
}
