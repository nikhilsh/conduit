package session

import (
	"fmt"
	"testing"
	"time"
)

// makePageEntries builds n ConvEntry values with RFC3339 timestamps spaced 1
// minute apart starting from a fixed epoch. The returned slice is ascending by
// ts. Named makePageEntries (not makeEntries) to avoid a redeclaration
// conflict with the pre-existing makeEntries helper in recap_test.go.
func makePageEntries(n int) []ConvEntry {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	out := make([]ConvEntry, n)
	for i := range out {
		out[i] = ConvEntry{
			Role:    "user",
			Content: fmt.Sprintf("msg %d", i+1),
			Ts:      base.Add(time.Duration(i) * time.Minute).UTC().Format(time.RFC3339Nano),
		}
	}
	return out
}

// pageTsMs returns the unix-millisecond timestamp of entry i (0-indexed) in a
// makePageEntries(N) slice. Named pageTsMs to avoid conflict with any tsMs
// declared in other test files within the same package.
func pageTsMs(i int) int64 {
	base := time.Date(2026, 1, 1, 0, 0, 0, 0, time.UTC)
	return base.Add(time.Duration(i) * time.Minute).UnixMilli()
}

// TestApplyPagination_Tail verifies that tail=N returns the last N items
// and sets HasMoreBefore=true when the transcript is longer.
func TestApplyPagination_Tail(t *testing.T) {
	all := makePageEntries(10) // msgs 1–10

	page := ApplyPagination(all, TranscriptPageOpts{Tail: 3})

	if len(page.Items) != 3 {
		t.Fatalf("tail=3: want 3 items, got %d", len(page.Items))
	}
	if page.Items[0].Content != "msg 8" || page.Items[2].Content != "msg 10" {
		t.Errorf("tail=3: unexpected items: %v %v %v",
			page.Items[0].Content, page.Items[1].Content, page.Items[2].Content)
	}
	if !page.HasMoreBefore {
		t.Error("tail=3 on 10 items: expected HasMoreBefore=true")
	}
	if page.OldestTs != pageTsMs(7) { // index 7 = msg 8
		t.Errorf("OldestTs want %d got %d", pageTsMs(7), page.OldestTs)
	}
	if page.LatestTs != pageTsMs(9) { // index 9 = msg 10
		t.Errorf("LatestTs want %d got %d", pageTsMs(9), page.LatestTs)
	}
}

// TestApplyPagination_Tail_Exact verifies that tail=N when N == len returns
// all items and HasMoreBefore==false.
func TestApplyPagination_Tail_Exact(t *testing.T) {
	all := makePageEntries(5)

	page := ApplyPagination(all, TranscriptPageOpts{Tail: 5})

	if len(page.Items) != 5 {
		t.Fatalf("tail=5 on 5 items: want 5, got %d", len(page.Items))
	}
	if page.HasMoreBefore {
		t.Error("tail=5 on 5 items: expected HasMoreBefore=false")
	}
}

// TestApplyPagination_BeforeTs verifies that before_ts returns messages
// strictly older than the cursor, limited to the page size cap.
func TestApplyPagination_BeforeTs(t *testing.T) {
	all := makePageEntries(10) // msgs 1–10, index 0–9

	// before_ts = pageTsMs(5) = timestamp of msg 6 (index 5).
	// Items strictly before this: indices 0–4 = msgs 1–5.
	// With limit=3: return the last 3 of those → msgs 3, 4, 5 (indices 2, 3, 4).
	cursor := pageTsMs(5)
	page := ApplyPagination(all, TranscriptPageOpts{BeforeTs: cursor, Limit: 3})

	if len(page.Items) != 3 {
		t.Fatalf("before_ts limit=3: want 3 items, got %d", len(page.Items))
	}
	if page.Items[0].Content != "msg 3" || page.Items[2].Content != "msg 5" {
		t.Errorf("before_ts limit=3: unexpected items: %v %v %v",
			page.Items[0].Content, page.Items[1].Content, page.Items[2].Content)
	}
	if !page.HasMoreBefore {
		t.Error("before_ts limit=3: expected HasMoreBefore=true (msgs 1,2 are older)")
	}
	if page.OldestTs != pageTsMs(2) { // index 2 = msg 3
		t.Errorf("OldestTs want %d got %d", pageTsMs(2), page.OldestTs)
	}
}

// TestApplyPagination_BeforeTs_StartOfHistory verifies HasMoreBefore==false
// and correct OldestTs when we reach the very beginning of the transcript.
func TestApplyPagination_BeforeTs_StartOfHistory(t *testing.T) {
	all := makePageEntries(5) // msgs 1–5, indices 0–4

	// before_ts = pageTsMs(3) = msg 4 (index 3).
	// Items strictly before: indices 0,1,2 = msgs 1,2,3 — only 3 items.
	// limit=10 → all 3 fit → HasMoreBefore=false.
	cursor := pageTsMs(3)
	page := ApplyPagination(all, TranscriptPageOpts{BeforeTs: cursor, Limit: 10})

	if len(page.Items) != 3 {
		t.Fatalf("start-of-history: want 3 items, got %d", len(page.Items))
	}
	if page.HasMoreBefore {
		t.Error("start-of-history: expected HasMoreBefore=false")
	}
	if page.Items[0].Content != "msg 1" {
		t.Errorf("start-of-history: first item = %q, want msg 1", page.Items[0].Content)
	}
	if page.OldestTs != pageTsMs(0) { // index 0 = msg 1
		t.Errorf("OldestTs want %d got %d", pageTsMs(0), page.OldestTs)
	}
}

// TestApplyPagination_SinceTs verifies the existing forward-delta behaviour
// is unchanged: items strictly newer than the cursor are returned.
func TestApplyPagination_SinceTs(t *testing.T) {
	all := makePageEntries(10)

	// since_ts = pageTsMs(6) = msg 7 (index 6).
	// Items strictly after: indices 7,8,9 = msgs 8,9,10.
	cursor := pageTsMs(6)
	page := ApplyPagination(all, TranscriptPageOpts{SinceTs: cursor})

	if len(page.Items) != 3 {
		t.Fatalf("since_ts: want 3 items, got %d", len(page.Items))
	}
	if page.Items[0].Content != "msg 8" || page.Items[2].Content != "msg 10" {
		t.Errorf("since_ts: unexpected items %v", page.Items)
	}
	// HasMoreBefore is not meaningful for a forward cursor.
	if page.HasMoreBefore {
		t.Error("since_ts: HasMoreBefore should be false")
	}
	if page.LatestTs != pageTsMs(9) {
		t.Errorf("LatestTs want %d got %d", pageTsMs(9), page.LatestTs)
	}
}

// TestApplyPagination_SinceTs_NoNewItems verifies that LatestTs is still
// returned correctly when since_ts filters out all items (no new messages).
func TestApplyPagination_SinceTs_NoNewItems(t *testing.T) {
	all := makePageEntries(5)

	// Cursor beyond all items → empty page, but LatestTs == ts of last item.
	cursor := pageTsMs(9999)
	page := ApplyPagination(all, TranscriptPageOpts{SinceTs: cursor})

	if len(page.Items) != 0 {
		t.Fatalf("since_ts beyond all: want 0 items, got %d", len(page.Items))
	}
	if page.LatestTs != pageTsMs(4) {
		t.Errorf("LatestTs want %d got %d", pageTsMs(4), page.LatestTs)
	}
}

// TestApplyPagination_Full verifies that zero opts returns the full transcript.
func TestApplyPagination_Full(t *testing.T) {
	all := makePageEntries(7)

	page := ApplyPagination(all, TranscriptPageOpts{})

	if len(page.Items) != 7 {
		t.Fatalf("full: want 7 items, got %d", len(page.Items))
	}
	if page.HasMoreBefore {
		t.Error("full: expected HasMoreBefore=false")
	}
}

// TestApplyPagination_Empty verifies zero-entry transcript returns safe empty state.
func TestApplyPagination_Empty(t *testing.T) {
	for _, opts := range []TranscriptPageOpts{
		{},
		{Tail: 5},
		{BeforeTs: pageTsMs(5)},
		{SinceTs: pageTsMs(5)},
	} {
		page := ApplyPagination(nil, opts)
		if len(page.Items) != 0 {
			t.Errorf("empty transcript: want 0 items, got %d (opts=%+v)", len(page.Items), opts)
		}
		if page.HasMoreBefore {
			t.Errorf("empty transcript: HasMoreBefore should be false (opts=%+v)", opts)
		}
		if page.LatestTs != 0 {
			t.Errorf("empty transcript: LatestTs should be 0 (opts=%+v)", opts)
		}
	}
}

// TestApplyPagination_LimitClamp verifies that limit > maxPageSize is clamped
// and that the clamp does not break HasMoreBefore logic.
func TestApplyPagination_LimitClamp(t *testing.T) {
	all := makePageEntries(10)

	// limit=9999 should be clamped to 500; 10 < 500 so all items fit.
	page := ApplyPagination(all, TranscriptPageOpts{Limit: 9999})
	if len(page.Items) != 10 {
		t.Fatalf("limit clamp: want 10 items, got %d", len(page.Items))
	}
	if page.HasMoreBefore {
		t.Error("limit clamp: HasMoreBefore should be false (all fit)")
	}
}
