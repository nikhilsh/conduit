package ws

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"sync"
	"time"
)

// chatDedupTTL bounds how long a (session, client_msg_id) pair is remembered.
// Resends after an app kill/reconnect carry the same client_msg_id; within
// this window the broker recognizes the duplicate and forwards it to the agent
// only once while still acking every copy. 10 minutes comfortably covers a
// backgrounded app reconnecting and replaying its outbox.
const chatDedupTTL = 10 * time.Minute

// dedupMaxPersist caps the number of entries written to dedup.json per session.
// At one entry per user message, 200 covers well over any realistic TTL window.
const dedupMaxPersist = 200

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

// persistSession writes the in-memory dedup entries for sessionID to
// <sessionDir>/dedup.json, capped at dedupMaxPersist entries. Called after
// accepting a new client_msg_id so a broker restart does not forget messages
// that were already delivered before the restart. Best-effort: I/O errors are
// silently swallowed so a disk hiccup never blocks the send path.
func (d *chatDedup) persistSession(sessionDir, sessionID string) {
	now := time.Now()
	d.mu.Lock()
	bySession := d.seen[sessionID]
	// Snapshot the live (non-expired) entries while holding the lock.
	type entry struct {
		id string
		ts time.Time
	}
	entries := make([]entry, 0, len(bySession))
	for id, ts := range bySession {
		if now.Sub(ts) < chatDedupTTL {
			entries = append(entries, entry{id, ts})
		}
	}
	d.mu.Unlock()

	if len(entries) == 0 {
		return
	}
	// Cap at dedupMaxPersist: drop the oldest to bound file size.
	if len(entries) > dedupMaxPersist {
		sort.Slice(entries, func(i, j int) bool {
			return entries[i].ts.Before(entries[j].ts)
		})
		entries = entries[len(entries)-dedupMaxPersist:]
	}
	// Serialize as {"<id>": "<RFC3339Nano>"} — small and human-readable.
	raw := make(map[string]string, len(entries))
	for _, e := range entries {
		raw[e.id] = e.ts.UTC().Format(time.RFC3339Nano)
	}
	data, err := json.Marshal(raw)
	if err != nil {
		return
	}
	_ = chatDedupAtomicWrite(filepath.Join(sessionDir, "dedup.json"), data)
}

// loadSession reads <sessionDir>/dedup.json and merges its entries into the
// in-memory dedup table. Only non-expired entries are loaded; existing
// in-memory entries are never overwritten (in-memory is always at least as
// fresh as disk). No-op when the file is absent or unreadable. Called when a
// WS client attaches to a session so broker-restart resends are caught.
func (d *chatDedup) loadSession(sessionDir, sessionID string) {
	data, err := os.ReadFile(filepath.Join(sessionDir, "dedup.json"))
	if err != nil {
		return // No file or unreadable — normal for new sessions.
	}
	var raw map[string]string
	if err := json.Unmarshal(data, &raw); err != nil {
		return // Corrupt file — treat as empty rather than crashing.
	}
	now := time.Now()
	d.mu.Lock()
	defer d.mu.Unlock()
	bySession := d.seen[sessionID]
	if bySession == nil {
		bySession = make(map[string]time.Time, len(raw))
		d.seen[sessionID] = bySession
	}
	for id, tsStr := range raw {
		ts, err := time.Parse(time.RFC3339Nano, tsStr)
		if err != nil || now.Sub(ts) >= chatDedupTTL {
			continue // Skip invalid or expired entries.
		}
		if _, exists := bySession[id]; !exists {
			bySession[id] = ts // Never overwrite a fresher in-memory entry.
		}
	}
}

// chatDedupAtomicWrite writes data to path via a temp-file rename so readers
// never see a torn file. Best-effort: the caller ignores the returned error.
func chatDedupAtomicWrite(path string, data []byte) error {
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}
