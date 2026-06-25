package push

import (
	"sync"
	"time"
)

// PresenceTracker records per-device foreground heartbeats with a TTL.
// The app calls POST /api/device/presence while foregrounded (even when
// the session WS is closed due to background throttling) so the broker
// can suppress alert pushes while the user is actively looking at the app.
// Safe for concurrent use.
type PresenceTracker struct {
	mu   sync.Mutex
	seen map[string]time.Time
}

// NewPresenceTracker allocates a ready-to-use PresenceTracker.
func NewPresenceTracker() *PresenceTracker {
	return &PresenceTracker{seen: make(map[string]time.Time)}
}

// Record notes a foreground heartbeat for deviceID at the current time.
func (p *PresenceTracker) Record(deviceID string) {
	if deviceID == "" {
		return
	}
	p.mu.Lock()
	p.seen[deviceID] = time.Now()
	p.mu.Unlock()
}

// Present returns true if a heartbeat for deviceID was received within ttl
// of the current time.
func (p *PresenceTracker) Present(deviceID string, ttl time.Duration) bool {
	if deviceID == "" {
		return false
	}
	p.mu.Lock()
	t, ok := p.seen[deviceID]
	p.mu.Unlock()
	if !ok {
		return false
	}
	return time.Since(t) < ttl
}
