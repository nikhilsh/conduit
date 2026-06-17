package session

// TranscriptPageOpts carries the backward-pagination parameters parsed from
// the query string. Zero values mean "apply no filtering" (full transcript).
//
// Pagination semantics:
//
//	tail=N        — initial bottom-anchored load: return the most recent N
//	                messages. Applied BEFORE before_ts filtering.
//	before_ts=T   — cursor for older-page fetches: return up to Limit messages
//	                whose timestamp is STRICTLY less than T (unix milliseconds).
//	limit=N       — maximum number of items in a single page (default 80,
//	                clamp 1–500). When limit is 0 the caller wants all items
//	                (tail= is still honoured).
//
// Interaction rules:
//
//   - If Tail > 0 and BeforeTs == 0: return the last min(Tail, N) items.
//   - If BeforeTs > 0: filter to items older than BeforeTs, then cap to Limit.
//     Tail is ignored when BeforeTs is set (the two cursors are mutually
//     exclusive — BeforeTs is for subsequent pages, Tail is for the first).
//   - If both are zero: return all items (respecting Limit when > 0).
type TranscriptPageOpts struct {
	// SinceTs is the existing forward-delta cursor (unix milliseconds).
	// When non-zero, only items STRICTLY NEWER than this value are returned.
	// Incompatible with BeforeTs; BeforeTs takes precedence.
	SinceTs int64

	// Tail requests the last N items (initial bottom-anchored load).
	// Honoured only when BeforeTs == 0 and SinceTs == 0.
	Tail int

	// BeforeTs is the cursor for older-page fetches.
	// When non-zero, only items STRICTLY OLDER than this value are returned.
	BeforeTs int64

	// Limit caps the page size. 0 = unlimited. Clamped to [1, 500].
	Limit int
}

// TranscriptPage is the result of ApplyPagination.
type TranscriptPage struct {
	// Items is the result page in ASCENDING timestamp order.
	Items []ConvEntry

	// HasMoreBefore is true when older messages exist beyond this page
	// (i.e. the history was not fully returned). Clients should keep
	// fetching with before_ts=OldestTs until HasMoreBefore==false.
	HasMoreBefore bool

	// OldestTs is the unix-millisecond timestamp of the earliest item in
	// Items, or 0 when Items is empty. Use this as the next before_ts
	// cursor to load the preceding page.
	OldestTs int64

	// LatestTs is the unix-millisecond timestamp of the newest item across
	// ALL items (not just this page). Returned so polling clients can advance
	// their since_ts cursor even when a since_ts request returns no items.
	// 0 when the full transcript is empty.
	LatestTs int64
}

const (
	defaultPageSize = 80
	maxPageSize     = 500
)

// ApplyPagination applies TranscriptPageOpts to a full, chronologically
// ordered transcript slice and returns a TranscriptPage.
//
// all must be in ascending time order (as readConvLog produces).
// Items with an unparseable Ts field are treated as having ts==0 and are
// included in SinceTs==0 / BeforeTs==0 queries but skipped in filtered ones.
func ApplyPagination(all []ConvEntry, opts TranscriptPageOpts) TranscriptPage {
	// Compute LatestTs across the FULL transcript (mirrors ExternalTranscriptSince).
	var latestTs int64
	for _, e := range all {
		if t := parseTimestamp(e.Ts); !t.IsZero() {
			if ms := t.UnixMilli(); ms > latestTs {
				latestTs = ms
			}
		}
	}

	// Resolve effective limit.
	limit := opts.Limit
	if limit <= 0 {
		limit = 0 // unlimited unless tail/before_ts need it
	}
	if limit > maxPageSize {
		limit = maxPageSize
	}

	switch {
	case opts.BeforeTs > 0:
		// Older-page fetch: collect items STRICTLY before BeforeTs, cap to limit.
		return applyBeforeTs(all, opts.BeforeTs, effectiveLimit(limit), latestTs)

	case opts.SinceTs > 0:
		// Forward-delta poll: items STRICTLY after SinceTs (existing behaviour).
		return applySinceTs(all, opts.SinceTs, latestTs)

	case opts.Tail > 0:
		// Initial bottom-anchored load: last N items.
		tail := opts.Tail
		if limit > 0 && tail > limit {
			tail = limit
		}
		return applyTail(all, tail, latestTs)

	default:
		// Full transcript, optionally capped to limit.
		return applyFull(all, limit, latestTs)
	}
}

// effectiveLimit returns limit, substituting defaultPageSize when limit==0.
func effectiveLimit(limit int) int {
	if limit <= 0 {
		return defaultPageSize
	}
	return limit
}

// applyBeforeTs returns up to limit items STRICTLY before beforeTs (ms),
// in ascending order. HasMoreBefore is true when further older items exist.
func applyBeforeTs(all []ConvEntry, beforeTs int64, limit int, latestTs int64) TranscriptPage {
	// Collect items with ts < beforeTs.
	var candidates []ConvEntry
	for _, e := range all {
		t := parseTimestamp(e.Ts)
		if t.IsZero() {
			// Item has no parseable timestamp — skip in cursor-paginated mode
			// to avoid undetermined ordering.
			continue
		}
		if t.UnixMilli() < beforeTs {
			candidates = append(candidates, e)
		}
	}

	// candidates is ascending. We want the LAST `limit` of them (the ones
	// closest to beforeTs), with HasMoreBefore==true if there are even
	// older ones beyond what we return.
	var (
		page          []ConvEntry
		hasMoreBefore bool
	)
	if len(candidates) <= limit {
		page = candidates
	} else {
		page = candidates[len(candidates)-limit:]
		hasMoreBefore = true
	}

	var oldestTs int64
	if len(page) > 0 {
		if t := parseTimestamp(page[0].Ts); !t.IsZero() {
			oldestTs = t.UnixMilli()
		}
	}
	items := page
	if items == nil {
		items = []ConvEntry{}
	}
	return TranscriptPage{
		Items:         items,
		HasMoreBefore: hasMoreBefore,
		OldestTs:      oldestTs,
		LatestTs:      latestTs,
	}
}

// applySinceTs returns all items STRICTLY after sinceTs (ms) — unchanged
// from the existing since_ts behaviour. HasMoreBefore is always false
// (since_ts is a forward cursor, not a backward page).
func applySinceTs(all []ConvEntry, sinceTs int64, latestTs int64) TranscriptPage {
	var items []ConvEntry
	for _, e := range all {
		t := parseTimestamp(e.Ts)
		if t.IsZero() {
			continue
		}
		if t.UnixMilli() > sinceTs {
			items = append(items, e)
		}
	}
	if items == nil {
		items = []ConvEntry{}
	}
	var oldestTs int64
	if len(items) > 0 {
		if t := parseTimestamp(items[0].Ts); !t.IsZero() {
			oldestTs = t.UnixMilli()
		}
	}
	return TranscriptPage{
		Items:         items,
		HasMoreBefore: false, // forward cursor: we never know about items before sinceTs
		OldestTs:      oldestTs,
		LatestTs:      latestTs,
	}
}

// applyTail returns the last n items (ascending). HasMoreBefore==true when
// there are items before the window.
func applyTail(all []ConvEntry, n int, latestTs int64) TranscriptPage {
	var hasMoreBefore bool
	page := all
	if len(all) > n {
		page = all[len(all)-n:]
		hasMoreBefore = true
	}
	var oldestTs int64
	if len(page) > 0 {
		if t := parseTimestamp(page[0].Ts); !t.IsZero() {
			oldestTs = t.UnixMilli()
		}
	}
	items := page
	if items == nil {
		items = []ConvEntry{}
	}
	return TranscriptPage{
		Items:         items,
		HasMoreBefore: hasMoreBefore,
		OldestTs:      oldestTs,
		LatestTs:      latestTs,
	}
}

// applyFull returns all items, optionally capped to limit (0=no cap).
func applyFull(all []ConvEntry, limit int, latestTs int64) TranscriptPage {
	var (
		page          []ConvEntry
		hasMoreBefore bool
	)
	if limit > 0 && len(all) > limit {
		page = all[len(all)-limit:]
		hasMoreBefore = true
	} else {
		page = all
	}
	var oldestTs int64
	if len(page) > 0 {
		if t := parseTimestamp(page[0].Ts); !t.IsZero() {
			oldestTs = t.UnixMilli()
		}
	}
	items := page
	if items == nil {
		items = []ConvEntry{}
	}
	return TranscriptPage{
		Items:         items,
		HasMoreBefore: hasMoreBefore,
		OldestTs:      oldestTs,
		LatestTs:      latestTs,
	}
}
