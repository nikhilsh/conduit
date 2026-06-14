package ws

import (
	"sync"
	"time"
)

// chatDedupTTL bounds how long a (session, client_msg_id) pair is remembered.
// Resends after an app kill/reconnect carry the same client_msg_id; within
// this window the broker recognizes the duplicate and forwards it to the agent
// only once while still acking every copy. 10 minutes comfortably covers a
// backgrounded app reconnecting and replaying its outbox.
const chatDedupTTL = 10 * time.Minute

// chatDedup remembers the client_msg_ids the broker has already forwarded to
// the agent, keyed by session, so a resend (same id) is acked but not
// re-delivered. Bounded by a TTL with lazy + periodic eviction; the id set
// lives at the broker (process) level so it survives a client reconnect (a new
// WS connection for the same session), which is exactly when resends happen.
type chatDedup struct {
	mu   sync.Mutex
	seen map[string]map[string]time.Time // sessionID -> clientMsgID -> first-seen
}

func newChatDedup() *chatDedup {
	return &chatDedup{seen: make(map[string]map[string]time.Time)}
}

// markSeen records (sessionID, clientMsgID) and reports whether it was already
// present (and still fresh). A return of true means "duplicate — ack but do
// NOT re-forward to the agent". A return of false means "new — forward it".
// Empty clientMsgID is never deduped (old clients): callers must guard.
func (d *chatDedup) markSeen(sessionID, clientMsgID string) bool {
	now := time.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	d.evictLocked(now)
	bySession := d.seen[sessionID]
	if bySession == nil {
		bySession = make(map[string]time.Time)
		d.seen[sessionID] = bySession
	}
	if ts, ok := bySession[clientMsgID]; ok && now.Sub(ts) < chatDedupTTL {
		return true
	}
	bySession[clientMsgID] = now
	return false
}

// evictLocked drops entries older than the TTL. O(n) over the live set, run on
// every markSeen; the set is tiny in practice (a handful of in-flight ids per
// session) so a sweep is cheaper than maintaining a heap. Caller holds d.mu.
func (d *chatDedup) evictLocked(now time.Time) {
	for sid, bySession := range d.seen {
		for id, ts := range bySession {
			if now.Sub(ts) >= chatDedupTTL {
				delete(bySession, id)
			}
		}
		if len(bySession) == 0 {
			delete(d.seen, sid)
		}
	}
}
