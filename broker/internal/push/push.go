// Package push is the broker foundation for Package 5 — remote push
// notifications + background wake. It owns a per-identity device-token
// registry and a transport-agnostic Notifier interface. The WS
// `register_push_token` handler feeds the registry; broker events
// (turn-complete, pending-input) fan out through a Notifier.
//
// This first slice ships the registry + interface + a no-op Notifier so
// the rest of the broker can depend on a stable surface. The concrete
// APNs (iOS) and FCM (Android) senders, the WS registration handler, and
// the event triggers land in follow-up PRs — none of which change this
// package's public shape.
package push

import (
	"context"
	"encoding/json"
	"log"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// Platform is the push transport a device token belongs to.
type Platform string

const (
	// PlatformAPNs is Apple Push Notification service (iOS).
	PlatformAPNs Platform = "apns"
	// PlatformFCM is Firebase Cloud Messaging (Android fallback via relay).
	PlatformFCM Platform = "fcm"
	// PlatformUnifiedPush is a self-hosted UnifiedPush distributor (Android
	// purist path — no vendor hop). The DeviceToken.Token is the distributor
	// endpoint URL the app registered.
	PlatformUnifiedPush Platform = "unifiedpush"
	// PlatformAPNsLiveActivityStart is the ActivityKit push-to-start token
	// (iOS 17.2+). Unlike the per-session LA update token (stored in
	// LARegistry), this is device-scoped (one per Activity type per device),
	// session-less, and persisted across broker restarts so a backgrounded
	// approval can start a Live Activity card even after a broker bounce.
	// Wire value must match the iOS POST /api/push/register-start platform field.
	PlatformAPNsLiveActivityStart Platform = "apns-liveactivity-start"
)

// ValidPlatform reports whether p is a transport the broker knows how to
// route to. Unknown platforms are rejected at registration time so a
// typo'd client doesn't silently never receive pushes.
func ValidPlatform(p Platform) bool {
	return p == PlatformAPNs || p == PlatformFCM || p == PlatformUnifiedPush ||
		p == PlatformAPNsLiveActivityStart
}

// DeviceToken is one registered device endpoint for an identity.
type DeviceToken struct {
	Platform Platform
	// Token is the opaque APNs/FCM device token. Treated as a unique
	// key per (identity, platform) — re-registering the same token is a
	// no-op, and a device that rotates its token registers the new one
	// (the stale one is reaped lazily on a failed send by the caller).
	Token string
	// DeviceID is the stable per-install UUID the app sends on
	// register/test/create to enable per-device push targeting.
	// Optional: empty for tokens registered by old clients; those tokens
	// participate only in broadcast Notify, never in NotifyDevice.
	DeviceID string `json:"device_id,omitempty"`
}

// Payload is the transport-agnostic notification the broker wants
// delivered. Concrete senders map this onto APNs `aps` / FCM `notification`
// shapes. SessionID lets the app deep-link straight to the session.
type Payload struct {
	Title     string
	Body      string
	SessionID string
	// Category, when set, routes through the relay's category-specific path.
	// "liveactivity" causes the relay to emit an APNs Live Activity push instead
	// of a standard alert. Empty = alert (default).
	Category string
	// ContentState is the Live Activity content-state object (category="liveactivity"
	// only). The relay forwards it verbatim into aps."content-state". Keys match the
	// iOS TurnActivityContentState Codable — see the shared contract in
	// docs/push-la-spec.md. Nil for alert pushes.
	ContentState map[string]any
	// Event is the APNs Live Activity event type: "update", "end", or "start".
	// Only used when Category="liveactivity".
	Event string
	// AttributesType is the ActivityKit attributes type name for push-to-start.
	// MUST be exactly "TurnActivityAttributes" — the OS uses this to route the
	// start push to the correct Activity type. A typo is rejected silently.
	// Only used when Event="start".
	AttributesType string
	// Attributes is the static attributes payload for push-to-start.
	// Keys MUST be exactly "agentName", "sessionID", "sessionName" to match the
	// TurnActivityAttributes struct property names. Only used when Event="start".
	Attributes map[string]any
	// Alert is the APNs alert block required by Apple for push-to-start.
	// Contains "title" and "body" keys. Only used when Event="start".
	Alert map[string]any
}

// LARegistry is a thread-safe per-(identity,session) Live Activity push-token
// store. Separate from the main alert Registry: LA tokens are session-scoped
// (one per session, replaced on update, dropped on turn-end) rather than
// device-global. Zero value is not usable; call NewLARegistry.
type LARegistry struct {
	mu sync.Mutex
	// (identity, session_id) -> token
	tokens map[laKey]string
}

type laKey struct {
	Identity  string
	SessionID string
}

// NewLARegistry returns an empty in-memory LA token store.
func NewLARegistry() *LARegistry {
	return &LARegistry{tokens: make(map[laKey]string)}
}

// SetLA stores or replaces the LA token for (identity, sessionID). An empty
// token is accepted and clears any existing entry (same as DropLA).
func (r *LARegistry) SetLA(identity, sessionID, token string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	k := laKey{Identity: identity, SessionID: sessionID}
	if token == "" {
		delete(r.tokens, k)
		return
	}
	r.tokens[k] = token
}

// GetLA returns the registered LA token for (identity, sessionID), or ""
// if none is registered.
func (r *LARegistry) GetLA(identity, sessionID string) string {
	r.mu.Lock()
	defer r.mu.Unlock()
	return r.tokens[laKey{Identity: identity, SessionID: sessionID}]
}

// DropLA removes the LA token for (identity, sessionID). Safe to call when
// no token is registered (no-op).
func (r *LARegistry) DropLA(identity, sessionID string) {
	r.mu.Lock()
	defer r.mu.Unlock()
	delete(r.tokens, laKey{Identity: identity, SessionID: sessionID})
}

// Notifier delivers a Payload to every device registered for an identity.
// Implementations must be safe for concurrent use and must not block the
// caller on slow network sends beyond ctx.
type Notifier interface {
	Notify(ctx context.Context, identity string, payload Payload) error
}

// Registry is a thread-safe per-identity device-token store. Zero value
// is not usable; call NewRegistry.
type Registry struct {
	mu sync.RWMutex
	// identity -> set of "<platform>\x00<token>" -> DeviceToken
	byIdentity  map[string]map[string]DeviceToken
	persistPath string // empty = no persistence
}

// NewRegistry returns an empty in-memory registry (no persistence).
func NewRegistry() *Registry {
	return &Registry{byIdentity: make(map[string]map[string]DeviceToken)}
}

// NewRegistryWithPersistence returns a Registry backed by a JSON file at
// path. Existing tokens are loaded from the file on construction; on
// every Register/Unregister call the file is rewritten atomically at
// mode 0600. An error loading the file is logged but not fatal — the
// registry starts empty rather than refusing to start.
func NewRegistryWithPersistence(path string) *Registry {
	r := &Registry{
		byIdentity:  make(map[string]map[string]DeviceToken),
		persistPath: path,
	}
	if err := r.load(); err != nil && !os.IsNotExist(err) {
		log.Printf("push registry: load %s: %v (starting empty)", path, err)
	}
	return r
}

// persistSnapshot is the on-disk representation. Using a simple slice of
// {identity, tokens} pairs is enough — the registry is small (one entry
// per paired device).
type persistSnapshot struct {
	Tokens []persistEntry `json:"tokens"`
}

type persistEntry struct {
	Identity string        `json:"identity"`
	Tokens   []DeviceToken `json:"tokens"`
}

// load reads the JSON snapshot from r.persistPath into r.byIdentity.
// Caller must NOT hold r.mu.
func (r *Registry) load() error {
	if r.persistPath == "" {
		return nil
	}
	data, err := os.ReadFile(r.persistPath)
	if err != nil {
		return err
	}
	var snap persistSnapshot
	if err := json.Unmarshal(data, &snap); err != nil {
		return err
	}
	for _, e := range snap.Tokens {
		set := make(map[string]DeviceToken, len(e.Tokens))
		for _, t := range e.Tokens {
			set[key(t)] = t
		}
		r.byIdentity[e.Identity] = set
	}
	return nil
}

// save writes r.byIdentity to r.persistPath atomically.
// Caller must hold r.mu (at least RLock). Errors are logged, not fatal.
func (r *Registry) save() {
	if r.persistPath == "" {
		return
	}
	snap := persistSnapshot{}
	for identity, set := range r.byIdentity {
		tokens := make([]DeviceToken, 0, len(set))
		for _, t := range set {
			tokens = append(tokens, t)
		}
		snap.Tokens = append(snap.Tokens, persistEntry{
			Identity: identity,
			Tokens:   tokens,
		})
	}
	data, err := json.Marshal(snap)
	if err != nil {
		log.Printf("push registry: marshal for persist: %v", err)
		return
	}
	dir := filepath.Dir(r.persistPath)
	tmp, err := os.CreateTemp(dir, ".push-tokens-*.tmp")
	if err != nil {
		log.Printf("push registry: create temp: %v", err)
		return
	}
	tmpPath := tmp.Name()
	if _, werr := tmp.Write(data); werr != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		log.Printf("push registry: write temp: %v", werr)
		return
	}
	if err := tmp.Chmod(0o600); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		log.Printf("push registry: chmod temp: %v", err)
		return
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		log.Printf("push registry: close temp: %v", err)
		return
	}
	if err := os.Rename(tmpPath, r.persistPath); err != nil {
		_ = os.Remove(tmpPath)
		log.Printf("push registry: rename to %s: %v", r.persistPath, err)
	}
}

func key(t DeviceToken) string {
	return string(t.Platform) + "\x00" + t.Token
}

// Register records a device token for identity. Returns false (and does
// nothing) for an empty identity/token or an unknown platform, so callers
// can surface a clean rejection. Re-registering an identical token is an
// idempotent success.
func (r *Registry) Register(identity string, token DeviceToken) bool {
	identity = strings.TrimSpace(identity)
	token.Token = strings.TrimSpace(token.Token)
	if identity == "" || token.Token == "" || !ValidPlatform(token.Platform) {
		return false
	}
	r.mu.Lock()
	defer r.mu.Unlock()
	set := r.byIdentity[identity]
	if set == nil {
		set = make(map[string]DeviceToken)
		r.byIdentity[identity] = set
	}
	set[key(token)] = token
	r.save()
	return true
}

// Unregister drops a device token for identity (e.g. on logout or a 410
// from APNs). Safe to call for tokens that were never registered.
func (r *Registry) Unregister(identity string, token DeviceToken) {
	r.mu.Lock()
	defer r.mu.Unlock()
	set := r.byIdentity[identity]
	if set == nil {
		return
	}
	delete(set, key(token))
	if len(set) == 0 {
		delete(r.byIdentity, identity)
	}
	r.save()
}

// TokensFor returns the device tokens registered for identity, sorted
// (platform, token) for deterministic fan-out. Never nil.
func (r *Registry) TokensFor(identity string) []DeviceToken {
	r.mu.RLock()
	defer r.mu.RUnlock()
	set := r.byIdentity[identity]
	out := make([]DeviceToken, 0, len(set))
	for _, t := range set {
		out = append(out, t)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Platform != out[j].Platform {
			return out[i].Platform < out[j].Platform
		}
		return out[i].Token < out[j].Token
	})
	return out
}

// TokensForDevice returns the device tokens registered for identity whose
// DeviceID matches deviceID. Returns nil when no match is found. Sorted
// deterministically (platform, token) like TokensFor.
func (r *Registry) TokensForDevice(identity, deviceID string) []DeviceToken {
	if deviceID == "" {
		return nil
	}
	r.mu.RLock()
	defer r.mu.RUnlock()
	set := r.byIdentity[identity]
	var out []DeviceToken
	for _, t := range set {
		if t.DeviceID == deviceID {
			out = append(out, t)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Platform != out[j].Platform {
			return out[i].Platform < out[j].Platform
		}
		return out[i].Token < out[j].Token
	})
	return out
}

// StartTokenFor returns the push-to-start token registered for identity
// (the PlatformAPNsLiveActivityStart token), or "" if none is registered.
// The start token is device-scoped (not session-scoped) and is stored in
// this persisted Registry so it survives broker restarts.
func (r *Registry) StartTokenFor(identity string) string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	set := r.byIdentity[identity]
	for _, t := range set {
		if t.Platform == PlatformAPNsLiveActivityStart {
			return t.Token
		}
	}
	return ""
}

// NoopNotifier is the default Notifier wired into the broker until the
// APNs/FCM senders land. It performs no network I/O and never errors, so
// the event-trigger call sites can be exercised end-to-end before any
// push credentials are configured.
type NoopNotifier struct{}

// Notify is a no-op; it never errors.
func (NoopNotifier) Notify(_ context.Context, _ string, _ Payload) error {
	return nil
}
