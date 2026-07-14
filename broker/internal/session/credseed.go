package session

import (
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/credentials"
)

// Shared-agent-credential lineage.
//
// This file implements the credential-lineage fix designed in
// docs/PLAN-AGENT-CREDENTIAL-LINEAGE.md, now the ONLY credential path. It
// shipped behind the CONDUIT_SHARED_AGENT_CREDS flag (default off), was
// flipped on the live box and verified (structural + behavioural refresh-
// cycle checks both passed), and the flag was then removed: the prior
// per-session-copy apparatus — mirrorHostCredentials(anthropic/openai) /
// credStore.Materialize into agent-home / the credfresh.go watchdog
// re-mirror — is deleted.
//
// Every session is pointed — via the CLI's own config-dir relocation env var
// (CLAUDE_CONFIG_DIR for claude, CODEX_HOME for codex) — at ONE canonical
// config directory per provider. The agent CLIs' own cross-process refresh
// coordination then governs every refresh, so the operator's host login is
// never stranded by a forked copy (the bug). Only claude (anthropic) and
// codex (openai) are in the single-use-refresh-token race; opencode /
// gemini authenticate via non-rotating env keys and are NOT touched (opencode
// keeps its own per-session mirror — mirrorOpencodeCredentials — since it is
// not relocated).
//
// Canonical layout. We keep ONE "credential lookup home" per session — a
// home-shaped directory whose provider-native subpaths hold the live
// credential:
//
//	<credLookupHome>/.claude/.credentials.json   (claude)
//	<credLookupHome>/.codex/auth.json            (codex)
//
// The relocation env vars then point at the SUBDIRS:
//
//	CLAUDE_CONFIG_DIR = <credLookupHome>/.claude
//	CODEX_HOME        = <credLookupHome>/.codex
//
// This keeps the broker-side fetchers' existing `<home>/.claude/...` /
// `<home>/.codex/...` join contract intact (they read credLookupHome) AND
// lets the seed path reuse credStore.Materialize verbatim.
//
// credLookupHome selection (Option A vs B, doc §3.4a), made ONCE per
// session over the store + host files:
//
//   - Option A — no valid app blob but a host login exists: credLookupHome
//     IS the operator's REAL $HOME (so the subdirs ARE ~/.claude / ~/.codex).
//     ZERO copy, ZERO seed: the session and the operator are the same
//     lineage by construction. The broker writes NOTHING into the host dir
//     (read-through only).
//   - Option B — a VALID (non-expired) app blob is present, OR no host
//     login: credLookupHome is a broker-owned dir <conduitRoot>/agent-cred,
//     and the canonical credential file is seeded ONCE from the app blob (if
//     any). A valid blob wins even over a host login because it may be a
//     deliberately-different account (doc §3.4 step 1 / the
//     deliberately-different-account corollary). This is also the login-less
//     SSH-bootstrap path.

// brokerOwnedCredHome is the Option-B credential lookup home under
// conduitRoot: <conduitRoot>/agent-cred. Its .claude/.codex subdirs hold the
// seeded canonical credential files.
func brokerOwnedCredHome(conduitRoot string) string {
	return filepath.Join(conduitRoot, "agent-cred")
}

// configSubdir is the provider-native config subdir name under a credential
// lookup home: ".claude" for anthropic, ".codex" for openai. "" for an
// unknown provider.
func configSubdir(provider string) string {
	switch provider {
	case "anthropic":
		return ".claude"
	case "openai":
		return ".codex"
	default:
		return ""
	}
}

// canonicalConfigEnvKey is the CLI-native config-dir relocation env var for
// `provider`. claude relocates the whole `.claude` via CLAUDE_CONFIG_DIR;
// codex relocates via CODEX_HOME. "" for providers not in the race.
func canonicalConfigEnvKey(provider string) string {
	switch provider {
	case "anthropic":
		return "CLAUDE_CONFIG_DIR"
	case "openai":
		return "CODEX_HOME"
	default:
		return ""
	}
}

// credResolution is the per-session outcome of the Option-A-vs-B selection.
type credResolution struct {
	// home is the credential lookup home (see file header). The
	// CLAUDE_CONFIG_DIR / CODEX_HOME env vars point at home/.claude,
	// home/.codex; the broker-side fetchers read those same subpaths.
	home string
	// optionA is true when home IS the operator's real $HOME (read-through,
	// no seeding). false ⇒ broker-owned Option-B home.
	optionA bool
	// seedFromBlob, per provider, is true when ensureSharedCred should seed
	// that provider's canonical file from the app blob (Option B only).
	seedFromBlob map[string]bool
	// sourceLabel, per provider, is the credential_source banner label
	// ("app_forwarded" when seeded from the pushed blob, "box" when pointing
	// at the host login, "" when neither).
	sourceLabel map[string]string
}

// raceProviders are the only providers in the single-use-refresh-token race
// that the shared-creds mechanism relocates.
func raceProviders() []string { return []string{"anthropic", "openai"} }

// resolveSharedCred performs the per-session Option-A-vs-B selection over
// the store + host files. Pure decision; it writes nothing (ensureSharedCred
// does the seed). Precedence per provider (doc §3.4):
//
//  1. Valid (non-expired) app blob present  → Option B, seed from blob.
//  2. No valid blob, host login file present → Option A (host home; no seed).
//  3. Neither                                → Option B home (empty); the
//     agent prompts /login cleanly.
//
// The HOME is a single per-session directory, so the selection across the
// two providers must agree on one home. We pick Option A (host home) only
// when NEITHER provider wants Option B (i.e. neither has a winning app
// blob); if either provider has a valid app blob we use the broker-owned
// home and seed only that provider (the other provider's canonical file is
// seeded from the host login if present, preserving the operator's box
// login for the Terminal tab).
func resolveSharedCred(conduitRoot string, store *credentials.Store) credResolution {
	res := credResolution{
		seedFromBlob: map[string]bool{},
		sourceLabel:  map[string]string{},
	}

	// Per-provider: does a valid app blob want to win (Option B)?
	blobWins := map[string]bool{}
	for _, p := range raceProviders() {
		if store != nil && store.Has(p) {
			if blob, err := store.Get(p); err == nil {
				if skip, _, _ := useHostOverAppBlob(p, blob); !skip {
					blobWins[p] = true
				}
			}
		}
	}

	anyBlob := false
	for _, p := range raceProviders() {
		if blobWins[p] {
			anyBlob = true
		}
	}

	if !anyBlob {
		// No winning app blob for either provider. If a host login exists for
		// at least one provider, use Option A (the operator's real $HOME):
		// zero-copy, read-through. (If no host login exists at all this still
		// resolves to the host home; both providers' files are simply absent
		// and the agent prompts /login — same clean outcome as today.)
		res.optionA = true
		res.home = hostHomeDir()
		for _, p := range raceProviders() {
			if hf := hostCredentialFile(p); hf != "" {
				if _, err := os.Stat(hf); err == nil {
					res.sourceLabel[p] = "box"
				}
			}
		}
		// Defensive: an unresolvable host home falls back to the broker-owned
		// home so the env vars never point at "".
		if strings.TrimSpace(res.home) == "" {
			res.optionA = false
			res.home = brokerOwnedCredHome(conduitRoot)
		}
		return res
	}

	// At least one provider has a winning app blob → broker-owned Option-B
	// home. Seed each provider's canonical file from its best source: the app
	// blob when it wins, else the host login (so the Terminal tab keeps the
	// operator's box login for the non-blob provider).
	res.optionA = false
	res.home = brokerOwnedCredHome(conduitRoot)
	for _, p := range raceProviders() {
		switch {
		case blobWins[p]:
			res.seedFromBlob[p] = true
			res.sourceLabel[p] = "app_forwarded"
		default:
			// Seed from the host login if present so the Terminal tab (and
			// this provider's own agent, if applicable) is logged in.
			// Labelled "box".
			if hf := hostCredentialFile(p); hf != "" {
				if _, err := os.Stat(hf); err == nil {
					res.sourceLabel[p] = "box"
				}
			}
		}
	}
	return res
}

// ensureSharedCred resolves the per-session credential lookup home and seeds
// the Option-B canonical credential files (idempotent atomic writes). It
// returns the resolution so the caller can point the relocation env vars at
// home/.claude, home/.codex.
//
// Option A is a strict NO-OP for the credential files: the broker never
// writes into the operator's real $HOME — the host login IS the lineage and
// the agent reads it directly.
//
// Seeding is NON-FATAL by design (doc §8 "fail-safe"): a seed error is
// returned to the caller for logging but never aborts the spawn. The agent
// prompts /login if the canonical file is absent — a clean error, no crash.
func ensureSharedCred(conduitRoot string, store *credentials.Store) (credResolution, error) {
	res := resolveSharedCred(conduitRoot, store)
	if res.optionA {
		// Read-through: never write into the operator's real $HOME.
		return res, nil
	}
	// Option B: ensure each provider's config subdir exists (0700) and seed
	// it from the blob (when it won) or the host login (otherwise).
	var firstErr error
	for _, p := range raceProviders() {
		sub := configSubdir(p)
		if sub == "" {
			continue
		}
		dir := filepath.Join(res.home, sub)
		if err := os.MkdirAll(dir, 0o700); err != nil {
			if firstErr == nil {
				firstErr = fmt.Errorf("ensureSharedCred: mkdir %s: %w", dir, err)
			}
			continue
		}
		switch {
		case res.seedFromBlob[p] && store != nil:
			// Skip re-materializing the stored blob when the canonical file on
			// disk is already fresher: the CLI refreshed its tokens there since
			// the app last pushed, and overwriting would clobber the valid
			// refresh_token with the original (now rotated/dead) one.
			if !absorbCanonicalIfFresher(p, store, res.home) {
				// Reuse Materialize: it writes <home>/.claude/.credentials.json
				// resp <home>/.codex/auth.json — exactly the canonical subpaths.
				if err := store.Materialize(p, res.home); err != nil {
					if firstErr == nil {
						firstErr = fmt.Errorf("ensureSharedCred: seed %s from blob: %w", p, err)
					}
				}
			}
		case res.sourceLabel[p] == "box":
			// No winning blob but the host is logged in → seed the canonical
			// file from the host login so the Terminal tab (and the session's
			// own agent, if this is its provider) is logged in. This is a
			// ONE-TIME seed of the shared canonical file; the agent CLI then
			// owns all subsequent refreshes of that single lineage head.
			if err := seedFromHostLogin(p, res.home); err != nil {
				if firstErr == nil {
					firstErr = fmt.Errorf("ensureSharedCred: seed %s from host: %w", p, err)
				}
			}
		}
	}
	return res, firstErr
}

// seedFromHostLogin copies the host login credential file for `provider`
// into the broker-owned credential lookup home's provider-native subpath,
// mode 0600. Best-effort: a missing host file is a no-op (the agent prompts
// /login). NOTE this is a Option-B-only seed: under Option A we never copy
// (read-through). Copying the host login into a SEPARATE broker-owned file
// does technically fork that lineage — but only on a box that ALSO has a
// winning app blob for the OTHER provider, which is a rare deliberate state;
// the operator's interactive box login is still governed by the host file,
// and the shared broker copy is refreshed by the broker sessions among
// themselves (one shared head, not N). This matches today's behaviour where
// the Terminal-tab mirror already copies the host login per session.
func seedFromHostLogin(provider, credHome string) error {
	hf := hostCredentialFile(provider)
	if hf == "" {
		return nil
	}
	data, err := os.ReadFile(hf)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	sub := configSubdir(provider)
	if sub == "" {
		return fmt.Errorf("seedFromHostLogin: unknown provider %q", provider)
	}
	var filename string
	switch provider {
	case "anthropic":
		filename = ".credentials.json"
	case "openai":
		filename = "auth.json"
	default:
		return fmt.Errorf("seedFromHostLogin: unknown provider %q", provider)
	}
	dst := filepath.Join(credHome, sub, filename)
	return atomicWriteFileMode(dst, data, 0o600)
}

// sharedCredEnvFrom builds the config-dir relocation env pairs
// (CLAUDE_CONFIG_DIR / CODEX_HOME → <home>/<subdir>) for a resolved
// credential home, for EVERY race provider — so the interactive Terminal tab
// is logged into whichever CLI the user runs. Also returns the per-provider
// canonical config dirs (used by resume staging).
func sharedCredEnvFrom(res credResolution) (env map[string]string, configDirs map[string]string) {
	env = map[string]string{}
	configDirs = map[string]string{}
	if strings.TrimSpace(res.home) == "" {
		return env, configDirs
	}
	for _, p := range raceProviders() {
		sub := configSubdir(p)
		if sub == "" {
			continue
		}
		dir := filepath.Join(res.home, sub)
		configDirs[p] = dir
		if key := canonicalConfigEnvKey(p); key != "" {
			env[key] = dir
		}
	}
	return env, configDirs
}

// seedClaudeCanonicalConfig idempotently seeds a `.claude.json`
// (theme/onboarding) inside a broker-owned shared CLAUDE_CONFIG_DIR. Some
// claude builds read theme/onboarding from <CLAUDE_CONFIG_DIR>/.claude.json
// rather than $HOME/.claude.json; seeding both is cheap and covers either
// build (doc §3.3 note). NO-OP under Option A (the dir is the operator's
// real ~/.claude, whose .claude.json already has onboarding done — and we
// never write into the host dir). Best-effort.
func seedClaudeCanonicalConfig(res credResolution) error {
	if res.optionA {
		return nil
	}
	dir := filepath.Join(res.home, ".claude")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	// seedClaudeConfig writes <ephemeralHome>/.claude.json; here the config
	// dir itself is the target, so write <dir>/.claude.json directly via a
	// tiny inline merge mirroring seedClaudeConfig's keys. Reuse by passing a
	// home whose ".claude.json" lands inside <dir>: seedClaudeConfig expects
	// the HOME and appends ".claude.json", so pass `dir` as the home — the
	// file becomes <dir>/.claude.json, which is what some builds read.
	return seedClaudeConfig(dir)
}

// SeedSharedCredentialsAtStartup ensures the canonical credential files for
// all known providers exist and are populated from the credential store at
// broker startup. Best-effort: any error is logged but never fatal.
//
// Without this the canonical files are only seeded on the first session spawn.
// Seeding at startup means broker-side fetchers (account usage, quick replies)
// that run before the first session already read the fresh canonical file.
//
// This is an exported entry point for cmd/conduit-broker/main.go; the session
// package must not import the main package, so the call flows outward.
func SeedSharedCredentialsAtStartup(conduitRoot string, store *credentials.Store) {
	if _, err := ensureSharedCred(conduitRoot, store); err != nil {
		// Non-fatal. Each session spawn also calls ensureSharedCred.
		fmt.Fprintf(os.Stderr, "startup: ensureSharedCred: %v (credentials will be seeded on first session spawn)\n", err)
	}
}

// credentialExpirySlack is how close to (or past) expiry a credential must
// be before we consider it stale enough for the host login to win over it.
// Mirrors the 30s guard in readClaudeOAuthToken but wider, since the
// replacement path is cheap and the failure mode (an agent stuck on 401) is
// expensive.
const credentialExpirySlack = 2 * time.Minute

// credentialExpiryMillis extracts a comparable expiry (epoch ms) from a
// provider-native credential blob:
//
//   - anthropic → `claudeAiOauth.expiresAt` (already epoch ms)
//   - openai    → the `exp` claim of `tokens.access_token` (JWT,
//     unverified decode — ordering metadata only, never an auth
//     decision), falling back to `last_refresh` when the token has no
//     parseable exp. Both orderings agree on "newer is fresher".
//
// ok=false means the blob carries no usable expiry (malformed JSON,
// missing fields); callers treat that as "assume stale".
func credentialExpiryMillis(provider string, data []byte) (int64, bool) {
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
		if exp, ok := jwtExpiryMillis(blob.Tokens.AccessToken); ok {
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

// jwtExpiryMillis reads the `exp` claim (epoch seconds) out of a JWT
// payload without verifying the signature — display/ordering metadata
// only, same trust posture as the apps' plan-badge decode.
func jwtExpiryMillis(token string) (int64, bool) {
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

// hostCredentialFile is the host-login counterpart of the canonical file:
// where claude / codex stash the operator's credential when they log in
// interactively. "" when the provider is unknown or the host home can't be
// resolved.
func hostCredentialFile(provider string) string {
	host := hostHomeDir()
	if host == "" {
		return ""
	}
	switch provider {
	case "anthropic":
		return filepath.Join(host, ".claude", ".credentials.json")
	case "openai":
		return filepath.Join(host, ".codex", "auth.json")
	default:
		return ""
	}
}

// sessionCredentialFile is where a provider's credential lives inside a
// credential lookup home (ephemeral or canonical) at its provider-native
// subpath — same layout Materialize / mirrorHostCredentials used to write
// and ensureSharedCred / absorbCanonicalIfFresher read today.
func sessionCredentialFile(provider, credHome string) string {
	switch provider {
	case "anthropic":
		return filepath.Join(credHome, ".claude", ".credentials.json")
	case "openai":
		return filepath.Join(credHome, ".codex", "auth.json")
	default:
		return ""
	}
}

// useHostOverAppBlob decides at seed time whether the app-pushed OAuth blob
// should be skipped in favour of the host login: only when the blob is
// expired (or carries no parseable expiry) AND the host file is strictly
// fresher. A valid blob always wins — it may be a deliberately different
// account than the box login.
func useHostOverAppBlob(provider string, blob []byte) (skip bool, blobExp, hostExp int64) {
	blobExp, blobOK := credentialExpiryMillis(provider, blob)
	if blobOK && blobExp > time.Now().Add(credentialExpirySlack).UnixMilli() {
		return false, blobExp, 0
	}
	hostData, err := os.ReadFile(hostCredentialFile(provider))
	if err != nil {
		return false, blobExp, 0
	}
	hostExp, hostOK := credentialExpiryMillis(provider, hostData)
	if !hostOK || hostExp <= blobExp {
		return false, blobExp, hostExp
	}
	return true, blobExp, hostExp
}

// absorbCanonicalIfFresher checks whether the on-disk canonical credential
// file (at sessionCredentialFile(provider, credHome)) is fresher than the
// stored blob. If so it writes the on-disk data back into the store — so
// future restarts see the CLI-refreshed lineage — and returns true (the
// caller should skip materializing the stale blob). Returns false when the
// blob is fresher or equal, or the on-disk file is absent/unreadable.
//
// This guards the ensureSharedCred seed path against the restart footgun:
// the Claude CLI refreshes tokens directly into the canonical file
// (Anthropic rotates the refresh token on every use), so re-materializing
// the stored blob after a restart would clobber the valid refresh token with
// a dead one.
func absorbCanonicalIfFresher(provider string, store *credentials.Store, credHome string) bool {
	path := sessionCredentialFile(provider, credHome)
	if path == "" {
		return false
	}
	diskData, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	blobData, err := store.Get(provider)
	if err != nil {
		return false
	}
	diskExp, diskOK := credentialExpiryMillis(provider, diskData)
	blobExp, blobOK := credentialExpiryMillis(provider, blobData)
	if !diskOK || !blobOK || diskExp <= blobExp {
		return false
	}
	// On-disk is fresher: absorb into store (best-effort; skip is
	// unconditional so a Set failure doesn't trigger an overwrite).
	if err := store.Set(provider, json.RawMessage(diskData)); err != nil {
		fmt.Fprintf(os.Stderr, "credentials: absorb fresher %s canonical into store: %v\n", provider, err)
	}
	return true
}
