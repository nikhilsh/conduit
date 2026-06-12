package session

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// ConvEntry is one persisted conversation message. The shape mirrors the
// chat `view_event` payload the clients already render
// (`{role, content, ts, files}`) so the read endpoint can hand entries
// straight back without a translation layer.
type ConvEntry struct {
	Role    string          `json:"role"`
	Content string          `json:"content"`
	Ts      string          `json:"ts"`
	Files   json.RawMessage `json:"files,omitempty"`
}

// convLogger appends conversation messages to a per-session JSONL file
// (`<sessionDir>/conversation.jsonl`). Unlike the in-memory stream and
// the replay recorder — which only ever carry assistant/tool/system
// chat frames (user prompts are sent straight to the agent and never
// re-published) — this log captures BOTH sides, so an exited session's
// transcript can be re-read after the session is reaped. Concurrency:
// the publish path and the chat-send path can both append, so writes are
// mutex-guarded.
type convLogger struct {
	path string
	mu   sync.Mutex
}

func newConvLogger(path string) *convLogger {
	return &convLogger{path: path}
}

// appendRaw persists an already-encoded chat payload (the `event` object
// from a `view_event` frame — `{role, content, ts, files}`) verbatim as
// one JSONL line. No-op on a nil logger / empty path / empty payload.
//
// Needs-input/approval cards (content prefixed with pendingInputSentinel)
// are transient live state — they are re-surfaced on reconnect from the
// live pendingAsk/pendingApproval, not from the transcript. Persisting
// them would cause a REOPEN of the session to replay the sentinel line,
// which the app classifies as a live tappable card for an
// already-answered question. Skip the durable write for these events
// only; live fan-out to subscribers is unaffected.
func (l *convLogger) appendRaw(payload []byte) {
	if l == nil || l.path == "" || len(payload) == 0 {
		return
	}
	// Skip needs-input/approval cards — transient state, must not replay.
	{
		var e ConvEntry
		if json.Unmarshal(payload, &e) == nil && strings.HasPrefix(e.Content, pendingInputSentinel) {
			return
		}
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	// The session dir is created elsewhere for scrollback/meta, but be
	// defensive — a missing dir shouldn't lose the transcript silently.
	_ = os.MkdirAll(filepath.Dir(l.path), 0o700)
	f, err := os.OpenFile(l.path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return
	}
	defer f.Close()
	// One JSON object per line. payload is already compact JSON.
	_, _ = f.Write(payload)
	_, _ = f.Write([]byte("\n"))
}

// appendUser records a user-sent prompt. The publish stream only carries
// assistant/tool/system frames, so without this the persisted transcript
// would be one-sided (replies with no questions).
func (l *convLogger) appendUser(content string) {
	if l == nil || l.path == "" || content == "" {
		return
	}
	b, err := json.Marshal(ConvEntry{
		Role:    "user",
		Content: content,
		Ts:      time.Now().UTC().Format(time.RFC3339Nano),
	})
	if err != nil {
		return
	}
	l.appendRaw(b)
}

// readConvLog parses every entry from a conversation.jsonl, in order.
// Malformed lines are skipped (a crash mid-append can truncate the final
// line) so a partial file still yields a usable transcript. Returns the
// underlying os error only when the file can't be opened.
func readConvLog(path string) ([]ConvEntry, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var out []ConvEntry
	for _, line := range strings.Split(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		var e ConvEntry
		if json.Unmarshal([]byte(line), &e) == nil && e.Role != "" {
			out = append(out, e)
		}
	}
	return out, nil
}
