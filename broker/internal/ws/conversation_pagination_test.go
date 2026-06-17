package ws

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/nikhilsh/conduit/broker/internal/session"
)

// writeTestConvLog creates a conversation.jsonl file under
// <conduitRoot>/sessions/<id>/conversation.jsonl with n entries whose
// timestamps are spaced 1 minute apart starting at a fixed epoch.
// Returns (conduitRoot, sessionID, entries) so callers can derive cursors.
func writeTestConvLog(t *testing.T, n int) (conduitRoot string, sessionID string, entries []session.ConvEntry) {
	t.Helper()
	root := t.TempDir()
	conduitRoot = filepath.Join(root, ".conduit")
	sessionID = "test-session-abc123"
	dir := filepath.Join(conduitRoot, "sessions", sessionID)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	f, err := os.Create(filepath.Join(dir, "conversation.jsonl"))
	if err != nil {
		t.Fatalf("create convlog: %v", err)
	}
	defer f.Close()

	for i := 0; i < n; i++ {
		e := session.ConvEntry{
			Role:    "user",
			Content: fmt.Sprintf("msg %d", i+1),
			Ts:      base.Add(time.Duration(i) * time.Minute).UTC().Format(time.RFC3339Nano),
		}
		entries = append(entries, e)
		b, _ := json.Marshal(e)
		_, _ = fmt.Fprintf(f, "%s\n", b)
	}
	return conduitRoot, sessionID, entries
}

// tsMs returns the unix-millisecond timestamp for entry index i in a
// writeTestConvLog(n) transcript.
func tsMs(i int) int64 {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return base.Add(time.Duration(i) * time.Minute).UnixMilli()
}

// convResp is the decoded body of GET /api/session/conversation/<id>.
type convResp struct {
	Items         []session.ConvEntry `json:"items"`
	HasMoreBefore bool                `json:"has_more_before"`
	OldestTs      int64               `json:"oldest_ts"`
	LatestTs      int64               `json:"latest_ts"`
}

func getConversation(t *testing.T, srvURL, tok, sessionID string, extra url.Values) convResp {
	t.Helper()
	u := srvURL + "/api/session/conversation/" + sessionID + "?token=" + url.QueryEscape(tok)
	for k, vs := range extra {
		for _, v := range vs {
			u += "&" + k + "=" + url.QueryEscape(v)
		}
	}
	resp, err := http.Get(u)
	if err != nil {
		t.Fatalf("GET conversation: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET conversation status=%d", resp.StatusCode)
	}
	var cr convResp
	if err := json.NewDecoder(resp.Body).Decode(&cr); err != nil {
		t.Fatalf("decode: %v", err)
	}
	return cr
}

// TestConversationPagination_Full verifies that the full transcript is returned
// when no pagination params are given, and that the new pagination fields are
// present with correct zero-values (no "more" at the boundary).
func TestConversationPagination_Full(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 5)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)
	cr := getConversation(t, srv.URL, tok, sessionID, nil)

	if len(cr.Items) != 5 {
		t.Fatalf("full: want 5 items, got %d", len(cr.Items))
	}
	if cr.HasMoreBefore {
		t.Error("full: HasMoreBefore should be false")
	}
	if cr.OldestTs != tsMs(0) {
		t.Errorf("full: OldestTs want %d got %d", tsMs(0), cr.OldestTs)
	}
	if cr.LatestTs != tsMs(4) {
		t.Errorf("full: LatestTs want %d got %d", tsMs(4), cr.LatestTs)
	}
}

// TestConversationPagination_Tail verifies tail=N returns the last N messages
// and sets HasMoreBefore=true when the transcript is longer.
func TestConversationPagination_Tail(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 10)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)
	cr := getConversation(t, srv.URL, tok, sessionID, url.Values{"tail": {"3"}})

	if len(cr.Items) != 3 {
		t.Fatalf("tail=3: want 3 items, got %d", len(cr.Items))
	}
	if cr.Items[0].Content != "msg 8" || cr.Items[2].Content != "msg 10" {
		t.Errorf("tail=3: unexpected items %v %v %v",
			cr.Items[0].Content, cr.Items[1].Content, cr.Items[2].Content)
	}
	if !cr.HasMoreBefore {
		t.Error("tail=3 on 10 items: expected HasMoreBefore=true")
	}
	if cr.OldestTs != tsMs(7) {
		t.Errorf("tail=3: OldestTs want %d got %d", tsMs(7), cr.OldestTs)
	}
	if cr.LatestTs != tsMs(9) {
		t.Errorf("tail=3: LatestTs want %d got %d", tsMs(9), cr.LatestTs)
	}
}

// TestConversationPagination_BeforeTs verifies before_ts returns items strictly
// older than the cursor, limited to the page size.
func TestConversationPagination_BeforeTs(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 10)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)

	// Fetch 3 items older than msg 6 (index 5).
	// Items strictly before tsMs(5): indices 0–4 = msgs 1–5.
	// limit=3 → last 3 of those → msgs 3,4,5 (indices 2,3,4). HasMore=true.
	cursor := fmt.Sprintf("%d", tsMs(5))
	cr := getConversation(t, srv.URL, tok, sessionID,
		url.Values{"before_ts": {cursor}, "limit": {"3"}})

	if len(cr.Items) != 3 {
		t.Fatalf("before_ts limit=3: want 3 items, got %d", len(cr.Items))
	}
	if cr.Items[0].Content != "msg 3" || cr.Items[2].Content != "msg 5" {
		t.Errorf("before_ts limit=3: unexpected items %v %v %v",
			cr.Items[0].Content, cr.Items[1].Content, cr.Items[2].Content)
	}
	if !cr.HasMoreBefore {
		t.Error("before_ts limit=3: expected HasMoreBefore=true")
	}
	if cr.OldestTs != tsMs(2) {
		t.Errorf("before_ts: OldestTs want %d got %d", tsMs(2), cr.OldestTs)
	}
}

// TestConversationPagination_BeforeTs_StartOfHistory verifies that
// HasMoreBefore==false at the very start of the transcript.
func TestConversationPagination_BeforeTs_StartOfHistory(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 5)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)

	// before_ts = tsMs(3) → items older than msg 4 = msgs 1,2,3. limit=10 → all fit.
	cursor := fmt.Sprintf("%d", tsMs(3))
	cr := getConversation(t, srv.URL, tok, sessionID,
		url.Values{"before_ts": {cursor}, "limit": {"10"}})

	if len(cr.Items) != 3 {
		t.Fatalf("start-of-history: want 3 items, got %d", len(cr.Items))
	}
	if cr.HasMoreBefore {
		t.Error("start-of-history: expected HasMoreBefore=false")
	}
	if cr.Items[0].Content != "msg 1" {
		t.Errorf("start-of-history: first item = %q, want msg 1", cr.Items[0].Content)
	}
	if cr.OldestTs != tsMs(0) {
		t.Errorf("start-of-history: OldestTs want %d got %d", tsMs(0), cr.OldestTs)
	}
}

// TestConversationPagination_SinceTs verifies since_ts still works exactly as
// before: items strictly newer than the cursor are returned with
// HasMoreBefore==false.
func TestConversationPagination_SinceTs(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 10)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)

	// since_ts = tsMs(6) = msg 7. Items strictly after: msgs 8,9,10.
	cursor := fmt.Sprintf("%d", tsMs(6))
	cr := getConversation(t, srv.URL, tok, sessionID,
		url.Values{"since_ts": {cursor}})

	if len(cr.Items) != 3 {
		t.Fatalf("since_ts: want 3 items, got %d", len(cr.Items))
	}
	if cr.Items[0].Content != "msg 8" || cr.Items[2].Content != "msg 10" {
		t.Errorf("since_ts: unexpected items %v", cr.Items)
	}
	if cr.HasMoreBefore {
		t.Error("since_ts: HasMoreBefore should be false")
	}
	if cr.LatestTs != tsMs(9) {
		t.Errorf("since_ts: LatestTs want %d got %d", tsMs(9), cr.LatestTs)
	}
}

// TestConversationPagination_InvalidParams verifies 400 on bad inputs.
func TestConversationPagination_InvalidParams(t *testing.T) {
	conduitRoot, sessionID, _ := writeTestConvLog(t, 3)
	t.Setenv("CONDUIT_ROOT", conduitRoot)

	srv, tok := newTestServer(t)

	for _, tc := range []struct {
		name  string
		param string
		value string
	}{
		{"negative since_ts", "since_ts", "-1"},
		{"non-numeric since_ts", "since_ts", "abc"},
		{"zero before_ts", "before_ts", "0"},
		{"non-numeric before_ts", "before_ts", "xyz"},
		{"zero tail", "tail", "0"},
		{"zero limit", "limit", "0"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			u := srv.URL + "/api/session/conversation/" + sessionID +
				"?token=" + url.QueryEscape(tok) +
				"&" + tc.param + "=" + url.QueryEscape(tc.value)
			resp, err := http.Get(u)
			if err != nil {
				t.Fatalf("GET: %v", err)
			}
			_ = resp.Body.Close()
			if resp.StatusCode != http.StatusBadRequest {
				t.Errorf("%s=%s: want 400, got %d", tc.param, tc.value, resp.StatusCode)
			}
		})
	}
}
