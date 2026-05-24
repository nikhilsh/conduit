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
	"sort"
	"strings"
	"sync"
)

// Platform is the push transport a device token belongs to.
type Platform string

const (
	// PlatformAPNs is Apple Push Notification service (iOS).
	PlatformAPNs Platform = "apns"
	// PlatformFCM is Firebase Cloud Messaging (Android).
	PlatformFCM Platform = "fcm"
)

// ValidPlatform reports whether p is a transport the broker knows how to
// route to. Unknown platforms are rejected at registration time so a
// typo'd client doesn't silently never receive pushes.
func ValidPlatform(p Platform) bool {
	return p == PlatformAPNs || p == PlatformFCM
}

// DeviceToken is one registered device endpoint for an identity.
type DeviceToken struct {
	Platform Platform
	// Token is the opaque APNs/FCM device token. Treated as a unique
	// key per (identity, platform) — re-registering the same token is a
	// no-op, and a device that rotates its token registers the new one
	// (the stale one is reaped lazily on a failed send by the caller).
	Token string
}

// Payload is the transport-agnostic notification the broker wants
// delivered. Concrete senders map this onto APNs `aps` / FCM `notification`
// shapes. SessionID lets the app deep-link straight to the session.
type Payload struct {
	Title     string
	Body      string
	SessionID string
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
	byIdentity map[string]map[string]DeviceToken
}

// NewRegistry returns an empty registry.
func NewRegistry() *Registry {
	return &Registry{byIdentity: make(map[string]map[string]DeviceToken)}
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

// NoopNotifier is the default Notifier wired into the broker until the
// APNs/FCM senders land. It performs no network I/O and never errors, so
// the event-trigger call sites can be exercised end-to-end before any
// push credentials are configured.
type NoopNotifier struct{}

// Notify is a no-op; it never errors.
func (NoopNotifier) Notify(_ context.Context, _ string, _ Payload) error {
	return nil
}
