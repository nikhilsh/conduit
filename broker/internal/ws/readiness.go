package ws

// readiness.go — per-request readiness block for GET /api/capabilities.
//
// The readiness block gives apps a structured signal for a post-pair
// checklist and a stale-broker prompt so sessions don't fail cryptically
// when a CLI isn't installed or credentials are expired.
//
// Shape:
//
//	"readiness": {
//	  "broker_version": "<ldflags-injected tag or dev>",
//	  "node_present":   <bool>,  // termgrid sidecar availability
//	  "tmux_present":   <bool>,  // session recovery
//	  "agents": {
//	    "<name>": {
//	      "cli_present":      <bool>,
//	      "signed_in":        <bool>,
//	      "auth_expires_in_s": <int64|null>
//	    }, ...
//	  }
//	}
//
// Identity decision: signed_in is true when EITHER the box-global host-login
// credential file exists OR the per-identity pushed-credential store has the
// provider (credentials.Store.Has). The store is consulted so an
// auto-propagated box — one the app pushed a credential to over
// POST /api/agent/credentials with no host login — correctly reports
// signed_in=true instead of the misleading false that caused a 401 when a
// session was started there. The store is keyed by the broker bearer
// (single-operator); for true multi-tenant support it would key per-request
// bearer, but the wiring point (the credStore passed into buildReadiness) is
// already here.

import (
	"encoding/base64"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"sync"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/agents"
	"github.com/nikhilsh/conduit/broker/internal/session"
)

// brokerVersion is the broker's version/SHA string. Populated by
// SetBrokerVersion (called from cmd/conduit-broker/main.go via the ldflags
// -X main.version=<tag> mechanism). Defaults to "dev" when the binary is
// built without the stamp (local builds, tests).
var brokerVersion = "dev"

// SetBrokerVersion injects the broker's version/SHA string for inclusion
// in the /api/capabilities readiness block. Called from main() with the
// ldflags-injected version variable.
func SetBrokerVersion(v string) {
	if v != "" {
		brokerVersion = v
	}
}

// readinessCache caches the box-global bits (version/node/tmux/git/cli-present)
// with a ~30s TTL so repeated /api/capabilities calls don't re-stat PATH.
var readinessCache struct {
	sync.Mutex
	built     time.Time
	nodeOK    bool
	tmuxOK    bool
	gitOK     bool
	cliByName map[string]bool // keyed by adapter.Name
}

const readinessCacheTTL = 30 * time.Second

// ReadinessBlock is the JSON shape of the readiness object.
type ReadinessBlock struct {
	BrokerVersion string                    `json:"broker_version"`
	NodePresent   bool                      `json:"node_present"`
	TmuxPresent   bool                      `json:"tmux_present"`
	GitPresent    bool                      `json:"git_present"`
	Agents        map[string]AgentReadiness `json:"agents"`
}

// AgentReadiness is per-agent readiness info in the readiness block.
type AgentReadiness struct {
	CLIPresent       bool   `json:"cli_present"`
	SignedIn         bool   `json:"signed_in"`
	AuthExpiresInS   *int64 `json:"auth_expires_in_s"`           // null = API-key or no-expiry
	CredentialSource string `json:"credential_source,omitempty"` // "env", "box", or "app"
}

// credStore is the subset of *credentials.Store readiness consults: a
// presence check for an app-pushed credential. Narrow interface so tests
// can inject a stub without a real on-disk store. A nil credStore is
// treated as "no pushed credentials" (readiness falls back to host-login
// detection only).
type credStore interface {
	Has(provider string) bool
}

// buildReadiness constructs the readiness block for the current request.
// Box-global bits (node/tmux/cli) are served from a ~30s cache; per-agent
// sign-in state is always computed fresh (cheap file reads + a store stat).
//
// `creds` is the per-identity pushed-credential store (nil-safe). When a
// provider has an app-pushed credential, signed_in is reported true even
// when no host-login file exists — this is what makes an auto-propagated
// box (e.g. a freshly-connected SSH box) correctly show signed-in instead
// of the misleading signed_in:false that bit the Hostinger 401 case.
func buildReadiness(mgr *session.Manager, reg registryLister, creds credStore) ReadinessBlock {
	now := time.Now()

	readinessCache.Lock()
	stale := now.Sub(readinessCache.built) > readinessCacheTTL
	if stale {
		h := mgr.Health()
		readinessCache.nodeOK = h.SidecarExpected
		_, tmuxErr := exec.LookPath("tmux")
		readinessCache.tmuxOK = tmuxErr == nil
		_, gitErr := exec.LookPath("git")
		readinessCache.gitOK = gitErr == nil
		// cli presence per non-hidden adapter
		cli := make(map[string]bool)
		for _, name := range reg.Names() {
			a, err := reg.Get(name)
			if err != nil {
				continue
			}
			if len(a.Command) == 0 {
				continue
			}
			_, err = exec.LookPath(a.Command[0])
			cli[name] = err == nil
		}
		readinessCache.cliByName = cli
		readinessCache.built = now
	}
	nodeOK := readinessCache.nodeOK
	tmuxOK := readinessCache.tmuxOK
	gitOK := readinessCache.gitOK
	cliSnap := readinessCache.cliByName
	readinessCache.Unlock()

	agentMap := make(map[string]AgentReadiness, len(cliSnap))
	for _, name := range reg.Names() {
		a, err := reg.Get(name)
		if err != nil {
			continue
		}
		ar := AgentReadiness{CLIPresent: cliSnap[name]}
		ar.SignedIn, ar.AuthExpiresInS, ar.CredentialSource = agentSignInState(a, creds)
		agentMap[name] = ar
	}

	return ReadinessBlock{
		BrokerVersion: brokerVersion,
		NodePresent:   nodeOK,
		TmuxPresent:   tmuxOK,
		GitPresent:    gitOK,
		Agents:        agentMap,
	}
}

// registryLister is the subset of *agents.Registry used by buildReadiness.
// Having a small interface lets tests inject a stub registry.
type registryLister interface {
	Names() []string
	Get(name string) (agents.Adapter, error)
}

// agentSignInState returns (signedIn, expiresInS) for the given adapter.
//
// Priority order:
//  1. Env API key (ANTHROPIC_API_KEY / OPENAI_API_KEY via EnvPassthrough):
//     → signedIn=true, expiresInS=nil (API-key mode, no expiry).
//  2. Host credential file (~/.claude/.credentials.json, ~/.codex/auth.json
//     per adapter.ConfigDir / provider defaults): read + decode expiry.
//     Fresh → signedIn=true, expiresInS=seconds until expiry.
//     Expired (or no expiry field) → signedIn=true, expiresInS=0.
//  3. No file → signedIn=false, expiresInS=nil.
//
// Identity: the host-HOME credential file is box-global; the pushed-cred
// store (`creds`) is per-bearer-identity. Both count as signed-in.
//
// Priority is host-file first (it carries a parseable expiry) and pushed
// store second: a box that received an auto-propagated credential but has
// no host login still reports signed_in=true (expiresInS=nil — we don't
// decrypt the blob here just to surface an expiry). `creds` may be nil.
func agentSignInState(a agents.Adapter, creds credStore) (signedIn bool, expiresInS *int64, source string) {
	// 1. API-key env var → always signed-in, no expiry.
	for _, env := range a.EnvPassthrough {
		if env == "ANTHROPIC_API_KEY" || env == "OPENAI_API_KEY" {
			if v := os.Getenv(env); v != "" {
				return true, nil, "env"
			}
		}
	}

	// 2. Host credential file.
	provider := a.LoginProvider
	if provider == "" {
		return false, nil, ""
	}
	// 2a. App-pushed credential present for this identity → signed-in.
	//     Checked before the host-file read so an auto-propagated box with
	//     no host login still reports signed_in=true. Only providers the
	//     store knows (openai/anthropic) can be Has()-true; opencode and
	//     any other LoginProvider fall through to the host-file path.
	if creds != nil && creds.Has(provider) {
		return true, nil, "app"
	}
	path := hostCredFile(provider)
	if path == "" {
		return false, nil, ""
	}
	data, err := os.ReadFile(path)
	if err != nil {
		// File absent → not signed in.
		return false, nil, ""
	}
	// File present → signed in. Decode expiry from the blob.
	expMS, ok := credentialExpiryMillisForReadiness(provider, data)
	if !ok {
		// Can't parse expiry; treat as signed in with no known expiry.
		return true, nil, "box"
	}
	secsUntil := (expMS - time.Now().UnixMilli()) / 1000
	if secsUntil < 0 {
		secsUntil = 0
	}
	return true, &secsUntil, "box"
}

// hostCredFile returns the host-login credential path for the given provider.
// Mirrors session.hostCredentialFile but avoids an import cycle by
// re-implementing the trivial path derivation here. Uses CONDUIT_HOST_HOME
// for test isolation (same env var the session package uses).
func hostCredFile(provider string) string {
	home := os.Getenv("CONDUIT_HOST_HOME")
	if home == "" {
		var err error
		home, err = os.UserHomeDir()
		if err != nil || home == "" {
			return ""
		}
	}
	switch provider {
	case "anthropic":
		return home + "/.claude/.credentials.json"
	case "openai":
		return home + "/.codex/auth.json"
	case "opencode":
		// opencode stores its auth under the XDG data dir.
		return home + "/.local/share/opencode/auth.json"
	default:
		return ""
	}
}

// credentialExpiryMillisForReadiness extracts the expiry epoch-ms from
// a provider-native credential blob. Mirrors session.credentialExpiryMillis
// but lives here to avoid exporting an internal function.
//
//   - anthropic → claudeAiOauth.expiresAt (epoch ms)
//   - openai    → exp claim of tokens.access_token JWT (epoch s → ms),
//     falling back to last_refresh RFC3339 string.
//   - opencode  → file present + valid JSON → signed-in, no expiry extracted
//     (opencode auth.json is per-provider and format varies).
func credentialExpiryMillisForReadiness(provider string, data []byte) (int64, bool) {
	switch provider {
	case "anthropic":
		var blob struct {
			ClaudeAiOauth struct {
				ExpiresAt int64 `json:"expiresAt"`
			} `json:"claudeAiOauth"`
		}
		if json.Unmarshal(data, &blob) != nil || blob.ClaudeAiOauth.ExpiresAt <= 0 {
			return 0, false
		}
		return blob.ClaudeAiOauth.ExpiresAt, true
	case "openai":
		var blob struct {
			Tokens struct {
				AccessToken string `json:"access_token"`
			} `json:"tokens"`
			LastRefresh string `json:"last_refresh"`
		}
		if json.Unmarshal(data, &blob) != nil {
			return 0, false
		}
		if exp, ok := jwtExpMillis(blob.Tokens.AccessToken); ok {
			return exp, true
		}
		if t, err := time.Parse(time.RFC3339Nano, blob.LastRefresh); err == nil {
			return t.UnixMilli(), true
		}
		return 0, false
	default:
		return 0, false
	}
}

// jwtExpMillis reads the `exp` claim (epoch seconds) from a JWT payload
// without verifying the signature (ordering/display metadata only).
func jwtExpMillis(token string) (int64, bool) {
	parts := strings.Split(token, ".")
	if len(parts) < 2 {
		return 0, false
	}
	payload, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(parts[1], "="))
	if err != nil {
		return 0, false
	}
	var claims struct {
		Exp int64 `json:"exp"`
	}
	if json.Unmarshal(payload, &claims) != nil || claims.Exp <= 0 {
		return 0, false
	}
	return claims.Exp * 1000, true
}
